import SwiftUI

struct ScheduleCardView: View {
    let entries: [StreetCleaningEntry]
    let side: SideDetector.StreetSide

    private var relevantEntries: [StreetCleaningEntry] {
        entries.filter { $0.normalizedSide == side }
    }

    private var nextEntry: StreetCleaningEntry? {
        relevantEntries
            .compactMap { entry -> (StreetCleaningEntry, Date)? in
                guard let next = entry.nextCleaningDate() else { return nil }
                return (entry, next)
            }
            .sorted { $0.1 < $1.1 }
            .first?.0
    }

    private var nextCleaningDate: Date? { nextEntry?.nextCleaningDate() }

    private var daysUntil: Int {
        guard let next = nextCleaningDate else { return 99 }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: next).day ?? 0)
    }

    private var isSoon: Bool { daysUntil < 2 }

    private var accentColor: Color { isSoon ? Color.sweepyAmber : Color.sweepyGreen }

    private var cleaningDayInts: [Int] {
        relevantEntries.compactMap { $0.weekdayInt }
    }

    private var nextCleaningWeekday: Int? {
        guard let next = nextCleaningDate else { return nil }
        return Calendar.current.component(.weekday, from: next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row: badge + time
            HStack(alignment: .top) {
                if let entry = nextEntry {
                    CleaningBadge(state: isSoon ? .cleaningSoon(daysUntil: daysUntil) : .safe(daysUntil: daysUntil))
                    Spacer()
                    Text(entry.timeWindowDisplay)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.sweepyGray2)
                } else {
                    Text("No cleaning schedule found")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sweepyGray3)
                }
            }

            // Countdown blocks
            if let target = nextCleaningDate, target > Date() {
                LiveCountdownBlocksView(targetDate: target, accentColor: accentColor)
            }

            // Week strip
            if !cleaningDayInts.isEmpty {
                MiniWeekView(
                    cleaningDays: cleaningDayInts,
                    nextCleaningDay: nextCleaningWeekday,
                    accentColor: accentColor
                )
            }

            // Footer line
            if let entry = nextEntry, let next = nextCleaningDate {
                footerLine(entry: entry, next: next)
            }
        }
        .padding(16)
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
        )
    }

    private func footerLine(entry: StreetCleaningEntry, next: Date) -> some View {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        let dayName = dayFormatter.string(from: next)

        let moveByMin = entry.startMinute == 0 ? 59 : entry.startMinute - 1
        let moveByH = entry.startMinute == 0 ? max(0, entry.startHour - 1) : entry.startHour
        let mbH = moveByH == 0 ? 12 : (moveByH > 12 ? moveByH - 12 : moveByH)
        let mbM = moveByMin == 0 ? "" : ":\(String(format: "%02d", moveByMin))"
        let mbP = moveByH < 12 ? "AM" : "PM"

        let text = isSoon
            ? "Move your car by \(mbH)\(mbM) \(mbP) \(dayName)"
            : "No rush — next cleaning is \(dayName)"

        return HStack(spacing: 4) {
            Image(systemName: isSoon ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(accentColor)
    }
}
