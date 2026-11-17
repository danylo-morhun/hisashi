import SwiftUI

/// Status tab: Claude sessions, working ones on top.
struct StatusPane: View {
    let agents: [AgentSession]

    private var sorted: [AgentSession] {
        Array(agents.sorted { a, b in a.working != b.working ? a.working : a.updated > b.updated }.prefix(5))
    }

    var body: some View {
        if agents.isEmpty {
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay {
                    VStack(spacing: 4) {
                        Text("All quiet").font(.system(size: 13, weight: .semibold))
                        Text("Claude sessions show here")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
        } else {
            VStack(spacing: 2) {
                ForEach(sorted) { StatusRow(agent: $0) }
                Spacer(minLength: 0)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sorted.map(\.id))
        }
    }
}

private struct StatusRow: View {
    let agent: AgentSession
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 16, height: 16)
            Text(agent.project)
                .font(.system(size: 13, weight: agent.working ? .semibold : .regular))
                .foregroundStyle(agent.working ? Theme.ink : Theme.soft)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            Text(agent.working ? agent.step : "Idle")
                .font(.system(size: 12))
                .foregroundStyle(agent.working ? Theme.soft : Theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusTime(agent: agent).frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9).fill(isHovered ? Theme.raised : (agent.working ? Theme.surface : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { Terminals.focus(tty: agent.tty) }
        .transition(.opacity)
    }

    @ViewBuilder
    private var icon: some View {
        if agent.working {
            Spark()
        } else {
            SparkMark().stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).padding(2)
        }
    }
}

/// Time on a row: live while it works, the age once it is idle.
private struct StatusTime: View {
    let agent: AgentSession

    var body: some View {
        if agent.working {
            TimelineView(.periodic(from: agent.since, by: 1)) { context in
                text(Agents.elapsed(context.date.timeIntervalSince(agent.since)))
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                text(History.age(agent.updated, now: context.date))
            }
        }
    }

    private func text(_ s: String) -> some View {
        Text(s).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.soft)
    }
}

/// Claude's spark standing still, for a session that waits.
struct SparkMark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, d = r * 0.7071
        var p = Path()
        for (dx, dy) in [(0, r), (r, 0), (d, d), (d, -d)] {
            p.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
            p.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
        }
        return p
    }
}
