import AppKit
import Foundation
import Observation

// The seikatsu tab: what waits in the user's life app, read through its MCP endpoint.
// Answers come as compact JSON, which drops empty lists, blank strings and nulls,
// so nearly every field is optional.

/// Today across every app, as seikatsu's Today page lists it.
struct LifeToday: Codable, Equatable {
    struct Item: Codable, Equatable {
        let app: String
        /// overdue, due or info.
        let tone: String
        let title: String
        var note: String?
        let key: String
    }

    struct Habit: Codable, Equatable {
        let id: String
        let name: String
        var due: Bool?
        var done: Bool?
    }

    var todo: [Item]?
    var habits: [Habit]?
}

/// Seiryu's Focus page: overdue, today, in progress, next seven days.
struct SeiryuFocus: Codable, Equatable {
    struct Section: Codable, Equatable {
        let section: String
        var cards: [Card]?
    }

    struct Card: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        var project: String?
        var group: String?
        var priority: String?
        var due: String?
        var dueTime: String?
        var checklist: String?
    }

    var today: String?
    var sections: [Section]?
}

/// Kuroji's plan for this month.
struct KurojiPlan: Codable, Equatable {
    struct Progress: Codable, Equatable {
        let elapsed: Int
        let days: Int
        var share: Double?
    }

    struct Line: Codable, Equatable {
        let name: String
        var plan: Double?
        var actual: Double?
    }

    struct Totals: Codable, Equatable {
        var expensePlan: Double?
        var expenseActual: Double?
        var instalments: Double?
        var free: Double?
    }

    struct Fund: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        var target: Double?
        var dueDate: String?
        var filled: Double?
        var instalment: Double?
    }

    let month: String
    var currency: String?
    var progress: Progress?
    var expense: [Line]?
    var totals: Totals?
    var funds: [Fund]?
}

/// The job search in numbers.
struct KyuuStats: Codable, Equatable {
    struct Median: Codable, Equatable { var median: Double? }

    var sent: Int?
    var answered: Int?
    var interviewed: Int?
    var offers: Int?
    var inProgress: Int?
    var waiting: Int?
    var replyRate: Double?
    var firstAnswer: Median?
}

/// A habit with its last seven days.
struct KeizokuHabit: Codable, Equatable, Identifiable {
    struct Streak: Codable, Equatable {
        var current: Int?
        var best: Int?
    }

    struct Day: Codable, Equatable {
        let date: String
        var done: Bool?
    }

    let id: String
    let name: String
    var frequency: String?
    var target: Int?
    /// Weekdays it is due on, 1 = Monday.
    var days: [Int]?
    var dueToday: Bool?
    var streak: Streak?
    var thisWeek: Int?
    var last7: [Day]?
}

/// The apps the tab has a tile for, in tile order.
enum LifeApp: String, CaseIterable, Identifiable {
    case seiryu, kuroji, kyuu, keizoku

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Which answer its open view is drawn from; Kuroji's is the plan the tile reads too.
    var part: String { self == .kuroji ? "plan" : rawValue }

    /// Where the app lives on the site.
    var path: String {
        switch self {
        case .kuroji: return "/kuroji?tab=plan"
        default: return "/" + rawValue
        }
    }
}

/// What a tile says about its app; worked out from the answers, no side effects.
struct LifeTile: Equatable {
    var big: String
    var label: String
    var line: String
    var tone: Tone = .neutral
}

enum Seikatsu {
    static func items(_ today: LifeToday?, _ app: LifeApp) -> [LifeToday.Item] {
        (today?.todo ?? []).filter { $0.app == app.rawValue }
    }

    static func tone(_ item: LifeToday.Item) -> Tone {
        switch item.tone {
        case "overdue": return .failure
        case "due": return .warning
        default: return .neutral
        }
    }

