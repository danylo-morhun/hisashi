import Foundation

// Pure rules of the today tab: agenda, timer, reminders. No AppKit, no side effects.

/// One calendar event of today.
struct DayEvent: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    var isAllDay = false
    /// The video call to join, when the event has one.
    var link: URL?
}

struct Weather: Equatable {
    let temperature: Int
    let high: Int
    let low: Int
    let summary: String
}

struct Power: Equatable {
    let percent: Int
    let plugged: Bool
    /// Nil while the system is still estimating, or when plugged in.
    let minutesLeft: Int?
}

struct TodayState: Equatable {
    var events: [DayEvent] = []
    /// Nil until the system has answered.
    var calendarAllowed: Bool?
    var weather: Weather?
    var power: Power?
    var timer: Countdown?
    /// Minutes being typed for the timer; nil when not typing.
    var entry: String?
    /// What was already announced, with when: event ids and titles of calendar banners.
    var announced: [String: Date] = [:]
}

/// A key that means something while the timer's minutes are being typed.
enum EntryKey: Equatable {
    case digit(Int)
    case backspace, submit, cancel

    /// By physical key, so the digit row works in any keyboard layout.
    init?(keyCode: Int) {
        let digits = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                      82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        switch keyCode {
        case 51: self = .backspace
        case 36, 76: self = .submit
        case 53: self = .cancel
        default:
            guard let digit = digits[keyCode] else { return nil }
            self = .digit(digit)
        }
    }
}

enum Today {
    static let timerPrefix = "today.timer:"
    static let extendLabel = "+5 min"
    static let dismissLabel = "Dismiss"

    /// The same meeting often sits in two calendars, say work and personal. It counts once.
    static func unique(_ events: [DayEvent]) -> [DayEvent] {
        var seen = Set<String>()
        return events.filter { seen.insert(Reminders.normalized($0.title) + "|\($0.start.timeIntervalSince1970)").inserted }
    }

    /// Ends the timer if its time is up.
    static func tick(_ state: NotchState, at now: Date) -> NotchState {
        var s = state
        if let timer = s.today.timer, timer.since != nil, timer.remaining(at: now) <= 0 {
            s.today.timer = nil
            s = reduce(s, .notify(AppNotice(
                id: timerPrefix + String(Int(now.timeIntervalSince1970 * 1000)),
                app: "Clock", title: "Timer", subtitle: "", body: "\(Int(timer.total / 60)) min done",
                actions: [extendLabel, dismissLabel], persistent: true)))
        }
        return s
    }

    /// Two digits at most: the time beside the camera has room for 99 minutes.
    static func type(_ key: EntryKey, in state: NotchState, at now: Date) -> NotchState {
        guard let entry = state.today.entry else { return state }
        var s = state
        switch key {
        case .digit(let digit):
            if entry.count < 2, !(entry.isEmpty && digit == 0) { s.today.entry = entry + String(digit) }
        case .backspace: s.today.entry = String(entry.dropLast())
        case .cancel: s.today.entry = nil
        case .submit:
            guard let minutes = Int(entry) else { return s }
            s.today.entry = nil
            s.today.timer = Countdown(total: TimeInterval(minutes * 60)).resumed(at: now)
        }
        return s
    }

    /// Time on the timer, rounded up so it never reads 0:00 while running.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The first video call found in an event's fields.
    static func link(in fields: [String?]) -> URL? {
        let pattern = #"https://[^\s<>"]*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com|whereby\.com|webex\.com)[^\s<>"]*"#
        for field in fields.compactMap({ $0 }) {
            if let range = field.range(of: pattern, options: .regularExpression) { return URL(string: String(field[range])) }
        }
        return nil
    }

    /// WMO weather code, as Open-Meteo reports it.
    static func summary(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Storm"
        default: return ""
        }
    }
}

enum Agenda {
    enum Kind: Equatable { case past, focus, upcoming, allDay }

