import AppKit
import SQLite3

// Notification Center's list, read from its own store for the notifications tab.
// Needs Full Disk Access; without it the tab lists only banners seen since launch.
// The store lags new notifications by about five seconds, banners fill that gap.

/// Reads every delivered notification whenever the store changes. No polling: a file
/// watcher on the database and its WAL wakes it, and one burst of writes is read once.
final class NoticeStore {
    private let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    private let queue = DispatchQueue(label: "hisashi.history")
    private var db: OpaquePointer?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending = false
    private let onChange: ([HistoryItem]) -> Void

    init(onChange: @escaping ([HistoryItem]) -> Void) {
        self.onChange = onChange
    }

    /// False without Full Disk Access.
    func start() -> Bool {
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              readAll() != nil else {
            sqlite3_close(db)
            db = nil
            return false
        }
        watch()
        queue.async { self.publish() }
        return true
    }

    private func watch() {
        sources.forEach { $0.cancel() }
        sources = [path, path + "-wal"].compactMap { file in
            let fd = open(file, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // The WAL can be replaced on checkpoint; follow the new file.
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.queue.async { self.watch() } }
                self.schedule()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pending = false
            self?.publish()
        }
    }

    private func publish() {
        guard let items = readAll() else { return }
        DispatchQueue.main.async { self.onChange(items) }
    }

    private func readAll() -> [HistoryItem]? {
        let sql = "select r.uuid, a.identifier, r.data, r.delivered_date from record r join app a using(app_id)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var items: [HistoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_bytes(stmt, 0) == 16, let raw = sqlite3_column_blob(stmt, 0) else { continue }
            let uuid = NSUUID(uuidBytes: raw.assumingMemoryBound(to: UInt8.self)).uuidString
            let bundle = String(cString: sqlite3_column_text(stmt, 1))
            let blob = Data(bytes: sqlite3_column_blob(stmt, 2), count: Int(sqlite3_column_bytes(stmt, 2)))
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            guard let item = Self.decode(id: uuid, bundle: bundle, blob: blob, date: date) else { continue }
            items.append(item)
        }
        return items
    }

    /// The row's data is a binary plist: `req` holds title, subtitle and body.
    private static func decode(id: String, bundle: String, blob: Data, date: Date) -> HistoryItem? {
        guard let root = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
              let req = root["req"] as? [String: Any] else { return nil }
        let title = req["titl"] as? String ?? ""
        let subtitle = req["subt"] as? String ?? ""
        let body = req["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }
        let detail = [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ")
        return HistoryItem(id: id, app: Apps.name(bundle), bundle: bundle, title: title, body: detail, date: date)
    }
}

/// App names and launching by bundle id; Notification Center stores ids, often lowercased.
enum Apps {
    private static var names: [String: String] = [:]

    static func name(_ bundle: String) -> String {
        if let hit = names[bundle] { return hit }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundle.split(separator: ".").last.map(String.init) ?? bundle
        names[bundle] = name
        return name
    }

    /// Opens the app behind a listed notification.
    static func open(_ item: HistoryItem) {
        if let bundle = item.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            BannerWatch.openApp(named: item.app)
        }
    }
}
