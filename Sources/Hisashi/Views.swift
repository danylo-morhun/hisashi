import SwiftUI

enum Theme {
    static let ink = Color(hex: 0xF5F5F7)
    static let muted = Color(hex: 0x8E8E93)
    static let surface = Color(hex: 0x1C1C1E)
    static let raised = Color(hex: 0x2C2C2E)

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: return ink
        case .success: return Color(hex: 0x30D158)
        case .warning: return Color(hex: 0xFF9F0A)
        case .failure: return Color(hex: 0xFF453A)
        }
    }
}

struct NotchView: View {
    let model: NotchModel

    var body: some View {
        let mode = model.state.mode
        let size = Layout.size(model.state, notch: model.notch)
        ZStack(alignment: .top) {
            NotchShape(flare: Layout.flare, bottomRadius: Layout.bottomRadius(mode))
                .fill(.black)
                .frame(width: size.width + Layout.flare * 2, height: size.height)
                .shadow(color: .black.opacity(mode == .compact ? 0 : 0.45), radius: 20, y: 10)
            content(mode)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Theme.ink)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.48, dampingFraction: 0.82), value: size)
    }

    @ViewBuilder
    private func content(_ mode: NotchMode) -> some View {
        switch mode {
        case .compact:
            if let np = model.state.activity {
                // Fixed width: when music stops the icons fade toward the camera
                // while the shape narrows, instead of being pushed out at once.
                let width = Layout.size(.compact, activity: true, notch: model.notch).width
                CompactActivity(nowPlaying: np, notch: model.notch)
                    .frame(width: width)
                    .transition(.activityFade)
            }
        case .event:
            if let event = model.state.event {
                EventBanner(event: event, notch: model.notch).transition(.blurFade)
            }
        case .open:
            OpenPanel(model: model).transition(.blurFade)
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

private struct ActivityFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 4 : 0)
            .scaleEffect(active ? 0.6 : 1)
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
            .offset(y: active ? -6 : 0)
    }
}

extension AnyTransition {
    static var activityFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ActivityFade(active: true), identity: ActivityFade(active: false))
                .animation(.easeOut(duration: 0.3).delay(0.1)),
            removal: .modifier(active: ActivityFade(active: true), identity: ActivityFade(active: false))
                .animation(.easeIn(duration: 0.3))
        )
    }

    static var blurFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.28).delay(0.12)),
            removal: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeInOut(duration: 0.24))
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
