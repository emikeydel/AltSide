import Foundation

/// Parses NYC DOT sign descriptions to extract alternate side parking schedule information.
///
/// Example inputs:
/// - "NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDAY 9AM-10:30AM <->"
/// - "NO PARKING (SANITATION BROOM SYMBOL) 7:30AM-8AM EXCEPT SUNDAY -->"
/// - "NO PARKING (SANITATION BROOM SYMBOL) MONDAY-FRIDAY 7:30AM-8AM <->"
/// - "NO PARKING (SANITATION BROOM SYMBOL) TUESDAY FRIDAY 8:30AM-10AM <->"
enum SignDescriptionParser {

    struct ParsedSchedule {
        let weekDay: String   // "Monday", "Tuesday", etc.
        let fromHour: Int     // 24-hour
        let fromMinutes: Int
        let toHour: Int
        let toMinutes: Int
    }

    /// Returns one ParsedSchedule per cleaning day encoded in the sign description.
    /// A sign like "MONDAY THURSDAY 9AM-10:30AM" yields two schedules.
    /// Returns an empty array if the description doesn't contain a recognizable broom schedule.
    static func parse(_ description: String) -> [ParsedSchedule] {
        let upper = description.uppercased()
        guard upper.contains("SANITATION BROOM SYMBOL") else { return [] }

        // Extract everything after the broom symbol marker
        let parts = upper.components(separatedBy: "(SANITATION BROOM SYMBOL)")
        guard parts.count > 1 else { return [] }
        var relevant = parts[1]

        // Remove secondary annotation if present
        relevant = relevant.replacingOccurrences(of: "MOON & STARS (SYMBOLS)", with: "")

        // Truncate at arrow direction markers and supersedes notes
        for sentinel in ["<->", "-->", "<--", "(SUPERSEDES"] {
            if let r = relevant.range(of: sentinel) {
                relevant = String(relevant[..<r.lowerBound])
            }
        }
        relevant = relevant.trimmingCharacters(in: .whitespaces)

        // --- Parse time range ---
        // Captures: "9AM-10:30AM", "7:30AM-8AM", "11:30AM-1PM", "3AM-6AM"
        let timePattern = #"(\d{1,2}(?::\d{2})?(?:AM|PM))-(\d{1,2}(?::\d{2})?(?:AM|PM))"#
        guard let timeRange = relevant.range(of: timePattern, options: .regularExpression) else { return [] }
        let timeStr = String(relevant[timeRange])
        let (fromH, fromM, toH, toM) = parseTimeRange(timeStr)

        // Remove time string to isolate the day specification
        var daysPart = relevant.replacingOccurrences(of: timeStr, with: "", options: .regularExpression)
        daysPart = daysPart.trimmingCharacters(in: .whitespaces)

        // --- Parse days ---
        let days = parseDays(from: daysPart)
        guard !days.isEmpty else { return [] }

        return days.map {
            ParsedSchedule(weekDay: $0, fromHour: fromH, fromMinutes: fromM, toHour: toH, toMinutes: toM)
        }
    }

    // MARK: - Time

    private static func parseTimeRange(_ str: String) -> (fromHour: Int, fromMinutes: Int, toHour: Int, toMinutes: Int) {
        let pattern = #"(\d{1,2}(?::\d{2})?(?:AM|PM))-(\d{1,2}(?::\d{2})?(?:AM|PM))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (0, 0, 0, 0) }
        let ns = str as NSString
        guard let match = regex.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 3 else { return (0, 0, 0, 0) }
        let from = ns.substring(with: match.range(at: 1))
        let to   = ns.substring(with: match.range(at: 2))
        let (fromH, fromM) = parseTime(from)
        let (toH, toM)     = parseTime(to)
        return (fromH, fromM, toH, toM)
    }

    private static func parseTime(_ str: String) -> (hour: Int, minute: Int) {
        let s = str.trimmingCharacters(in: .whitespaces)
        let isPM = s.hasSuffix("PM")
        let numPart = s.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "")
        let components = numPart.components(separatedBy: ":")
        var hour   = Int(components[0]) ?? 0
        let minute = components.count > 1 ? (Int(components[1]) ?? 0) : 0
        if isPM && hour != 12 { hour += 12 }
        if !isPM && hour == 12 { hour = 0 }
        return (hour, minute)
    }

    // MARK: - Days

    private static let orderedDays = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]

    private static func parseDays(from text: String) -> [String] {
        // "EXCEPT SUNDAY" means Mon–Sat daily cleaning
        if text.contains("EXCEPT SUNDAY") {
            return ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        }

        // Day range: "MONDAY-FRIDAY" or "TUESDAY-SATURDAY"
        let rangePattern = #"(MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY|SATURDAY|SUNDAY)-(MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY|SATURDAY|SUNDAY)"#
        if let rangeStr = text.range(of: rangePattern, options: .regularExpression)
            .map({ String(text[$0]) }) {
            let parts = rangeStr.components(separatedBy: "-")
            if parts.count == 2,
               let startIdx = orderedDays.firstIndex(of: parts[0]),
               let endIdx   = orderedDays.firstIndex(of: parts[1]) {
                return Array(orderedDays[startIdx...endIdx]).map { $0.capitalized }
            }
        }

        // Individual days, space-separated (e.g. "MONDAY THURSDAY")
        return orderedDays.filter { text.contains($0) }.map { $0.capitalized }
    }
}
