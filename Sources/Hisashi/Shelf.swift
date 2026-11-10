import AppKit
import Observation
import QuickLookThumbnailing

/// A file put on the shelf.
struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    /// A copy in the shelf's own folder, made because the original was about to vanish
    /// (the screenshot thumbnail, a browser download). Other files are kept by reference.
    let owned: Bool
    let added: Date
    let size: Int64

    var name: String { url.lastPathComponent }
}

/// Where a file dragged onto the notch is let go.
enum DropTarget: Equatable {
    case keep, airdrop
}

/// Files kept for a while to be dragged somewhere else later.
/// They stay a week, until moved away or cleared, across restarts.
@MainActor
@Observable
final class Shelf {
    private(set) var items: [ShelfItem] = []
    /// A file is being dragged over the open notch, and over which target.
    private(set) var incoming: DropTarget?
    /// Previews of pictures and documents; the file's icon until one is made.
    private(set) var thumbs: [UUID: Thumb] = [:]
    /// Set by the shell: files were just put on the shelf.
    @ObservationIgnored var onKept: () -> Void = {}
    /// Set by the shell: a file started or stopped hovering the notch, which opens it over a notice too.
    @ObservationIgnored var onIncoming: (Bool) -> Void = { _ in }
    @ObservationIgnored private let source = DragOut()
    @ObservationIgnored private let promises = OperationQueue()

    struct Thumb: Equatable {
        let image: NSImage
        /// A real preview of the content, drawn filling its frame; else an icon, drawn whole.
        let isPreview: Bool
    }

    static let lifetime: TimeInterval = 7 * 24 * 3600

