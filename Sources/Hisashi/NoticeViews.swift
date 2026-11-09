import AppKit
import SwiftUI

/// Another app's notification as an island dropped out of the camera:
/// big icon, app, title, body, the app's buttons with the first one bright.
/// Click opens what it points to; on hover the time turns into a close mark.
struct NoticeBanner: View {
    let notice: AppNotice
    let notch: CGSize
    let clock: Countdown?
    let act: (NoticeEffect) -> Void
    @State private var isHovered = false
    @State private var arrived = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                SenderIcon(app: notice.app)
                    .frame(width: 44, height: 44)
                    .scaleEffect(arrived ? 1 : 0.3)
                    .rotationEffect(.degrees(arrived ? 0 : -12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.app.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                    Text(notice.title.isEmpty ? notice.app : notice.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.soft)
                            .lineSpacing(2)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                corner
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 18)
            }
            .frame(height: Layout.noticeBody - 4)
            .contentShape(Rectangle())
            .onTapGesture { act(.open) }

            if !notice.actions.isEmpty {
                ActionRow(actions: notice.actions, pressed: notice.pressed) { act(.press($0)) }
                    .frame(height: Layout.noticeActions, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, notch.height + 4)
        .modifier(NoticeExitEffect(exit: notice.leaving))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.45), value: notice.leaving)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: notice.actions)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.5).delay(0.16)) { arrived = true }
        }
    }

    /// Time and countdown ring; on hover the close mark spins in.
    private var corner: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 6) {
                if let clock { CountdownRing(clock: clock).frame(width: 12, height: 12) }
                Text("now").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .opacity(isHovered ? 0 : 1)
            CloseMark { act(.close) }
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                .rotationEffect(.degrees(isHovered ? 0 : -90))
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isHovered)
        }
        .frame(width: 52, height: 22, alignment: .trailing)
    }

    /// Subtitle and body under the title.
    private var detail: String? {
        let parts = [notice.subtitle, notice.body].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The exit plays on the content while the shape shrinks back into the camera.
private struct NoticeExitEffect: ViewModifier {
    let exit: NoticeExit?

    func body(content: Content) -> some View {
        content
            .opacity(exit == nil ? 1 : 0)
            .blur(radius: exit == nil ? 0 : 6)
            .scaleEffect(scale, anchor: .top)
            .offset(y: offset)
    }

    private var scale: CGFloat {
        switch exit {
        case .open: return 0.7
        case .press, .timeout: return 0.98
        default: return 1
        }
    }

    private var offset: CGFloat {
        switch exit {
        case .open: return -30
        case .close: return -18
        case .press, .timeout: return -12
        case nil: return 0
        }
    }
}

/// How much of the countdown is left. Core Animation drains it in the render server,
/// so the app does no per-frame work; a pause freezes the layer where it is.
private struct CountdownRing: NSViewRepresentable {
    let clock: Countdown

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) { view.show(clock) }

    final class RingView: NSView {
        private let track = CAShapeLayer()
        private let fill = CAShapeLayer()
        private var shown: Countdown?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (layer, color) in [(track, Theme.raisedNS), (fill, Theme.mutedNS)] {
                layer.fillColor = nil
                layer.strokeColor = color.cgColor
                layer.lineWidth = 1.5
                layer.lineCap = .round
                self.layer?.addSublayer(layer)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            // Starts at twelve o'clock and drains counterclockwise, like a clock hand going back.
            let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            for layer in [track, fill] {
                layer.frame = bounds
                layer.path = path
            }
        }

        func show(_ clock: Countdown) {
            guard clock != shown else { return }
            shown = clock
            // No implicit fades: the ring jumps to where the clock is, then drains.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let now = Date()
            let progress = clock.progress(at: now)
            fill.removeAllAnimations()
            fill.strokeEnd = progress
            guard clock.since != nil, progress > 0 else { return }
            let drain = CABasicAnimation(keyPath: "strokeEnd")
            drain.fromValue = progress
            drain.toValue = 0
            drain.duration = clock.remaining(at: now)
            drain.fillMode = .forwards
            drain.isRemovedOnCompletion = false
            fill.strokeEnd = 0
            fill.add(drain, forKey: "drain")
        }
    }
}

/// Capsule buttons, the first one bright. As many as fit at their own width share the row;
/// the rest go into Options. A pressed button folds into a green check.
private struct ActionRow: View {
    let actions: [String]
    let pressed: String?
    let press: (String) -> Void

    var body: some View {
        ZStack {
            if pressed != nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.color(.success)))
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach((0...actions.count).reversed(), id: \.self) { shown in
                        row(shown)
                    }
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pressed)
    }

    private func row(_ shown: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.prefix(shown).enumerated()), id: \.offset) { i, title in
                Button { press(title) } label: { ActionCapsule(title: title, primary: i == 0) }
                    .buttonStyle(PressStyle())
            }
            if shown < actions.count {
                Menu {
                    ForEach(actions.dropFirst(shown), id: \.self) { title in
                        Button(title) { press(title) }
                    }
                } label: {
                    ActionCapsule(title: "Options", primary: shown == 0, chevron: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

private struct ActionCapsule: View {
    let title: String
    var primary = false
    var chevron = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).fixedSize()
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(primary ? Color.black : Theme.ink)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(SwiftUI.Capsule().fill(fill))
        .contentShape(SwiftUI.Capsule())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var fill: Color {
        if primary { return isHovered ? .white : Theme.ink }
        return isHovered ? Theme.raised : Theme.surface
    }
}

/// Buttons give a little under the finger.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct CloseMark: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovered ? Theme.ink : Theme.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isHovered ? Theme.raised : Theme.surface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .onHover { isHovered = $0 }
    }
}

/// The sender's app icon.
private struct SenderIcon: View {
    let app: String

    var body: some View {
        if let image = Senders.icon(app) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 11).fill(Theme.raised)
        }
    }
}

extension AnyTransition {
    /// The next waiting notice comes up from below once the one above has left.
    static var noticeRise: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Shift(active: true, y: 18, scale: 0.94), identity: Shift(active: false, y: 18, scale: 0.94))
                .animation(.spring(response: 0.75, dampingFraction: 0.92)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    /// A new notice drops in front; the one it covers steps back.
    static var noticeSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Shift(active: true, y: -16, scale: 0.96), identity: Shift(active: false, y: -16, scale: 0.96))
                .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.12)),
            removal: .modifier(active: Shift(active: true, y: 16, scale: 0.95), identity: Shift(active: false, y: 16, scale: 0.95))
                .animation(.easeIn(duration: 0.22))
        )
    }
}

private struct Shift: ViewModifier {
    let active: Bool
    let y: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 4 : 0)
            .scaleEffect(active ? scale : 1, anchor: .top)
            .offset(y: active ? y : 0)
    }
}
