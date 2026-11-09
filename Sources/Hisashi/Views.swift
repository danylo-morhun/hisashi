import SwiftUI

enum Theme {
    static let ink = Color(hex: 0xF5F5F7)
    static let muted = Color(hex: 0x8E8E93)
    static let surface = Color(hex: 0x1C1C1E)
    static let raised = Color(hex: 0x2C2C2E)
    /// Small caps labels, quieter than muted.
    static let dim = Color(hex: 0x636366)
    /// Body copy of a notice, a step above muted.
    static let soft = Color(hex: 0xA1A1A6)
    var body: some View {
        let mode = model.state.mode
        let target = Layout.size(model.state, notch: model.notch)
        let size = shown ?? target
        let targetRadius = Layout.bottomRadius(model.state, notch: model.notch)
        let shape = NotchShape(flare: Layout.flare, bottomRadius: radius ?? targetRadius)
        // Content and black body are one view, clipped by one shape: nothing can float outside it.
        content(mode)
            .frame(width: size.width, height: size.height, alignment: .top)
            .padding(.horizontal, Layout.flare)
            .clipShape(shape)
            // Shadow lives on the still black body, so live content above it
            // (the equalizer) does not make the system redraw the shadow every frame.
            .background(shape.fill(.black).shadow(color: .black.opacity(size.height > model.notch.height ? 0.45 : 0),
                                                  radius: size.height > model.notch.height ? 20 : 0, y: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(Theme.ink)
            .environment(\.colorScheme, .dark)
            .onChange(of: target) { old, new in
                // Losing the closed activity: let the icons fade first, then narrow,
                // the reverse of how they arrived. Everything else moves at once.
                let fadingActivity = mode == .compact && new.width < old.width && new.height == old.height
                // A notice drops out of the camera with a bounce; everything else keeps the calm spring.
                let dropping = mode == .notice && old.height <= model.notch.height + 1 && new.height > old.height
                withAnimation((dropping ? Self.drop : Self.spring).delay(fadingActivity ? 0.24 : 0)) {
                    shown = new
                    radius = targetRadius
                }
            }
    }

    @ViewBuilder
    private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .compact:
            if let np = model.state.activity {
                let width = Layout.size(.compact, activity: true, notch: model.notch).width
                CompactActivity(nowPlaying: np, notch: model.notch)
                    .frame(width: width)
                    .transition(.activityFade)
            }
        case .event:
            if let event = model.state.event {
                EventBanner(event: event, notch: model.notch).transition(.panelFade)
            }
        case .hud:
            if let hud = model.state.hud {
                HudBar(hud: hud, notch: model.notch)
                    .frame(width: Layout.size(.hud, activity: false, notch: model.notch).width)
                    .transition(.activityFade)
            }
        case .notice:
            if let notice = model.state.notice {
                NoticeBanner(notice: notice, notch: model.notch, clock: model.noticeClock) { model.act(notice, $0) }
                    .id(notice.id)
                    .transition(model.state.noticeEntrance == .rise ? .noticeRise : .noticeSwap)
            }
        case .open:
            OpenPanel(model: model).transition(.panelFade)
        }
    }
}

/// Black body with concave flares at the top edge and round bottom corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, f = flare
        let r = min(bottomRadius, h / 2, (w - 2 * f) / 2)
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - r))
        p.addQuadCurve(to: CGPoint(x: f + r, y: h), control: CGPoint(x: f, y: h))
        p.addLine(to: CGPoint(x: w - f - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - f, y: h - r), control: CGPoint(x: w - f, y: h))
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        p.closeSubpath()
        return p
    }
}

struct EventBanner: View {
    let event: NotchEvent
    let notch: CGSize

    var body: some View {
        let tint = Theme.color(event.tone)
        HStack(spacing: 12) {
            Circle().fill(tint).frame(width: 10, height: 10).shadow(color: tint, radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 14, weight: .semibold))
                Text(event.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Text("now").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 20)
        .frame(height: Layout.eventBody)
        .padding(.top, notch.height)
    }
}

struct OpenPanel: View {
    let model: NotchModel

    var body: some View {
        VStack(spacing: 10) {
            // Top row lives in the "ears" left and right of the camera.
            HStack(spacing: 0) {
                TabBar(selected: model.state.tab) { model.send(.select($0)) }
                Spacer(minLength: model.notch.width + 16)
                IconButton(symbol: model.state.isPinned ? "pin.fill" : "pin",
                           label: "Pin open", isOn: model.state.isPinned) { model.send(.togglePin) }
            }
            .frame(height: model.notch.height)

            TabPane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .contextMenu {
            Button("Quit Hisashi") { NSApp.terminate(nil) }
        }
    }
}

struct TabBar: View {
    let selected: Tab
    let pick: (Tab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                IconButton(symbol: tab.symbol, label: tab.title, isOn: tab == selected) { pick(tab) }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 26)
                .foregroundStyle(isOn ? Theme.ink : Theme.muted)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.raised : (isHovered ? Theme.surface : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

struct TabPane: View {
    let model: NotchModel

    var body: some View {
        Group {
            switch model.state.tab {
            case .media:
                MediaPane(players: model.state.players, current: model.state.nowPlaying,
                          select: { model.send(.selectPlayer($0)) }, command: model.media)
            default: Placeholder(tab: model.state.tab)
            }
        }
        .id(model.state.tab)
        .transition(.opacity)
    }
}

struct Placeholder: View {
    let tab: Tab

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.surface)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: tab.symbol).font(.system(size: 20)).foregroundStyle(Theme.muted)
                    Text(tab.title).font(.system(size: 15, weight: .semibold))
                    Text("Coming next").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
    }
}

extension Tab {
    var symbol: String {
        switch self {
        case .media: return "music.note"
        case .today: return "calendar"
        case .shelf: return "tray"
        case .focus: return "scope"
        case .life: return "leaf"
        }
    }

    var title: String {
        switch self {
        case .media: return "Now playing"
        case .today: return "Today"
        case .shelf: return "Shelf"
        case .focus: return "Focus"
        case .life: return "Seikatsu"
        }
    }
}

/// Opacity, blur and scale from the top edge; one modifier for every notch transition.
private struct Fade: ViewModifier {
    let active: Bool
    var scale: CGFloat
    var y: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
            .scaleEffect(active ? scale : 1, anchor: .top)
            .offset(y: active ? y : 0)
    }
}

extension AnyTransition {
    /// Closed activity icons fly out of the camera after the shape has grown,
    /// and fly back into it before the shape narrows.
    static var activityFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Fade(active: true, scale: 0.6), identity: Fade(active: false, scale: 0.6))
                .animation(.easeOut(duration: 0.3).delay(0.1)),
            removal: .modifier(active: Fade(active: true, scale: 0.6), identity: Fade(active: false, scale: 0.6))
                .animation(.easeIn(duration: 0.26))
        )
    }

    /// Panel and banner content: arrive after the shape, leave shrinking with it as one piece.
    static var panelFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Fade(active: true, scale: 0.98, y: -6), identity: Fade(active: false, scale: 0.98, y: -6))
                .animation(.easeOut(duration: 0.28).delay(0.12)),
            removal: .modifier(active: Fade(active: true, scale: 0.7), identity: Fade(active: false, scale: 0.7))
                .animation(NotchView.spring)
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