    /// The first whole number in a line such as "11 payments to add".
    static func leadingNumber(_ text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// "Tomorrow at 12:00" → "12:00".
    static func clock(_ text: String) -> String? {
        text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// Whole amount with spaced thousands, as seikatsu writes it: 7 865.
    static func amount(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{2009}"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }

    static func currency(_ code: String?) -> String {
        switch code {
        case "PLN", nil: return "zł"
        case "EUR": return "€"
        case "USD": return "$"
        default: return code!
        }
    }

    static func tile(_ app: LifeApp, today: LifeToday?, plan: KurojiPlan?) -> LifeTile {
        let items = items(today, app)
        switch app {
        case .seiryu:
            let due = items.filter { $0.tone != "info" }
            let first = due.first ?? items.first
            let tone: Tone = due.contains { $0.tone == "overdue" } ? .failure : due.isEmpty ? .neutral : .warning
            let when = first?.note.flatMap(clock).map { $0 + " " } ?? ""
            return LifeTile(big: "\(due.count)", label: due.isEmpty ? "nothing due" : "due today",
                            line: first.map { when + $0.title } ?? "", tone: tone)
        case .kuroji:
            let unit = currency(plan?.currency)
            var line = ""
            if let t = plan?.totals, let i = t.instalments, i > 0 {
                let n = plan?.funds?.filter { ($0.filled ?? 0) < ($0.target ?? 0) }.count ?? 0
                line = "\(amount(i)) \(unit) into \(n) fund" + (n == 1 ? "" : "s")
            } else if let free = plan?.totals?.free {
                line = "\(amount(free)) \(unit) free"
            }
            if let captures = items.first(where: { $0.key == "kuroji:captures" }), let n = leadingNumber(captures.title) {
                let label = captures.title.dropFirst("\(n)".count).trimmingCharacters(in: .whitespaces)
                return LifeTile(big: "\(n)", label: label, line: line, tone: tone(captures))
            }
            if let t = plan?.totals, let plan = t.expensePlan, plan > 0 {
                return LifeTile(big: "\(Int((t.expenseActual ?? 0) / plan * 100))%", label: "of the month's plan", line: line)
            }
            return LifeTile(big: "—", label: "nothing to add", line: line)
        case .kyuu:
            let ghost = items.first { $0.key == "kyuu:ghost" }
            if let call = items.first(where: { $0.key.hasPrefix("kyuu:call:") }) {
                let note = call.note ?? ""
                let day = note.components(separatedBy: " at ").first?.lowercased() ?? ""
                let kind = call.title.components(separatedBy: " · ").first?.lowercased() ?? call.title
                return LifeTile(big: clock(note) ?? note, label: "\(kind) \(day)".trimmingCharacters(in: .whitespaces),
                                line: ghost.flatMap { g in leadingNumber(g.title).map { "\($0) to close as ghosted" } } ?? "")
            }
            if let ghost, let n = leadingNumber(ghost.title) {
                return LifeTile(big: "\(n)", label: "with no answer", line: "quiet long enough to close")
            }
            return LifeTile(big: "—", label: "nothing waiting", line: items.first?.title ?? "")
        case .keizoku:
            return LifeTile(big: "", label: "", line: "")
        }
    }

    /// Habits due today and how many are ticked.
    static func habitCount(_ today: LifeToday?) -> (done: Int, due: Int) {
        let due = (today?.habits ?? []).filter { $0.due ?? true }
        return (due.filter { $0.done == true }.count, due.count)
    }

    /// The first section with cards, else the first.
    static func defaultSection(_ focus: SeiryuFocus?) -> String? {
        let sections = focus?.sections ?? []
        return (sections.first { !($0.cards ?? []).isEmpty } ?? sections.first)?.section
    }

    /// When a card is due, short: 20:00, today, Thu, 2 Dec. Quiet leaves "today" out,
    /// for a list that is already today's.
    static func when(_ card: SeiryuFocus.Card, today: String?, quiet: Bool = false) -> String {
        if card.due == today { return card.dueTime ?? (quiet ? "" : "today") }
        guard let due = card.due, let date = day(due) else { return card.dueTime ?? "" }
        let days = today.flatMap(day).map { Calendar.current.dateComponents([.day], from: $0, to: date).day ?? 99 } ?? 99
        if days < 0 { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return days < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func day(_ text: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)
    }

    /// "W" for a date, the week strip's heading.
    static func weekdayLetter(_ text: String) -> String {
        guard let date = day(text) else { return "" }
        return String(date.formatted(.dateTime.weekday(.narrow)))
    }

    /// Whether a habit was due on a past day; a weekday habit has no dot on the weekend.
    static func isDue(_ habit: KeizokuHabit, on text: String) -> Bool {
        guard let days = habit.days, !days.isEmpty, let date = day(text) else { return true }
        let weekday = (Calendar(identifier: .gregorian).component(.weekday, from: date) + 5) % 7 + 1
        return days.contains(weekday)
    }

    /// This week's count against what the habit asks for: 0/7, 0/4, 0/5.
    static func weekGoal(_ habit: KeizokuHabit) -> Int {
        switch habit.frequency {
        case "times_per_week": return habit.target ?? 7
        case "weekdays": return 5
        default: return habit.days.map(\.count).flatMap { $0 > 0 ? $0 : nil } ?? 7
        }
    }
}

/// seikatsu's MCP endpoint, called with a personal token. Stateless: one POST per tool call.
struct SeikatsuAPI {
    enum Failure: Error { case noToken, unauthorized, refused(String), broken }

    static let site = URL(string: "https://seikatsu.danylomorhun.com")!
    static var endpoint: URL { site.appending(path: "api/mcp") }
    static var settings: URL { site.appending(path: "settings/account") }

    /// ~/Library/Application Support/Hisashi/seikatsu.json: {"token": "..."}, from
    /// seikatsu's Settings → Account → Claude → Personal token, with "Can make changes".
    static var tokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Hisashi/seikatsu.json")
    }

    static var token: String? {
        struct File: Decodable { let token: String }
        guard let data = try? Data(contentsOf: tokenFile), let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        let token = file.token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Settings offers it as "Bearer …"; either form works.
        return token.hasPrefix("Bearer ") ? String(token.dropFirst(7)) : token
    }

    func call<T: Decodable>(_ tool: String, _ arguments: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        guard let token = Self.token else { throw Failure.noToken }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.unauthorized }
        guard status == 200 else { throw Failure.refused("HTTP \(status)") }
        return try JSONDecoder().decode(T.self, from: Self.text(of: data))
    }

    /// The tool's answer: the text of its first content block, from plain JSON or one SSE message.
    static func text(of data: Data) throws -> Data {
        struct Envelope: Decodable {
            struct Result: Decodable {
                struct Block: Decodable { let type: String; let text: String? }
                let content: [Block]?
                let isError: Bool?
            }
            struct RPCError: Decodable { let message: String }
            let result: Result?
            let error: RPCError?
        }
        var json = data
        if let raw = String(data: data, encoding: .utf8), !raw.hasPrefix("{") {
            let line = raw.split(separator: "\n").last { $0.hasPrefix("data:") }
            json = Data((line?.dropFirst(5) ?? "").utf8)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: json)
        if let error = envelope.error { throw Failure.refused(error.message) }
        guard let text = envelope.result?.content?.first(where: { $0.type == "text" })?.text else { throw Failure.broken }
        if envelope.result?.isError == true { throw Failure.refused(text) }
        return Data(text.utf8)
    }
}

/// The last answers, kept so the tab opens on them at once and refreshes in place.
/// ~/Library/Application Support/Hisashi/seikatsu-cache.json, readable only by the user.
struct LifeCache: Codable {
    var today: LifeToday?
    var plan: KurojiPlan?
    var focus: SeiryuFocus?
    var kyuu: KyuuStats?
    var habits: [KeizokuHabit]?

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Hisashi/seikatsu-cache.json")
    }

    static func load() -> LifeCache? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LifeCache.self, from: $0) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

/// The tab's data and the app it has open. Today and the month's plan are read when the tab
/// shows, an app's own view when it opens; again after two minutes, and after every change.
@MainActor
@Observable
final class Life {
    enum Phase: Equatable { case noToken, loading, ready, unauthorized, failed }

