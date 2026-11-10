import AppKit
import Foundation

/// GitHub Actions runs of every account `gh` is signed in to, on the repos pushed to lately.
/// Asks often while something runs, rarely when all is quiet. Unchanged answers come back
/// as 304 through ETags, which GitHub does not count against the rate limit.
@MainActor
final class GitHubWatch {
    var onRuns: ([CIRun], Set<String>) -> Void = { _, _ in }

    /// Repos pushed to within this long are followed.
    private static let recent: TimeInterval = 7 * 24 * 3600
    private static let maxRepos = 12

    private struct Account { let login: String; let token: String }
    private struct Cached { var etag: String?; var runs: [CIRun] }

    private var accounts: [Account] = []
    /// Followed repos, each with the account that sees it.
    private var repos: [(name: String, account: Account)] = []
    private var reposLoaded: Date?
    private var cache: [String: Cached] = [:]
    /// Jobs as last read, by run id and the run's update time, so a quiet run is not asked again.
    private var jobs: [Int: (updated: Date, jobs: [CIRun.Job], job: String?)] = [:]
    private var task: Task<Void, Never>?

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = await self.round()
                try? await Task.sleep(for: .seconds(busy ? 15 : 60))
            }
        }
    }

    func stop() { task?.cancel() }

    /// Reruns the failed jobs of a run.
    func rerun(_ run: CIRun) {
        guard let account = accounts.first(where: { $0.login == run.account }) else { return }
        Task {
            _ = try? await request("/repos/\(run.repo)/actions/runs/\(run.id)/rerun-failed-jobs",
                                   account: account, method: "POST")
            _ = await round()
        }
    }

    /// One look at every followed repo. True while a run is in progress.
    private func round() async -> Bool {
        if accounts.isEmpty { accounts = await Self.signedIn() }
        if reposLoaded.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true { await loadRepos() }
        var fresh = Set<String>()
        for (name, account) in repos {
            if cache[name] == nil { fresh.insert(name) }
            await loadRuns(name, account: account)
        }
        let runs = repos.flatMap { cache[$0.name]?.runs ?? [] }
        onRuns(runs, fresh)
        return runs.contains(where: \.isActive)
    }

    private struct Repo: Decodable { let full_name: String; let pushed_at: Date? }

    private func loadRepos() async {
        var found: [(name: String, account: Account, pushed: Date)] = []
        for account in accounts {
            let path = "/user/repos?sort=pushed&per_page=30&affiliation=owner,collaborator,organization_member"
            guard let (data, _) = try? await request(path, account: account),
                  let list = try? Self.decoder.decode([Repo].self, from: data) else { continue }
            for repo in list {
                guard let pushed = repo.pushed_at, Date().timeIntervalSince(pushed) < Self.recent,
                      !found.contains(where: { $0.name == repo.full_name }) else { continue }
                found.append((repo.full_name, account, pushed))
            }
        }
        // A failed look keeps the repos of the last one.
        guard !found.isEmpty || repos.isEmpty else { return }
        repos = found.sorted { $0.pushed > $1.pushed }.prefix(Self.maxRepos).map { ($0.name, $0.account) }
        reposLoaded = Date()
    }

    private struct Runs: Decodable {
        struct Run: Decodable {
            struct Actor: Decodable { let login: String }
            struct Pull: Decodable { let number: Int }
            let id: Int
            let name: String?
            let head_branch: String?
            let event: String
            let status: String
            let conclusion: String?
            let run_started_at: Date?
            let created_at: Date
            let updated_at: Date
            let html_url: URL
            let actor: Actor?
            let pull_requests: [Pull]?
        }
        let workflow_runs: [Run]
    }

    private func loadRuns(_ repo: String, account: Account) async {
        let old = cache[repo]
        guard let (data, response) = try? await request("/repos/\(repo)/actions/runs?per_page=10", account: account,
                                                        etag: old?.etag) else { return }
        var runs: [CIRun]
        if response.statusCode == 304, let old {
            runs = old.runs
        } else if let list = try? Self.decoder.decode(Runs.self, from: data) {
            runs = list.workflow_runs.map { r in
                CIRun(id: r.id, repo: repo, workflow: r.name ?? "CI", branch: r.head_branch ?? "",
                      event: r.event, actor: r.actor?.login ?? "", account: account.login,
                      status: CI.status(r.status, conclusion: r.conclusion),
                      started: r.run_started_at ?? r.created_at, updated: r.updated_at, url: r.html_url,
                      pullRequest: r.pull_requests?.first?.number)
            }
        } else {
            return
        }
        // Jobs tell how far a run is and where it failed; asked again only when the run changed.
        for i in runs.indices where runs[i].isActive || runs[i].status == .failed {
            let run = runs[i]
            if let known = jobs[run.id], known.updated == run.updated, !run.isActive {
                runs[i].jobs = known.jobs
                runs[i].job = known.job
                continue
            }
            if let read = await loadJobs(run, account: account) {
                jobs[run.id] = (run.updated, read.jobs, read.job)
                runs[i].jobs = read.jobs
                runs[i].job = read.job
            }
        }
        cache[repo] = Cached(etag: response.value(forHTTPHeaderField: "ETag") ?? old?.etag, runs: runs)
    }

    private struct Jobs: Decodable {
        struct Job: Decodable { let name: String; let status: String; let conclusion: String? }
        let jobs: [Job]
    }

    private func loadJobs(_ run: CIRun, account: Account) async -> (jobs: [CIRun.Job], job: String?)? {
        guard let (data, _) = try? await request("/repos/\(run.repo)/actions/runs/\(run.id)/jobs?per_page=50", account: account),
              let list = try? Self.decoder.decode(Jobs.self, from: data) else { return nil }
        let states: [CIRun.Job] = list.jobs.map { job in
            switch job.status {
            case "completed": return ["failure", "timed_out", "startup_failure"].contains(job.conclusion ?? "") ? .failed : .passed
            case "in_progress": return .running
            default: return .waiting
            }
        }
        let job = run.status == .failed
            ? list.jobs.first { ["failure", "timed_out"].contains($0.conclusion ?? "") }?.name
            : list.jobs.first { $0.status == "in_progress" }?.name
        return (states, job)
    }

    private func request(_ path: String, account: Account, method: String = "GET",
                         etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // ETags are kept here; the system cache would answer 200 for a 304.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // A token that stopped working is fetched again next round.
        if http.statusCode == 401 { accounts = [] }
        guard http.statusCode < 400 else { throw URLError(.userAuthenticationRequired) }
        return (data, http)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Accounts as `gh` lists them in its config, with tokens from its keychain.
    private static func signedIn() async -> [Account] {
        await Task.detached {
            let hosts = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gh/hosts.yml")
            guard let text = try? String(contentsOf: hosts, encoding: .utf8) else { return [] }
            return logins(in: text).compactMap { login in
                token(for: login).map { Account(login: login, token: $0) }
            }
        }.value
    }

    /// The names under github.com's `users:` key.
    nonisolated static func logins(in hostsYAML: String) -> [String] {
        var inUsers = false, inHost = false
        var found: [String] = []
        for line in hostsYAML.components(separatedBy: .newlines) {
            let indent = line.prefix { $0 == " " }.count
            let key = line.trimmingCharacters(in: .whitespaces)
            if indent == 0 { inHost = key == "github.com:"; inUsers = false; continue }
            guard inHost else { continue }
            if key == "users:" { inUsers = true; continue }
            if inUsers {
                if indent <= 4 { inUsers = false; continue }
                if indent == 8, key.hasSuffix(":") { found.append(String(key.dropLast())) }
            }
        }
        return found
    }

    private nonisolated static func token(for login: String) -> String? {
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gh else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "token", "-h", "github.com", "-u", login]
        // A token in the environment would answer for every account.
        var env = ProcessInfo.processInfo.environment
        env["GH_TOKEN"] = nil
        env["GITHUB_TOKEN"] = nil
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !token.isEmpty ? token : nil
    }
}

enum Browser {
    static func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }
}
