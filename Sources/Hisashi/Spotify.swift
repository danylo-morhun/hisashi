import AppKit
import CryptoKit
import Foundation
import Network
import Observation

/// One song offered while nothing plays.
struct Pick: Equatable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let art: URL?
    let duration: Double
    /// Why it is offered: when it was liked, or that it is played a lot.
    let note: String
    /// The playlist it came from; playing it then goes on through that playlist.
    var context: String?
}

/// Where the picks come from.
enum PickSource: Hashable {
    case mix, liked, top, forgotten
    case playlist(id: String, name: String)

    var title: String {
        switch self {
        case .mix: return "Mix"
        case .liked: return "Liked"
        case .top: return "Top"
        case .forgotten: return "Forgotten"
        case .playlist(_, let name): return name
        }
    }
}

/// Random songs from the listener's Spotify, drawn again on request.
/// The library is read once and again after six hours; playlists when first opened.
@MainActor
@Observable
final class Picks {
    enum Phase: Equatable { case signedOut, signingIn, loading, ready, failed }

    private(set) var phase: Phase
    private(set) var sources: [PickSource] = [.mix, .liked, .top, .forgotten]
    private(set) var source: PickSource = .mix
    private(set) var shown: [Pick] = []
    /// The song just picked, shown in the player until Spotify reports it playing.
    private(set) var starting: Pick?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var pools: [PickSource: [Pick]] = [:]
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let api = SpotifyAPI()

    static let count = 6

    init() {
        phase = SpotifyAPI.isConnected ? .loading : .signedOut
    }

    /// Called whenever the picks come into view.
    func wake() {
        guard phase != .signedOut, phase != .signingIn else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 6 * 3600 { return }
        load()
    }

    func connect() {
        phase = .signingIn
        Task {
            do {
                try await api.signIn()
                load()
            } catch {
                phase = .signedOut
            }
        }
    }

    func select(_ next: PickSource) {
        source = next
        if pools[next] != nil || next == .mix { return shuffle() }
        guard case .playlist(let id, _) = next else { return shuffle() }
        shown = []
        Task {
            let picks = (try? await api.playlist(id)) ?? []
            pools[next] = picks
            if source == next { shuffle() }
        }
    }

    /// A fresh draw, avoiding what is on screen while the source has enough.
    func shuffle() {
        let old = Set(shown.map(\.id))
        if source == .mix {
            var drawn: [Pick] = []
            for part in [PickSource.liked, .top, .forgotten] {
                let pool = (pools[part] ?? []).filter { p in !drawn.contains { $0.id == p.id } }
                drawn += Self.draw(pool, Self.count / 3, avoiding: old)
            }
            if drawn.count < Self.count {
                let rest = (pools[.liked] ?? []).filter { p in !drawn.contains { $0.id == p.id } }
                drawn += Self.draw(rest, Self.count - drawn.count, avoiding: old)
            }
            shown = drawn.shuffled()
        } else {
            shown = Self.draw(pools[source] ?? [], Self.count, avoiding: old)
        }
    }

    /// Starts the song's radio; when the Web API cannot, the app plays it in its album.
    /// The player shows the song at once and lets go when Spotify reports it, or after 15 s.
    func play(_ pick: Pick) {
        starting = pick
        startTask?.cancel()
        startTask = Task {
            do { try await api.radio(pick.id) } catch { Spotify.play(pick) }
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, starting?.id == pick.id { starting = nil }
        }
    }

    /// Called with each new track; the picked one arriving ends the stand-in.
    func arrived(_ title: String?) {
        guard let pick = starting, let title, Self.same(title, pick.title) else { return }
        starting = nil
        startTask?.cancel()
    }

    /// Spotify may name a track a little differently in the system's now playing.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    private func load() {
        guard !loading else { return }
        loading = true
        if shown.isEmpty { phase = .loading }
        Task {
            defer { loading = false }
            do {
                let library = try await api.library()
                pools = [.liked: library.liked, .top: library.top, .forgotten: library.forgotten]
                sources = [.mix, .liked, .top, .forgotten] + library.playlists.map { .playlist(id: $0.id, name: $0.name) }
                if !sources.contains(source) { source = .mix }
                loadedAt = Date()
                phase = .ready
                shuffle()
            } catch SpotifyAPI.Failure.signedOut {
                phase = .signedOut
            } catch {
                if shown.isEmpty { phase = .failed }
            }
        }
    }

    private static func draw(_ pool: [Pick], _ n: Int, avoiding: Set<String>) -> [Pick] {
        let fresh = pool.filter { !avoiding.contains($0.id) }
        let from = fresh.count >= n ? fresh : pool
        return Array(from.shuffled().prefix(n))
    }
}