    init() {
        source.onEnd = { [weak self] ids in MainActor.assumeIsolated { self?.dragEnded(ids) } }
        load()
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    // MARK: Dropping in

    func hover(_ target: DropTarget?) {
        guard incoming != target else { return }
        let flipped = (incoming == nil) != (target == nil)
        incoming = target
        if flipped { onIncoming(target != nil) }
    }

    func receive(_ pasteboard: NSPasteboard, to target: DropTarget) {
        hover(nil)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            target == .keep ? keep(urls) : airdrop(urls)
            return
        }
        // Browsers, Mail and Photos hand over a promise; the file is written where asked.
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty, let folder = Self.newFolder() else { return }
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        var received: [URL] = []
        var answered = 0
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promises) { url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        answered += 1
                        if error == nil { received.append(url) }
                        guard answered == expected else { return }
                        if target == .keep { self.add(received, owned: true) } else { self.airdrop(received) }
                    }
                }
            }
        }
    }

    private func keep(_ urls: [URL]) {
        var owned: [URL] = []
        var referenced: [URL] = []
        for url in urls {
            if Self.isTemporary(url), let folder = Self.newFolder() {
                let copy = folder.appending(path: url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { owned.append(copy) }
            } else {
                referenced.append(url)
            }
        }
        add(referenced, owned: false)
        add(owned, owned: true)
    }

    private func add(_ urls: [URL], owned: Bool) {
        let known = Set(items.map { $0.url.standardizedFileURL })
        let fresh = urls.filter { !known.contains($0.standardizedFileURL) }.map {
            ShelfItem(id: UUID(), url: $0, owned: owned, added: Date(), size: Self.size(of: $0))
        }
        guard !fresh.isEmpty else { return }
        items = fresh.reversed() + items
        fresh.forEach(makeThumb)
        save()
        onKept()
    }

    /// Files that would be gone soon: the floating screenshot, anything in a temporary or cache folder.
    static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return path.hasPrefix(temp) || path.hasPrefix("/private/var/folders/") || path.contains("/TemporaryItems/")
            || path.hasPrefix(NSHomeDirectory() + "/Library/Caches/")
    }

    // MARK: Taking out

    func beginDrag(_ chosen: [ShelfItem], from view: NSView, event: NSEvent) {
        guard !chosen.isEmpty else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let drags = chosen.prefix(12).enumerated().map { index, item in
            let drag = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let shift = CGFloat(index) * 4
            drag.setDraggingFrame(CGRect(x: point.x - 24 + shift, y: point.y - 24 - shift, width: 48, height: 48),
                                  contents: image(of: item))
            return drag
        }
        // More than twelve still go along, just without their own picture.
        let rest = chosen.dropFirst(12).map { item in
            let drag = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            drag.setDraggingFrame(CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: nil)
            return drag
        }
        source.ids = chosen.map(\.id)
        view.beginDraggingSession(with: drags + rest, event: event, source: source)
    }

    /// Dropping into an app only hands it a copy (a chat may never send it), so files stay.
    /// Only a file moved away, by Finder say, leaves the shelf; our emptied folder goes with it.
    private func dragEnded(_ ids: [UUID]) {
        let moved = items.filter { ids.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        guard !moved.isEmpty else { return }
        items.removeAll { moved.contains($0) }
        for item in moved {
            thumbs[item.id] = nil
            if item.owned { Self.removeOwned(item.url.deletingLastPathComponent()) }
        }
        save()
    }

    /// Deletes one of our copy folders, never anything outside the shelf's own store.
    private static func removeOwned(_ folder: URL) {
        let root = store.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(root) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        discard([item])
        save()
    }

    func clear() {
        let all = items
        items = []
        discard(all)
        save()
    }

    func airdrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    func share(from view: NSView) {
        guard !items.isEmpty else { return }
        NSApp.activate()
        NSSharingServicePicker(items: items.map(\.url)).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// The folder the last move went to, Downloads at first.
    var moveFolder: URL {
        UserDefaults.standard.url(forKey: "shelfMoveFolder")
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Asks for a folder and moves every file there; they leave the shelf.
    func moveAll() {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.directoryURL = moveFolder
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let folder = panel.url, let self else { return }
                UserDefaults.standard.set(folder, forKey: "shelfMoveFolder")
                var moved: [UUID] = []
                for item in self.items {
                    let target = Self.free(folder.appending(path: item.name))
                    if (try? FileManager.default.moveItem(at: item.url, to: target)) != nil { moved.append(item.id) }
                }
                let gone = self.items.filter { moved.contains($0.id) }
                self.items.removeAll { moved.contains($0.id) }
                self.discard(gone)
                self.save()
            }
        }
    }

    /// The name with " 2", " 3"… added until nothing is in the way.
    private static func free(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let next = folder.appending(path: name)
            if !fm.fileExists(atPath: next.path) { return next }
        }
        return url
    }

    /// Our copies go with their item; referenced files are never touched.
    private func discard(_ gone: [ShelfItem]) {
        for item in gone {
            thumbs[item.id] = nil
            if item.owned { Self.removeOwned(item.url.deletingLastPathComponent()) }
        }
    }

    // MARK: Pictures

    func image(of item: ShelfItem) -> NSImage {
        thumbs[item.id]?.image ?? NSWorkspace.shared.icon(forFile: item.url.path)
    }

    private func makeThumb(_ item: ShelfItem) {
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96),
                                                   scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let thumb = Thumb(image: rep.nsImage, isPreview: rep.type == .thumbnail)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.items.contains(where: { $0.id == item.id }) { self.thumbs[item.id] = thumb }
                }
            }
        }
    }

    // MARK: Keeping

    private struct Record: Codable {
        let id: UUID
        let bookmark: Data
        let owned: Bool
        let added: Date
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Hisashi")
    }

    private static var listFile: URL { home.appending(path: "shelf.json") }

    /// Where our copies live, one folder per drop so names never clash.
    private static var store: URL { home.appending(path: "Shelf") }

    private static func newFolder() -> URL? {
        let folder = store.appending(path: UUID().uuidString)
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : nil
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let next = walk?.nextObject() as? URL {
                total += Int64((try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    /// Bookmarks follow a file that was moved or renamed; one that is gone leaves the shelf.
    private func load() {
        guard let data = try? Data(contentsOf: Self.listFile),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        var loaded: [ShelfItem] = []
        for record in records {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            loaded.append(ShelfItem(id: record.id, url: url, owned: record.owned, added: record.added, size: Self.size(of: url)))
        }
        items = loaded
        prune()
        sweep()
        items.forEach(makeThumb)
        save()
    }

    /// A week on the shelf is enough.
    func prune(now: Date = Date()) {
        let old = items.filter { now.timeIntervalSince($0.added) > Self.lifetime }
        guard !old.isEmpty else { return }
        items.removeAll { old.contains($0) }
        discard(old)
        save()
    }

    /// Copies whose item is gone, from a quit before their delayed delete.
    private func sweep() {
        let kept = Set(items.filter(\.owned).map { $0.url.deletingLastPathComponent().lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.store, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !kept.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func save() {
        let records = items.compactMap { item in
            (try? item.url.bookmarkData()).map { Record(id: item.id, bookmark: $0, owned: item.owned, added: item.added) }
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        try? data.write(to: Self.listFile, options: .atomic)
    }
}

/// Source of files dragged out of the shelf. Lives apart from the views, which close as the
/// pointer leaves the notch while the drag goes on.
final class DragOut: NSObject, NSDraggingSource {
    var ids: [UUID] = []
    var onEnd: ([UUID]) -> Void = { _ in }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Dropping them back on the notch does nothing.
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd(ids)
        ids = []
    }
}

/// The panel's root view: catches files dragged onto the open notch and tells the shelf where they are.
/// Drags that start on the shelf itself are left alone.
final class DropZone: NSView {
    private let shelf: Shelf

    init(shelf: Shelf) {
        self.shelf = shelf
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { nil }

    private func target(_ info: NSDraggingInfo) -> DropTarget? {
        guard info.draggingSource == nil,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self],
                                                    options: [.urlReadingFileURLsOnly: true]) else { return nil }
        return convert(info.draggingLocation, from: nil).x < bounds.midX ? .keep : .airdrop
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = target(sender)
        shelf.hover(target)
        return target == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { shelf.hover(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = target(sender) else { return false }
        shelf.receive(sender.draggingPasteboard, to: target)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { shelf.hover(nil) }
}
