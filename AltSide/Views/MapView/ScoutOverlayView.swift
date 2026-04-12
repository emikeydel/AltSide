import SwiftUI
import MapKit

/// Scout mode bottom panel — shows side-by-side comparison for the nearest street.
struct ScoutBottomPanel: View {
    var locationManager: LocationManager
    var cleaningDataManager: CleaningDataManager
    var onHelpTap: (() -> Void)? = nil
    var onSegmentsLoaded: (([BlockSegment]) -> Void)? = nil
    let onSaveWithSide: (SideDetector.StreetSide, [StreetCleaningEntry], BlockMatcher.ResolvedStreet) -> Void

    @State private var resolvedStreet: BlockMatcher.ResolvedStreet?
    @State private var allEntries: [StreetCleaningEntry] = []
    @State private var nearbyEntries: [StreetCleaningEntry] = []
    @State private var currentSegments: [BlockSegment] = []
    @State private var isResolving = false
    @State private var lastResolvedCoordinate: CLLocationCoordinate2D? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Scout mode pill + exit button
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.sweepyGreen)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1.0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: UUID())
                    Text("Scout mode · looking for parking")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.sweepyGray2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.sweepySurface2)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.sweepyGreen.opacity(0.3), lineWidth: 1))

                Spacer()

                // Help button
                if let onHelpTap {
                    Button(action: onHelpTap) {
                        Text("?")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.sweepyGray2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.sweepySurface2)
                            .clipShape(Capsule())
                    }
                }

                // Refresh button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isResolving = false
                    Task { @MainActor in await resolve() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sweepyGray2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.sweepySurface2)
                        .clipShape(Capsule())
                }
                .disabled(isResolving)

                Button(action: { withAnimation { locationManager.scoutModeActive = false } }) {
                    Text("Exit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.sweepyGray3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.sweepySurface2)
                        .clipShape(Capsule())
                }
            }

            if isResolving {
                HStack {
                    ProgressView().tint(Color.sweepyGray2)
                    Text("Finding nearby schedule…")
                        .font(.system(size: 13)).foregroundStyle(Color.sweepyGray3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if let street = resolvedStreet {
                // Street name
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEAREST STREET")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Color.sweepyGray3)
                    Text(street.name)
                        .font(.system(size: 20, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(Color.sweepyWhite)
                }

                // Side comparison — tap a card to save on that side
                let rawSides: [SideDetector.StreetSide] = street.orientation == .eastWest ? [.north, .south] : [.east, .west]
                let sides = orderedSides(from: rawSides)
                let displayEntries = nearbyEntries
                let recommendedSide = recommendSide(sides: sides, entries: displayEntries)
                Text("TAP THE SIDE YOU'RE PARKED ON")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.sweepyGray3)
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
                    .foregroundStyle(Color.sweepyGray3)
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
            let coord = locationManager.coordinate
            if let last = lastResolvedCoordinate {
                let moved = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
                guard moved >= 50 else { return }
            }
            Task { @MainActor in await resolve() }
        }
    }

    // MARK: - ASP Updates

    @ViewBuilder
    private var aspUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREET CLEANING UPDATES")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.sweepyGray3)

            if let todayHoliday = ASPSuspensionCalendar.holidayName(on: Date()) {
                aspRow(icon: "checkmark.shield.fill", iconColor: .sweepyGreen,
                       title: "Suspended today", subtitle: todayHoliday, accent: .sweepyGreen)
            } else {
                aspRow(icon: "checkmark.circle.fill", iconColor: .sweepyGray3,
                       title: "ASP in effect", subtitle: "Normal street cleaning schedule applies", accent: .sweepyGray3)
            }

            if let upcoming = ASPSuspensionCalendar.nextSuspension(after: Date()) {
                let fmt = DateFormatter()
                aspRow(icon: "calendar", iconColor: .sweepyGray2,
                       title: "Next suspension",
                       subtitle: formattedDate(upcoming.date, formatter: fmt) + " · " + upcoming.holiday,
                       accent: .sweepyGray2)
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
                    .foregroundStyle(Color.sweepyWhite)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyGray3)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.sweepySurface2)
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
        let nextEntry = sideEntries.min { ($0.nextCleaningDate() ?? .distantFuture) < ($1.nextCleaningDate() ?? .distantFuture) }
        let nextDate = nextEntry?.nextCleaningDate()
        let daysUntil: Int = {
            guard let nd = nextDate else { return 99 }
            let cal = Calendar.current
            return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: nd)).day ?? 0)
        }()
        let isSoon = daysUntil < 2
        let accentColor: Color = isSoon ? Color.sweepyAmber : Color.sweepyGreen

        return Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(relativeLabel)
                        .font(.system(size: 28, weight: .black))
                        .tracking(-1)
                        .foregroundStyle(isRecommended ? accentColor : Color.sweepyWhite)
                    Spacer()
                    if isRecommended {
                        Text("BEST")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.sweepyGreen)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.sweepyGreen.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                let rel = side.relativeLabel(facing: locationManager.heading)
                Text(rel.map { "\($0) side (\(side.displayName))" } ?? "\(side.displayName) side")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sweepyWhite)
                if let entry = nextEntry {
                    Text(entry.timeWindowDisplay)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.sweepyGray2)
                    Text(entry.weekDay)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.sweepyGray3)
                } else {
                    Text("No schedule")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.sweepyGray3)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isRecommended ? Color.sweepyGreen.opacity(0.06) : Color.sweepySurface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSoon ? Color.sweepyAmber.opacity(0.4) : (isRecommended ? Color.sweepyGreen.opacity(0.4) : Color.sweepyBorder),
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
            let coord = locationManager.coordinate
            let street = try await BlockMatcher.resolve(coordinate: coord)
            let entries = await cleaningDataManager.loadSchedule(
                streetName: street.normalizedName,
                borough: street.borough,
                coordinate: street.snappedCoordinate
            )
            resolvedStreet = street
            allEntries = entries

            let nearby = CleaningDataManager.proximityFiltered(entries, coordinate: street.snappedCoordinate)
            let pool = nearby.isEmpty ? entries : nearby
            let segments = CleaningDataManager.buildSegments(pool, snappedCoordinate: street.snappedCoordinate)
            let userLoc = CLLocation(latitude: street.snappedCoordinate.latitude, longitude: street.snappedCoordinate.longitude)

            // Per-side block-face filtering: for each side, find its nearest segment and keep
            // only entries on that specific block. Entries from adjacent blocks with unique
            // weekdays would otherwise survive closestSignDedup and show wrong schedules.
            let relevantSides: [SideDetector.StreetSide] = street.orientation == .eastWest
                ? [.north, .south] : [.east, .west]
            var blockFiltered: [StreetCleaningEntry] = []
            for side in relevantSides {
                let sideSegs = segments.filter { $0.side == side }
                if let nearest = sideSegs.min(by: {
                    userLoc.distance(from: CLLocation(latitude: $0.centroid.latitude, longitude: $0.centroid.longitude))
                    < userLoc.distance(from: CLLocation(latitude: $1.centroid.latitude, longitude: $1.centroid.longitude))
                }) {
                    blockFiltered += pool.filter { e in
                        guard e.normalizedSide == side else { return false }
                        return (BlockMatcher.fuzzyMatch(e.fromStreet, nearest.fromStreet) && BlockMatcher.fuzzyMatch(e.toStreet, nearest.toStreet))
                            || (BlockMatcher.fuzzyMatch(e.fromStreet, nearest.toStreet)   && BlockMatcher.fuzzyMatch(e.toStreet, nearest.fromStreet))
                    }
                } else {
                    blockFiltered += pool.filter { $0.normalizedSide == side }
                }
            }

            nearbyEntries = CleaningDataManager.closestSignDedup(
                blockFiltered.isEmpty ? pool : blockFiltered,
                coordinate: street.snappedCoordinate
            )
            // Drop segments whose centroid is > 400 m from the user — removes stray lines
            // from distant blocks on long streets.
            let filteredSegments = segments.filter {
                userLoc.distance(from: CLLocation(latitude: $0.centroid.latitude,
                                                   longitude: $0.centroid.longitude)) < 400
            }
            currentSegments = filteredSegments
            onSegmentsLoaded?(filteredSegments)
            lastResolvedCoordinate = coord
            prefetchNearby(from: street.snappedCoordinate)
        } catch {}
    }

    /// Fires background BlockMatcher + loadSchedule calls for coordinates ahead of the user
    /// so the cache is warm before they drive to the next block.
    private func prefetchNearby(from coordinate: CLLocationCoordinate2D) {
        let heading = locationManager.heading
        guard heading >= 0 else { return }
        let headingRad = heading * .pi / 180
        let latMeters = 111_139.0
        let lonMeters = 111_139.0 * cos(coordinate.latitude * .pi / 180)

        for dist in [150.0, 300.0] {
            let nearbyCoord = CLLocationCoordinate2D(
                latitude:  coordinate.latitude  + (dist / latMeters) * cos(headingRad),
                longitude: coordinate.longitude + (dist / lonMeters) * sin(headingRad)
            )
            Task { [mgr = cleaningDataManager] in
                if let street = try? await BlockMatcher.resolve(coordinate: nearbyCoord) {
                    _ = await mgr.loadSchedule(
                        streetName: street.normalizedName,
                        borough: street.borough,
                        coordinate: street.snappedCoordinate
                    )
                }
            }
        }
    }

}
