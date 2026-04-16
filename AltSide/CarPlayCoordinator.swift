import CoreLocation
import Observation
import SwiftData

/// Drives the CarPlay UI by watching the user's location and SwiftData.
/// Runs exclusively on the main actor so it can safely access @Observable managers.
@MainActor
final class CarPlayCoordinator {

    private let locationManager: LocationManager
    private let cleaningDataManager: CleaningDataManager
    private let notificationManager: NotificationManager
    private let modelContainer: ModelContainer
    private let context: ModelContext

    // Pending data captured during scout-mode resolution (used when user taps Save).
    private var pendingStreet: BlockMatcher.ResolvedStreet?
    private var pendingEntries: [StreetCleaningEntry] = []
    private var pendingLeftSide: SideDetector.StreetSide = .north
    private var pendingRightSide: SideDetector.StreetSide = .south

    private var lastResolvedCoordinate: CLLocationCoordinate2D?
    private var isResolving = false
    private var trackedSpotID: UUID?

    init(
        locationManager: LocationManager,
        cleaningDataManager: CleaningDataManager,
        notificationManager: NotificationManager,
        modelContainer: ModelContainer
    ) {
        self.locationManager = locationManager
        self.cleaningDataManager = cleaningDataManager
        self.notificationManager = notificationManager
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)

        setupCallbacks()
        observeScoutMode()
        observeLocation()
        startSpotPolling()

