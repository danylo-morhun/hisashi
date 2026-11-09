import AppKit
import SwiftUI

/// The day at a glance: the date, what is on, and weather, battery and timer.
struct TodayPane: View {
    let model: NotchModel

    var body: some View {
        // Captions count minutes; nothing here needs redrawing more often.
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                DateCard(now: context.date).frame(width: 112)
                AgendaList(today: model.state.today, now: context.date, open: model.openEvent)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    WeatherCard(weather: model.state.today.weather)
                    PowerCard(power: model.state.today.power)
                    TimerControl(timer: model.state.today.timer, entry: model.state.today.entry, send: model.send)
                }
                .frame(width: 148)
            }
        }
    }
}

private enum Format {
    static let locale = Locale(identifier: "en_GB")
}

private struct DateCard: View {
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(now.formatted(Date.FormatStyle(locale: Format.locale).weekday(.wide)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.color(.warning))
            Spacer(minLength: 0)
            Text(now.formatted(Date.FormatStyle(locale: Format.locale).day()))
                .font(.system(size: 62, weight: .semibold).monospacedDigit())
                .tracking(-2)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(now.formatted(Date.FormatStyle(locale: Format.locale).month(.wide)))
                .font(.system(size: 12))
                .foregroundStyle(Theme.soft)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgendaList: View {
    let today: TodayState
    let now: Date
    let open: (DayEvent) -> Void

    var body: some View {
        let rows = Agenda.rows(today.events, at: now)
        if today.calendarAllowed == false {
            Button(action: TodayLinks.openCalendarSettings) {
                message("Allow calendar access")
            }
            .buttonStyle(.plain)
        } else if rows.isEmpty {
            message("Nothing today")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    Button { open(row.event) } label: { AgendaRow(row: row, now: now) }
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private struct AgendaRow: View {
    let row: Agenda.Row
    let now: Date
    @State private var isHovered = false

    private var isFocus: Bool { row.kind == .focus }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.kind == .allDay ? "all day" : Agenda.time(row.event.start))
                    .font(.system(size: row.kind == .allDay ? 11 : 13).monospacedDigit())
                    .foregroundStyle(isFocus ? Theme.ink : row.kind == .past ? Theme.muted : Theme.soft)
                    .fontWeight(isFocus ? .semibold : .regular)
                    .frame(width: 40, alignment: .leading)
                Text(row.event.title)
                    .font(.system(size: 13, weight: isFocus ? .semibold : .regular))
                    .foregroundStyle(row.kind == .past ? Theme.muted : Theme.ink)
                    .strikethrough(row.kind == .past, color: Theme.muted)
                    .lineLimit(1)
            }
            if isFocus {
                Text(Agenda.caption(row.event, at: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.soft)
                    .padding(.leading, 50)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isFocus ? 6 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isFocus || isHovered) ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// A big number with two quiet lines beside it.
private struct FactCard: View {
    let value: String
    var tint = Theme.ink
    let top: String
    let bottom: String

    var body: some View {
        HStack {
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(top).lineLimit(1)
                if !bottom.isEmpty { Text(bottom).lineLimit(1) }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.soft)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WeatherCard: View {
    let weather: Weather?

    var body: some View {
        Button(action: weather == nil ? TodayLinks.openLocationSettings : TodayLinks.openWeather) {
            if let weather {
                FactCard(value: "\(weather.temperature)°", top: weather.summary, bottom: "\(weather.high)° / \(weather.low)°")
            } else {
                FactCard(value: "–", tint: Theme.muted, top: "Weather", bottom: "No location")
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PowerCard: View {
    let power: Power?

    var body: some View {
        if let power {
            FactCard(value: "\(power.percent)%",
                     tint: !power.plugged && power.percent <= 10 ? Theme.color(.warning) : Theme.ink,
                     top: power.plugged ? "Plugged in" : "Battery", bottom: left(power))
        } else {
            FactCard(value: "–", tint: Theme.muted, top: "Battery", bottom: "")
        }
    }

    private func left(_ power: Power) -> String {
        guard let minutes = power.minutesLeft else { return "" }
        return minutes >= 60 ? "\(minutes / 60) h left" : "\(minutes) min left"
    }
}

/// Presets while idle, the field for typed minutes, or the running time and its controls.
private struct TimerControl: View {
    let timer: Countdown?
    let entry: String?
    let send: (NotchAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let timer {
                running(timer)
            } else if let entry {
                TimerField(text: entry)
                TimerKey(symbol: "play.fill", label: "Start timer") { send(.entryKey(.submit, at: Date())) }
                TimerKey(symbol: "xmark", label: "Cancel") { send(.endEntry) }
            } else {
                ForEach([5, 15, 25], id: \.self) { minutes in
                    TimerKey(text: "\(minutes)", label: "Start a \(minutes) minute timer") { start(minutes) }
                }
                TimerKey(symbol: "plus", label: "Type the minutes", quiet: true) { send(.beginEntry) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func start(_ minutes: Int) { send(.startTimer(TimeInterval(minutes * 60), at: Date())) }

    @ViewBuilder
    private func running(_ timer: Countdown) -> some View {
        TimelineView(.periodic(from: timer.since ?? .now, by: 1)) { context in
            Text(Today.clock(timer.remaining(at: context.date)))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        if timer.since == nil {
            TimerKey(symbol: "play.fill", label: "Resume timer") { send(.resumeTimer(at: Date())) }
        } else {
            TimerKey(symbol: "pause.fill", label: "Pause timer") { send(.pauseTimer(at: Date())) }
        }
        TimerKey(symbol: "xmark", label: "Stop timer") { send(.stopTimer) }
    }
}

/// The minutes as they are typed, with a caret blinking twice a second.
private struct TimerField: View {
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            HStack(spacing: 1) {
                Text(text).foregroundStyle(Theme.ink)
                Rectangle().fill(Theme.ink).frame(width: 1.5, height: 14).opacity(on ? 1 : 0)
                Text(" min").foregroundStyle(Theme.soft)
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("Minutes: \(text)")
    }
}

private struct TimerKey: View {
    var text: String?
    var symbol: String?
    let label: String
    var quiet = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                } else if let text {
                    Text(text).font(.system(size: 13, weight: .medium).monospacedDigit())
                }
            }
            .foregroundStyle(quiet ? Theme.soft : Theme.ink)
            .frame(maxWidth: text != nil || quiet ? .infinity : 34, maxHeight: .infinity)
            .background(isHovered ? Theme.raised : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }
}

/// The ring running down in one continuous Core Animation move, so it costs no SwiftUI redraws.
private struct TimerRing: NSViewRepresentable {
    let timer: Countdown
    let tint: NSColor

    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) { view.show(timer, tint: tint) }

    final class RingView: NSView {
        private let track = CAShapeLayer()
        private let arc = CAShapeLayer()
        private var shown: Countdown?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for ring in [track, arc] {
                ring.fillColor = nil
                ring.lineWidth = 2
                ring.lineCap = .round
                layer?.addSublayer(ring)
            }
            track.strokeColor = Theme.raisedNS.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let path = CGMutablePath()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            // From the top, clockwise; the view's y axis points up.
            path.addArc(center: center, radius: 6, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            let scale = window?.backingScaleFactor ?? 2
            for ring in [track, arc] {
                ring.frame = bounds
                ring.path = path
                ring.contentsScale = scale
            }
        }

        /// Starts the move only when the timer itself changes; the once-a-second updates just recolor.
        func show(_ timer: Countdown, tint: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.strokeColor = tint.cgColor
            if timer != shown {
                shown = timer
                let now = Date()
                let start = timer.progress(at: now)
                arc.removeAnimation(forKey: "run")
                arc.strokeEnd = timer.since == nil ? start : 0
                if timer.since != nil {
                    let run = CABasicAnimation(keyPath: "strokeEnd")
                    run.fromValue = start
                    run.toValue = 0
                    run.duration = timer.remaining(at: now)
                    run.timingFunction = CAMediaTimingFunction(name: .linear)
                    arc.add(run, forKey: "run")
                }
            }
            CATransaction.commit()
        }
    }
}

/// Closed notch while the timer runs: its ring left of the camera, the time right of it.
struct TimerActivity: View {
    let timer: Countdown
    let notch: CGSize

    var body: some View {
        TimelineView(.periodic(from: timer.since ?? .now, by: 1)) { context in
            let left = timer.remaining(at: context.date)
            let tint = left <= 60 ? Theme.color(.warning) : Theme.ink
            HStack(spacing: 0) {
                TimerRing(timer: timer, tint: NSColor(tint))
                    .frame(width: 16, height: 16)
                Spacer(minLength: notch.width)
                Text(Today.clock(left))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 11)
            .frame(height: notch.height)
        }
    }
}
