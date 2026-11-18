import SwiftUI

/// The seikatsu tab: one tile per app; a tile opens into that app's own view until Back.
struct LifePane: View {
    @Environment(Life.self) private var life

    var body: some View {
        Group {
            switch life.phase {
            case .ready:
                ZStack {
                    if let app = life.open {
                        LifeOpen(app: app)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else {
                        LifeTiles()
                            .transition(.scale(scale: 1.03).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: life.open)
            case .noToken:
                Quiet(line: "Add a seikatsu token to seikatsu.json", button: "Open seikatsu settings") { life.openSettings() }
            case .unauthorized:
                Quiet(line: "seikatsu refused the token", button: "Open seikatsu settings") { life.openSettings() }
            case .loading:
                Quiet(line: "Reading seikatsu…")
            case .failed:
                Quiet(line: "seikatsu did not answer", button: "Try again") { life.wake() }
            }
        }
        .onAppear { life.wake() }
    }
}

// MARK: Tiles

private struct LifeTiles: View {
    @Environment(Life.self) private var life

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LifeApp.allCases) { app in
                Tile(app: app)
            }
        }
    }
}

private struct Tile: View {
    let app: LifeApp
    @Environment(Life.self) private var life
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer(minLength: 6)
            if app == .keizoku {
                HabitTicks()
            } else {
                let tile = Seikatsu.tile(app, today: life.today, plan: life.plan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.big)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(tile.tone == .neutral ? Theme.ink : Theme.color(tile.tone))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(tile.label).font(.system(size: 11)).foregroundStyle(Theme.soft).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(tile.line).font(.system(size: 11)).foregroundStyle(Theme.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(isHovered ? Theme.surfaceHover : Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { life.expand(app) }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(app.title)")
    }

    private var heading: String {
        guard app == .keizoku else { return app.title }
        let count = Seikatsu.habitCount(life.today)
        return "Keizoku · \(count.done) of \(count.due)"
    }
}

/// Today's habits with a tick each, in the Keizoku tile.
private struct HabitTicks: View {
    @Environment(Life.self) private var life

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach((life.today?.habits ?? []).filter { $0.due ?? true }.prefix(4), id: \.id) { habit in
                Button { life.tick(habit.id, done: habit.done != true) } label: {
                    HStack(spacing: 6) {
                        CheckCircle(done: habit.done == true, size: 16)
                        Text(habit.name).font(.system(size: 12)).lineLimit(1)
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(habit.done == true ? "Clear \(habit.name)" : "Tick \(habit.name)")
            }
        }
    }
}

// MARK: Open app
// One main fact, then rows of name and value. Color only on what waits on the user;
// everything that leaves for the site carries the ↗ arrow.

private struct LifeOpen: View {
    let app: LifeApp
    @Environment(Life.self) private var life

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                BackButton(title: app.title) { life.expand(nil) }
                Spacer(minLength: 4)
                if app == .seiryu {
                    ForEach(life.focus?.sections ?? [], id: \.section) { s in
                        SectionTab(title: s.section, isOn: s.section == life.section) { life.section = s.section }
                    }
                }
                LinkButton { life.site(app.path) }
                    .padding(.leading, app == .seiryu ? -4 : 0)
            }
            .frame(height: 26)
            content
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(EdgeInsets(top: 8, leading: 6, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }

    @ViewBuilder private var content: some View {
        switch app {
        case .seiryu: SeiryuView()
        case .kuroji: KurojiView()
        case .kyuu: KyuuView()
        case .keizoku: KeizokuView()
        }
    }
}

private struct SeiryuView: View {
    @Environment(Life.self) private var life

    var body: some View {
        let cards = life.focus?.sections?.first { $0.section == life.section }?.cards ?? []
        let projects = Set(cards.compactMap(\.project))
        if life.focus == nil {
            Waiting()
        } else if cards.isEmpty {
            Empty(line: "Nothing here")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(cards) { card in
                            CardRow(card: card, showsProject: projects.count > 1)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: cards.map(\.id))
                }
                // A project every card shares is said once, under the list.
                if projects.count == 1, let project = projects.first {
                    Text(project).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        .padding(.top, 4)
                }
            }
        }
    }
}

private struct CardRow: View {
    let card: SeiryuFocus.Card
    let showsProject: Bool
    @Environment(Life.self) private var life

