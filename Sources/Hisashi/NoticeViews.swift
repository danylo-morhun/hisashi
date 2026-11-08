import AppKit
import SwiftUI

/// Another app's notification, grown out of the camera: icon, title, body, the app's buttons.
/// Click opens what it points to; the close mark shows on hover.
struct NoticeBanner: View {
    let notice: AppNotice
    let notch: CGSize
    let act: (NoticeEffect) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                SenderIcon(app: notice.app).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title.isEmpty ? notice.app : notice.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    Text("now").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .opacity(isHovered ? 0 : 1)
                    CloseMark { act(.close) }.opacity(isHovered ? 1 : 0)
                }
                .frame(width: 26)
            }
            .frame(height: Layout.noticeBody)

            if !notice.actions.isEmpty {
                // As many buttons as fit at their own width; the rest go into Options.
                ViewThatFits(in: .horizontal) {
                    ForEach((0...notice.actions.count).reversed(), id: \.self) { shown in
                        ActionRow(actions: notice.actions, shown: shown, act: act)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Layout.noticeActions - 8, alignment: .top)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, notch.height)
        .contentShape(Rectangle())
        .onTapGesture { act(.open) }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.2), value: notice.actions)
    }

    /// Subtitle and body under the title.
    private var detail: String? {
        let parts = [notice.subtitle, notice.body].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The first `shown` buttons, then an Options menu with the rest.
private struct ActionRow: View {
    let actions: [String]
    let shown: Int
    let act: (NoticeEffect) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions.prefix(shown), id: \.self) { title in
                ActionButton(title: title) { act(.press(title)) }
            }
            if shown < actions.count {
                Menu {
                    ForEach(actions.dropFirst(shown), id: \.self) { title in
                        Button(title) { act(.press(title)) }
                    }
                } label: {
                    ActionLabel(title: "Options", chevron: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .fixedSize()
    }
}

/// One of the app's buttons: quiet grey capsule, lighter on hover.
private struct ActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { ActionLabel(title: title) }
            .buttonStyle(.plain)
    }
}

private struct ActionLabel: View {
    let title: String
    var chevron = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(isHovered ? Theme.raised : Theme.surface))
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
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
            RoundedRectangle(cornerRadius: 7).fill(Theme.raised)
        }
    }
}
