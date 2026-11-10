import SwiftUI

/// Shown in the media tab while nothing plays: a few random songs from Spotify, by source.
struct PicksPane: View {
    /// Back to the player, when there is one.
    var back: (() -> Void)?
    /// Shared with the player, so a picked song's cover grows into the big one.
    let art: Namespace.ID
    @Environment(Picks.self) private var picks

    var body: some View {
        Group {
            switch picks.phase {
            case .ready:
                PickList(picks: picks, back: back, art: art)
            case .signedOut:
                Quiet(line: "Pick a song from Spotify when nothing plays",
                      button: "Connect Spotify") { picks.connect() }
            case .signingIn:
                Quiet(line: "Waiting for Spotify in the browser…")
            case .loading:
                Quiet(line: "Reading your library…")
            case .failed:
                Quiet(line: "Spotify did not answer", button: "Try again") { picks.wake() }
            }
        }
        .onAppear { picks.wake() }
    }
}

private struct PickList: View {
    let picks: Picks
    let back: (() -> Void)?
    let art: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let back {
                    IconButton(symbol: "chevron.left", label: "Back to the player", isOn: false, width: 26, action: back)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(picks.sources, id: \.self) { source in
                            SourceTab(title: source.title, isOn: source == picks.source) { picks.select(source) }
                        }
                    }
                }
                AgainButton { picks.shuffle() }
            }
            .frame(height: 26)
            if picks.shown.isEmpty {
                Text("Reading the playlist…")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(picks.shown) { pick in
                        PickRow(pick: pick, art: art) {
                            withAnimation(.trackSwap) { picks.play(pick) }
                        }
                            .transition(.trackSwap)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .animation(.trackSwap, value: picks.shown.map(\.id))
    }
}

/// A source, drawn like the tab buttons above it.
private struct SourceTab: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .foregroundStyle(isOn ? Theme.ink : Theme.muted)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.raised : (isHovered ? Theme.surface : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

private struct AgainButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "shuffle").font(.system(size: 10, weight: .semibold))
                Text("Again").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(isHovered ? Theme.ink : Theme.soft)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Theme.raised : Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle again")
        .onHover { isHovered = $0 }
    }
}

private struct PickRow: View {
    let pick: Pick
    let art: Namespace.ID
    let play: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                ZStack {
                    PickCover(url: pick.art)
                        .matchedGeometryEffect(id: pick.id, in: art)
                    if isHovered {
                        Color.black.opacity(0.45)
                        Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pick.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(pick.artist).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(pick.note).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1).fixedSize()
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(pick.title) by \(pick.artist)")
        .onHover { isHovered = $0 }
    }
}

/// The empty pane with one line and maybe one button.
private struct Quiet: View {
    let line: String
    var button: String?
    var action: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.surface)
            .overlay {
                VStack(spacing: 10) {
                    Text(line).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    if let button {
                        Button(action: action) {
                            Text(button)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .foregroundStyle(Theme.ink)
                                .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Theme.card : Theme.raised))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered = $0 }
                    }
                }
            }
    }
}

/// A song's cover from Spotify; the same request serves the small and the big one.
struct PickCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Theme.surface
        }
    }
}