    struct Row: Equatable, Identifiable {
        let event: DayEvent
        let kind: Kind
        var id: String { event.id }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String { time.string(from: date) }

    /// What is on and what comes next; all-day events and the latest past ones fill what is left.
    static func rows(_ events: [DayEvent], at now: Date, limit: Int = 4) -> [Row] {
        let timed = events.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
        let coming = timed.filter { $0.end > now }.prefix(limit)
        var rows = coming.enumerated().map { Row(event: $1, kind: $0 == 0 ? .focus : .upcoming) }
        let allDay = events.filter(\.isAllDay).prefix(limit - rows.count)
        rows += allDay.map { Row(event: $0, kind: .allDay) }
        let past = timed.filter { $0.end <= now }.suffix(limit - rows.count)
        return past.map { Row(event: $0, kind: .past) } + rows
    }

    /// "in 24 min · until 16:30", or "now · until 16:30" once it has started.
    static func caption(_ event: DayEvent, at now: Date) -> String {
        (event.start > now ? "in " + span(event.start.timeIntervalSince(now)) : "now") + " · until " + time(event.end)
    }

    /// Rounded up: a reminder at 4 min 10 s reads "5 min".
    private static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// One event, one notification, whoever sends it. The notch makes no reminders of its own:
/// the first banner about an event shows, with its app's sound and a way to join the call;
/// everything else about that event stays quiet in Notification Center.
enum Reminders {
    static let joinLabel = "Join"
    /// A banner counts as being about an event only this close to it. An alert a day
    /// or an hour ahead is its own thing and does not use up the reminder.
    static let window: TimeInterval = 15 * 60
    /// Calendars the Mac cannot read: their repeated banners are told apart by title alone.
    static let repeatWindow: TimeInterval = 20 * 60

    /// Everything these send is about the calendar.
    static let calendarApps: Set = ["Calendar", "Календарь", "Notion Calendar", "Google Calendar", "Fantastical", "BusyCal"]
    /// These send other things too, so they count only when they name an event of today.
    static let otherSources: Set = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Dia",
                                    "Microsoft Outlook", "zoom.us", "Microsoft Teams"]

    enum Route: Equatable {
        case show
        /// The first banner about this event.
        case first(DayEvent)
        case drop
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func titleKey(_ title: String) -> String { "title:" + normalized(title) }

    /// What to do with a banner that just arrived.
    static func route(_ notice: AppNotice, in today: TodayState, at now: Date) -> Route {
        let calendar = calendarApps.contains(notice.app)
        guard calendar || otherSources.contains(notice.app) else { return .show }
        if let event = event(of: notice, in: today, at: now) { return today.announced[event.id] == nil ? .first(event) : .drop }
        if calendar, !notice.title.isEmpty, let at = today.announced[titleKey(notice.title)],
           now.timeIntervalSince(at) < repeatWindow { return .drop }
        return .show
    }

    /// The event of today a banner talks about, if it is close enough in time.
    static func event(of notice: AppNotice, in today: TodayState, at now: Date) -> DayEvent? {
        let text = normalized([notice.title, notice.subtitle, notice.body].joined(separator: " "))
        return today.events.first { e in
            let title = normalized(e.title)
            return !e.isAllDay && title.count >= 3 && now >= e.start.addingTimeInterval(-window) && now < e.end && text.contains(title)
        }
    }

    static func apply(_ route: Route, _ notice: AppNotice, to state: NotchState, at now: Date) -> NotchState {
        var s = state
        s.today.announced = s.today.announced.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        switch route {
        case .drop: return s
        case .first(let event):
            s.today.announced[event.id] = now
            var notice = notice
            if event.link != nil, !notice.actions.contains(joinLabel) { notice.actions.append(joinLabel) }
            return reduce(s, .notify(notice))
        case .show:
            if calendarApps.contains(notice.app), !notice.title.isEmpty { s.today.announced[titleKey(notice.title)] = now }
            return reduce(s, .notify(notice))
        }
    }
}
