import Foundation

/// NYC Alternate Side Parking suspension calendar.
/// ASP is suspended on legal and religious holidays — on those days, street cleaning
/// rules do not apply even if the normal schedule calls for it.
///
/// Source: https://www.nyc.gov/html/dot/html/motorist/alternate-side-parking.shtml
enum ASPSuspensionCalendar {

    // MARK: - Public API

    /// Returns true if ASP is suspended on the given date.
    static func isSuspended(on date: Date = .now) -> Bool {
        holidayName(on: date) != nil
    }

    /// Returns the holiday name if ASP is suspended on the given date, or nil if not suspended.
    static func holidayName(on date: Date = .now) -> String? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return nil }
        return entries[year]?.first { $0.month == month && $0.day == day }?.name
    }

    /// The next scheduled suspension after the given date, if known.
    static func nextSuspension(after date: Date = .now) -> (date: Date, holiday: String)? {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        let candidates = (entries[year] ?? []) + (entries[year + 1] ?? [])

        return candidates
            .compactMap { entry -> (Date, String)? in
                var c = DateComponents()
                c.year = entry.year; c.month = entry.month; c.day = entry.day
                guard let d = cal.date(from: c), d > date else { return nil }
                return (d, entry.name)
            }
            .sorted { $0.0 < $1.0 }
            .first
    }

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