    var body: some View {
        let done = life.finished.contains(card.id)
        HStack(spacing: 10) {
            Button { life.finish(card) } label: {
                CheckCircle(done: done, size: 16, ring: card.priority == "urgent" ? Theme.color(.failure) : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done: \(card.title)" + (card.priority == "urgent" ? ", urgent" : ""))
            Text(card.title).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(done ? Theme.muted : Theme.ink)
            Spacer(minLength: 4)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Text(Seikatsu.when(card, today: life.focus?.today, quiet: true))
                .font(.system(size: 12))
                .foregroundStyle(overdue ? Theme.color(.failure) : Theme.soft)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private var detail: String {
        [showsProject ? card.project : nil, card.checklist].compactMap { $0 }.joined(separator: " · ")
    }

    private var overdue: Bool {
        guard let due = card.due, let today = life.focus?.today else { return false }
        return due < today
    }
}

private struct KurojiView: View {
    @Environment(Life.self) private var life

    var body: some View {
        if let plan = life.plan {
            let unit = Seikatsu.currency(plan.currency)
            let spent = plan.totals?.expenseActual ?? 0
            let planned = plan.totals?.expensePlan ?? 0
            let share = planned > 0 ? spent / planned : 0
            let pace = plan.progress?.share ?? 0
            let ahead = share > pace + 0.02
            let captures = Seikatsu.items(life.today, .kuroji).first { $0.key == "kuroji:captures" }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Seikatsu.amount(spent)) \(unit)").font(.system(size: 20, weight: .semibold))
                        Spacer(minLength: 6)
                        Text("of \(Seikatsu.amount(planned))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    PaceBar(share: share, pace: pace, ahead: ahead)
                    if let p = plan.progress {
                        Text("Day \(p.elapsed) of \(p.days), " + (ahead ? "spending ahead of the month" : "within the month's pace"))
                            .font(.system(size: 12)).foregroundStyle(Theme.soft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let captures {
                        ActionLink(title: captures.title, tone: .warning) { life.site("/kuroji?tab=transactions") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 0) {
                    let over = (plan.expense ?? [])
                        .filter { ($0.actual ?? 0) > ($0.plan ?? 0) }
                        .sorted { ($0.actual ?? 0) - ($0.plan ?? 0) > ($1.actual ?? 0) - ($1.plan ?? 0) }
                    if over.isEmpty {
                        Row(name: "Every category within plan", value: "", muted: true)
                    }
                    ForEach(over.prefix(3), id: \.name) { line in
                        HStack(spacing: 0) {
                            Text(line.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Seikatsu.amount(line.actual ?? 0))
                            Text(" / \(Seikatsu.amount(line.plan ?? 0))").foregroundStyle(Theme.muted)
                        }
                        .font(.system(size: 12))
                        .frame(height: 24)
                    }
                    Spacer(minLength: 0)
                    let funds = (plan.funds ?? []).filter { ($0.instalment ?? 0) > 0 }
                    if !funds.isEmpty {
                        Row(name: "Into \(funds.count) fund" + (funds.count == 1 ? "" : "s"),
                            value: "\(Seikatsu.amount(funds.reduce(0) { $0 + ($1.instalment ?? 0) })) \(unit)", muted: true)
                    }
                }
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            Waiting()
        }
    }
}

/// Spent against the plan, with a mark where the month is. Orange only while spending runs ahead.
private struct PaceBar: View {
    let share: Double
    let pace: Double
    let ahead: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(ahead ? Theme.color(.warning) : Theme.ink)
                    .frame(width: geo.size.width * min(1, max(0, share)))
                RoundedRectangle(cornerRadius: 1).fill(Theme.ink)
                    .frame(width: 2, height: 10)
                    .offset(x: geo.size.width * min(1, max(0, pace)) - 1)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("\(Int(share * 100))% of the plan spent, \(Int(pace * 100))% of the month gone")
    }
}

private struct KyuuView: View {
    @Environment(Life.self) private var life

    var body: some View {
        let items = Seikatsu.items(life.today, .kyuu)
        let call = items.first { $0.key.hasPrefix("kyuu:call:") }
        let ghosted = items.first { $0.key == "kyuu:ghost" }.flatMap { Seikatsu.leadingNumber($0.title) } ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let call {
                    Text((call.note ?? "").replacingOccurrences(of: " at ", with: ", "))
                        .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(call.title).font(.system(size: 12)).foregroundStyle(Theme.soft).lineLimit(1)
                } else {
                    Text("No call booked").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.soft)
                }
            }
            Spacer(minLength: 4)
            if let n = life.kyuu?.inProgress, n > 0 {
                Row(name: "\(n) in progress", value: "")
            }
            if ghosted > 0 {
                HStack {
                    Text("\(ghosted) with no answer").font(.system(size: 12))
                    Spacer(minLength: 6)
                    ActionLink(title: "Close as ghosted", tone: .warning) { life.site("/kyuu") }
                }
                .frame(height: 24)
            }
            if let k = life.kyuu {
                Text(funnel(k)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(height: 22)
            }
        }
    }

    private func funnel(_ k: KyuuStats) -> String {
        "\(k.sent ?? 0) sent → \(k.answered ?? 0) answered → \(k.interviewed ?? 0) interviews → \(k.offers ?? 0) offer"
            + ((k.offers ?? 0) == 1 ? "" : "s")
    }
}

private struct KeizokuView: View {
    @Environment(Life.self) private var life

    var body: some View {
        if let habits = life.habits {
            let days = habits.first?.last7?.map(\.date) ?? []
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        ForEach(days.dropLast(), id: \.self) { day in
                            Text(Seikatsu.weekdayLetter(day)).frame(width: 8)
                        }
                    }
                    Text(days.last.map(Seikatsu.weekdayLetter) ?? "").foregroundStyle(Theme.ink).frame(width: 18)
                    Color.clear.frame(width: 32, height: 1)
                }
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(height: 16)
                .accessibilityHidden(true)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(habits) { habit in HabitRow(habit: habit) }
                    }
                }
            }
        } else {
            Waiting()
        }
    }
}

