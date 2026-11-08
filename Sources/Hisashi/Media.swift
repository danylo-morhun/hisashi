import Foundation
import AppKit

// Now playing comes from the HisashiMedia helper, hosted in /usr/bin/perl
// because MediaRemote answers only Apple-signed processes. See Sources/HisashiMedia.

/// Values are MediaRemote command codes.
enum MediaCommand: UInt32 {
    case toggle = 2
    case next = 4
    case previous = 5
}

/// Runs the helper, turns its lines into players, forwards commands to it.
final class MediaBridge {
    private let onUpdate: ([NowPlaying]) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var players: [NowPlaying] = []

    private static let loader = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "hisashi_media_run") or die "no entry";
    DynaLoader::dl_install_xsub("main::run", $sym);
    run();
    """

    init(onUpdate: @escaping ([NowPlaying]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        guard let lib = Bundle.main.privateFrameworksURL?.appendingPathComponent("libHisashiMedia.dylib") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loader, lib.path]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
        }
        try? process.run()
        self.process = process
        self.input = input.fileHandleForWriting
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    /// MediaRemote only obeys the system's active player. Spotify and Music
    /// take AppleScript at any time, so they get that instead.
    func send(_ command: MediaCommand, to app: String) {
        if let source = PlayerScript.source(app: app, command: command) {
            DispatchQueue.global(qos: .userInitiated).async {
                NSAppleScript(source: source)?.executeAndReturnError(nil)
            }
            return
        }
        let line = #"{"cmd":\#(command.rawValue),"app":"\#(app)"}"# + "\n"
        try? input?.write(contentsOf: Data(line.utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
            guard let next = MediaWire.decode(line, previous: players), next != players else { continue }
            players = next
            onUpdate(next)
        }
    }
}

/// Official scripting for players that support it. Pure mapping.
enum PlayerScript {
    private static let apps = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]

    static func source(app: String, command: MediaCommand) -> String? {
        guard let name = apps[app] else { return nil }
        let verb: String
        switch command {
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        return "tell application \"\(name)\" to \(verb)"
    }
}

/// Wire format of one helper line. Pure decoding, no I/O.
struct MediaWire: Decodable {
    struct Player: Decodable {
        var app: String
        var title: String
        var artist: String?
        var duration: Double?
        var elapsed: Double?
        var timestamp: Double?
        var playing: Bool?
        var artwork: String?
    }

    var players: [Player]

    /// Nil means the line was unreadable and should be ignored.
    static func decode(_ data: Data, previous: [NowPlaying]) -> [NowPlaying]? {
        guard let wire = try? JSONDecoder().decode(MediaWire.self, from: data) else { return nil }
        return wire.players.map { p in
            let artist = p.artist ?? ""
            let old = previous.first { $0.app == p.app && $0.title == p.title && $0.artist == artist }
            // Artwork arrives once per track; keep it while the track stays.
            let artwork = p.artwork.flatMap { Data(base64Encoded: $0) } ?? old?.artwork
            let stamp = p.timestamp ?? 0
            return NowPlaying(
                title: p.title,
                artist: artist,
                duration: p.duration ?? 0,
                elapsed: p.elapsed ?? 0,
                timestamp: stamp > 0 ? Date(timeIntervalSince1970: stamp) : (old?.timestamp ?? Date()),
                isPlaying: p.playing ?? false,
                app: p.app,
                artwork: artwork
            )
        }
    }
}
