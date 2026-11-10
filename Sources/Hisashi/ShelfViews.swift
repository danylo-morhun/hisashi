import AppKit
import SwiftUI

/// The shelf tab: the pile of kept files on the left, what to do with them on the right.
/// Clicking the pile fans it out into single files.
struct ShelfPane: View {
    @Environment(Shelf.self) private var shelf
    @State private var fanned = false

    var body: some View {
        HStack(spacing: 8) {
            Pile(fanned: $fanned).frame(width: 236)
            Group {
                if fanned && !shelf.items.isEmpty {
                    FileStrip().transition(.opacity)
                } else {
                    Actions().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.18), value: fanned)
        .onAppear { shelf.prune() }
        .onChange(of: shelf.items.isEmpty) { _, empty in if empty { fanned = false } }
    }
}

private struct Pile: View {
    @Binding var fanned: Bool
    @Environment(Shelf.self) private var shelf

    var body: some View {
        if shelf.items.isEmpty {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.raised, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(Theme.muted)
                        Text("Drop files on the notch").font(.system(size: 13, weight: .semibold))
                        Text("They stay here for a week").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
        } else {
            HStack(spacing: 16) {
                Stack(items: Array(shelf.items.prefix(3)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(shelf.items.count == 1 ? "1 file" : "\(shelf.items.count) files")
                        .font(.system(size: 13, weight: .semibold))
                    Text(ByteCountFormatter.string(fromByteCount: shelf.totalSize, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(Theme.soft)
                    Text(fanned ? "Drag out all at once, click to fold" : "Drag out all at once, click to fan out")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(DragHandle(items: shelf.items, shelf: shelf) { fanned.toggle() })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Up to three files, newest on top, tilted like a pile of paper.
private struct Stack: View {
    let items: [ShelfItem]
    @Environment(Shelf.self) private var shelf
    private static let tilts: [Double] = [-7, 4, 12]
    private static let offsets: [CGSize] = [CGSize(width: -6, height: 6), CGSize(width: 2, height: 0), CGSize(width: 10, height: 2)]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
                    FileImage(item: item, size: CGSize(width: 64, height: 76))
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .rotationEffect(.degrees(Self.tilts[index]))
                        .offset(Self.offsets[index])
                }
            }
            .frame(width: 92, height: 112)
            Text("\(shelf.items.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 22)
                .background(Capsule().fill(Theme.ink))
                .offset(x: 2, y: -2)
        }
        .frame(width: 92, height: 112)
    }
}

/// A preview fills its frame with round corners; an icon is drawn whole.
private struct FileImage: View {
    let item: ShelfItem
    let size: CGSize
    @Environment(Shelf.self) private var shelf

    var body: some View {
        let thumb = shelf.thumbs[item.id]
        Group {
            if let thumb, thumb.isPreview {
                Image(nsImage: thumb.image).resizable().interpolation(.high).scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(nsImage: shelf.image(of: item)).resizable().interpolation(.high).scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

private struct Actions: View {
    @Environment(Shelf.self) private var shelf
    @State private var shareAnchor = ViewRef()

    var body: some View {
        let empty = shelf.items.isEmpty
        let urls = shelf.items.map(\.url)
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ActionTile(icon: .airdrop, title: "AirDrop", detail: "to devices nearby") { shelf.airdrop(urls) }
                ActionTile(icon: .symbol("square.and.arrow.up"), title: "Share…") {
                    if let view = shareAnchor.view { shelf.share(from: view) }
                }
                .background(Anchor(ref: shareAnchor))
            }
            GridRow {
                ActionTile(icon: .symbol("folder"), title: "Move to…", detail: shelf.moveFolder.lastPathComponent) { shelf.moveAll() }
                ActionTile(icon: .symbol("trash"), title: "Clear") { shelf.clear() }
            }
        }
        .disabled(empty)
        .opacity(empty ? 0.4 : 1)
    }
}

private struct ActionTile: View {
    enum Icon { case airdrop, symbol(String) }

    let icon: Icon
    let title: String
    var detail: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                iconView.frame(width: 18, height: 18, alignment: .leading)
                Spacer(minLength: 0)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.soft).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(isHovered ? Theme.raised : Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .airdrop:
            if let image = NSSharingService(named: .sendViaAirDrop)?.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 16)).foregroundStyle(Color(hex: 0x0A84FF))
            }
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 16))
        }
    }
}

/// The pile fanned out: each file alone, to drag out, open or take off the shelf.
private struct FileStrip: View {
    @Environment(Shelf.self) private var shelf

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shelf.items) { item in
                    FileTile(item: item)
                }
            }
        }
        .scrollClipDisabled(false)
    }
}

private struct FileTile: View {
    let item: ShelfItem
    @Environment(Shelf.self) private var shelf

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                FileImage(item: item, size: CGSize(width: 56, height: 56))
                    .frame(height: 64)
                VStack(spacing: 1) {
                    Text(item.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.system(size: 10)).foregroundStyle(Theme.soft)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 96)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(DragHandle(items: [item], shelf: shelf) { shelf.open(item) })
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.name)

            Button { shelf.remove(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.raised))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Take \(item.name) off the shelf")
            .padding(5)
        }
    }
}

/// Shown instead of the whole panel while a file is dragged over the open notch.
struct DropTargets: View {
    let target: DropTarget
    let notch: CGSize

    var body: some View {
        HStack(spacing: 8) {
            Zone(isOn: target == .keep, title: "Keep on shelf", detail: "for a week") {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 24))
            }
            Zone(isOn: target == .airdrop, title: "AirDrop", detail: "sends at once") {
                if let image = NSSharingService(named: .sendViaAirDrop)?.image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 28, height: 28)
                } else {
                    Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 24)).foregroundStyle(Color(hex: 0x0A84FF))
                }
            }
        }
        .padding(.top, notch.height + 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .animation(.easeOut(duration: 0.15), value: target)
    }

    private struct Zone<Icon: View>: View {
        let isOn: Bool
        let title: String
        let detail: String
        @ViewBuilder let icon: Icon

        var body: some View {
            VStack(spacing: 8) {
                icon.frame(height: 28)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.soft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(isOn ? Theme.surface : .clear))
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.ink, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.raised, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
        }
    }
}

/// Starts an AppKit drag of the given files, as SwiftUI drags only one item at a time.
/// A press without movement counts as a click.
private struct DragHandle: NSViewRepresentable {
    let items: [ShelfItem]
    let shelf: Shelf
    let click: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.items = items
        view.shelf = shelf
        view.click = click
    }

    final class HandleView: NSView {
        var items: [ShelfItem] = []
        weak var shelf: Shelf?
        var click: () -> Void = {}
        private var start: NSPoint?

        // The panel is never key; the first press must still count.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { start = event.locationInWindow }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            self.start = nil
            shelf?.beginDrag(items, from: self, event: event)
        }

        override func mouseUp(with event: NSEvent) {
            if start != nil { click() }
            start = nil
        }
    }
}

/// Holds the AppKit view behind a SwiftUI one, for menus that need a place to open from.
final class ViewRef {
    weak var view: NSView?
}

private struct Anchor: NSViewRepresentable {
    let ref: ViewRef

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ref.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { ref.view = view }
}
