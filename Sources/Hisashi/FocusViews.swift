import SwiftUI

/// Focus tab: Claude sessions and CI runs in one feed, work in progress on top.
struct FocusPane: View {
    let items: [FocusItem]

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
                ForEach(items) { FocusRow(item: $0) }
                Spacer(minLength: 0)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: items.map(\.id))
        }
    }
}

private struct FocusRow: View {
    let item: FocusItem
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
            FocusTime(item: item).frame(width: 52, alignment: .trailing)
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
private struct FocusTime: View {
    let item: FocusItem

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

/// A run's state as a mark: a ring filling with its jobs while it runs, a check or a cross after.
struct RunMark: View {
    let run: CIRun
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch run.status {
            case .queued: ProgressRing(progress: 0, tint: Theme.muted)
            case .running: ProgressRing(progress: run.progress, tint: Theme.color(.warning))
            case .passed: StatusMark(tone: .success)
            case .failed: StatusMark(tone: .failure)
            case .cancelled: StatusMark(tone: .neutral)
            }
        }
        .frame(width: size, height: size)
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

struct ProgressRing: View {
    let progress: Double
    let tint: Color
    var line: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raised, lineWidth: line)
            Circle().trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(line / 2)
        .animation(.easeOut(duration: 0.4), value: progress)
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

/// Closed notch while CI runs: the ring left of the camera, elapsed time right of it.
struct CIActivity: View {
    let run: CIRun
    let notch: CGSize

    var body: some View {
        HStack(spacing: 0) {
            ProgressRing(progress: run.progress, tint: Theme.color(.warning), line: 2)
                .frame(width: 16, height: 16)
            Spacer(minLength: notch.width)
            TimelineView(.periodic(from: run.started, by: 1)) { context in
                Text(Agents.elapsed(context.date.timeIntervalSince(run.started)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.color(.warning))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: notch.height)
    }
}
