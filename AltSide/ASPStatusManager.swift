import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.laidoffdad.sweepy", category: "ASPStatus")

/// Live Alternate Side Parking status from the NYC 311 Public API.
///
/// Endpoint: GET https://api.nyc.gov/public/api/GetCalendar?fromdate=YYYY-MM-DD&todate=YYYY-MM-DD
/// Auth:     `Ocp-Apim-Subscription-Key` header — key from https://api-portal.nyc.gov
///           (subscribe to "NYC 311 Public Developers"), stored in `Secrets.nyc311ApiKey`.
///
/// Unlike the bundled `ASPSuspensionCalendar`, this covers emergency/snow suspensions
/// and next year's holidays as soon as the city publishes them. Each refresh covers
/// today + 45 days (the API's cap) and is pushed into
/// `ASPSuspensionCalendar.liveDays`, so every existing caller benefits automatically.
/// Without a key or network, the app falls back to the bundled calendar.
@Observable
final class ASPStatusManager {

    /// Today's ASP item from the feed, if loaded.
    private(set) var today: TodayStatus?
    /// When the feed was last fetched successfully (from network or disk cache).
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false

    struct TodayStatus: Codable, Equatable {
        /// Raw 311 status: "IN EFFECT", "SUSPENDED" or "NOT IN EFFECT".
        let status: String
        let details: String?
        let exceptionName: String?

        var isSuspended: Bool { status.uppercased() == "SUSPENDED" }
        var isNotInEffect: Bool { status.uppercased() == "NOT IN EFFECT" }
    }

    var isConfigured: Bool { !Secrets.nyc311ApiKey.isEmpty }

    /// Suspensions after now, bundled calendar merged with the feed. Reads `lastUpdated`
    /// so SwiftUI views calling this re-render when the feed refreshes.
    func upcomingSuspensions(limit: Int) -> [(date: Date, holiday: String)] {
        _ = lastUpdated
        return ASPSuspensionCalendar.upcomingSuspensions(after: .now, limit: limit)
    }

    private let endpoint = "https://api.nyc.gov/public/api/GetCalendar"
    /// Today's status can change same-day (snow emergencies), so refresh often.
    private let maxAge: TimeInterval = 30 * 60

    init() {
        loadFromDisk()
    }

    // MARK: - Fetch

    /// Fetches today + 90 days unless the data is fresh. Safe to call often.
    func refresh(force: Bool = false) async {
        guard isConfigured, !isLoading else { return }
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < maxAge,
           Calendar.current.isDateInToday(last) { return }

        isLoading = true
        defer { isLoading = false }

        // The API caps responses at 45 days — plenty for today's status, upcoming
        // cleanings and the next few suspensions; the bundled calendar covers the rest.
        let now = Date()
        guard let to = Calendar.current.date(byAdding: .day, value: 44, to: now),
              let days = await fetchWindow(from: now, to: to) else { return }
        let merged = CalendarResponse(days: days)
        apply(merged, fetchedAt: now)
        if let data = try? JSONEncoder().encode(merged) { saveToDisk(data) }
        log.info("311 calendar: \(days.count) days, today = \(self.today?.status ?? "?")")
    }

    private func fetchWindow(from: Date, to: Date) async -> [CalendarDay]? {
        var comps = URLComponents(string: endpoint)
        comps?.queryItems = [
            URLQueryItem(name: "fromdate", value: Self.isoDay(from)),
            URLQueryItem(name: "todate",   value: Self.isoDay(to)),
        ]
        guard let url = comps?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(Secrets.nyc311ApiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.error("311 calendar HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return try JSONDecoder().decode(CalendarResponse.self, from: data).days
        } catch {
            log.error("311 calendar fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func apply(_ response: CalendarResponse, fetchedAt: Date) {
        var live: [String: ASPSuspensionCalendar.LiveDay] = [:]
        var todayItem: TodayStatus?
        let todayKey = ASPSuspensionCalendar.dayKey(Date())

        for day in response.days ?? [] {
            guard let id = day.today_id, id.count == 8,
                  let item = day.items?.first(where: { $0.type?.localizedCaseInsensitiveContains("Alternate Side") == true }),
                  let status = item.status else { continue }
            // today_id is "YYYYMMDD"; liveDays uses "YYYY-MM-DD".
            let key = "\(id.prefix(4))-\(id.dropFirst(4).prefix(2))-\(id.suffix(2))"
            let suspended = status.uppercased() == "SUSPENDED"
            live[key] = .init(suspended: suspended, name: suspended ? Self.reason(item) : nil)
            if key == todayKey {
                todayItem = TodayStatus(status: status, details: item.details, exceptionName: item.exceptionName)
            }
        }
        guard !live.isEmpty else { return }
        ASPSuspensionCalendar.liveDays = live
        today = todayItem
        lastUpdated = fetchedAt
    }

    /// "Memorial Day 2026" → "Memorial Day"; falls back to the details sentence.
    private static func reason(_ item: CalendarItem) -> String {
        if let name = item.exceptionName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name.replacingOccurrences(of: #"\s+\d{4}$"#, with: "", options: .regularExpression)
        }
        return item.details ?? "ASP suspended"
    }

    /// API expects YYYY-MM-DD in New York time (passing YYYYMMDD returns HTTP 500).
    private static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Disk cache (so the last known status shows offline)

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nyc311_calendar.json")
    }

    private func saveToDisk(_ data: Data) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CalendarResponse.self, from: data),
              let modified = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        else { return }
        apply(decoded, fetchedAt: modified)
    }
}

// MARK: - 311 response shape

private struct CalendarResponse: Codable {
    let days: [CalendarDay]?
}

private struct CalendarDay: Codable {
    let today_id: String?
    let items: [CalendarItem]?
}

private struct CalendarItem: Codable {
    let type: String?
    let status: String?
    let exceptionName: String?
    let details: String?
}
