import AppKit
import SwiftUI

/// The notifications tab: Notification Center's list as one stack per app.
/// A stack shows its newest notification and opens to the rest; on hover the time
/// turns into a close mark that clears the whole app. Clear all sweeps them off one by one.
struct HistoryPane: View {
    let items: [HistoryItem]
    let clear: (String?) -> Void
    let open: (HistoryItem) -> Void
    @State private var expanded: String?
    @State private var sweeping: Set<String> = []

    var body: some View {
        let stacks = History.stacks(items).filter { !sweeping.contains($0.app) }
        VStack(spacing: 4) {
            if stacks.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "bell").font(.system(size: 16))
                    Text("No notifications").font(.system(size: 12))
                }
                .foregroundStyle(Theme.dim)
                .transition(.opacity.combined(with: .offset(y: 4)))
                Spacer()
            } else {
                HStack {
                    Text(count(stacks))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    TextButton(title: "Clear all") { sweep(stacks) }
                }
                .padding(.leading, 8)
                .frame(height: 22)
                ScrollView(.vertical, showsIndicators: false) {
                    TimelineView(.everyMinute) { context in
                        LazyVStack(spacing: 8) {
                            ForEach(stacks) { stack in
                                StackCard(stack: stack, now: context.date, isOpen: expanded == stack.app,
                                          toggle: { expanded = expanded == stack.app ? nil : stack.app },
                                          clear: { withAnimation(.easeInOut(duration: 0.3)) { clear(stack.app) } },
                                          open: open)
                                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)),
                                                            removal: .opacity.combined(with: .offset(x: 40))))
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: items)
    }

    private func count(_ stacks: [AppStack]) -> String {
        let n = stacks.reduce(0) { $0 + $1.items.count }
        return (n == 1 ? "1 notification" : "\(n) notifications").uppercased()
    }

    /// Stacks leave one after another, top first, then everything is cleared at once.
    private func sweep(_ stacks: [AppStack]) {
        for (i, stack) in stacks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055 * Double(i)) {
                _ = withAnimation(.easeInOut(duration: 0.3)) { sweeping.insert(stack.app) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055 * Double(stacks.count) + 0.35) {
            clear(nil)
            sweeping = []
        }
    }
}

private struct StackCard: View {
    let stack: AppStack
    let now: Date
    let isOpen: Bool
    let toggle: () -> Void
    let clear: () -> Void
    let open: (HistoryItem) -> Void
    @State private var isHovered = false

    var body: some View {
        let latest = stack.latest
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(item: latest).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(stack.app.uppercased()).foregroundStyle(Theme.dim)
                        if stack.items.count > 1 { Text("\(stack.items.count)").foregroundStyle(Theme.muted) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    line(latest)
                }
                Spacer(minLength: 6)
                ZStack(alignment: .trailing) {
                    Text(History.age(latest.date, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .opacity(isHovered ? 0 : 1)
                    CloseMark(action: clear)
                        .opacity(isHovered ? 1 : 0)
                        .scaleEffect(isHovered ? 1 : 0.5)
                        .rotationEffect(.degrees(isHovered ? 0 : -90))
                }
                .frame(width: 40, alignment: .trailing)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture { stack.items.count > 1 ? toggle() : open(latest) }

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(stack.items.dropFirst()) { item in
                        HStack(spacing: 8) {
                            line(item)
                            Spacer(minLength: 6)
                            Text(History.age(item.date, now: now)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        .frame(height: 34)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.cardEdge).frame(height: 1) }
                        .contentShape(Rectangle())
                        .onTapGesture { open(item) }
                    }
                }
                .padding(.leading, 46)
                .padding(.trailing, 10)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(isHovered ? Theme.cardHover : Theme.card))
        .background(alignment: .bottom) { edges }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    /// Bold title, then the text in a softer tone, on one line.
    private func line(_ item: HistoryItem) -> some View {
        (Text(item.title).fontWeight(.semibold).foregroundStyle(Theme.ink)
            + Text(item.body.isEmpty ? "" : "  " + item.body).foregroundStyle(Theme.soft))
            .font(.system(size: 12.5))
            .lineLimit(1)
    }

    /// The cards behind, one strip per extra notification (two at most), hidden when open.
    private var edges: some View {
        ZStack(alignment: .bottom) {
            if stack.items.count > 2 {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(Theme.cardFar).frame(height: 6).padding(.horizontal, 20).offset(y: 8)
            }
            if stack.items.count > 1 {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(Theme.cardNear).frame(height: 6).padding(.horizontal, 10).offset(y: 4)
            }
        }
        .opacity(isOpen ? 0 : 1)
    }
}

/// The sender's photo with an app badge when there is one, else the app icon.
private struct Avatar: View {
    let item: HistoryItem

    var body: some View {
        if let data = item.image, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    appIcon.frame(width: 12, height: 12).background(Circle().fill(.black).padding(-1.5)).offset(x: 2, y: 2)
                }
        } else {
            appIcon
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = Senders.icon(item.app) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 7).fill(Theme.raised)
        }
    }
}

/// Quiet text button: muted, brighter with a soft fill on hover.
private struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? Theme.ink : Theme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.surface : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
        .accessibilityLabel("Clear")
        .onHover { isHovered = $0 }
    }
}
