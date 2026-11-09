import AppKit
import CoreLocation
import EventKit
import IOKit.ps

/// Today's events from every calendar the Mac knows, kept fresh as they change.
final class CalendarWatch {
    var onAccess: (Bool) -> Void = { _ in }
    var onEvents: ([DayEvent]) -> Void = { _ in }
    private let store = EKEventStore()

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onAccess(granted)
                guard granted else { return }
                self.reload()
                for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged] {
                    NotificationCenter.default.addObserver(self, selector: #selector(self.reload), name: name, object: nil)
                }
            }
        }
    }

    @objc private func reload() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        // NSCalendarDayChanged may arrive off the main thread.
        let events = found.filter(Self.attending).map(Self.day)
        DispatchQueue.main.async { self.onEvents(events) }
    }

    private static func attending(_ event: EKEvent) -> Bool {
        event.status != .canceled && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
    }

    private static func day(_ event: EKEvent) -> DayEvent {
        DayEvent(id: (event.eventIdentifier ?? event.calendarItemIdentifier) + "@\(Int(event.startDate.timeIntervalSince1970))",
                 title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                 link: Today.link(in: [event.url?.absoluteString, event.location, event.notes]))
    }
}

/// Current weather from Open-Meteo, where the Mac is. Without location access it uses the city
/// in Hisashi's config file; with neither there is no request.
final class WeatherWatch: NSObject, CLLocationManagerDelegate {
    var onWeather: (Weather) -> Void = { _ in }
    private let locator = CLLocationManager()
    private var place: (latitude: Double, longitude: Double)?
    private var timer: Timer?

    /// ~/Library/Application Support/Hisashi/config.json: {"city": "..."}
    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Hisashi/config.json")
    }

    private struct Config: Decodable { let city: String }
    private struct Places: Decodable {
        struct Place: Decodable { let latitude: Double; let longitude: Double }
        let results: [Place]?
    }
    private struct Forecast: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current
        let daily: Daily
    }

    func start() {
        locator.desiredAccuracy = kCLLocationAccuracyKilometer
        locator.delegate = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
        guard let c = locations.last?.coordinate else { return }
        // About 10 km: enough for weather, and no exact position leaves the Mac.
        forecast((c.latitude * 10).rounded() / 10, (c.longitude * 10).rounded() / 10)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        refreshCity()
    }

    /// Starting the updates is what brings up the permission prompt on the Mac.
    /// A failed request just waits for the next round.
    private func refresh() {
        switch locator.authorizationStatus {
        case .denied, .restricted: refreshCity()
        case .notDetermined:
            locator.requestWhenInUseAuthorization()
            locator.startUpdatingLocation()
        default: locator.startUpdatingLocation()
        }
    }

    private func refreshCity() {
        guard let data = try? Data(contentsOf: Self.configFile),
              let city = (try? JSONDecoder().decode(Config.self, from: data))?.city else { return }
        if let place { return forecast(place.latitude, place.longitude) }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        fetch(url, as: Places.self) { [weak self] places in
            guard let self, let first = places.results?.first else { return }
            self.place = (first.latitude, first.longitude)
            self.forecast(first.latitude, first.longitude)
        }
    }

    private func forecast(_ latitude: Double, _ longitude: Double) {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "1"),
        ]
        fetch(url, as: Forecast.self) { [weak self] f in
            guard let high = f.daily.temperature_2m_max.first, let low = f.daily.temperature_2m_min.first else { return }
            self?.onWeather(Weather(temperature: Int(f.current.temperature_2m.rounded()), high: Int(high.rounded()),
                                    low: Int(low.rounded()), summary: Today.summary(code: f.current.weather_code)))
        }
    }

    private func fetch<T: Decodable>(_ url: URLComponents, as type: T.Type, then: @escaping (T) -> Void) {
        guard let url = url.url else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let value = try? JSONDecoder().decode(T.self, from: data) else { return }
            DispatchQueue.main.async { then(value) }
        }.resume()
    }
}

/// The battery, told by the system whenever it changes.
final class PowerWatch {
    var onChange: (Power?) -> Void = { _ in }
    private var source: CFRunLoopSource?

    func start() {
        onChange(Self.read())
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<PowerWatch>.fromOpaque(context).takeUnretainedValue().onChange(PowerWatch.read())
        }
        guard let made = IOPSNotificationCreateRunLoopSource(callback, me)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), made, .defaultMode)
        source = made
    }

    private static func read() -> Power? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let percent = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = d[kIOPSTimeToEmptyKey] as? Int
            return Power(percent: percent, plugged: plugged, minutesLeft: !plugged && (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }
}

enum TodayLinks {
    /// The call when the event has one, else Calendar.
    static func open(_ event: DayEvent?) {
        NSWorkspace.shared.open(event?.link ?? URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    static func openWeather() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
    }

    /// The privacy pane where location access is turned on.
    static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The privacy pane where calendar access is turned on.
    static func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
