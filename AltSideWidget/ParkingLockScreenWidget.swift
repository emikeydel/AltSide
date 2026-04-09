import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct ParkingWidgetEntry: TimelineEntry {
    let date: Date
    let data: ParkingWidgetData?
}

// MARK: - Provider

struct ParkingWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> ParkingWidgetEntry {
        ParkingWidgetEntry(
            date: .now,
            data: ParkingWidgetData(
                streetName: "Columbia St",
                sideDisplayName: "Right side (East)",
                moveByDisplay: "Move by Thu 9:29 AM",
                scheduleDisplay: "Thu 9:30 AM – 11 AM",
                cleaningDate: Date().addingTimeInterval(3600 * 26),
                isCleaningSoon: false,
                isParked: true
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ParkingWidgetEntry) -> Void) {
        completion(ParkingWidgetEntry(date: .now, data: ParkingWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ParkingWidgetEntry>) -> Void) {
        let data = ParkingWidgetData.load()
        let now  = Date()

        // Refresh rate scales with urgency
        let refreshDate: Date
        if let cleaning = data?.cleaningDate {
            let left = cleaning.timeIntervalSinceNow
            if left < 2 * 3600 {
                refreshDate = now.addingTimeInterval(5 * 60)    // every 5 min
            } else if left < 24 * 3600 {
                refreshDate = now.addingTimeInterval(30 * 60)   // every 30 min
            } else {
                refreshDate = now.addingTimeInterval(3600)      // every 1 hr
            }
        } else {
            refreshDate = now.addingTimeInterval(3600)
        }

        let entry = ParkingWidgetEntry(date: now, data: data)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

// MARK: - Widget

struct ParkingLockScreenWidget: Widget {
    let kind = "ParkingLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ParkingWidgetProvider()) { entry in
            ParkingWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AltSide Parking")
        .description("See your parked spot and street cleaning countdown.")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
            .systemSmall,
            .systemMedium
        ])
    }
}

// MARK: - Entry View (routes by family)

struct ParkingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ParkingWidgetEntry

    var body: some View {
        switch family {
        case .accessoryInline:      ParkingInlineView(entry: entry)
        case .accessoryCircular:    ParkingCircularView(entry: entry)
        case .accessoryRectangular: ParkingRectangularView(entry: entry)
        case .systemSmall:          ParkingSmallView(entry: entry)
        case .systemMedium:         ParkingMediumView(entry: entry)
        default:                    ParkingRectangularView(entry: entry)
        }
    }
}

// MARK: - Accessory Inline  ──────────────────────────────────────────────────
//  e.g. "🚗 Columbia St · 14h left"

struct ParkingInlineView: View {
    let entry: ParkingWidgetEntry

    var body: some View {
        if let data = entry.data, data.isParked {
            if let date = data.cleaningDate {
                Label {
                    Text("\(data.streetName) · \(date, style: .relative)")
                } icon: {
                    if data.isCleaningSoon {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .widgetAccentable()
                    } else {
                        Image(systemName: "car.fill").widgetAccentable()
                    }
                }
            } else {
                Label {
                    Text(data.streetName)
                } icon: {
                    Image(systemName: "car.fill").widgetAccentable()
                }
            }
        } else {
            if let holiday = ASPSuspensionCalendar.holidayName(on: .now) {
                Label {
                    Text("ASP suspended · \(holiday)")
                } icon: {
                    Image(systemName: "checkmark.shield.fill").widgetAccentable()
                }
            } else if let next = ASPSuspensionCalendar.nextSuspension(after: .now) {
                Label {
                    Text("Next suspension · \(next.date, style: .relative)")
                } icon: {
                    Image(systemName: "calendar").widgetAccentable()
                }
            } else {
                Label("ASP in effect", systemImage: "car.fill")
            }
        }
    }
}

// MARK: - Accessory Circular  ────────────────────────────────────────────────
//  Progress ring showing time remaining + car/warning icon

struct ParkingCircularView: View {
    let entry: ParkingWidgetEntry

