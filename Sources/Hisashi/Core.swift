import CoreText
import Foundation

// Pure rules: state, actions, reducer, layout. No AppKit, no side effects.

enum Tab: CaseIterable, Equatable {
    case media, today, notifications, shelf, focus, life
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
    /// The picture the app sent along, such as the sender's photo in a messenger.
    var image: Data?
    /// The button just pressed; it turns into a check before the notice leaves.
    var pressed: String?
    /// Set while the notice animates away; how depends on why.
    var leaving: NoticeExit?

    /// Subtitle and body as one line of text under the title.
    var detail: String { [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// How the shown notice came in: dropped from the camera, or risen from the queue below.
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

/// A notification as Notification Center keeps it, for the list in the open notch.
struct HistoryItem: Equatable, Identifiable {
    /// The notification's UUID, the same one its banner carries.
    let id: String
    /// Display name of the sending app.
    let app: String
    /// Bundle id when known (from Notification Center's store), to open the app.
    var bundle: String?
    let title: String
    let body: String
    let date: Date
    var image: Data?
}

/// One app's notifications, newest first; the notch shows them as a stack.
struct AppStack: Equatable, Identifiable {
    let app: String
    let items: [HistoryItem]
    var id: String { app }
    var latest: HistoryItem { items[0] }
}

enum History {
    /// A banner is kept in the list this long while Notification Center has not stored it yet.
    static let pending: TimeInterval = 12

    /// Notification Center's list plus banners it has not stored yet, minus apps just cleared.
    static func merge(stored: [HistoryItem], recent: [HistoryItem], cleared: [String: Date]) -> [HistoryItem] {
        let ids = Set(stored.map(\.id))
        return (stored + recent.filter { !ids.contains($0.id) })
            .filter { item in cleared[item.app].map { item.date > $0 } ?? true }
    }

    /// Takes a fresh copy of the store. Photos from banners stay with their notification;
    /// banners the store now has, or that waited too long, stop being pending.
    static func store(_ items: [HistoryItem], over state: NotchState, at now: Date) -> NotchState {
        var s = state
        var photos: [String: Data] = [:]
        for item in s.stored + s.recent { if let image = item.image { photos[item.id] = image } }
        s.stored = items.map { item in
            var item = item
            if item.image == nil { item.image = photos[item.id] }
            return item
        }
        let ids = Set(items.map(\.id))
        s.recent = s.recent.filter { !ids.contains($0.id) && now.timeIntervalSince($0.date) < pending }
        s.clearedApps = s.clearedApps.filter { now.timeIntervalSince($0.value) < pending }
        return s
    }

    /// Stacks by app, the app with the newest notification first.
    static func stacks(_ items: [HistoryItem]) -> [AppStack] {
        Dictionary(grouping: items, by: \.app)
            .map { AppStack(app: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.latest.date > $1.latest.date }
    }

    /// Short age: now, 4m, 2h, Yesterday, then the date.
    static func age(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A notice's arrangement, worked out once from its text.
struct NoticeLayout: Equatable {
    /// Width of each wing beside the camera.
    let wing: CGFloat
    /// What the left wing says: the title, or the app when the title is too long.
    let label: String
    /// The title moved under the camera, as the first line.
    let titleBelow: Bool
    let bodyLines: Int

    /// Height of what sits under the camera, buttons left out.
    var belowHeight: CGFloat {
        let lines = CGFloat(bodyLines + (titleBelow ? 1 : 0))
        return lines > 0 ? lines * Layout.noticeLine + Layout.noticeBottom : 0
    }
}

/// Width of a single line of system text, the way the notch draws it.
enum TextWidth {
    enum Weight { case regular, semibold }

    /// Layout asks on every mouse move while a notice shows; the same text is measured once.
    private static var measured: [String: CGFloat] = [:]

    static func of(_ text: String, size: CGFloat, weight: Weight = .regular) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = "\(size)\(weight)\u{1F}" + text
        if let hit = measured[key] { return hit }
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font(size, weight)] as CFDictionary)!
        let width = ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)))
        if measured.count > 200 { measured.removeAll() }
        measured[key] = width
        return width
    }

    private static func font(_ size: CGFloat, _ weight: Weight) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
        guard weight == .semibold else { return base }
        let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
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