enum Spotify {
    static let bundleID = "com.spotify.client"

    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// The desktop app plays it in its album: needs no Premium, but there is no radio this way.
    /// The first time macOS asks to allow it.
    static func play(_ pick: Pick) {
        let track = "spotify:track:\(pick.id)"
        let context = pick.context.map { " in context \"spotify:playlist:\($0)\"" } ?? ""
        let script = "tell application \"Spotify\" to play track \"\(track)\"\(context)"
        DispatchQueue.global().async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }
}

/// The Web API as the listener: sign-in with PKCE through a loopback page, then plain reads.
actor SpotifyAPI {
    enum Failure: Error { case signedOut, failed }

    struct Library {
        var liked: [Pick]
        var top: [Pick]
        var forgotten: [Pick]
        var playlists: [(id: String, name: String)]
    }

    private struct Token: Codable {
        var access: String
        var refresh: String
        var expires: Date
        var scope: String?
    }

    static let clientID = "74808c92d4ec41b19058059a80313f4b"
    static let radioName = "hisashi radio"
    static let port: UInt16 = 51853
    static var redirect: String { "http://127.0.0.1:\(port)/callback" }
    static let scopes = "user-library-read user-top-read user-read-recently-played playlist-read-private "
        + "user-read-playback-state user-modify-playback-state playlist-modify-private"

    /// ~/Library/Application Support/Hisashi/spotify.json, readable only by the user.
    static var tokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Hisashi/spotify.json")
    }

    /// Signed in with every scope asked for now; a token from before a new scope means signing in again.
    nonisolated static var isConnected: Bool {
        guard let data = try? Data(contentsOf: tokenFile), let token = try? JSONDecoder().decode(Token.self, from: data) else { return false }
        let granted = Set((token.scope ?? "").split(separator: " "))
        return scopes.split(separator: " ").allSatisfy(granted.contains)
    }

    private var token: Token?
    private var refreshing: Task<Void, Error>?

    init() {
        token = (try? Data(contentsOf: Self.tokenFile)).flatMap { try? JSONDecoder().decode(Token.self, from: $0) }
    }

    // MARK: Sign-in

    func signIn() async throws {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: Self.clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        let catcher = try LoopbackCatcher(port: Self.port)
        await MainActor.run { _ = NSWorkspace.shared.open(url.url!) }
        let reply = try await catcher.wait()
        guard reply["state"] == state, let code = reply["code"] else { throw Failure.signedOut }
        try await exchange([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
            "client_id": Self.clientID, "code_verifier": verifier,
        ])
    }

    private func exchange(_ form: [String: String]) async throws {
        struct Reply: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String? }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { forget(); throw Failure.signedOut }
        guard status == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.failed }
        // Spotify may hand out a new refresh token; without one the old stays valid.
        let refresh = reply.refresh_token ?? token?.refresh ?? ""
        let next = Token(access: reply.access_token, refresh: refresh, expires: Date().addingTimeInterval(reply.expires_in - 60),
                         scope: reply.scope ?? token?.scope)
        token = next
        save(next)
    }

    private func save(_ token: Token) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let file = Self.tokenFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private func forget() {
        token = nil
        try? FileManager.default.removeItem(at: Self.tokenFile)
    }

    /// Parallel reads share one refresh: a rotated refresh token is good only once.
    private func access() async throws -> String {
        guard let token else { throw Failure.signedOut }
        if token.expires > Date() { return token.access }
        if let refreshing { try await refreshing.value } else {
            let task = Task { try await self.exchange(["grant_type": "refresh_token", "refresh_token": token.refresh,
                                                       "client_id": Self.clientID]) }
            refreshing = task
            defer { refreshing = nil }
            try await task.value
        }
        guard let fresh = self.token else { throw Failure.signedOut }
        return fresh.access
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         retried: Bool = false) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        request.httpMethod = method
        request.setValue("Bearer " + (try await access()), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            guard !retried else { throw Failure.signedOut }
            // The token died before its time: refresh once.
            token?.expires = .distantPast
            return try await self.request(method, path, body: body, retried: true)
        }
        return (data, status)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, status) = try await request("GET", path)
        guard status == 200 else { throw Failure.failed }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        let (_, status) = try await request(method, path, body: body)
        guard (200..<300).contains(status) else { throw Failure.failed }
    }

    // MARK: Playback (Premium only)

    /// The desktop app drops a bare track sent through the Web API (204, then an empty player),
    /// but takes a playlist. So the track goes alone into a new private playlist that is played:
    /// when it ends, Spotify's autoplay goes on with songs like it, as after a search.
    /// Autoplay is worked out once per playlist, hence a new one each time; the old ones are
    /// deleted once the new one plays (a deleted playlist does not play), so the library keeps one.
    /// Repeat would loop that one track forever, so it goes off first.
    func radio(_ track: String) async throws {
        async let device = device()
        let list = try await newRadioList(with: track)
        let target = try await device
        try? await send("PUT", "/me/player/repeat?state=off&device_id=\(target)")
        try await send("PUT", "/me/player/play?device_id=\(target)", body: [
            "context_uri": "spotify:playlist:\(list)", "offset": ["uri": "spotify:track:\(track)"], "position_ms": 0,
        ])
        if let lists = try? await get("/me/playlists?limit=50", as: Page<Playlist>.self) {
            for old in lists.items where old.name == Self.radioName && old.id != list {
                try? await send("DELETE", "/playlists/\(old.id)/followers")
            }
        }
    }

    private func newRadioList(with track: String) async throws -> String {
        struct Made: Decodable { let id: String }
        let (data, status) = try await request("POST", "/me/playlists", body: [
            "name": Self.radioName, "public": false,
            "description": "The song hisashi started a radio from. Replaced on the next one.",
        ])
        guard (200..<300).contains(status), let made = try? JSONDecoder().decode(Made.self, from: data) else { throw Failure.failed }
        try await send("POST", "/playlists/\(made.id)/items", body: ["uris": ["spotify:track:\(track)"]])
        return made.id
    }

    /// This Mac's Spotify, started in the background when it is not running.
    private func device() async throws -> String {
        struct Devices: Decodable {
            struct Device: Decodable { let id: String?; let is_active: Bool; let type: String; let is_restricted: Bool? }
            let devices: [Device]
        }
        for attempt in 0..<20 {
            let all = try await get("/me/player/devices", as: Devices.self).devices
                .filter { $0.id != nil && $0.is_restricted != true }
            let computers = all.filter { $0.type == "Computer" }
            if let d = computers.first(where: \.is_active) ?? computers.first, let id = d.id { return id }
            if attempt == 0 { await MainActor.run { Spotify.launch() } }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure.failed
    }

    // MARK: Reads

    private struct Page<Item: Decodable>: Decodable { let items: [Item]; let total: Int? }
    private struct Image: Decodable { let url: URL; let width: Int? }
    private struct Album: Decodable { let images: [Image]? }
    private struct Artist: Decodable { let name: String }
    private struct Track: Decodable {
        let id: String?
        let name: String
        let type: String?
        let artists: [Artist]?
        let album: Album?
        let duration_ms: Double?
    }
    /// A liked song or a playlist entry; playlists name the track `item` since 2026, `track` before.
    private struct Entry: Decodable { let added_at: String?; let track: Track?; let item: Track? }
    private struct Played: Decodable { let track: Track }
    private struct Playlist: Decodable { let id: String; let name: String }

    func library() async throws -> Library {
        async let liked = likedSongs()
        async let short = top("short_term")
        async let medium = top("medium_term")
        async let long = top("long_term")
        async let recent = get("/me/player/recently-played?limit=50", as: Page<Played>.self)
        async let lists = get("/me/playlists?limit=50", as: Page<Playlist>.self)

        let saved = try await liked
        let (now, mid, ever) = try await (short, medium, long)
        let heard = Set((try await recent).items.compactMap(\.track.id))
        let busy = heard.union(now.compactMap(\.id)).union(mid.compactMap(\.id))
        let halfYear = Date().addingTimeInterval(-182 * 86400)
        let forgotten = saved.filter { $0.added < halfYear && !busy.contains($0.pick.id) }.map(\.pick)

        var top: [Pick] = []
        for p in Self.picks(now, note: "on repeat") + Self.picks(ever, note: "all-time") where !top.contains(where: { $0.id == p.id }) {
            top.append(p)
        }
        let playlists = (try await lists).items.filter { $0.name != Self.radioName }.map { (id: $0.id, name: $0.name) }
        return Library(liked: saved.map(\.pick), top: top, forgotten: forgotten, playlists: playlists)
    }

    func playlist(_ id: String) async throws -> [Pick] {
        let first = try await get("/playlists/\(id)/items?limit=50", as: Page<Entry>.self)
        var entries = first.items
        let total = min(first.total ?? 0, 1000)
        try await withThrowingTaskGroup(of: [Entry].self) { group in
            for offset in stride(from: 50, to: total, by: 50) {
                group.addTask { try await self.get("/playlists/\(id)/items?limit=50&offset=\(offset)", as: Page<Entry>.self).items }
            }
            for try await page in group { entries += page }
        }
        return entries.compactMap { e in
            guard let t = e.item ?? e.track, var p = Self.pick(t, note: Self.addedNote(e.added_at, prefix: "added")) else { return nil }
            p.context = id
            return p
        }
    }

    private func likedSongs() async throws -> [(pick: Pick, added: Date)] {
        let first = try await get("/me/tracks?limit=50", as: Page<Entry>.self)
        var entries = first.items
        let total = min(first.total ?? 0, 3000)
        try await withThrowingTaskGroup(of: [Entry].self) { group in
            for offset in stride(from: 50, to: total, by: 50) {
                group.addTask { try await self.get("/me/tracks?limit=50&offset=\(offset)", as: Page<Entry>.self).items }
            }
            for try await page in group { entries += page }
        }
        return entries.compactMap { e in
            guard let t = e.track ?? e.item, let p = Self.pick(t, note: Self.addedNote(e.added_at, prefix: "liked")) else { return nil }
            return (p, Self.date(e.added_at) ?? .distantPast)
        }
    }

    private func top(_ range: String) async throws -> [Track] {
        try await get("/me/top/tracks?time_range=\(range)&limit=50", as: Page<Track>.self).items
    }

    private static func picks(_ tracks: [Track], note: String) -> [Pick] {
        tracks.compactMap { pick($0, note: note) }
    }

    private static func pick(_ t: Track, note: String) -> Pick? {
        guard let id = t.id, t.type == nil || t.type == "track" else { return nil }
        let images = (t.album?.images ?? []).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        // 64 px is too soft on a Retina screen at 34 pt.
        let art = images.first { ($0.width ?? 0) >= 100 }?.url ?? images.last?.url
        return Pick(id: id, title: t.name, artist: (t.artists ?? []).map(\.name).joined(separator: ", "), art: art,
                    duration: (t.duration_ms ?? 0) / 1000, note: note)
    }

    private static func date(_ text: String?) -> Date? {
        text.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// "liked 2023", or the month within the last year.
    private static func addedNote(_ text: String?, prefix: String) -> String {
        guard let date = date(text) else { return "" }
        let format = date > Date().addingTimeInterval(-330 * 86400) ? "MMM" : "yyyy"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return prefix + " " + f.string(from: date).lowercased()
    }

    private static func randomString(_ count: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<count).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Waits for the browser to come back to the redirect address, answers it with a short page,
/// and hands over the query. Gives up after five minutes.
final class LoopbackCatcher {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func wait() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.main.async {
                self.continuation = c
                self.listener.newConnectionHandler = { [weak self] in self?.serve($0) }
                self.listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state { self?.finish(.failure(error)) }
                }
                self.listener.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                    self?.finish(.failure(SpotifyAPI.Failure.signedOut))
                }
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : ""
            let url = URLComponents(string: target)
            let isCallback = url?.path == "/callback"
            let page = isCallback
                ? "<!doctype html><meta charset=utf-8><title>hisashi</title><body style=\"background:#000;color:#f5f5f7;font:15px -apple-system;display:grid;place-items:center;height:90vh\">spotify is connected. this tab can be closed."
                : ""
            let head = isCallback ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found"
            let reply = "\(head)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isCallback else { return }
            var query: [String: String] = [:]
            for item in url?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            self?.finish(.success(query))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        listener.cancel()
        c.resume(with: result)
    }
}
