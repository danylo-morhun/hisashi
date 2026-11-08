import SwiftUI

/// Volume or brightness beside the camera: icon on the left, level on the right.
struct HudBar: View {
    let hud: Hud
    let notch: CGSize

    var body: some View {
        HStack {
            icon.frame(width: 24, height: 16)
            Spacer(minLength: notch.width)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(hud.muted ? Theme.muted : Theme.ink)
                        .frame(width: geo.size.width * CGFloat(hud.muted ? 0 : hud.level))
                }
            }
            .frame(width: 52, height: 4)
        }
        .padding(.horizontal, 14)
        .frame(height: notch.height)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: hud)
    }

    @ViewBuilder
    private var icon: some View {
        switch hud.kind {
        case .volume:
            // Waves fill one by one as the level rises.
            Image(systemName: hud.muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: Double(hud.level))
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        case .brightness:
            Sun(level: CGFloat(hud.level)).fill(Theme.ink)
        }
    }
}

/// A sun whose rays grow from dots to full length with the brightness.
struct Sun: Shape {
    var level: CGFloat

    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let size = min(rect.width, rect.height)
        let core = size * 0.2
        let start = size * 0.32
        let length = size * (0.04 + 0.14 * level)
        let width = size * 0.11
        var p = Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2))
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let from = CGPoint(x: c.x + dir.x * start, y: c.y + dir.y * start)
            let to = CGPoint(x: c.x + dir.x * (start + length), y: c.y + dir.y * (start + length))
            var ray = Path()
            ray.move(to: from)
            ray.addLine(to: to)
            p.addPath(ray.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)))
        }
        return p
    }
}
