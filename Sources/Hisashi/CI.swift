import Foundation

// Pure rules for GitHub Actions runs and the status tab. No AppKit, no side effects.

/// One workflow run on GitHub Actions.
struct CIRun: Equatable, Identifiable {
    enum Status: Equatable { case queued, running, passed, failed, cancelled }
    /// One job of the run, as its segment shows it.
    enum Job: Equatable { case waiting, running, passed, failed }

    let id: Int
    /// Owner and name, "danylo-morhun/hisashi".
    let repo: String
    let workflow: String
    let branch: String
    /// What started it: push, pull_request, schedule, workflow_dispatch.
    let event: String
    let actor: String
    /// The signed-in account that sees it, which also reruns it.
    let account: String
    var status: Status
    let started: Date
    var updated: Date
    let url: URL
    var pullRequest: Int?
    /// Jobs in the order GitHub lists them.
    var jobs: [Job] = []
    /// The job running now, or the one that failed.
    var job: String?

    var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var isActive: Bool { status == .queued || status == .running }
    /// Started by the user, not a schedule or a bot.
    var isMine: Bool { actor == account && event != "schedule" }
    var duration: TimeInterval { max(0, updated.timeIntervalSince(started)) }

    var pullURL: URL? {
        pullRequest.flatMap { URL(string: "https://github.com/\(repo)/pull/\($0)") }
    }
}

/// One row of the status tab: a Claude session or a CI run.
enum StatusItem: Equatable, Identifiable {
    case agent(AgentSession)
    case run(CIRun)

    var id: String {
        switch self {
        case .agent(let a): return "agent:" + a.id
        case .run(let r): return "run:\(r.id)"
        }
    }

    var isActive: Bool {
        switch self {
        case .agent(let a): return a.working
        case .run(let r): return r.isActive
        }
    }

    var updated: Date {
        switch self {
        case .agent(let a): return a.updated
        case .run(let r): return r.updated
        }
    }
}

enum CI {
    static let app = "GitHub"
    static let passedPrefix = "ci.passed:"
    static let failedPrefix = "ci.failed:"
    static let rerunLabel = "Rerun"
    static let pullLabel = "Open PR"
    /// Runs older than this drop out of the tab.
    static let keep: TimeInterval = 24 * 3600

    /// Takes a fresh look at every followed repo. A run that finished since the last look
    /// becomes a notice; runs of repos seen for the first time (`fresh`) only fill the list,
    /// so starting the app does not replay the day.
    static func apply(_ runs: [CIRun], fresh: Set<String>, to state: NotchState, at now: Date) -> NotchState {
        var s = state
        let before = Dictionary(s.runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let finished = runs.filter { run in
            guard !run.isActive, run.status != .cancelled, !fresh.contains(run.repo) else { return false }
            if let old = before[run.id] { return old.isActive }
            // Started and ended between two looks.
            return now.timeIntervalSince(run.updated) < 10 * 60
        }
        s.runs = runs.filter { $0.isActive || now.timeIntervalSince($0.updated) < keep }
            .sorted { $0.updated > $1.updated }
        for run in finished.sorted(by: { $0.updated < $1.updated }) {
            s = reduce(s, .notify(notice(run)))
        }
        return s
    }

    /// Failures stay until looked at, with a rerun; passes go after the usual five seconds.
    static func notice(_ run: CIRun) -> AppNotice {
        let failed = run.status == .failed
        let step = failed ? run.job.map { " at " + $0 } ?? "" : ""
        let body = [run.name, run.workflow + " on " + run.branch + step, Agents.elapsed(run.duration)]
            .joined(separator: " · ")
        var actions: [String] = []
        if failed { actions.append(rerunLabel) }
        if run.pullRequest != nil { actions.append(pullLabel) }
        return AppNotice(id: (failed ? failedPrefix : passedPrefix) + "\(run.id)", app: app,
                         title: failed ? "CI failed" : "CI passed", subtitle: "", body: body,
                         actions: actions, persistent: failed)
    }

    /// The run a notice is about.
    static func run(ofNotice id: String) -> Int? {
        for prefix in [passedPrefix, failedPrefix] where id.hasPrefix(prefix) {
            return Int(id.dropFirst(prefix.count))
        }
        return nil
    }

    /// Whether a notice tells of a failure, a pass, or is not about CI at all.
    static func tone(ofNotice id: String) -> Tone? {
        if id.hasPrefix(failedPrefix) { return .failure }
        if id.hasPrefix(passedPrefix) { return .success }
        return nil
    }

    /// The run beside the camera: one the user started, the newest of them.
    static func shown(_ runs: [CIRun]) -> CIRun? {
        runs.filter { $0.isActive && $0.isMine }.max { $0.started < $1.started }
    }

    /// The status tab's rows. Work in progress first, newest on top, then the rest by time.
    /// Only the latest run of a workflow on a branch counts; an older one says nothing new.
    static func feed(agents: [AgentSession], runs: [CIRun], limit: Int = 5) -> [StatusItem] {
        var seen = Set<String>()
        let latest = runs.sorted { $0.started > $1.started }
            .filter { seen.insert($0.repo + "|" + $0.workflow + "|" + $0.branch).inserted }
        let items = agents.map(StatusItem.agent) + latest.map(StatusItem.run)
        return Array(items.sorted { a, b in
            a.isActive != b.isActive ? a.isActive : a.updated > b.updated
        }.prefix(limit))
    }

    /// Segments drawn for a run's jobs: one per job, at most `limit`. Past that, neighbours
    /// share a segment, which shows the worst of them. A run that lists no jobs yet shows one waiting.
    static func segments(_ jobs: [CIRun.Job], limit: Int = 8) -> [CIRun.Job] {
        guard !jobs.isEmpty else { return [.waiting] }
        guard jobs.count > limit else { return jobs }
        func rank(_ j: CIRun.Job) -> Int { [.passed: 0, .waiting: 1, .running: 2, .failed: 3][j] ?? 0 }
        return (0..<limit).map { i in
            let part = jobs[i * jobs.count / limit ..< (i + 1) * jobs.count / limit]
            return part.max { rank($0) < rank($1) } ?? .waiting
        }
    }

    /// What a run row says after the repo.
    static func detail(_ run: CIRun) -> String {
        let base = run.workflow + " on " + run.branch
        switch run.status {
        case .queued: return base + " · queued"
        case .running: return base + (run.job.map { " · " + $0 } ?? "")
        case .passed: return base + " passed"
        case .failed: return base + " failed" + (run.job.map { " at " + $0 } ?? "")
        case .cancelled: return base + " cancelled"
        }
    }

    /// GitHub's status and conclusion as one status. Skipped and neutral runs count as passed.
    static func status(_ status: String, conclusion: String?) -> CIRun.Status {
        switch status {
        case "completed":
            switch conclusion {
            case "success", "skipped", "neutral": return .passed
            case "cancelled", "stale": return .cancelled
            default: return .failed
            }
        case "in_progress": return .running
        default: return .queued
        }
    }
}