    var body: some View {
        if let data = entry.data, data.isParked, let date = data.cleaningDate {
            Gauge(value: gaugeValue(cleaningDate: date), in: 0...1) {
                if data.isCleaningSoon {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .widgetAccentable()
                } else {
                    Image("SweepyWidget")
                        .resizable()
                        .scaledToFit()
                }
            }
            .gaugeStyle(.accessoryCircular)
        } else if let data = entry.data, data.isParked {
            Image("SweepyWidget")
                .resizable()
                .scaledToFit()
                .padding(4)
        } else {
            if ASPSuspensionCalendar.isSuspended(on: .now) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20, weight: .bold))
                    .widgetAccentable()
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func gaugeValue(cleaningDate: Date) -> Double {
        let total    = 7.0 * 24 * 3600
        let remaining = max(0, cleaningDate.timeIntervalSinceNow)
        return min(1, remaining / total)
    }
}

// MARK: - Accessory Rectangular  ─────────────────────────────────────────────
//  Street name + move-by time + countdown

struct ParkingRectangularView: View {
    let entry: ParkingWidgetEntry

    var body: some View {
        if let data = entry.data, data.isParked {
            VStack(alignment: .leading, spacing: 3) {
                // Status badge
                HStack(spacing: 4) {
                    if data.isCleaningSoon {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .widgetAccentable()
                    } else {
                        Image(systemName: "car.fill")
                            .font(.system(size: 9, weight: .bold))
                            .widgetAccentable()
                    }
                    Text(data.isCleaningSoon ? "MOVE SOON" : "PARKED")
                        .font(.system(size: 9, weight: .bold))
                        .widgetAccentable()
                }

                // Street + side
                Text(data.streetName)
                    .font(.system(size: 14, weight: .black))
                    .lineLimit(1)
                if !data.sideDisplayName.isEmpty {
                    Text(data.sideDisplayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Move-by
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                    if let date = data.cleaningDate {
                        Text(date, style: .relative)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    } else {
                        Text(data.moveByDisplay)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            aspStatusView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aspStatusView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let holiday = ASPSuspensionCalendar.holidayName(on: .now) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 9, weight: .bold))
                        .widgetAccentable()
                    Text("SUSPENDED TODAY")
                        .font(.system(size: 9, weight: .bold))
                        .widgetAccentable()
                }
                Text(holiday)
                    .font(.system(size: 13, weight: .black))
                    .lineLimit(2)
                Text("No street cleaning today")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9))
                    Text("ASP IN EFFECT")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.secondary)
                if let next = ASPSuspensionCalendar.nextSuspension(after: .now) {
                    Text("Next: \(next.holiday)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(next.date, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - System Small (Home Screen)  ────────────────────────────────────────
//  Cream background card matching app style

struct ParkingSmallView: View {
    let entry: ParkingWidgetEntry

    private let cream   = Color(red: 0.918, green: 0.910, blue: 0.878) // #EAE8E0
    private let dark    = Color(red: 0.102, green: 0.102, blue: 0.102) // #1A1A1A
    private let green   = Color(red: 0.176, green: 0.702, blue: 0.286) // #2DB349
    private let orange  = Color(red: 1,     green: 0.369, blue: 0)     // #FF5E00

    var body: some View {
        ZStack {
            cream

            if let data = entry.data, data.isParked {
                VStack(alignment: .leading, spacing: 6) {
                    // Icon row
                    HStack {
                        ZStack {
                            Circle()
                                .fill(accent(data).opacity(0.15))
                                .frame(width: 36, height: 36)
                            if data.isCleaningSoon {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(accent(data))
                            } else {
                                Image("SweepyWidget")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                            }
                        }
                        Spacer()
                        // Countdown
                        if !data.scheduleDisplay.isEmpty {
                            Text(data.scheduleDisplay)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent(data))
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    Spacer()

                    // Street name
                    Text(data.streetName)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(dark)
                        .lineLimit(2)

                    // Move by pill
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9))
                        Text(data.moveByDisplay
                            .replacingOccurrences(of: "Move by ", with: ""))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dark)
                    .clipShape(Capsule())
                }
                .padding(14)
            } else {
                aspSmallView
            }
        }
    }

    private var aspSmallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let holiday = ASPSuspensionCalendar.holidayName(on: .now) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(green)
                    Text("SUSPENDED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(green)
                }
                Spacer()
                Text(holiday)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(dark)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text("No street cleaning today")
                    .font(.system(size: 10))
                    .foregroundStyle(dark.opacity(0.5))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                        .foregroundStyle(dark.opacity(0.4))
                    Text("ASP IN EFFECT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(dark.opacity(0.4))
                }
                Spacer()
                if let next = ASPSuspensionCalendar.nextSuspension(after: .now) {
                    Text("Next suspension")
                        .font(.system(size: 10))
                        .foregroundStyle(dark.opacity(0.4))
                    Text(next.holiday)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(dark)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(next.date, style: .relative)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dark.opacity(0.5))
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func accent(_ data: ParkingWidgetData) -> Color {
        data.isCleaningSoon ? orange : green
    }
}

// MARK: - System Medium (Home Screen)  ───────────────────────────────────────
//  Sweepy on the left, spot details + countdown on the right

struct ParkingMediumView: View {
    let entry: ParkingWidgetEntry

