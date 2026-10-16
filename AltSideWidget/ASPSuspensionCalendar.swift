import Foundation

/// NYC Alternate Side Parking suspension calendar.
/// ASP is suspended on legal and religious holidays — on those days, street cleaning
/// rules do not apply even if the normal schedule calls for it.
///
/// Source: https://www.nyc.gov/html/dot/html/motorist/alternate-side-parking.shtml
enum ASPSuspensionCalendar {

    // MARK: - Live overrides (NYC 311 feed)

    /// One day's status from the live NYC 311 calendar feed.
    struct LiveDay: Codable, Equatable {
        let suspended: Bool
        /// Holiday / reason, e.g. "Election Day" or "Snow removal". Nil when in effect.
        let name: String?
    }

    /// Days reported by the live feed, keyed "yyyy-MM-dd" (New York time). Where present
    /// these win over the bundled list — they include emergency/snow suspensions and dates
    /// past `lastKnownYear`. Populated by `ASPStatusManager` in the app; empty in the widget.
    nonisolated(unsafe) static var liveDays: [String: LiveDay] = [:]

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Public API

    /// Returns true if ASP is suspended on the given date.
    static func isSuspended(on date: Date = .now) -> Bool {
        holidayName(on: date) != nil
    }

    /// Returns the holiday name if ASP is suspended on the given date, or nil if not suspended.
    static func holidayName(on date: Date = .now) -> String? {
        if let live = liveDays[dayKey(date)] {
            return live.suspended ? (live.name ?? "ASP suspended") : nil
        }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        return entries[year]?.first { $0.month == month && $0.day == day }?.name
    }

    /// The next scheduled suspension after the given date, if known.
    static func nextSuspension(after date: Date = .now) -> (date: Date, holiday: String)? {
        upcomingSuspensions(after: date, limit: 1).first
    }

    /// Upcoming suspensions after the given date, soonest first — bundled calendar merged
    /// with the live feed. Empty once both run out (see `lastKnownYear`).
    static func upcomingSuspensions(after date: Date = .now, limit: Int = 3) -> [(date: Date, holiday: String)] {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        var byDay: [String: (date: Date, holiday: String)] = [:]

        for entry in (entries[year] ?? []) + (entries[year + 1] ?? []) {
            var c = DateComponents()
            c.year = entry.year; c.month = entry.month; c.day = entry.day
            guard let d = cal.date(from: c), d > date else { continue }
            byDay[dayKey(d)] = (d, entry.name)
        }
        for (key, live) in liveDays {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            var c = DateComponents()
            c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
            guard let d = cal.date(from: c), d > date else { continue }
            if live.suspended {
                byDay[key] = (d, live.name ?? byDay[key]?.holiday ?? "ASP suspended")
            } else {
                byDay[key] = nil   // feed says rules are in effect after all
            }
        }

        return byDay.values
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// The last year this bundled calendar has dates for.
    static var lastKnownYear: Int { entries.keys.max() ?? 0 }

    // MARK: - Data

    private struct Entry {
        let year: Int; let month: Int; let day: Int; let name: String
    }

    private static let entries: [Int: [Entry]] = [
        2026: [
            Entry(year: 2026, month: 1,  day: 1,  name: "New Year's Day"),
            Entry(year: 2026, month: 1,  day: 6,  name: "Three Kings' Day"),
            Entry(year: 2026, month: 1,  day: 19, name: "Martin Luther King Jr. Day"),
            Entry(year: 2026, month: 2,  day: 12, name: "Lincoln's Birthday"),
            Entry(year: 2026, month: 2,  day: 16, name: "Washington's Birthday / Lunar New Year's Eve"),
            Entry(year: 2026, month: 2,  day: 17, name: "Lunar New Year"),
            Entry(year: 2026, month: 2,  day: 18, name: "Ash Wednesday / Losar"),
            Entry(year: 2026, month: 3,  day: 3,  name: "Purim"),
            Entry(year: 2026, month: 3,  day: 20, name: "Eid Al-Fitr"),
            Entry(year: 2026, month: 3,  day: 21, name: "Eid Al-Fitr"),
            Entry(year: 2026, month: 4,  day: 2,  name: "Holy Thursday / Passover"),
            Entry(year: 2026, month: 4,  day: 3,  name: "Good Friday / Passover"),
            Entry(year: 2026, month: 4,  day: 8,  name: "Passover (7th Day)"),
            Entry(year: 2026, month: 4,  day: 9,  name: "Passover (8th Day) / Holy Thursday (Orthodox)"),
            Entry(year: 2026, month: 4,  day: 10, name: "Good Friday (Orthodox)"),
            Entry(year: 2026, month: 5,  day: 14, name: "Solemnity of the Ascension"),
            Entry(year: 2026, month: 5,  day: 22, name: "Shavuoth"),
            Entry(year: 2026, month: 5,  day: 23, name: "Shavuoth"),
            Entry(year: 2026, month: 5,  day: 25, name: "Memorial Day"),
            Entry(year: 2026, month: 5,  day: 27, name: "Eid Al-Adha"),
            Entry(year: 2026, month: 5,  day: 28, name: "Eid Al-Adha"),
            Entry(year: 2026, month: 6,  day: 19, name: "Juneteenth"),
            Entry(year: 2026, month: 7,  day: 3,  name: "Independence Day"),
            Entry(year: 2026, month: 7,  day: 4,  name: "Independence Day"),
            Entry(year: 2026, month: 7,  day: 23, name: "Tisha B'Av"),
            Entry(year: 2026, month: 8,  day: 15, name: "Feast of the Assumption"),
            Entry(year: 2026, month: 9,  day: 7,  name: "Labor Day"),
            Entry(year: 2026, month: 9,  day: 12, name: "Rosh Hashanah"),
            Entry(year: 2026, month: 9,  day: 13, name: "Rosh Hashanah"),
            Entry(year: 2026, month: 9,  day: 21, name: "Yom Kippur"),
            Entry(year: 2026, month: 9,  day: 26, name: "Succoth"),
            Entry(year: 2026, month: 9,  day: 27, name: "Succoth"),
            Entry(year: 2026, month: 10, day: 3,  name: "Shemini Atzereth"),
            Entry(year: 2026, month: 10, day: 4,  name: "Simchas Torah"),
            Entry(year: 2026, month: 10, day: 12, name: "Columbus Day"),
            Entry(year: 2026, month: 11, day: 1,  name: "All Saints' Day"),
            Entry(year: 2026, month: 11, day: 3,  name: "Election Day"),
            Entry(year: 2026, month: 11, day: 8,  name: "Diwali"),
            Entry(year: 2026, month: 11, day: 11, name: "Veterans Day"),
            Entry(year: 2026, month: 11, day: 26, name: "Thanksgiving Day"),
            Entry(year: 2026, month: 12, day: 8,  name: "Immaculate Conception"),
            Entry(year: 2026, month: 12, day: 25, name: "Christmas Day"),
        ]
    ]
}
