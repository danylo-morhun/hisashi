import AppKit
import Foundation

/// Hears Claude Code hooks. scripts/claude-hook.sh connects to a unix socket and sends
/// one line "tty pid" and one line with the hook's JSON; what comes back is the hook's output.
/// Most calls get nothing back at once. Questions with single choices are held open until
/// each is answered in the notch, one after another, or handed back empty so the terminal
/// asks them instead.
/// A watchdog notices sessions that stopped without saying so: Esc leaves no Stop hook,
/// a killed process no SessionEnd.
final class ClaudeWatch {
    static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hisashi/claude.sock").path

    var onReport: (AgentReport) -> Void = { _ in }
    /// Set by the shell: the sessions the watchdog checks.
    var sessions: () -> [AgentSession] = { [] }

    private var listener: Int32 = -1
    private var accept: DispatchSourceRead?
    private var watchdog: Timer?
    /// Questions waiting for answers, by session.
    private var pending: [String: Pending] = [:]

    private struct Pending {
        let client: Int32
        /// The hook's tool input, sent back with the answers added.
        let input: [String: Any]
        let questions: [AgentQuestion]
        /// Who asked, for the reports of the questions that follow.
        let report: AgentReport
        var answers: [String: String] = [:]
    }
    private let queue = DispatchQueue(label: "hisashi.claude")

    func start() {
        try? FileManager.default.createDirectory(atPath: (Self.socketPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(Self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            Self.socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 { self?.read(client) }
        }
        source.resume()
        accept = source
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        for session in pending.keys { reply(session, nil) }
        accept?.cancel()
        if listener >= 0 { close(listener) }
        unlink(Self.socketPath)
        watchdog?.invalidate()
    }

    /// Reads one hook call: two lines, then hangs up so the script exits at once.
    private func read(_ client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while data.filter({ $0 == 10 }).count < 2 {
            let n = Darwin.read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        let report = Self.parse(data)
        guard case .question = report?.event, let report, let input = Self.input(data) else {
            close(client)
            if let report { DispatchQueue.main.async { [weak self] in self?.onReport(report) } }
            return
        }
        // Writing to a hook that gave up (Esc) must not kill the app.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.main.async { [weak self] in
            guard let self else { close(client); return }
            self.reply(report.session, nil)
            self.pending[report.session] = Pending(client: client, input: input,
                                                   questions: Self.questions(input), report: report)
            self.onReport(report)
        }
    }

    /// Answers the session's current question with the picked choice. The next one follows
    /// once the pressed button has shown its check; after the last, Claude gets all answers.
    /// nil hands every question back to the terminal.
    func reply(_ session: String, _ choice: String?) {
        guard var p = pending.removeValue(forKey: session) else { return }
        guard let choice else { return finish(p.client, nil) }
        p.answers[p.questions[p.answers.count].text] = choice
        guard p.answers.count == p.questions.count else {
            pending[session] = p
            let next = AgentReport(session: p.report.session, cwd: p.report.cwd, tty: p.report.tty, pid: p.report.pid,
                                   transcript: p.report.transcript, event: Agents.ask(p.questions, at: p.answers.count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                if self?.pending[session] != nil { self?.onReport(next) }
            }
            return
        }
        var answered = p.input
        answered["answers"] = p.answers
        finish(p.client, ["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": answered]])
    }

    /// Writes the hook's output, empty for none, and hangs up.
    private func finish(_ client: Int32, _ output: [String: Any]?) {
        let out = output.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        queue.async {
            out.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }

    private static func input(_ data: Data) -> [String: Any]? {
        let parts = data.split(separator: 10, maxSplits: 1)
        guard parts.count == 2, let json = try? JSONSerialization.jsonObject(with: parts[1]) as? [String: Any] else { return nil }
        return json["tool_input"] as? [String: Any]
    }

    private static func questions(_ input: Any?) -> [AgentQuestion] {
        ((input as? [String: Any])?["questions"] as? [[String: Any]] ?? []).map { q in
            AgentQuestion(text: q["question"] as? String ?? "Has a question",
                          options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                          multiple: q["multiSelect"] as? Bool == true)
        }
    }

    static func parse(_ data: Data) -> AgentReport? {
        let parts = data.split(separator: 10, maxSplits: 1)
        guard parts.count == 2,
              let json = try? JSONSerialization.jsonObject(with: parts[1]) as? [String: Any],
              let session = json["session_id"] as? String,
              let name = json["hook_event_name"] as? String else { return nil }
        let head = String(decoding: parts[0], as: UTF8.self).split(separator: " ").map(String.init)
        let tool = json["tool_name"] as? String ?? ""
        let input = (json["tool_input"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let event: AgentEvent
        switch name {
        case "UserPromptSubmit": event = .prompt
        case "PreToolUse" where tool == "AskUserQuestion":
            let questions = questions(json["tool_input"])
            event = Agents.answerable(questions) ? Agents.ask(questions, at: 0) : .waiting(Agents.summary(questions))
        case "PreToolUse": event = .tool(Agents.step(tool: tool, input: input))
        case "PostToolUse", "PostToolUseFailure": event = .toolDone
        case "Notification": event = .waiting(json["message"] as? String ?? "Needs your input")
        case "Stop": event = .stop(json["last_assistant_message"] as? String ?? "")
        case "SessionEnd": event = .end
        default: return nil
        }
        return AgentReport(session: session, cwd: json["cwd"] as? String ?? "",
                           tty: head.first.flatMap { $0 == "-" || $0 == "??" ? nil : $0 },
                           pid: head.count > 1 ? Int32(head[1]) : nil,
                           transcript: json["transcript_path"] as? String, event: event)
    }

    /// Working sessions whose process died or whose last turn was cut off with Esc.
    private func check() {
        // A session that just spoke is alive; its transcript may not have the new prompt yet.
        for s in sessions() where s.working && Date().timeIntervalSince(s.updated) > 3 {
            if let pid = s.pid, kill(pid, 0) != 0, errno == ESRCH {
                onReport(AgentReport(session: s.id, event: .end))
            } else if let path = s.transcript, Self.interrupted(path) {
                onReport(AgentReport(session: s.id, event: .interrupted))
            }
        }
    }

    /// The transcript's last message is "[Request interrupted by user…]".
    static func interrupted(_ path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let tail = String(decoding: file.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            if line.contains("\"type\":\"assistant\"") { return false }
            if line.contains("\"type\":\"user\"") { return line.contains("[Request interrupted by user") }
        }
        return false
    }
}

/// Brings the Terminal tab running a session to the front. A session without a terminal
/// runs in the Claude desktop app, which comes forward instead.
enum Terminals {
    static func focus(tty: String?) {
        guard let tty else { return activate("com.anthropic.claudefordesktop") }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        DispatchQueue.global().async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error != nil { DispatchQueue.main.async { activate("com.apple.Terminal") } }
        }
    }

    private static func activate(_ bundle: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
    }
}
