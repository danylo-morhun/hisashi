import AppKit
import SwiftUI

/// Closed notch while Claude works: the spark turns left of the camera, elapsed time right of it.
/// A second working session shows as a count beside the spark.
struct AgentActivity: View {
    let agent: AgentSession
    let working: Int
    let notch: CGSize

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Spark().frame(width: 16, height: 16)
                if working > 1 {
                    Text("\(working)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: notch.width)
            Elapsed(since: agent.since)
        }
        .padding(.horizontal, 11)
        .frame(height: notch.height)
    }
}

/// Open notch, beside the pin: what Claude does right now, and in which project once two work.
struct AgentStatus: View {
    let agent: AgentSession
    let showsProject: Bool

    var body: some View {
        HStack(spacing: 6) {
            Spark().frame(width: 12, height: 12)
            (Text(showsProject ? agent.project + "  " : "").foregroundStyle(Theme.dim) + Text(agent.step).foregroundStyle(Theme.soft))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(agent.step)
                .transition(.opacity.combined(with: .offset(y: 5)))
            Elapsed(since: agent.since)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: agent.step)
    }
}

/// Seconds since the turn started, redrawn once a second.
private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Agents.elapsed(context.date.timeIntervalSince(since)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
    }
}

/// Claude's spark: turns a quarter, breathing in and out. Drawn and animated by Core Animation,
/// so it costs no SwiftUI redraws.
struct Spark: NSViewRepresentable {
    func makeNSView(context: Context) -> SparkView { SparkView() }
    func updateNSView(_ view: SparkView, context: Context) {}

    final class SparkView: NSView {
        private let shape = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            shape.fillColor = nil
            shape.strokeColor = NSColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1).cgColor
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let side = min(bounds.width, bounds.height)
            shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            shape.lineWidth = side * 0.11
            let path = CGMutablePath()
            let c = side / 2, r = side * 0.375, d = r * 0.7071
            path.move(to: CGPoint(x: c, y: c - r)); path.addLine(to: CGPoint(x: c, y: c + r))
            path.move(to: CGPoint(x: c - r, y: c)); path.addLine(to: CGPoint(x: c + r, y: c))
            path.move(to: CGPoint(x: c - d, y: c - d)); path.addLine(to: CGPoint(x: c + d, y: c + d))
            path.move(to: CGPoint(x: c - d, y: c + d)); path.addLine(to: CGPoint(x: c + d, y: c - d))
            shape.path = path
            if shape.animation(forKey: "turn") == nil { shape.add(Self.turn, forKey: "turn") }
        }

        /// Ends at an angle where the eight arms look the same as at the start, so the loop is seamless.
        private static let turn: CAAnimation = {
            let a = CAKeyframeAnimation(keyPath: "transform")
            a.values = [CATransform3DIdentity,
                        CATransform3DScale(CATransform3DMakeRotation(-.pi / 4, 0, 0, 1), 0.8, 0.8, 1),
                        CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)]
            a.keyTimes = [0, 0.5, 1]
            a.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.6, 0, 0.4, 1),
                                 CAMediaTimingFunction(controlPoints: 0.6, 0, 0.4, 1)]
            a.duration = 1.6
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            return a
        }()
    }
}
