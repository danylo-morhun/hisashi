import Foundation
import ObjectiveC

// Runs inside /usr/bin/perl. MediaRemote answers only Apple-signed processes,
// and perl is one that will load this library.
// Out: one JSON line on stdout whenever any player changes.
// In: one JSON command per line on stdin, {"cmd": 2, "app": "com.spotify.client"}.

@_cdecl("hisashi_media_run")
public func hisashiMediaRun(_: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?) {
    guard let remote = Remote() else { exit(2) }
    let service = Service(remote: remote)
    service.start()
    dispatchMain()
}

/// Typed wrapper over the few private MediaRemote calls we use.
final class Remote {
    private typealias GetClients = @convention(c) (DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
    private typealias InitPath = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<NSObject>?
    private typealias InitRequest = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<NSObject>?
    private typealias RequestInfo = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (NSDictionary?, NSError?) -> Void) -> Void
    private typealias SendCommand = @convention(c) (AnyObject, Selector, UInt32, NSDictionary?, DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void

    private let getClients: GetClients
    private let pathClass: AnyClass
    private let requestClass: AnyClass
    private let origin: AnyObject?

    init?() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(lib, "MRMediaRemoteGetNowPlayingClients"),
              let pathClass = NSClassFromString("MRPlayerPath"),
              let requestClass = NSClassFromString("MRNowPlayingRequest"),
              let originClass = NSClassFromString("MROrigin") as? NSObject.Type
        else { return nil }
        getClients = unsafeBitCast(sym, to: GetClients.self)
        self.pathClass = pathClass
        self.requestClass = requestClass
        origin = originClass.perform(NSSelectorFromString("localOrigin"))?.takeUnretainedValue()
    }

    func clients(on queue: DispatchQueue, _ done: @escaping ([NSObject]) -> Void) {
        getClients(queue) { done(($0 as? [NSObject]) ?? []) }
    }

    func request(for client: NSObject) -> NSObject? {
        let initPath = NSSelectorFromString("initWithOrigin:client:player:")
        let initRequest = NSSelectorFromString("initWithPlayerPath:")
        let makePath = unsafeBitCast(class_getMethodImplementation(pathClass, initPath), to: InitPath.self)
        let makeRequest = unsafeBitCast(class_getMethodImplementation(requestClass, initRequest), to: InitRequest.self)
        guard let path = makePath(alloc(pathClass), initPath, origin, client, nil)?.takeRetainedValue() else { return nil }
        return makeRequest(alloc(requestClass), initRequest, path)?.takeRetainedValue()
    }

    func info(_ request: NSObject, on queue: DispatchQueue, _ done: @escaping ([String: Any]?) -> Void) {
        let sel = NSSelectorFromString("requestNowPlayingInfoOnQueue:completion:")
        let call = unsafeBitCast(class_getMethodImplementation(requestClass, sel), to: RequestInfo.self)
        call(request, sel, queue) { info, _ in done(info as? [String: Any]) }
    }

    func send(_ command: UInt32, to request: NSObject, on queue: DispatchQueue) {
        let sel = NSSelectorFromString("sendCommand:options:queue:completion:")
        let call = unsafeBitCast(class_getMethodImplementation(requestClass, sel), to: SendCommand.self)
        call(request, sel, command, nil, queue) { _ in }
    }

    private func alloc(_ cls: AnyClass) -> AnyObject {
        // init consumes the allocated object, so it is not released here.
        (cls as! NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue()
    }
}

/// Polls all players twice a second and answers commands.
final class Service {
    private let remote: Remote
    private let queue = DispatchQueue(label: "hisashi.media")
    private var requests: [String: (key: String, request: NSObject)] = [:]
    private var lastLine = ""
    private var sentArtwork: [String: String] = [:]

    init(remote: Remote) {
        self.remote = remote
    }

    func start() {
        Thread.detachNewThread { [weak self] in self?.readCommands() }
        queue.async { self.tick() }
    }

    private func tick() {
        remote.clients(on: queue) { clients in
            var players: [[String: Any]] = []
            let group = DispatchGroup()
            var alive: Set<String> = []
            for client in clients {
                guard let app = client.value(forKey: "bundleIdentifier") as? String,
                      let request = self.request(app: app, client: client) else { continue }
                alive.insert(app)
                group.enter()
                self.remote.info(request, on: self.queue) { info in
                    if let player = Self.player(app: app, info: info) { players.append(player) }
                    group.leave()
                }
            }
            group.notify(queue: self.queue) {
                self.requests = self.requests.filter { alive.contains($0.key) }
                self.emit(players.sorted { ($0["app"] as? String ?? "") < ($1["app"] as? String ?? "") })
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.tick() }
            }
        }
    }

    private func request(app: String, client: NSObject) -> NSObject? {
        let key = "\(app)#\(client.value(forKey: "processIdentifier") ?? "")"
        if let cached = requests[app], cached.key == key { return cached.request }
        guard let request = remote.request(for: client) else { return nil }
        requests[app] = (key, request)
        return request
    }

    private static func player(app: String, info: [String: Any]?) -> [String: Any]? {
        let k = "kMRMediaRemoteNowPlayingInfo"
        guard let info, let title = info[k + "Title"] as? String, !title.isEmpty else { return nil }
        var p: [String: Any] = [
            "app": app,
            "title": title,
            "artist": info[k + "Artist"] as? String ?? "",
            "duration": info[k + "Duration"] as? Double ?? 0,
            "elapsed": info[k + "ElapsedTime"] as? Double ?? 0,
            "timestamp": (info[k + "Timestamp"] as? Date)?.timeIntervalSince1970 ?? 0,
            "playing": (info[k + "PlaybackRate"] as? Double ?? 0) > 0,
        ]
        if let art = info[k + "ArtworkData"] as? Data { p["artworkData"] = art }
        return p
    }

    private func emit(_ players: [[String: Any]]) {
        // Compare without artwork and timestamps that drift while nothing changes.
        let plain = players.map { $0.filter { $0.key != "artworkData" } }
        guard let plainLine = Self.json(["players": plain]) else { return }
        var out = plain
        var newArtwork = false
        for (i, p) in players.enumerated() {
            guard let art = p["artworkData"] as? Data, let app = p["app"] as? String else { continue }
            let key = "\(p["title"] ?? "")|\(p["artist"] ?? "")"
            if sentArtwork[app] != key {
                out[i]["artwork"] = art.base64EncodedString()
                sentArtwork[app] = key
                newArtwork = true
            }
        }
        guard newArtwork || plainLine != lastLine, let line = Self.json(["players": out]) else { return }
        lastLine = plainLine
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func readCommands() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = obj["cmd"] as? Int, let app = obj["app"] as? String else { continue }
            queue.async {
                guard let request = self.requests[app]?.request else { return }
                self.remote.send(UInt32(cmd), to: request, on: self.queue)
            }
        }
        exit(0) // stdin closed: the app is gone.
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
