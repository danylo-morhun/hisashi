import Foundation

// Pure rules for Claude Code sessions, as their hooks report them. No AppKit, no side effects.

/// One Claude Code session.
struct AgentSession: Equatable, Identifiable {
    let id: String
    /// Folder name of the project it runs in.
    var project: String
    /// Terminal the session runs in, to bring it forward on click.
    var tty: String?
    /// The claude process; when it is gone, so is the session.
    var pid: Int32?
    var transcript: String?
    /// What it does right now: "Thinking", "Reading Core.swift".
    var step = "Thinking"
    /// Start of the current turn; the closed notch counts from here.
    var since: Date
    /// Last time a hook spoke; the newest working session is the one shown.
    var updated: Date
    var working = true
}

/// What a hook says happened.
enum AgentEvent: Equatable {
    /// A prompt was sent: a new turn starts.
    case prompt
    /// A tool starts, described as a step.
    case tool(String)
    /// A tool finished; back to thinking.
    case toolDone
    /// It waits for the user: a permission or a question to answer in the terminal.
    case waiting(String)
    /// A question with choices; picking one in the notch answers it.
    case question(String, options: [String])
    /// The turn is over, with the reply.
    case stop(String)
    /// Stopped without a reply (Esc), noticed from the transcript.
    case interrupted
    case end
}

/// One hook call: who sent it and what happened.
struct AgentReport: Equatable {
    let session: String
    var cwd = ""
    var tty: String?
    var pid: Int32?
    var transcript: String?
    let event: AgentEvent
}

enum Agents {
    /// The app name notices carry; also picks the Claude icon.
    static let app = "Claude"
    static let noticePrefix = "claude:"

    /// Applies a report to the sessions. Returns the notice to show, if any.
    static func apply(_ report: AgentReport, to sessions: [AgentSession], at now: Date)
        -> (sessions: [AgentSession], notice: AppNotice?) {
        var list = sessions
        let i = list.firstIndex { $0.id == report.session }
        if report.event == .end {
            list.removeAll { $0.id == report.session }
            return (list, nil)
        }
        var s = i.map { list[$0] } ?? AgentSession(id: report.session, project: project(report.cwd),
                                                    since: now, updated: now, working: false)
        if !report.cwd.isEmpty { s.project = project(report.cwd) }
        s.tty = report.tty ?? s.tty
        s.pid = report.pid ?? s.pid
        s.transcript = report.transcript ?? s.transcript
        s.updated = now
        var notice: AppNotice?
        switch report.event {
        case .prompt:
            s.working = true
            s.since = now
            s.step = "Thinking"
        case .tool(let step):
            if !s.working { s.working = true; s.since = now }
            s.step = step
        case .toolDone:
            if s.working { s.step = "Thinking" }
        case .waiting(let text):
            // The idle reminder after a finished turn says nothing new.
            if s.working { notice = self.notice(s, text: text, asking: true, at: now) }
        case .question(let text, let options):
            s.working = true
            notice = self.notice(s, text: text, asking: true, at: now)
            notice?.actions = options
        case .stop(let text):
            s.working = false
            let reply = plain(text)
            notice = self.notice(s, text: reply.isEmpty ? "Done" : reply, asking: false, at: now)
        case .interrupted:
            s.working = false
        case .end:
            break
        }
        if let i { list[i] = s } else { list.append(s) }
        return (list, notice)
    }

    /// A question or a finished reply, shown like any other app's notice.
    /// Questions stay until answered; replies go after the usual five seconds.
    static func notice(_ s: AgentSession, text: String, asking: Bool, at now: Date) -> AppNotice {
        AppNotice(id: noticePrefix + s.id + ":" + String(Int(now.timeIntervalSince1970 * 1000)),
                  app: app, title: asking ? s.project + " needs you" : s.project,
                  subtitle: "", body: text, persistent: asking)
    }

    /// The session a notice belongs to.
    static func session(ofNotice id: String) -> String? {
        guard id.hasPrefix(noticePrefix) else { return nil }
        return id.dropFirst(noticePrefix.count).split(separator: ":").first.map(String.init)
    }

    /// Notices still up for a session that has moved on: an answered question.
    static func stale(_ notices: [AppNotice], after report: AgentReport) -> [String] {
        switch report.event {
        case .prompt, .tool, .toolDone, .interrupted, .end, .question:
            return notices.filter { $0.persistent && $0.leaving == nil && session(ofNotice: $0.id) == report.session }
                .map(\.id)
        default: return []
        }
    }

    /// The working session to show: the one that spoke last.
    static func shown(_ sessions: [AgentSession]) -> AgentSession? {
        sessions.filter(\.working).max { $0.updated < $1.updated }
    }

    static func project(_ cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }

    /// A tool call as a short step. `input` holds the tool's string fields.
    static func step(tool: String, input: [String: String]) -> String {
        let file = input["file_path"].map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Read": return "Reading " + (file ?? "a file")
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + (file ?? "a file")
        case "Write": return "Writing " + (file ?? "a file")
        case "Bash": return input["description"] ?? input["command"].map { "Running " + firstWord($0) } ?? "Running"
        case "Grep", "Glob": return "Searching"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading " + (input["url"].flatMap { URL(string: $0)?.host() } ?? "the web")
        case "Agent", "Task": return input["description"].map { "Agent · " + $0 } ?? "Running an agent"
        case "TodoWrite": return "Planning"
        case "Skill": return input["skill"].map { "Skill · " + $0 } ?? "Using a skill"
        default:
            // mcp__server__tool_name → "tool name"
            if tool.hasPrefix("mcp__"), let name = tool.components(separatedBy: "__").last {
                return name.replacingOccurrences(of: "_", with: " ").capitalizedFirst
            }
            return tool
        }
    }

    /// Markdown reply as one plain run of text for a two-line notice.
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty || line.allSatisfy({ "-|:".contains($0) }) { continue }
            var text = line
            while let first = text.first, "#>-*".contains(first) { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            lines.append(text)
        }
        return lines.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "|", with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Elapsed time as the closed notch shows it: 0:42, 12:05, 1:02:10.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        let (h, m, s) = (t / 3600, t / 60 % 60, t % 60)
        let ss = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):" + (m < 10 ? "0\(m)" : "\(m)") + ":" + ss }
        return "\(m):" + ss
    }

    private static func firstWord(_ command: String) -> String {
        String(command.split(separator: " ").first ?? "")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
