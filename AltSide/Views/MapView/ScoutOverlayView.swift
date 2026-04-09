import SwiftUI
import MapKit

/// Scout mode bottom panel — shows side-by-side comparison for the nearest street.
struct ScoutBottomPanel: View {
    var locationManager: LocationManager
    var cleaningDataManager: CleaningDataManager
    let onSaveWithSide: (SideDetector.StreetSide, [StreetCleaningEntry], BlockMatcher.ResolvedStreet) -> Void

    @State private var resolvedStreet: BlockMatcher.ResolvedStreet?
    @State private var allEntries: [StreetCleaningEntry] = []
    @State private var nearbyEntries: [StreetCleaningEntry] = []
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Scout mode pill + exit button
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.uberGreen)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1.0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: UUID())
                    Text("Scout mode · looking for parking")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.uberGray2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.uberSurface2)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.uberGreen.opacity(0.3), lineWidth: 1))

                Spacer()

                Button(action: { withAnimation { locationManager.scoutModeActive = false } }) {
                    Text("Exit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.uberGray3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.uberSurface2)
                        .clipShape(Capsule())
                }
            }

            if isResolving {
                HStack {
                    ProgressView().tint(Color.uberGray2)
                    Text("Finding nearby schedule…")
                        .font(.system(size: 13)).foregroundStyle(Color.uberGray3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if let street = resolvedStreet {
                // Street name
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEAREST STREET")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Color.uberGray3)
                    Text(street.name)
                        .font(.system(size: 20, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(Color.uberWhite)
                }

                // Side comparison — tap a card to save on that side
                let rawSides: [SideDetector.StreetSide] = street.orientation == .eastWest ? [.north, .south] : [.east, .west]
                let sides = orderedSides(from: rawSides)
                let displayEntries = nearbyEntries.isEmpty ? allEntries : nearbyEntries
                let recommendedSide = recommendSide(sides: sides, entries: displayEntries)
                Text("TAP THE SIDE YOU'RE PARKED ON")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.uberGray3)
                HStack(spacing: 10) {
                    ForEach(Array(sides.enumerated()), id: \.element) { index, side in
                        sideButton(
                            side: side,
                            relativeLabel: index == 0 ? "Left" : "Right",
                            entries: displayEntries,
                            isRecommended: side == recommendedSide,
                            action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onSaveWithSide(side, allEntries, street)
                            }
                        )
                    }
                }
                .animation(.spring(duration: 0.35), value: sides)

                aspUpdatesSection

            } else {
                Text("Move around to scan nearby streets.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.uberGray3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await resolve() }
        .onChange(of: locationManager.coordinate.latitude) { _, _ in
            Task { await resolve() }
        }
    }

    // MARK: - ASP Updates

    @ViewBuilder
    private var aspUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREET CLEANING UPDATES")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.uberGray3)

            if let todayHoliday = ASPSuspensionCalendar.holidayName(on: Date()) {
                aspRow(icon: "checkmark.shield.fill", iconColor: .uberGreen,
                       title: "Suspended today", subtitle: todayHoliday, accent: .uberGreen)
            } else {
                aspRow(icon: "checkmark.circle.fill", iconColor: .uberGray3,
                       title: "ASP in effect", subtitle: "Normal street cleaning schedule applies", accent: .uberGray3)
            }

            if let upcoming = ASPSuspensionCalendar.nextSuspension(after: Date()) {
                let fmt = DateFormatter()
                aspRow(icon: "calendar", iconColor: .uberGray2,
                       title: "Next suspension",
                       subtitle: formattedDate(upcoming.date, formatter: fmt) + " · " + upcoming.holiday,
                       accent: .uberGray2)
            }
        }
    }

    private func formattedDate(_ date: Date, formatter: DateFormatter) -> String {
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    private func aspRow(icon: String, iconColor: Color, title: String, subtitle: String, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.uberWhite)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.uberGray3)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.uberSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.2), lineWidth: 1)
        )
    }

    private func sideButton(
        side: SideDetector.StreetSide,
        relativeLabel: String,
        entries: [StreetCleaningEntry],
        isRecommended: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let sideEntries = entries.filter { $0.normalizedSide == side }
        let nextDate = sideEntries.compactMap { $0.nextCleaningDate() }.min()
        let daysUntil = nextDate.map { max(0, Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0) } ?? 99
        let isSoon = daysUntil < 2
        let accentColor: Color = isSoon ? Color.uberAmber : Color.uberGreen

        return Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(relativeLabel)
                        .font(.system(size: 28, weight: .black))
                        .tracking(-1)
                        .foregroundStyle(isRecommended ? accentColor : Color.uberWhite)
                    Spacer()
                    if isRecommended {
                        Text("BEST")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.uberGreen)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.uberGreen.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                let rel = side.relativeLabel(facing: locationManager.heading)
                Text(rel.map { "\($0) side (\(side.displayName))" } ?? "\(side.displayName) side")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.uberWhite)
                if let entry = sideEntries.first {
                    Text(entry.timeWindowDisplay)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.uberGray2)
                    Text(entry.weekDay)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.uberGray3)
                } else {
                    Text("No schedule")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.uberGray3)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isRecommended ? Color.uberGreen.opacity(0.06) : Color.uberSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSoon ? Color.uberAmber.opacity(0.4) : (isRecommended ? Color.uberGreen.opacity(0.4) : Color.uberBorder),
                        lineWidth: isRecommended ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Orders sides so the left side is always first (index 0) based on current heading.
    private func orderedSides(from sides: [SideDetector.StreetSide]) -> [SideDetector.StreetSide] {
        let h = locationManager.heading
        guard h >= 0 else { return sides }
        guard let left = sides.first(where: { $0.relativeLabel(facing: h) == "Left" }),
              let right = sides.first(where: { $0 != left })
        else { return sides }
        return [left, right]
    }

    private func recommendSide(sides: [SideDetector.StreetSide], entries: [StreetCleaningEntry]) -> SideDetector.StreetSide {
        sides.max { a, b in
            let daysA = entries.filter { $0.normalizedSide == a }.compactMap { $0.nextCleaningDate() }.min()
                .map { $0.timeIntervalSinceNow } ?? 0
            let daysB = entries.filter { $0.normalizedSide == b }.compactMap { $0.nextCleaningDate() }.min()
                .map { $0.timeIntervalSinceNow } ?? 0
            return daysA < daysB
        } ?? sides.first ?? .north
    }

    private func resolve() async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            let street = try await BlockMatcher.resolve(coordinate: locationManager.coordinate)
            let entries = await cleaningDataManager.loadSchedule(
                streetName: street.normalizedName,
                borough: street.borough,
                coordinate: locationManager.coordinate
            )
            resolvedStreet = street
            allEntries = entries
            nearbyEntries = proximityFiltered(entries, coordinate: locationManager.coordinate)
        } catch {}
    }

    /// Returns entries whose physical sign is within 300 m (≈ 984 ft) of the coordinate.
    private func proximityFiltered(_ entries: [StreetCleaningEntry], coordinate: CLLocationCoordinate2D) -> [StreetCleaningEntry] {
        let (userX, userY) = CleaningDataManager.wgs84ToStatePlane(lat: coordinate.latitude, lon: coordinate.longitude)
        let thresholdFt: Double = 984
        return entries.filter { entry in
            guard let sx = entry.signXCoord, let sy = entry.signYCoord else { return false }
            let dx = sx - userX, dy = sy - userY
            return sqrt(dx * dx + dy * dy) <= thresholdFt
        }
    }
}
