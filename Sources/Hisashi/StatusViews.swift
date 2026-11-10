import SwiftUI

/// Status tab: Claude sessions and CI runs in one feed, work in progress on top.
struct StatusPane: View {
    let items: [StatusItem]

    var body: some View {
        if items.isEmpty {
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay {
                    VStack(spacing: 4) {
                        Text("All quiet").font(.system(size: 13, weight: .semibold))
                        Text("Claude sessions and CI runs show here")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
        } else {
            VStack(spacing: 2) {
                ForEach(items) { StatusRow(item: $0) }
                Spacer(minLength: 0)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: items.map(\.id))
        }
    }
}

private struct StatusRow: View {
    let item: StatusItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 16, height: 16)
            Text(project)
                .font(.system(size: 13, weight: item.isActive ? .semibold : .regular))
                .foregroundStyle(item.isActive ? Theme.ink : Theme.soft)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(item.isActive ? Theme.soft : Theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusTime(item: item).frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9).fill(isHovered ? Theme.raised : (item.isActive ? Theme.surface : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .transition(.opacity)
    }

    private var project: String {
        switch item {
        case .agent(let a): return a.project
        case .run(let r): return r.name
        }
    }

    private var detail: String {
        switch item {
        case .agent(let a): return a.working ? a.step : "Idle"
        case .run(let r): return CI.detail(r)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .agent(let a):
            if a.working { Spark() } else { SparkMark().stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).padding(2) }
        case .run(let r): RunMark(run: r)
        }
    }

    private func open() {
        switch item {
        case .agent(let a): Terminals.focus(tty: a.tty)
        case .run(let r): Browser.open(r.url)
        }
    }
}

/// Time on a row: live while it runs, the age once it is done.
private struct StatusTime: View {
    let item: StatusItem

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                text(Agents.elapsed(context.date.timeIntervalSince(since)))
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                text(History.age(item.updated, now: context.date))
            }
        }
    }

    private var since: Date? {
        switch item {
        case .agent(let a): return a.working ? a.since : nil
        case .run(let r): return r.isActive ? r.started : nil
        }
    }

    private func text(_ s: String) -> some View {
        Text(s).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.soft)
    }
}

/// A run's state as a mark: its job segments while it runs, a check or a cross after.
struct RunMark: View {
    let run: CIRun

    var body: some View {
        switch run.status {
        case .queued, .running: JobSegments(jobs: run.jobs, gap: 1.5).frame(width: 16, height: 2)
        case .passed: StatusMark(tone: .success).frame(width: 12, height: 12)
        case .failed: StatusMark(tone: .failure).frame(width: 12, height: 12)
        case .cancelled: StatusMark(tone: .neutral).frame(width: 12, height: 12)
        }
    }
}

/// One short bar per job: green done, orange running, grey waiting, red failed.
struct JobSegments: View {
    let jobs: [CIRun.Job]
    var gap: CGFloat = 3
    /// Many jobs share segments; off when the caller already did that.
    var grouped = true

    var body: some View {
        HStack(spacing: gap) {
            ForEach(Array((grouped ? CI.segments(jobs) : jobs).enumerated()), id: \.offset) { _, job in
                Capsule().fill(Self.color(job))
            }
        }
        .animation(.easeOut(duration: 0.3), value: jobs)
    }

    static func color(_ job: CIRun.Job) -> Color {
        switch job {
        // Like the system fill on dark: present, but quieter than any state.
        case .waiting: return .white.opacity(0.18)
        case .running: return Theme.color(.warning)
        case .passed: return Theme.color(.success)
        case .failed: return Theme.color(.failure)
        }
    }
}

extension View {
    /// Lays a run's jobs along the bottom of the closed notch, centered under this item
    /// (the spark, the time), so each ear's track lines up with what sits above it.
    func jobTrack(_ jobs: [CIRun.Job]?, height: CGFloat) -> some View {
        frame(height: height).overlay(alignment: .bottom) {
            if let jobs {
                JobSegments(jobs: jobs, gap: 2, grouped: false)
                    .frame(width: Layout.earTrack, height: 2)
                    .padding(.bottom, 3)
                    .fixedSize()
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }
        }
    }
}

/// Filled circle with a check, a cross or, for neutral, a bar.
struct StatusMark: View {
    let tone: Tone

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                Circle().fill(tone == .neutral ? Theme.muted : Theme.color(tone))
                Path { p in
                    switch tone {
                    case .success:
                        p.move(to: CGPoint(x: s * 0.3, y: s * 0.51))
                        p.addLine(to: CGPoint(x: s * 0.44, y: s * 0.65))
                        p.addLine(to: CGPoint(x: s * 0.7, y: s * 0.38))
                    case .failure:
                        p.move(to: CGPoint(x: s * 0.34, y: s * 0.34)); p.addLine(to: CGPoint(x: s * 0.66, y: s * 0.66))
                        p.move(to: CGPoint(x: s * 0.66, y: s * 0.34)); p.addLine(to: CGPoint(x: s * 0.34, y: s * 0.66))
                    default:
                        p.move(to: CGPoint(x: s * 0.32, y: s * 0.5)); p.addLine(to: CGPoint(x: s * 0.68, y: s * 0.5))
                    }
                }
                .stroke(.black, style: StrokeStyle(lineWidth: max(1.5, s * 0.12), lineCap: .round, lineJoin: .round))
            }
        }
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

/// A git branch: two commits on a line, a third joining from the side.
struct BranchMark: Shape {
    func path(in rect: CGRect) -> Path {
        let u = min(rect.width, rect.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        var p = Path()
        for (x, y) in [(4.5, 3.5), (4.5, 12.5), (11.5, 5.5)] {
            p.addEllipse(in: CGRect(x: rect.minX + (x - 1.8) * u, y: rect.minY + (y - 1.8) * u, width: 3.6 * u, height: 3.6 * u))
        }
        p.move(to: pt(4.5, 5.3)); p.addLine(to: pt(4.5, 10.7))
        p.move(to: pt(11.5, 7.3)); p.addCurve(to: pt(4.5, 10.7), control1: pt(11.5, 10.3), control2: pt(4.5, 8.8))
        return p
    }
}

/// Closed notch while CI runs: a branch left of the camera, elapsed time right of it,
/// the jobs along the bottom under each.
struct CIActivity: View {
    let run: CIRun
    let notch: CGSize

    var body: some View {
        let ears = CI.ears(CI.segments(run.jobs))
        HStack(spacing: 0) {
            BranchMark()
                .stroke(Theme.color(.warning), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 14, height: 14)
                .jobTrack(ears.left, height: notch.height)
            Spacer(minLength: notch.width)
            TimelineView(.periodic(from: run.started, by: 1)) { context in
                Text(Agents.elapsed(context.date.timeIntervalSince(run.started)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.color(.warning))
            }
            .jobTrack(ears.right, height: notch.height)
        }
        .padding(.horizontal, 11)
        .frame(height: notch.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CI.summary(run.jobs))
    }
}
