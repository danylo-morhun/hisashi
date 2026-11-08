import Foundation

// Since macOS 15.4 MediaRemote answers only Apple-signed processes.
// osascript is one, so it reads now playing and sends commands for us.

enum MediaCommand: UInt32 {
    case toggle = 2
    case next = 4
    case previous = 5
}

/// Keeps one osascript process alive that prints a JSON line whenever now playing changes.
final class MediaBridge {
    private let onUpdate: (NowPlaying?) -> Void
    private var process: Process?
    private var buffer = Data()
    private var current: NowPlaying?

    init(onUpdate: @escaping (NowPlaying?) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Scripts.stream]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
        }
        try? process.run()
        self.process = process
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    static func send(_ command: MediaCommand) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Scripts.command(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
            let next = MediaMessage.decode(line, previous: current)
            if next != current {
                current = next
                onUpdate(next)
            }
        }
    }
}

/// Wire format of one stream line. Pure decoding, no I/O.
struct MediaMessage: Decodable {
    var empty: Bool?
    var title: String?
    var artist: String?
    var duration: Double?
    var elapsed: Double?
    var timestamp: Double?
    var playing: Bool?
    var app: String?
    var artwork: String?

    static func decode(_ data: Data, previous: NowPlaying?) -> NowPlaying? {
        guard let m = try? JSONDecoder().decode(MediaMessage.self, from: data) else { return previous }
        guard m.empty != true, let title = m.title, !title.isEmpty else { return nil }
        let artist = m.artist ?? ""
        let sameTrack = previous?.title == title && previous?.artist == artist
        // Artwork is sent once per track to keep lines small.
        let artwork = m.artwork.flatMap { Data(base64Encoded: $0) } ?? (sameTrack ? previous?.artwork : nil)
        return NowPlaying(
            title: title,
            artist: artist,
            duration: m.duration ?? 0,
            elapsed: m.elapsed ?? 0,
            timestamp: m.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            isPlaying: m.playing ?? false,
            app: m.app ?? "",
            artwork: artwork
        )
    }
}

private enum Scripts {
    static let prelude = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    """

    static let stream = prelude + """
    const R = $.NSClassFromString('MRNowPlayingRequest');
    const out = $.NSFileHandle.fileHandleWithStandardOutput;
    const K = 'kMRMediaRemoteNowPlayingInfo';
    const val = (info, k) => { const v = info.objectForKey(K + k); return v.isNil() ? null : ObjC.unwrap(v); };
    let last = '', artKey = '';
    while (true) {
      let msg = { empty: true };
      const item = R.localNowPlayingItem;
      const info = item.isNil() ? null : item.nowPlayingInfo;
      if (info && !info.isNil()) {
        const ts = info.objectForKey(K + 'Timestamp');
        msg = {
          title: val(info, 'Title') || '',
          artist: val(info, 'Artist') || '',
          duration: val(info, 'Duration') || 0,
          elapsed: val(info, 'ElapsedTime') || 0,
          timestamp: ts.isNil() ? Date.now() / 1000 : ts.timeIntervalSince1970,
          playing: R.localIsPlaying,
          app: ObjC.unwrap(R.localNowPlayingPlayerPath.client.bundleIdentifier) || ''
        };
        const art = info.objectForKey(K + 'ArtworkData');
        const key = msg.title + '|' + msg.artist;
        if (!art.isNil() && key !== artKey) {
          msg.artwork = ObjC.unwrap(art.base64EncodedStringWithOptions(0));
          artKey = key;
        }
      }
      const line = JSON.stringify(msg);
      if (line !== last) {
        out.writeData($(line + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
        last = line;
      }
      delay(0.5);
    }
    """

    static func command(_ id: UInt32) -> String {
        prelude + """
        ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['unsigned int', 'id']]);
        $.MRMediaRemoteSendCommand(\(id), $());
        """
    }
}