    /// Adds a notice on top of the queue. The newest shows, the others wait underneath.
    /// One already queued comes back when Notification Center surfaces it again:
    /// it is refreshed where it is, so it does not jump over the one being handled.
    static func add(_ notice: AppNotice, to queue: [AppNotice]) -> [AppNotice] {
        if let i = queue.firstIndex(where: { $0.id == notice.id }) {
            var q = queue
            if q[i].pressed == nil, q[i].leaving == nil { q[i].actions = notice.actions }
            return q
        }
        return Array((queue.filter { $0.leaving == nil } + [notice]).suffix(limit))
    }

    /// The system banner is gone. A temporary notice still waiting in the queue goes with it;
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

    /// Where a notice's parts go and how wide the wings are. The wings grow with the title
    /// up to a limit; a title that still does not fit leaves the wing to the app's name and
    /// becomes the first line under the camera.
    static func layout(_ notice: AppNotice, notch: CGSize) -> NoticeLayout {
        let wingChrome = Layout.noticeTextStart + 10
        func need(_ text: String) -> CGFloat { wingChrome + TextWidth.of(text, size: 13, weight: .semibold) }
        let title = notice.title.isEmpty ? notice.app : notice.title
        let fits = need(title) <= Layout.noticeWingMax
        let label = fits ? title : notice.app
        let wing = min(Layout.noticeWingMax, max(Layout.noticeWingMin, need(label)))
        let textWidth = notch.width + wing * 2 - Layout.noticeTextStart - Layout.noticeEdge
        let detail = notice.detail
        let lines = detail.isEmpty ? 0 : TextWidth.of(detail, size: 12) > textWidth ? 2 : 1
        return NoticeLayout(wing: wing, label: label, titleBelow: !fits && !notice.title.isEmpty, bodyLines: lines)
    }

    /// Calls ring through their own interface, and a banner with no title or body is drawn
    /// by its app: both stay with the system, which shows them itself.
    static func passesThrough(app: String, title: String, body: String) -> Bool {
        ["FaceTime", "Phone"].contains(app) || (title.isEmpty && body.isEmpty)
    }

    /// Buttons wait until they are wanted: always on a persistent alert, on hover otherwise,
    /// and while a pressed one shows its check.
    static func showsActions(_ notice: AppNotice, hovering: Bool) -> Bool {
        !notice.actions.isEmpty && (notice.persistent || hovering || notice.pressed != nil)
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
    /// Notification Center's list as last read from its store.
    var stored: [HistoryItem] = []
    /// Banners shown in the notch that the store has not caught up with yet.
    var recent: [HistoryItem] = []
    /// Apps cleared from the notch, with when; their older notifications stay hidden until the store agrees.
    var clearedApps: [String: Date] = [:]

    /// Everything the notifications tab lists.
    var history: [HistoryItem] { History.merge(stored: stored, recent: recent, cleared: clearedApps) }
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
    /// A fresh copy of Notification Center's list.
    case stored([HistoryItem], at: Date)
    /// A banner the notch just showed, listed before the store has it.
    case remember(HistoryItem)
    /// Clears one app's stack, or every stack when nil.
    case clearHistory(app: String?, at: Date)
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
    case .stored(let items, let now): s = History.store(items, over: s, at: now)
    case .remember(let item): s.recent = s.recent.filter { $0.id != item.id } + [item]
    case .clearHistory(let app, let now):
        for name in app.map({ [$0] }) ?? Array(Set(s.history.map(\.app))) { s.clearedApps[name] = now }
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
    /// A notice spreads into the menu bar on both sides of the camera; each wing holds
    /// the icon and title on the left, the time on the right. They grow with the title, within limits.
    static let noticeWingMin: CGFloat = 117
    static let noticeWingMax: CGFloat = 170
    /// Outer margin, and where the title and everything under it start.
    static let noticeEdge: CGFloat = 14
    static let noticeTextStart: CGFloat = 38
    /// Body text sits under the camera; one line is this tall.
    static let noticeLine: CGFloat = 16
    static let noticeBottom: CGFloat = 12
    /// Height the row of app buttons adds, gap above included.
    static let noticeActions: CGFloat = 34
    static let noticeRadius: CGFloat = 18
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
        if state.mode == .notice, let notice = state.notice {
            let layout = Notices.layout(notice, notch: notch)
            var height = notch.height + layout.belowHeight
            if Notices.showsActions(notice, hovering: state.isHovering) {
                height += noticeActions + (layout.belowHeight == 0 ? noticeBottom : 0)
            }
            return CGSize(width: notch.width + layout.wing * 2, height: height)
        }
        return size(state.mode, activity: state.hasActivity, notch: notch)
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
        case .notice: return CGSize(width: notch.width + noticeWingMin * 2, height: notch.height)
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