private struct HabitRow: View {
    let habit: KeizokuHabit
    @Environment(Life.self) private var life

    var body: some View {
        let week = habit.last7 ?? []
        let done = week.last?.done == true
        HStack(spacing: 10) {
            Text(habit.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                ForEach(week.dropLast(), id: \.date) { day in
                    let due = Seikatsu.isDue(habit, on: day.date)
                    Circle()
                        .fill(day.done == true ? Theme.color(.success) : Theme.line)
                        .frame(width: due ? 8 : 4, height: due ? 8 : 4)
                        .frame(width: 8)
                }
            }
            .accessibilityHidden(true)
            Button { life.tick(habit.id, done: !done) } label: { CheckCircle(done: done, size: 18) }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Clear \(habit.name) today" : "Tick \(habit.name) today")
            Text("\(habit.thisWeek ?? 0)/\(Seikatsu.weekGoal(habit))")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .frame(width: 32, alignment: .trailing)
                .accessibilityLabel("\(habit.thisWeek ?? 0) of \(Seikatsu.weekGoal(habit)) this week")
        }
        .frame(height: 28)
    }
}

// MARK: Parts

/// An open circle that fills green with a check once done; the check shows on hover.
/// A colored ring marks an urgent card.
private struct CheckCircle: View {
    let done: Bool
    let size: CGFloat
    var ring: Color?
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle().fill(done ? Theme.color(.success) : .clear)
            if !done { Circle().strokeBorder(ring ?? (isHovered ? Theme.soft : Theme.dim), lineWidth: 1.5) }
            if done || isHovered {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(done ? Color.black : (ring ?? Theme.soft))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: done)
    }
}

private struct BackButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 26)
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Theme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to all apps")
        .onHover { isHovered = $0 }
    }
}

/// Opens the app on the site.
private struct LinkButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? Theme.ink : Theme.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isHovered ? Theme.raised : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in seikatsu")
        .onHover { isHovered = $0 }
    }
}

/// A section of Seiryu's focus list: plain text, the chosen one bright.
private struct SectionTab: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .lineLimit(1)
                .frame(height: 26)
                .foregroundStyle(isOn || isHovered ? Theme.ink : Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// Something to do on the site: text with the ↗ arrow, colored when it waits on the user.
private struct ActionLink: View {
    let title: String
    var tone: Tone = .neutral
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
            }
            .frame(height: 24)
            .foregroundStyle(tone == .neutral ? Theme.ink : Theme.color(tone))
            .opacity(isHovered ? 0.8 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), opens seikatsu")
        .onHover { isHovered = $0 }
    }
}

/// A name and its value on one line.
private struct Row: View {
    let name: String
    let value: String
    var muted = false

    var body: some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
        }
        .font(.system(size: 12))
        .foregroundStyle(muted ? Theme.soft : Theme.ink)
        .frame(height: 24)
    }
}

private struct Waiting: View {
    var body: some View {
        Text("Reading…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Empty: View {
    let line: String

    var body: some View {
        Text(line).font(.system(size: 12)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
