import Foundation

// Pure rules: state, actions, reducer, layout. No AppKit, no side effects.

enum Tab: CaseIterable, Equatable {
    case media, today, shelf, focus, life
}

enum Tone: Equatable {
    case neutral, success, warning, failure
}

struct NotchEvent: Equatable {
    let title: String
    let subtitle: String
    let tone: Tone
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var isPlaying: Bool
    var app: String
    /// Process of the player; one app can run several (browser profiles).
    var pid: Int32
    var artwork: Data?

    var id: String { "\(app)#\(pid)" }

    /// Changes when the player or the track changes; drives the swap animation.
    var trackKey: String { id + "|" + title + "|" + artist }

    /// Playback position now, extrapolated from the last snapshot.
    func position(at now: Date) -> Double {
        let p = elapsed + (isPlaying ? now.timeIntervalSince(timestamp) : 0)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

/// Volume or brightness feedback shown in place of the system popup.
struct Hud: Equatable {
    enum Kind: Equatable { case volume, brightness }
    var kind: Kind
    var level: Float
    var muted = false
}

/// Hardware keys the notch answers instead of the system.
enum SystemKey: Int {
    // NX_KEYTYPE codes.
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

enum Levels {
    /// One key press: 1/16 like macOS, 1/64 with Option+Shift. Snaps to the step grid.
    static func step(_ level: Float, up: Bool, fine: Bool) -> Float {
        let step: Float = fine ? 1 / 64 : 1 / 16
        let next = ((level + (up ? step : -step)) / step).rounded() * step
        return min(1, max(0, next))
    }

    /// New volume and mute after a key. Volume up unmutes, as in macOS.
    static func volume(_ key: SystemKey, level: Float, muted: Bool, fine: Bool) -> (level: Float, muted: Bool) {
        switch key {
        case .mute: return (level, !muted)
        case .volumeUp: return (step(level, up: true, fine: fine), false)
        case .volumeDown: return (step(level, up: false, fine: fine), muted)
        default: return (level, muted)
        }
    }
}

enum NotchMode: Equatable {
    case compact, open, event, hud
}

struct NotchState: Equatable {
    var isHovering = false
    var isPinned = false
    var tab: Tab = .media
    var event: NotchEvent?
    var hud: Hud?
    var players: [NowPlaying] = []
    var selectedID: String?

    /// The player shown and controlled: the chosen one, else whatever plays.
    var nowPlaying: NowPlaying? {
        players.first { $0.id == selectedID } ?? players.first { $0.isPlaying } ?? players.first
    }

    /// What the closed notch shows beside the camera: the shown player if it plays, else any that does.
    var activity: NowPlaying? {
        nowPlaying?.isPlaying == true ? nowPlaying : players.first { $0.isPlaying }
    }

    var hasActivity: Bool { activity != nil }

    var mode: NotchMode {
        if event != nil { return .event }
        if hud != nil { return .hud }
        return isHovering || isPinned ? .open : .compact
    }
}

enum NotchAction {
    case hover(Bool)
    case togglePin
    case unpin
    case select(Tab)
    case show(NotchEvent)
    case dismissEvent
    case showHud(Hud)
    case dismissHud
    case players([NowPlaying])
    case selectPlayer(String)
    case togglePlayback(at: Date)
}

func reduce(_ state: NotchState, _ action: NotchAction) -> NotchState {
    var s = state
    switch action {
    case .hover(let inside): s.isHovering = inside
    case .togglePin: s.isPinned.toggle()
    case .unpin: s.isPinned = false
    case .select(let tab): s.tab = tab
    case .show(let event): s.event = event
    case .dismissEvent: s.event = nil
    case .showHud(let hud): s.hud = hud
    case .dismissHud: s.hud = nil
    case .players(let next):
        let before = s.nowPlaying
        // A player that just started takes over the panel.
        let started = next.first { p in p.isPlaying && !(s.players.first { $0.id == p.id }?.isPlaying ?? false) }
        if let started, started.id != before?.id {
            s.selectedID = started.id
        } else if let chosen = s.selectedID, !next.contains(where: { $0.id == chosen }) {
            s.selectedID = nil
        }
        s.players = next
        // Stay on the shown player when it pauses, instead of falling back to another one.
        s.selectedID = s.nowPlaying?.id
    case .selectPlayer(let id):
        s.selectedID = id
    case .togglePlayback(let now):
        // Optimistic: flip right away, the next player snapshot corrects it.
        if let i = s.players.firstIndex(where: { $0.id == s.nowPlaying?.id }) {
            s.selectedID = s.players[i].id
            s.players[i].elapsed = s.players[i].position(at: now)
            s.players[i].timestamp = now
            s.players[i].isPlaying.toggle()
        }
    }
    return s
}

enum Layout {
    /// Concave flare where the shape meets the top edge, like the real notch.
    static let flare: CGFloat = 6
    /// Extra hit area around the visible shape, so hover is not twitchy at the edges.
    static let hoverSlack: CGFloat = 8
    /// Room for the drop shadow inside the transparent window.
    static let shadowRoom: CGFloat = 60
    static let openWidth: CGFloat = 580
    static let openBody: CGFloat = 176
    static let eventBody: CGFloat = 44
    /// Width added on each side of the camera for the closed live activity.
    static let activityEar: CGFloat = 38
    /// Width added on each side of the camera for volume and brightness.
    static let hudEar: CGFloat = 76

    static func size(_ state: NotchState, notch: CGSize) -> CGSize {
        size(state.mode, activity: state.hasActivity, notch: notch)
    }

    static func size(_ mode: NotchMode, activity: Bool, notch: CGSize) -> CGSize {
        switch mode {
        case .compact:
            return activity ? CGSize(width: notch.width + activityEar * 2, height: notch.height) : notch
        case .event: return CGSize(width: max(notch.width + 200, 380), height: notch.height + eventBody)
        case .hud: return CGSize(width: notch.width + hudEar * 2, height: notch.height)
        case .open: return CGSize(width: openWidth, height: notch.height + openBody)
        }
    }

    /// Corner radius follows the height, so it eases along with the size.
    static func bottomRadius(height: CGFloat, notch: CGSize) -> CGFloat {
        let t = min(1, max(0, (height - notch.height) / openBody))
        return 10 + 14 * t
    }

    static func windowSize(notch: CGSize) -> CGSize {
        CGSize(width: openWidth + flare * 2 + shadowRoom * 2, height: notch.height + openBody + shadowRoom)
    }

    /// Visible shape rect in screen coordinates (origin bottom-left, AppKit style).
    static func visibleRect(_ state: NotchState, notch: CGSize, screen: CGRect) -> CGRect {
        let s = size(state, notch: notch)
        let w = s.width + flare * 2
        return CGRect(x: screen.midX - w / 2, y: screen.maxY - s.height, width: w, height: s.height)
    }
}