        // Set initial ASP state right away.
        CarPlayDataStore.shared.setState(.noSpot, aspSummary: aspSummary())
    }

    // MARK: - Callbacks (scene delegate → coordinator)

    private func setupCallbacks() {
        CarPlayDataStore.shared.onFindParkingTapped = { [weak self] in
            self?.locationManager.scoutModeActive = true
        }
        CarPlayDataStore.shared.onSaveLeftTapped = { [weak self] in
            Task { @MainActor [weak self] in await self?.saveSpot(isLeft: true) }
        }
        CarPlayDataStore.shared.onSaveRightTapped = { [weak self] in
            Task { @MainActor [weak self] in await self?.saveSpot(isLeft: false) }
        }
        CarPlayDataStore.shared.onSetRemindersConfirmed = { [weak self] in
            Task { @MainActor [weak self] in await self?.scheduleReminders() }
        }
    }

    // MARK: - Observation

    private func observeScoutMode() {
        withObservationTracking {
            _ = locationManager.scoutModeActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleScoutModeChange()
                self?.observeScoutMode()
            }
        }
    }

    private func handleScoutModeChange() {
        if locationManager.scoutModeActive {
            // Show a placeholder immediately while the street resolves.
            CarPlayDataStore.shared.setState(
                .scouting(
                    streetName: "Finding street…",
                    leftLabel: "Left Side",  leftSchedule: "—",
                    rightLabel: "Right Side", rightSchedule: "—"
                ),
                aspSummary: aspSummary()
            )
            lastResolvedCoordinate = nil
            let coord = locationManager.coordinate
            let heading = locationManager.heading
            guard coord.latitude != 0 else { return }
            Task { await resolveAndUpdate(coordinate: coord, heading: heading) }
        } else {
            lastResolvedCoordinate = nil
            checkActiveSpot()
        }
    }

    private func observeLocation() {
        withObservationTracking {
            _ = locationManager.coordinate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleLocationChange()
                self?.observeLocation()
            }
        }
    }

    private func handleLocationChange() async {
        guard locationManager.scoutModeActive, !isResolving else { return }
        let coord = locationManager.coordinate
        guard coord.latitude != 0 else { return }

        // Re-resolve only after moving ~50 m from the last resolved position.
        if let last = lastResolvedCoordinate {
            let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard dist > 50 else { return }
        }

        isResolving = true
        lastResolvedCoordinate = coord
        await resolveAndUpdate(coordinate: coord, heading: locationManager.heading)
        isResolving = false
    }

    // MARK: - Spot polling (detects saves/clears made from the iPhone)

    private func startSpotPolling() {
        Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                if !self.locationManager.scoutModeActive {
                    self.checkActiveSpot()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func checkActiveSpot() {
        let descriptor = FetchDescriptor<ParkingSpot>(predicate: #Predicate { $0.isActive })
        let spots = (try? context.fetch(descriptor)) ?? []

        if let spot = spots.first {
            if trackedSpotID != spot.id {
                trackedSpotID = spot.id
                showSpotSaved(spot)
            }
        } else if trackedSpotID != nil {
            trackedSpotID = nil
            CarPlayDataStore.shared.setState(.noSpot, aspSummary: aspSummary())
        }
    }

    // MARK: - Street resolution

    private func resolveAndUpdate(
        coordinate: CLLocationCoordinate2D,
        heading: CLLocationDirection
    ) async {
        do {
            let street = try await BlockMatcher.resolve(coordinate: coordinate)
            let snapped = street.snappedCoordinate
            let allEntries = await cleaningDataManager.loadSchedule(
                streetName: street.normalizedName,
                borough: street.borough,
                coordinate: snapped
            )

            // Derive orientation from sign data — more reliable than street name inference.
            let nsCount = allEntries.filter { $0.normalizedSide == .east || $0.normalizedSide == .west }.count
            let ewCount = allEntries.filter { $0.normalizedSide == .north || $0.normalizedSide == .south }.count
            let (side1, side2): (SideDetector.StreetSide, SideDetector.StreetSide) = nsCount > ewCount
                ? (.east, .west) : (.north, .south)

            let sched1 = scheduleText(allEntries.filter { $0.normalizedSide == side1 })
            let sched2 = scheduleText(allEntries.filter { $0.normalizedSide == side2 })

            // Map cardinal sides to Left / Right based on the driver's current heading.
            let side1IsLeft = (side1.relativeLabel(facing: heading) == "Left")
            let (leftSide, leftSched, rightSide, rightSched): (SideDetector.StreetSide, String, SideDetector.StreetSide, String)
            if side1IsLeft {
                (leftSide, leftSched, rightSide, rightSched) = (side1, sched1, side2, sched2)
            } else {
                (leftSide, leftSched, rightSide, rightSched) = (side2, sched2, side1, sched1)
            }

            pendingStreet   = street
            pendingEntries  = allEntries
            pendingLeftSide  = leftSide
            pendingRightSide = rightSide

            CarPlayDataStore.shared.setState(
                .scouting(
                    streetName: street.name,
                    leftLabel:  "\(leftSide.displayName) Side",  leftSchedule:  leftSched,
                    rightLabel: "\(rightSide.displayName) Side", rightSchedule: rightSched
                ),
                aspSummary: aspSummary()
            )
        } catch {
            // Keep showing the placeholder — will retry on next location change.
        }
    }

    // MARK: - Save spot from CarPlay

    private func saveSpot(isLeft: Bool) async {
        guard let street = pendingStreet else { return }
        let side = isLeft ? pendingLeftSide : pendingRightSide

        // Mirror the deduplication logic from MainMapView.createSpot.
        let sideEntries = pendingEntries.filter { $0.normalizedSide == side }
        var seenDays = Set<Int>()
        let deduped = sideEntries
            .sorted { ($0.nextCleaningDate() ?? .distantFuture) < ($1.nextCleaningDate() ?? .distantFuture) }
            .filter { e in
                guard let day = e.weekdayInt, !seenDays.contains(day) else { return false }
                seenDays.insert(day)
                return true
            }

        let coord = lastResolvedCoordinate ?? locationManager.coordinate
        let spot = ParkingSpot(
            coordinate: coord,
            streetName: street.name,
            crossStreetFrom: street.crossStreetFrom,
            crossStreetTo: street.crossStreetTo,
            side: side,
            cleaningDays: deduped.compactMap { $0.weekdayInt },
            cleaningStartHour:   deduped.first?.startHour   ?? 8,
            cleaningStartMinute: deduped.first?.startMinute ?? 0,
            cleaningEndHour:     deduped.first?.endHour     ?? 9,
            cleaningEndMinute:   deduped.first?.endMinute   ?? 30
        )
        spot.parkingHeading = locationManager.heading
        spot.refreshNextCleaningDate()

        // Clear any existing active spot before saving the new one.
        let existing = (try? context.fetch(FetchDescriptor<ParkingSpot>(predicate: #Predicate { $0.isActive }))) ?? []
        for old in existing {
            Task { await notificationManager.cancelAlerts(for: old.id) }
            old.isActive = false
        }

        context.insert(spot)
        try? context.save()

        trackedSpotID = spot.id
        locationManager.scoutModeActive = false
        showSpotSaved(spot)
    }

    // MARK: - Schedule reminders from CarPlay

    private func scheduleReminders() async {
        let descriptor = FetchDescriptor<ParkingSpot>(predicate: #Predicate { $0.isActive })
        guard let spot = try? context.fetch(descriptor).first else { return }
        _ = await notificationManager.requestPermission()
        await notificationManager.scheduleAlerts(for: spot)
    }

    // MARK: - Helpers

    private func showSpotSaved(_ spot: ParkingSpot) {
        guard let side = spot.streetSide else {
            CarPlayDataStore.shared.setState(.noSpot, aspSummary: aspSummary())
            return
        }
        let relLabel = side.relativeLabel(facing: spot.parkingHeading) ?? side.displayName
        let sideLabel = "\(relLabel) (\(side.displayName) Side)"

        let schedule = spot.cleaningDays.compactMap { day -> String? in
            guard day >= 1, day <= 7 else { return nil }
            return "\(ScheduleFormatter.dayNames[day]) \(ScheduleFormatter.time(spot.cleaningStartHour, spot.cleaningStartMinute)) – \(ScheduleFormatter.time(spot.cleaningEndHour, spot.cleaningEndMinute))"
        }.joined(separator: "\n")

        let nextCleaning: String
        if let next = spot.nextCleaningDate {
            let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"
            nextCleaning = f.string(from: next)
        } else {
            nextCleaning = ""
        }

        let leftLabel = pendingStreet != nil
            ? "\(pendingLeftSide.displayName) Side"
            : "\(side.displayName) Side"
        let rightLabel = pendingStreet != nil
            ? "\(pendingRightSide.displayName) Side"
            : "\(side.opposite.displayName) Side"

        CarPlayDataStore.shared.setState(
            .spotSaved(
                streetName: spot.streetName,
                sideLabel: sideLabel,
                schedule: schedule.isEmpty ? "No restrictions" : schedule,
                nextCleaning: nextCleaning,
                spotID: spot.id,
                leftLabel: leftLabel,
                rightLabel: rightLabel
            ),
            aspSummary: aspSummary()
        )
    }

    private func aspSummary() -> String {
        if let holiday = ASPSuspensionCalendar.holidayName(on: Date()) {
            return "Suspended – \(holiday)"
        }
        if let next = ASPSuspensionCalendar.nextSuspension(after: Date()) {
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return "Next day off: \(f.string(from: next.date)) (\(next.holiday))"
        }
        return "In effect"
    }

    private func scheduleText(_ entries: [StreetCleaningEntry]) -> String {
        var seenDays = Set<Int>()
        let unique = entries
            .filter { e in
                guard let day = e.weekdayInt, !seenDays.contains(day) else { return false }
                seenDays.insert(day)
                return true
            }
            .sorted { ($0.weekdayInt ?? 0) < ($1.weekdayInt ?? 0) }
        guard !unique.isEmpty else { return "No restrictions" }
        return unique.map { "\(String($0.weekDay.prefix(3))) \($0.timeWindowDisplay)" }.joined(separator: "\n")
    }
}
