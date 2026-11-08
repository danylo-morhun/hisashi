import AppKit
import SwiftUI

/// Closed state while music plays: artwork left of the camera, equalizer right of it.
struct CompactActivity: View {
    let nowPlaying: NowPlaying
    let notch: CGSize

    var body: some View {
        HStack {
            Artwork(nowPlaying: nowPlaying, size: 20, radius: 5)
            Spacer(minLength: notch.width)
            Equalizer(isPlaying: nowPlaying.isPlaying)
        }
        .padding(.horizontal, 10)
        .frame(height: notch.height)
    }
}

struct MediaPane: View {
    let nowPlaying: NowPlaying?
    let command: (MediaCommand) -> Void

    var body: some View {
        if let np = nowPlaying {
            HStack(spacing: 16) {
                Artwork(nowPlaying: np, size: 132, radius: 16)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(np.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            Text(np.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Equalizer(isPlaying: np.isPlaying).padding(.top, 4)
                    }
                    Spacer(minLength: 8)
                    Progress(nowPlaying: np)
                    Spacer(minLength: 8)
                    Controls(isPlaying: np.isPlaying, command: command)
                }
                .padding(.vertical, 4)
            }
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay(Text("Nothing playing").font(.system(size: 13)).foregroundStyle(Theme.muted))
        }
    }
}

private struct Progress: View {
    let nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = nowPlaying.position(at: context.date)
            let fraction = nowPlaying.duration > 0 ? position / nowPlaying.duration : 0
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule().fill(Theme.ink).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(clock(position))
                    Spacer()
                    Text(clock(nowPlaying.duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
            }
            .animation(.linear(duration: 1), value: fraction)
        }
    }
}

private struct Controls: View {
    let isPlaying: Bool
    let command: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: 28) {
            PlayerButton(symbol: "backward.fill", size: 17, label: "Previous") { command(.previous) }
            PlayerButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 24, label: "Play or pause") { command(.toggle) }
            PlayerButton(symbol: "forward.fill", size: 17, label: "Next") { command(.next) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .foregroundStyle(isHovered ? Theme.ink : Theme.ink.opacity(0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }
}

/// Album art, or the player's app icon when the track has none.
struct Artwork: View {
    let nowPlaying: NowPlaying
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let data = nowPlaying.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.surface
                if let icon = AppIcon.image(for: nowPlaying.app) {
                    Image(nsImage: icon).resizable().frame(width: size * 0.6, height: size * 0.6)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

enum AppIcon {
    static func image(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct Equalizer: View {
    let isPlaying: Bool
    private static let speeds: [Double] = [5.1, 7.3, 4.2, 6.4]
    private static let phases: [Double] = [0, 1.7, 3.1, 0.9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().frame(width: 3, height: isPlaying ? Self.height(t, i) : 3)
                }
            }
            .frame(height: 12)
        }
    }

    static func height(_ t: Double, _ i: Int) -> CGFloat {
        CGFloat(3 + 9 * (0.5 + 0.5 * sin(t * speeds[i] + phases[i])))
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
