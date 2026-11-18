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

private struct LifeOpen: View {
    let app: LifeApp
    @Environment(Life.self) private var life

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                BackButton(title: app.title) { life.expand(nil) }
                header
                Spacer(minLength: 4)
                trailing
                LinkButton { life.site(app.path) }
            }
            .frame(height: 26)
            content
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }

    @ViewBuilder private var header: some View {
        switch app {
        case .kuroji:
            if let p = life.plan?.progress { Caption(text: "\(monthName) · day \(p.elapsed) of \(p.days)") }
        case .keizoku:
            let count = Seikatsu.habitCount(life.today)
            Caption(text: "\(count.done) of \(count.due) today")
        default: EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch app {
        case .seiryu:
            ForEach(life.focus?.sections ?? [], id: \.section) { s in
                Chip(title: "\(s.section) \(s.cards?.count ?? 0)", isOn: s.section == life.section) {
                    life.section = s.section
                }
            }
        case .kuroji:
            if let captures = Seikatsu.items(life.today, .kuroji).first(where: { $0.key == "kuroji:captures" }) {
                Pill(title: captures.title, tone: .warning) { life.site("/kuroji?tab=transactions") }
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch app {
        case .seiryu: SeiryuView()
        case .kuroji: KurojiView()
        case .kyuu: KyuuView()
        case .keizoku: KeizokuView()
        }
    }

    private var monthName: String {
        guard let month = life.plan?.month, let date = Seikatsu.day(month + "-01") else { return "" }
        return date.formatted(.dateTime.month(.wide))
    }
}

private struct SeiryuView: View {
    @Environment(Life.self) private var life

    var body: some View {
        let cards = life.focus?.sections?.first { $0.section == life.section }?.cards ?? []
        if life.focus == nil {
            Waiting()
        } else if cards.isEmpty {
            Empty(line: "Nothing here")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(cards) { card in
                        CardRow(card: card)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: cards.map(\.id))
            }
        }
    }
}

private struct CardRow: View {
    let card: SeiryuFocus.Card
    @Environment(Life.self) private var life

    var body: some View {
        let done = life.finished.contains(card.id)
        HStack(spacing: 10) {
            Button { life.finish(card) } label: { CheckCircle(done: done, size: 18) }
                .buttonStyle(.plain)
                .accessibilityLabel("Done: \(card.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(done ? Theme.muted : Theme.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if card.priority == "urgent" {
                Text("URGENT").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.color(.failure))
            }
            Text(Seikatsu.when(card, today: life.focus?.today))
                .font(.system(size: 11))
                .foregroundStyle(overdue ? Theme.color(.failure) : Theme.soft)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .frame(height: 32)
    }

    private var detail: String {
        [card.project, card.group, card.checklist].compactMap { $0 }.joined(separator: " · ")
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
            let totals = plan.totals
            let spent = totals?.expenseActual ?? 0
            let planned = totals?.expensePlan ?? 0
            let pace = plan.progress?.share ?? 0
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Caption(text: "Spent")
                    (Text(Seikatsu.amount(spent)).font(.system(size: 22, weight: .semibold))
                        + Text(" of \(Seikatsu.amount(planned)) \(unit)").font(.system(size: 12)).foregroundColor(Theme.soft))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    PaceBar(share: planned > 0 ? spent / planned : 0, pace: pace)
                    Spacer(minLength: 6)
                    Text(paceLine(spent: spent, planned: planned, pace: pace, free: totals?.free, unit: unit))
                        .font(.system(size: 11)).foregroundStyle(Theme.soft).lineLimit(1)
                }
                .frame(width: 168)

                VStack(alignment: .leading, spacing: 3) {
                    Caption(text: "Over plan")
                    let over = (plan.expense ?? [])
                        .filter { ($0.actual ?? 0) > ($0.plan ?? 0) }
                        .sorted { ($0.actual ?? 0) - ($0.plan ?? 0) > ($1.actual ?? 0) - ($1.plan ?? 0) }
                    if over.isEmpty {
                        Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(over.prefix(4), id: \.name) { line in
                        HStack(spacing: 0) {
                            Text(line.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Seikatsu.amount(line.actual ?? 0)).foregroundStyle(Theme.color(.warning))
                            Text(" / \(Seikatsu.amount(line.plan ?? 0))").foregroundStyle(Theme.muted)
                        }
                        .font(.system(size: 12))
                        .frame(height: 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Caption(text: "Funds this month")
                    let funds = (plan.funds ?? []).filter { ($0.instalment ?? 0) > 0 }
                    if funds.isEmpty {
                        Text("All filled").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(funds.prefix(3)) { fund in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(fund.name).font(.system(size: 12)).lineLimit(1)
                                Text(fundLine(fund, unit: unit)).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Pill(title: "Transfer") { life.site("/kuroji?tab=plan") }
                        }
                        .frame(height: 30)
                    }
                }
                .frame(width: 170)
            }
        } else {
            Waiting()
        }
    }

    private func paceLine(spent: Double, planned: Double, pace: Double, free: Double?, unit: String) -> String {
        let ahead = planned > 0 && spent / planned > pace + 0.02
        let freeText = free.map { " · \(Seikatsu.amount($0)) \(unit) free" } ?? ""
        return (ahead ? "Ahead of pace" : "Within pace") + freeText
    }

    private func fundLine(_ fund: KurojiPlan.Fund, unit: String) -> String {
        let amount = "\(Seikatsu.amount(fund.instalment ?? 0)) \(unit)"
        guard let due = fund.dueDate.flatMap(Seikatsu.day) else { return amount }
        return amount + " · by " + due.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Spent against the plan, with a mark where the month is.
private struct PaceBar: View {
    let share: Double
    let pace: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(share > 1 ? Theme.color(.warning) : Theme.ink)
                    .frame(width: geo.size.width * min(1, max(0, share)))
                RoundedRectangle(cornerRadius: 1).fill(Theme.color(.warning))
                    .frame(width: 2, height: 12)
                    .offset(x: geo.size.width * min(1, max(0, pace)) - 1)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("\(Int(share * 100))% of the plan spent, \(Int(pace * 100))% of the month gone")
    }
}

private struct KyuuView: View {
    @Environment(Life.self) private var life

    var body: some View {
        let items = Seikatsu.items(life.today, .kyuu)
        let call = items.first { $0.key.hasPrefix("kyuu:call:") }
        let ghost = items.first { $0.key == "kyuu:ghost" }
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Caption(text: "Next call")
                Spacer(minLength: 4)
                if let call {
                    Text(call.note ?? "").font(.system(size: 20, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(call.title).font(.system(size: 12)).foregroundStyle(Theme.soft).lineLimit(1)
                } else {
                    Text("None booked").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.soft)
                }
                Spacer(minLength: 4)
                if let n = life.kyuu?.inProgress { Caption(text: "\(n) in progress") }
            }
            .frame(width: 160, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Caption(text: "Funnel")
                Spacer(minLength: 4)
                if let k = life.kyuu {
                    HStack(spacing: 6) {
                        Stat(value: k.sent ?? 0, label: "sent")
                        Stat(value: k.answered ?? 0, label: "answered")
                        Stat(value: k.interviewed ?? 0, label: "interview")
                        Stat(value: k.offers ?? 0, label: "offer")
                    }
                    Spacer(minLength: 4)
                    Caption(text: rates(k), color: Theme.soft)
                } else {
                    Waiting()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Caption(text: "Waiting")
                Spacer(minLength: 4)
                let n = ghost.flatMap { Seikatsu.leadingNumber($0.title) } ?? 0
                Text("\(n)").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(n > 0 ? Theme.color(.warning) : Theme.ink)
                Caption(text: n > 0 ? "quiet long enough" : "no one to close", color: Theme.soft)
                Spacer(minLength: 4)
                if n > 0 {
                    Pill(title: "Close all as ghosted", wide: true) { life.site("/kyuu") }
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(.bottom, 2)
    }

    private func rates(_ k: KyuuStats) -> String {
        var parts: [String] = []
        if let r = k.replyRate { parts.append("\(Int((r * 100).rounded()))% reply") }
        if let m = k.firstAnswer?.median { parts.append("first answer in \(Int(m)) days") }
        return parts.joined(separator: " · ")
    }
}

private struct Stat: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.system(size: 17, weight: .semibold))
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    HStack(spacing: 6) {
                        ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                            Text(Seikatsu.weekdayLetter(day))
                                .foregroundStyle(i == days.count - 1 ? Theme.ink : Theme.muted)
                                .frame(width: i == days.count - 1 ? 24 : 18)
                        }
                    }
                    Text("week · best").frame(width: 74, alignment: .trailing)
                }
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(height: 18)
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
            HStack(spacing: 6) {
                ForEach(week.dropLast(), id: \.date) { day in
                    let due = Seikatsu.isDue(habit, on: day.date)
                    Circle()
                        .fill(day.done == true ? Theme.color(.success) : Theme.line)
                        .frame(width: due ? 8 : 4, height: due ? 8 : 4)
                        .frame(width: 18)
                }
            }
            .accessibilityHidden(true)
            Button { life.tick(habit.id, done: !done) } label: { CheckCircle(done: done, size: 24) }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Clear \(habit.name) today" : "Tick \(habit.name) today")
            Text("\(habit.thisWeek ?? 0)/\(Seikatsu.weekGoal(habit)) · \(habit.streak?.best ?? 0)")
                .font(.system(size: 11)).foregroundStyle(Theme.soft)
                .frame(width: 74, alignment: .trailing)
        }
        .frame(height: 30)
    }
}

// MARK: Parts

/// An open circle that fills green with a check once done; the check shows on hover.
private struct CheckCircle: View {
    let done: Bool
    let size: CGFloat
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Circle().fill(done ? Theme.color(.success) : .clear)
            if !done { Circle().strokeBorder(isHovered ? Theme.soft : Theme.dim, lineWidth: 1.5) }
            if done || isHovered {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(done ? Color.black : Theme.soft)
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

private struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(isOn ? Theme.ink : Theme.soft)
                .background(Capsule().fill(isOn ? Theme.line : (isHovered ? Theme.raised : .clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

private struct Pill: View {
    let title: String
    var tone: Tone = .neutral
    var wide = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(maxWidth: wide ? .infinity : nil)
                .frame(height: wide ? 26 : 22)
                .foregroundStyle(tone == .neutral ? Theme.ink : Theme.color(tone))
                .background(Capsule().fill(isHovered ? Theme.lineHover : Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct Caption: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).lineLimit(1)
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
