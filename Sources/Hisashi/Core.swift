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

/// A notification from another app, taken from the system banner as it arrives.
struct AppNotice: Equatable, Identifiable {
    /// The banner's own id, unique per notification.
    let id: String
    /// Display name of the sending app.
    let app: String
    let title: String
    let subtitle: String
    let body: String
    /// The app's buttons, e.g. "Reply" or "Mark as Completed". Gone once the system banner expires.
    var actions: [String] = []
    /// Stays until clicked or closed, like the system's persistent alert style.
    var persistent = false
    /// The button just pressed; it turns into a check before the notice leaves.
    var pressed: String?
    /// Set while the notice animates away; how depends on why.
    var leaving: NoticeExit?
}

/// How the shown notice came in: dropped from the camera, or risen from the deck below.
enum NoticeEntrance: Equatable {
    case drop, rise
}

/// Why a notice leaves, which picks its exit animation.
enum NoticeExit: Equatable {
    case open, close, press, timeout
}

/// Time left before a temporary notice hides. Hover pauses it, leaving resumes it.
struct Countdown: Equatable {
    let total: TimeInterval
    var left: TimeInterval
    /// Running since this moment; nil while paused.
    var since: Date?

    init(total: TimeInterval) {
        self.total = total
        left = total
    }

    func remaining(at now: Date) -> TimeInterval {
        guard let since else { return left }
        return max(0, left - now.timeIntervalSince(since))
    }

    /// 1 when fresh, 0 when it runs out.
    func progress(at now: Date) -> Double { total > 0 ? remaining(at: now) / total : 0 }

    func paused(at now: Date) -> Countdown {
        var c = self
        c.left = remaining(at: now)
        c.since = nil
        return c
    }

    func resumed(at now: Date) -> Countdown {
        guard since == nil else { return self }
        var c = self
        c.since = now
        return c
    }
}

/// What the user did with a notice in the notch.
enum NoticeEffect: Equatable {
    /// Open what the notification points to.
    case open
    /// One of the app's buttons.
    case press(String)
    case close
}

enum Notices {
    /// Most notices kept waiting behind the shown one.
    static let limit = 10

    /// Adds a notice on top of the deck. The newest shows, the others wait underneath.
    /// One already in the deck comes back when Notification Center surfaces it again:
    /// it is refreshed where it is, so it does not jump over the one being handled.
    static func add(_ notice: AppNotice, to queue: [AppNotice]) -> [AppNotice] {
        if let i = queue.firstIndex(where: { $0.id == notice.id }) {
            var q = queue
            if q[i].pressed == nil, q[i].leaving == nil { q[i].actions = notice.actions }
            return q
        }
        return Array((queue.filter { $0.leaving == nil } + [notice]).suffix(limit))
    }

    /// The system banner is gone. A temporary notice still waiting in the deck goes with it;
    /// the shown one stays, only without buttons.
    static func expire(_ id: String, in queue: [AppNotice]) -> [AppNotice] {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return queue }
        var q = queue
        if i != q.count - 1, !q[i].persistent {
            q.remove(at: i)
        } else if q[i].pressed == nil {
            q[i].actions = []
        }
        return q
    }

    /// Starts a notice's exit; it is removed once that has played.
    static func leave(_ id: String, _ exit: NoticeExit, in queue: [AppNotice]) -> [AppNotice] {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return queue }
        var q = queue
        q[i].leaving = exit
        return q
    }

    /// Banner actions arrive as "Name:Mark as Completed\nTarget:…". Keeps the app's own buttons,
    /// without the system ones every banner has.
    static func buttons(_ actionNames: [String]) -> [String] {
        let system: Set = ["Show Details", "Show", "Close"]
        return actionNames.compactMap { name in
            guard name.hasPrefix("Name:") else { return nil }
            let title = String(name.dropFirst(5).prefix { $0 != "\n" })
            return system.contains(title) ? nil : title
        }
    }

    /// The banner describes itself as "App, Title, Subtitle, Body"; the app is what comes before the title.
    static func appName(description: String, title: String) -> String {
        if !title.isEmpty, let r = description.range(of: ", " + title) { return String(description[..<r.lowerBound]) }
        return description.components(separatedBy: ", ").first ?? ""
    }
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
    case compact, open, event, hud, notice
}

struct NotchState: Equatable {
    var isHovering = false
    var isPinned = false
    var tab: Tab = .media
    var event: NotchEvent?
    var hud: Hud?
    /// Waiting notices; the last one shows.
    var notices: [AppNotice] = []
    var noticeEntrance = NoticeEntrance.drop
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

    var notice: AppNotice? { notices.last }

    var mode: NotchMode {
        if event != nil { return .event }
        if hud != nil { return .hud }
        // Hovering a notice keeps it, it does not open the panel.
        if notice != nil { return .notice }
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
    case notify(AppNotice)
    /// Starts the exit animation; `dismissNotice` removes it once that has played.
    case leaveNotice(String, NoticeExit)
    case dismissNotice(String)
    case pressNotice(String, String)
    /// The system banner is gone, and with it the buttons.
    case expireNotice(String)
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
    case .notify(let notice):
        if !s.notices.contains(where: { $0.id == notice.id }) { s.noticeEntrance = .drop }
        s.notices = Notices.add(notice, to: s.notices)
    case .dismissNotice(let id):
        s.notices.removeAll { $0.id == id }
        s.noticeEntrance = .rise
    case .leaveNotice(let id, let exit): s.notices = Notices.leave(id, exit, in: s.notices)
    case .pressNotice(let id, let title):
        if let i = s.notices.firstIndex(where: { $0.id == id }) { s.notices[i].pressed = title }
    case .expireNotice(let id): s.notices = Notices.expire(id, in: s.notices)
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
    static let noticeWidth: CGFloat = 480
    static let noticeBody: CGFloat = 100
    /// Extra height for the row of app buttons.
    static let noticeActions: CGFloat = 48
    /// A notice is a rounder island than the panel.
    static let noticeRadius: CGFloat = 32
    /// Width added on each side of the camera for the closed live activity.
    static let activityEar: CGFloat = 38
    /// Width added on each side of the camera for volume and brightness.
    static let hudEar: CGFloat = 76

    static func size(_ state: NotchState, notch: CGSize) -> CGSize {
        // The last notice shrinks back into the camera while its content plays the exit;
        // with more waiting the island stays for the next one.
        if state.mode == .notice, state.notice?.leaving != nil, state.notices.count == 1 {
            return size(.compact, activity: state.hasActivity, notch: notch)
        }
        var s = size(state.mode, activity: state.hasActivity, notch: notch)
        if state.mode == .notice, state.notice?.actions.isEmpty == false { s.height += noticeActions }
        return s
    }

    static func bottomRadius(_ state: NotchState, notch: CGSize) -> CGFloat {
        if state.mode == .notice, state.notice?.leaving == nil || state.notices.count > 1 { return noticeRadius }
        return bottomRadius(height: size(state, notch: notch).height, notch: notch)
    }

    static func size(_ mode: NotchMode, activity: Bool, notch: CGSize) -> CGSize {
        switch mode {
        case .compact:
            return activity ? CGSize(width: notch.width + activityEar * 2, height: notch.height) : notch
        case .event: return CGSize(width: max(notch.width + 200, 380), height: notch.height + eventBody)
        case .hud: return CGSize(width: notch.width + hudEar * 2, height: notch.height)
        case .notice: return CGSize(width: max(notch.width + 160, noticeWidth), height: notch.height + noticeBody)
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