    private(set) var phase: Phase
    private(set) var today: LifeToday?
    private(set) var plan: KurojiPlan?
    private(set) var focus: SeiryuFocus?
    private(set) var kyuu: KyuuStats?
    private(set) var habits: [KeizokuHabit]?
    /// The app expanded over the tiles; it stays open until Back, across closing the panel and restarts.
    private(set) var open: LifeApp?
    var section: String?
    /// Cards and habits being written; their buttons show the result before the answer comes.
    private(set) var finished: Set<String> = []
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private let api = SeikatsuAPI()
    @ObservationIgnored private static let openKey = "lifeOpen"

    static let stale: TimeInterval = 120

    init() {
        phase = SeikatsuAPI.token == nil ? .noToken : .loading
        open = UserDefaults.standard.string(forKey: Self.openKey).flatMap(LifeApp.init)
        if phase == .loading, let cache = LifeCache.load(), cache.today != nil {
            today = cache.today
            plan = cache.plan
            focus = cache.focus
            kyuu = cache.kyuu
            habits = cache.habits
            section = Seikatsu.defaultSection(focus)
            phase = .ready
        }
    }

    private func keep() {
        LifeCache(today: today, plan: plan, focus: focus, kyuu: kyuu, habits: habits).save()
    }

    /// The tab came into view.
    func wake() {
        if SeikatsuAPI.token == nil { phase = .noToken; return }
        if phase == .noToken || phase == .unauthorized { phase = .loading }
        read("today", force: false)
        read("plan", force: false)
        if let open { read(open.part, force: false) }
    }

