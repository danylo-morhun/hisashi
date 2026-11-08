import SwiftUI

/// Volume or brightness beside the camera: icon on the left, level on the right.
struct HudBar: View {
    let hud: Hud
    let notch: CGSize

    var body: some View {
        HStack {
            Image(systemName: hud.symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)
            Spacer(minLength: notch.width)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(hud.muted ? Theme.muted : Theme.ink)
                        .frame(width: geo.size.width * CGFloat(hud.muted ? 0 : hud.level))
                }
            }
            .frame(width: 52, height: 4)
            .animation(.spring(response: 0.22, dampingFraction: 0.9), value: hud.level)
        }
        .padding(.horizontal, 14)
        .frame(height: notch.height)
    }
}

extension Hud {
    var symbol: String {
        switch kind {
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || level == 0 { return "speaker.slash.fill" }
            if level < 1 / 3 { return "speaker.wave.1.fill" }
            return level < 2 / 3 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}
