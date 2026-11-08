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
    private typealias EnableOverride = @convention(c) (Bool) -> Void
    private typealias SetOverride = @convention(c) (CFString?) -> Void
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias ActivePID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void

    private let getClients: GetClients
    private let enableOverride: EnableOverride
    private let setOverride: SetOverride
    private let sendCommand: SendCommand
    private let activePID: ActivePID
    private let pathClass: AnyClass
    private let requestClass: AnyClass
    private let origin: AnyObject?

    init?() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(lib, "MRMediaRemoteGetNowPlayingClients"),
              let enableSym = dlsym(lib, "MRMediaRemoteSetNowPlayingApplicationOverrideEnabled"),
              let overrideSym = dlsym(lib, "MRMediaRemoteSetOverriddenNowPlayingApplication"),
              let sendSym = dlsym(lib, "MRMediaRemoteSendCommand"),
              let pidSym = dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationPID"),
              let pathClass = NSClassFromString("MRPlayerPath"),
              let requestClass = NSClassFromString("MRNowPlayingRequest"),
              let originClass = NSClassFromString("MROrigin") as? NSObject.Type
        else { return nil }
        getClients = unsafeBitCast(sym, to: GetClients.self)
        enableOverride = unsafeBitCast(enableSym, to: EnableOverride.self)
        setOverride = unsafeBitCast(overrideSym, to: SetOverride.self)
        sendCommand = unsafeBitCast(sendSym, to: SendCommand.self)
        activePID = unsafeBitCast(pidSym, to: ActivePID.self)
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

    /// Commands only reach the system's active player. If the target is that
    /// player, send plainly. Otherwise briefly make its app the active one.
    /// An app with several player processes cannot be narrowed to one this way.
    func send(_ command: UInt32, to app: String, pid: Int32, on queue: DispatchQueue, done: @escaping () -> Void) {
        activePID(queue) { [self] active in
            if active == pid {
                _ = sendCommand(command, nil)
                return done()
            }
            enableOverride(true)
            setOverride(app as CFString)
            queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                _ = sendCommand(command, nil)
                queue.asyncAfter(deadline: .now() + 0.4) { [self] in
                    setOverride(nil)
                    enableOverride(false)
                    done()
                }
            }
        }
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
    /// One request per player process, keyed "bundle#pid".
    private var requests: [String: NSObject] = [:]
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
                      let pid = client.value(forKey: "processIdentifier") as? Int32 else { continue }
                let id = "\(app)#\(pid)"
                guard let request = self.request(id: id, client: client) else { continue }
                alive.insert(id)
                group.enter()
                self.remote.info(request, on: self.queue) { info in
                    if let player = Self.player(app: app, pid: pid, info: info) { players.append(player) }
                    group.leave()
                }
            }
            group.notify(queue: self.queue) {
                self.requests = self.requests.filter { alive.contains($0.key) }
                self.emit(players.sorted { Self.id($0) < Self.id($1) })
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.tick() }
            }
        }
    }

    private func request(id: String, client: NSObject) -> NSObject? {
        if let cached = requests[id] { return cached }
        guard let request = remote.request(for: client) else { return nil }
        requests[id] = request
        return request
    }

    private static func id(_ player: [String: Any]) -> String {
        "\(player["app"] ?? "")#\(player["pid"] ?? "")"
    }

    private static func player(app: String, pid: Int32, info: [String: Any]?) -> [String: Any]? {
        let k = "kMRMediaRemoteNowPlayingInfo"
        guard let info, let title = info[k + "Title"] as? String, !title.isEmpty else { return nil }
        var p: [String: Any] = [
            "app": app,
            "pid": pid,
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
            guard let art = p["artworkData"] as? Data else { continue }
            let id = Self.id(p)
            let key = "\(p["title"] ?? "")|\(p["artist"] ?? "")"
            if sentArtwork[id] != key {
                out[i]["artwork"] = art.base64EncodedString()
                sentArtwork[id] = key
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
                  let cmd = obj["cmd"] as? Int, let app = obj["app"] as? String,
                  let pid = obj["pid"] as? Int else { continue }
            // One command at a time, so overrides never overlap.
            let finished = DispatchSemaphore(value: 0)
            queue.async { self.remote.send(UInt32(cmd), to: app, pid: Int32(pid), on: self.queue) { finished.signal() } }
            finished.wait()
        }
        exit(0) // stdin closed: the app is gone.
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