    func expand(_ app: LifeApp?) {
        open = app
        UserDefaults.standard.set(app?.rawValue, forKey: Self.openKey)
        if let app { read(app.part, force: false) }
    }

    func site(_ path: String) {
        guard let url = URL(string: path, relativeTo: SeikatsuAPI.site) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSettings() { NSWorkspace.shared.open(SeikatsuAPI.settings) }

    /// Moves a card to its project's finish column. It ticks at once and leaves the list a moment later.
    func finish(_ card: SeiryuFocus.Card) {
        guard !finished.contains(card.id) else { return }
        finished.insert(card.id)
        Task {
            do {
                struct Done: Decodable { var error: String? }
                let reply: Done = try await api.call("seiryu_finish_card", ["cardId": card.id])
                if reply.error != nil { throw SeikatsuAPI.Failure.refused(reply.error!) }
                try? await Task.sleep(for: .seconds(0.6))
                focus?.sections = focus?.sections?.map { s in
                    var s = s
                    s.cards = s.cards?.filter { $0.id != card.id }
                    return s
                }
                today?.todo = today?.todo?.filter { $0.key != "seiryu:" + card.id }
            } catch {}
            finished.remove(card.id)
            read("today", force: true)
            read("seiryu", force: true)
        }
    }

    /// Ticks a habit for today, or clears today's tick.
    func tick(_ id: String, done: Bool) {
        setHabit(id, done: done)
        Task {
            do {
                struct Reply: Decodable { var error: String? }
                let reply: Reply = try await api.call("keizoku_tick", ["habitId": id, "done": done])
                if reply.error != nil { setHabit(id, done: !done) }
            } catch {
                setHabit(id, done: !done)
            }
            read("today", force: true)
            if habits != nil { read("keizoku", force: true) }
        }
    }

    private func setHabit(_ id: String, done: Bool) {
        today?.habits = today?.habits?.map { h in
            var h = h
            if h.id == id { h.done = done }
            return h
        }
        let date = focus?.today ?? Self.isoToday()
        habits = habits?.map { h in
            guard h.id == id else { return h }
            var h = h
            let was = h.last7?.first { $0.date == date }?.done == true
            h.last7 = h.last7?.map { d in
                var d = d
                if d.date == date { d.done = done }
                return d
            }
            if was != done { h.thisWeek = max(0, (h.thisWeek ?? 0) + (done ? 1 : -1)) }
            return h
        }
    }

    private static func isoToday() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func read(_ part: String, force: Bool) {
        guard !reading.contains(part) else { return }
        if !force, let at = readAt[part], Date().timeIntervalSince(at) < Self.stale { return }
        reading.insert(part)
        Task {
            defer { reading.remove(part) }
            do {
                switch part {
                case "today": today = try await api.call("today")
                case "plan": plan = try await api.call("kuroji_plan")
                case "seiryu":
                    focus = try await api.call("seiryu_focus")
                    if section == nil || !(focus?.sections ?? []).contains(where: { $0.section == section }) {
                        section = Seikatsu.defaultSection(focus)
                    }
                case "kyuu": kyuu = try await api.call("kyuu_stats")
                case "keizoku": habits = try await api.call("keizoku_habits")
                default: return
                }
                readAt[part] = Date()
                if part == "today" { phase = .ready }
                keep()
            } catch SeikatsuAPI.Failure.unauthorized {
                phase = .unauthorized
            } catch SeikatsuAPI.Failure.noToken {
                phase = .noToken
            } catch {
                if today == nil { phase = .failed }
            }
        }
    }
}
