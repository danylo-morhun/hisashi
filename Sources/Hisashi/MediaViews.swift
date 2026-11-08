import AppKit
import SwiftUI

/// Closed state while music plays: artwork left of the camera, equalizer right of it.
struct CompactActivity: View {
    let nowPlaying: NowPlaying
    let notch: CGSize

    var body: some View {
        HStack {
            Artwork(nowPlaying: nowPlaying, size: 20, radius: 5)
                .id(nowPlaying.trackKey)
                .transition(.trackSwap)
            Spacer(minLength: notch.width)
            Equalizer(isPlaying: nowPlaying.isPlaying)
        }
        .padding(.horizontal, 10)
        .frame(height: notch.height)
        .animation(.trackSwap, value: nowPlaying.trackKey)
    }
}

struct MediaPane: View {
    let players: [NowPlaying]
    let current: NowPlaying?
    let select: (String) -> Void
    let command: (MediaCommand) -> Void

    var body: some View {
        if let np = current {
            HStack(spacing: 16) {
                ZStack {
                    Artwork(nowPlaying: np, size: 132, radius: 16)
                        .id(np.trackKey)
                        .transition(.artworkSwap)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(np.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                Text(np.artist).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            .id(np.trackKey)
                            .transition(.trackSwap)
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
                if players.count > 1 {
                    SourceSwitcher(players: players, current: np.id, select: select)
                }
            }
            .animation(.trackSwap, value: np.trackKey)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay(Text("Nothing playing").font(.system(size: 13)).foregroundStyle(Theme.muted))
        }
    }
}

/// One small app icon per player. The shown one is in color, the rest are grey.
private struct SourceSwitcher: View {
    let players: [NowPlaying]
    let current: String
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(players, id: \.id) { p in
                SourceButton(player: p, isCurrent: p.id == current) { select(p.id) }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct SourceButton: View {
    let player: NowPlaying
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let icon = AppIcon.image(for: player.app) {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "music.note")
                    }
                }
                .frame(width: 22, height: 22)
                .saturation(isCurrent ? 1 : 0)
                .opacity(isCurrent || isHovered ? 1 : 0.45)
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 3, height: 3)
                    .opacity(player.isPlaying ? 1 : 0)
            }
            .frame(width: 30, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(isCurrent ? Theme.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.title)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}

/// Blur, fade and a small vertical drift: the old track leaves upward, the new one rises in.
private struct SwapEffect: ViewModifier {
    let opacity: Double
    let blur: CGFloat
    let y: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).offset(y: y).scaleEffect(scale)
    }
}

extension AnyTransition {
    static var trackSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapEffect(opacity: 0, blur: 8, y: 10, scale: 1),
                                 identity: SwapEffect(opacity: 1, blur: 0, y: 0, scale: 1)),
            removal: .modifier(active: SwapEffect(opacity: 0, blur: 8, y: -10, scale: 1),
                               identity: SwapEffect(opacity: 1, blur: 0, y: 0, scale: 1))
        )
    }

    static var artworkSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapEffect(opacity: 0, blur: 12, y: 0, scale: 0.88),
                                 identity: SwapEffect(opacity: 1, blur: 0, y: 0, scale: 1)),
            removal: .modifier(active: SwapEffect(opacity: 0, blur: 12, y: 0, scale: 1.06),
                               identity: SwapEffect(opacity: 1, blur: 0, y: 0, scale: 1))
        )
    }
}

extension Animation {
    static let trackSwap = Animation.spring(response: 0.55, dampingFraction: 0.86)
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
                    .animation(.linear(duration: 1), value: fraction)
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

/// Four bars driven by the real sound, see AudioTap. Flat while paused.
struct Equalizer: View {
    let isPlaying: Bool
    @Environment(AudioLevels.self) private var levels

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().frame(width: 3, height: isPlaying ? 3 + 9 * CGFloat(levels.values[i]) : 3)
            }
        }
        .frame(height: 12)
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