    private let cream  = Color(red: 0.918, green: 0.910, blue: 0.878) // #EAE8E0
    private let dark   = Color(red: 0.102, green: 0.102, blue: 0.102) // #1A1A1A
    private let green  = Color(red: 0.176, green: 0.702, blue: 0.286) // #2DB349
    private let orange = Color(red: 1,     green: 0.369, blue: 0)     // #FF5E00

    var body: some View {
        ZStack {
            cream

            if let data = entry.data, data.isParked {
                HStack(spacing: 0) {
                    // Left — Sweepy
                    ZStack {
                        accent(data).opacity(0.08)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Image("SweepyWidget")
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    }
                    .frame(width: 110)

                    // Right — details
                    VStack(alignment: .leading, spacing: 0) {
                        // Status chip
                        HStack(spacing: 4) {
                            if data.isCleaningSoon {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(orange)
                            }
                            Text(data.isCleaningSoon ? "MOVE SOON" : "PARKED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(accent(data))
                        }
                        .padding(.bottom, 6)

                        // Street name
                        Text(data.streetName)
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(dark)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        // Side
                        if !data.sideDisplayName.isEmpty {
                            Text(data.sideDisplayName)
                                .font(.system(size: 11))
                                .foregroundStyle(dark.opacity(0.5))
                                .padding(.top, 2)
                        }

                        Spacer()

                        // Countdown + move-by
                        if !data.scheduleDisplay.isEmpty {
                            Text(data.scheduleDisplay)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(accent(data))
                                .padding(.bottom, 6)
                        }

                        // Move by pill
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 9))
                            Text(data.moveByDisplay
                                .replacingOccurrences(of: "Move by ", with: ""))
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(dark)
                        .clipShape(Capsule())
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 0) {
                    // Left — Sweepy faded
                    ZStack {
                        dark.opacity(0.04)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Image("SweepyWidget")
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    }
                    .frame(width: 110)

                    // Right — ASP status
                    VStack(alignment: .leading, spacing: 4) {
                        if let holiday = ASPSuspensionCalendar.holidayName(on: .now) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(green)
                                Text("SUSPENDED TODAY")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(green)
                            }
                            Text(holiday)
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(dark)
                                .lineLimit(2)
                            Text("No street cleaning today")
                                .font(.system(size: 11))
                                .foregroundStyle(dark.opacity(0.5))
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 10))
                                Text("ASP IN EFFECT")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(dark.opacity(0.4))
                            .padding(.bottom, 2)
                            if let next = ASPSuspensionCalendar.nextSuspension(after: .now) {
                                Text("Next suspension")
                                    .font(.system(size: 10))
                                    .foregroundStyle(dark.opacity(0.4))
                                Text(next.holiday)
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(dark)
                                    .lineLimit(2)
                                Text(next.date, style: .relative)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(dark.opacity(0.5))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func accent(_ data: ParkingWidgetData) -> Color {
        data.isCleaningSoon ? orange : green
    }
}
