import AppKit
import SwiftUI

/// Another app's notification spread into the menu bar beside the camera:
/// icon and title in the left wing, time in the right, the text under the camera,
/// the app's buttons below when wanted. Every column starts at the title's edge.
/// Click opens what it points to; on hover the time turns into a close mark.
struct NoticeBanner: View {
    let notice: AppNotice
    let notch: CGSize
    let hovering: Bool
    let clock: Countdown?
    let act: (NoticeEffect) -> Void
    @State private var arrived = false

    private let edge = Layout.noticeEdge

    var body: some View {
        let layout = Notices.layout(notice, notch: notch)
        let width = notch.width + layout.wing * 2
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                leftWing(layout.label)
                    .frame(width: layout.wing, alignment: .leading)
                    .offset(x: arrived ? 0 : 50)
                Spacer(minLength: notch.width)
                rightWing
                    .frame(width: layout.wing, alignment: .trailing)
                    .offset(x: arrived ? 0 : -50)
            }
            .frame(height: notch.height)
            .opacity(arrived ? 1 : 0)
            .blur(radius: arrived ? 0 : 4)
            .modifier(WingExit(exit: notice.leaving))

            VStack(alignment: .leading, spacing: 10) {
                if layout.titleBelow || layout.bodyLines > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        if layout.titleBelow {
                            Text(notice.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .frame(height: Layout.noticeLine)
                        }
                        if layout.bodyLines > 0 {
                            Text(notice.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.soft)
                                .lineSpacing(Layout.noticeLine - 14.3)
                                .lineLimit(layout.bodyLines)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { act(.open) }
                }
                if Notices.showsActions(notice, hovering: hovering) {
                    ActionRow(actions: notice.actions, pressed: notice.pressed) { act(.press($0)) }
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .padding(.leading, Layout.noticeTextStart)
            .padding(.trailing, edge)
            .padding(.top, layout.belowHeight > 0 ? 0 : Layout.noticeBottom - 2)
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : -6)
            .blur(radius: arrived ? 0 : 4)
            .modifier(BodyExit(exit: notice.leaving))
        }
        .frame(width: width, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: notice.leaving)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: Notices.showsActions(notice, hovering: hovering))
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.06)) { arrived = true }
        }
    }

    private func leftWing(_ label: String) -> some View {
        HStack(spacing: 6) {
            SenderIcon(app: notice.app, photo: notice.image).frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.leading, edge)
        .contentShape(Rectangle())
        .onTapGesture { act(.open) }
    }

    /// Time and countdown ring; on hover the close mark spins in.
    private var rightWing: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 5) {
                if let clock { CountdownRing(clock: clock).frame(width: 11, height: 11) }
                Text("now").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .opacity(hovering ? 0 : 1)
            CloseMark { act(.close) }
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.5)
                .rotationEffect(.degrees(hovering ? 0 : -90))
        }
        .padding(.trailing, edge)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovering)
    }
}

/// Wings slide back into the camera when the notice is opened; otherwise they lift away.
private struct WingExit: ViewModifier {
    let exit: NoticeExit?

    func body(content: Content) -> some View {
        content
            .opacity(exit == nil ? 1 : 0)
            .blur(radius: exit == nil ? 0 : 3)
            .scaleEffect(exit == .open ? 0.8 : 1)
            .offset(y: exit == nil || exit == .open ? 0 : -8)
    }
}

/// The text under the camera shrinks into it on open, lifts away otherwise.
private struct BodyExit: ViewModifier {
    let exit: NoticeExit?

    func body(content: Content) -> some View {
        content
            .opacity(exit == nil ? 1 : 0)
            .blur(radius: exit == nil ? 0 : 3)
            .scaleEffect(exit == .open ? 0.85 : 1, anchor: .top)
            .offset(y: exit == nil || exit == .open ? 0 : -8)
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pressed)
    }

    private func row(_ shown: Int) -> some View {
        HStack(spacing: 6) {
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
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(primary ? Color.black : Theme.ink)
        .padding(.horizontal, 11)
        .frame(height: 24)
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
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovered ? Theme.ink : Theme.muted)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isHovered ? Theme.raised : Theme.surface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .onHover { isHovered = $0 }
    }
}

/// The sender's app icon.
/// The sender: their photo with a small app badge when the app sent one, else the app icon.
private struct SenderIcon: View {
    let app: String
    var photo: Data?

    var body: some View {
        if let photo, let image = NSImage(data: photo) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    appIcon
                        .frame(width: 9, height: 9)
                        .background(Circle().fill(.black).padding(-1))
                        .offset(x: 2, y: 2)
                }
        } else {
            appIcon
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = Senders.icon(app) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Theme.raised)
        }
    }
}

extension AnyTransition {
    /// The next waiting notice comes up from below once the one above has left.
    static var noticeRise: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Shift(active: true, y: 8, scale: 0.97), identity: Shift(active: false, y: 8, scale: 0.97))
                .animation(.spring(response: 0.75, dampingFraction: 0.92)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    /// A new notice comes up in place; the one it replaces lifts away.
    static var noticeSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Shift(active: true, y: 8, scale: 0.98), identity: Shift(active: false, y: 8, scale: 0.98))
                .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.12)),
            removal: .modifier(active: Shift(active: true, y: -8, scale: 0.98), identity: Shift(active: false, y: -8, scale: 0.98))
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
