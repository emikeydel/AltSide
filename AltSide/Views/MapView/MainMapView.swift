import SwiftUI
import MapKit
import SwiftData
import WidgetKit
import Combine

// MARK: - Modal routing

private enum ModalSheet: Identifiable {
    case savePicker
    case saveConfirm
    case reminderSetup
    case parkedSummary

    var id: Int {
        switch self {
        case .savePicker:     0
        case .saveConfirm:    1
        case .reminderSetup:  2
        case .parkedSummary:  3
        }
    }
}

struct MainMapView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<ParkingSpot> { $0.isActive }) private var spots: [ParkingSpot]

    var locationManager: LocationManager
    var motionManager: MotionManager
    var bluetoothManager: BluetoothManager
    var cleaningDataManager: CleaningDataManager
    var notificationManager: NotificationManager
    var liveActivityManager: LiveActivityManager

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var activeModal: ModalSheet?
    @State private var pendingSpot: ParkingSpot?
    @State private var resolvedStreet: BlockMatcher.ResolvedStreet?
    @State private var streetEntries: [StreetCleaningEntry] = []
    @State private var bestBlock: (from: String, to: String)?
    @State private var isResolvingStreet = false
    @State private var isBottomPanelExpanded = false
    @State private var screenHeight: CGFloat = 800
    @State private var showOutsideNYC = false
    @State private var showWelcome = false
    @State private var hasZoomedToUser = false

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    private var savedSpot: ParkingSpot? { spots.first }

    var body: some View {
        ZStack {
            if let spot = savedSpot {
                SavedSpotView(
                    spot: spot,
                    onClear: { clearSpot(spot) },
                    onNavigate: { navigateToCar(spot) },
                    notificationManager: notificationManager
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ZStack(alignment: .bottom) {
                    map

                    // Info button — top left
                    VStack {
                        HStack {
                            Button(action: { showWelcome = true }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.uberSurface2)
                                        .frame(width: 36, height: 36)
                                        .shadow(radius: 4)
                                    Text("?")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color.uberGray2)
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.top, 60)
                            Spacer()
                        }
                        Spacer()
                    }
                    .zIndex(5)

                    bottomPanelOverlay

                    if showOutsideNYC {
                        OutsideNYCView { _, _ in showOutsideNYC = false }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(10)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: savedSpot == nil)
        .onAppear {
            if !hasSeenWelcome { showWelcome = true }
        }
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.height
        } action: { height in
            screenHeight = height
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView {
                hasSeenWelcome = true
                showWelcome = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $activeModal) { modal in
            modalContent(for: modal)
        }
        .onChange(of: motionManager.justParked) { _, parked in
            if parked && savedSpot == nil { triggerSaveFlow() }
        }
        .onChange(of: bluetoothManager.justDisconnectedFromCar) { _, disconnected in
            if disconnected && savedSpot == nil { triggerSaveFlow() }
        }
        .onChange(of: notificationManager.pendingAction) { _, action in
            guard let action else { return }
            handleNotificationAction(action)
            notificationManager.pendingAction = nil
        }
        .task(id: spots.first?.id) { syncWidgetData() }
        .onChange(of: spots) { _, _ in syncWidgetData() }
        // Check every 5 minutes whether it's time to start the Live Activity
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            if let spot = spots.first { liveActivityManager.startIfNeeded(for: spot) }
        }
        // Also check immediately when the app comes back to foreground
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let spot = spots.first {
                liveActivityManager.startIfNeeded(for: spot)
            }
        }
        .onChange(of: locationManager.coordinate.latitude) { _, lat in
            guard lat != 0, !showOutsideNYC else { return }
            let borough = CleaningDataManager.borough(for: locationManager.coordinate)
            if borough.isEmpty {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showOutsideNYC = true
                }
            }
            if !hasZoomedToUser {
                hasZoomedToUser = true
                withAnimation {
                    cameraPosition = .camera(MapCamera(
                        centerCoordinate: locationManager.coordinate,
                        distance: 400
                    ))
                }
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            if let spot = savedSpot {
                Annotation("My Car", coordinate: spot.coordinate) {
                    savedSpotPin(for: spot)
                }
            }
        }
        .mapStyle(.standard)
        .environment(\.colorScheme, .light)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: panelCollapsedHeight)
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea()
    }

    private func savedSpotPin(for spot: ParkingSpot) -> some View {
        let color: Color = spot.isCleaningSoon ? Color.uberAmber : Color.uberGreen
        return ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 48, height: 48)
            Circle()
                .fill(color)
                .frame(width: 32, height: 32)
            Image(systemName: "car.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .shadow(color: color.opacity(0.5), radius: 8)
    }

    // MARK: - Bottom Panel Overlay (replaces persistent sheet)

    private var bottomPanelOverlay: some View {
        VStack(spacing: 0) {
            // Drag handle — tap to toggle expanded
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isBottomPanelExpanded.toggle()
                }
            }) {
                Capsule()
                    .fill(Color.uberGray3.opacity(0.5))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ASP suspension banner — shown when street cleaning is suspended today.
            if let holiday = ASPSuspensionCalendar.holidayName(on: Date()) {
                ASPSuspendedBanner(holidayName: holiday)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Panel content
            Group {
                if locationManager.scoutModeActive {
                    ScoutBottomPanel(
                        locationManager: locationManager,
                        cleaningDataManager: cleaningDataManager,
                        onSaveWithSide: { side, entries, street in
                            streetEntries = entries
                            resolvedStreet = street
                            Task {
                                let best = await BlockMatcher.findBestBlock(
                                    entries: entries,
                                    streetName: street.normalizedName,
                                    borough: street.borough,
                                    userCoordinate: locationManager.coordinate
                                )
                                bestBlock = best
                                withAnimation { locationManager.scoutModeActive = false }
                                createSpot(street: street, side: side)
                            }
                        }
                    )
                } else {
                    NoSpotPanel(
                        isLoading: isResolvingStreet || cleaningDataManager.isLoading,
                        onSaveTap: {
                            motionManager.startMonitoring()
                            triggerSaveFlow()
                        },
                        onScoutTap: {
                            motionManager.startMonitoring()
                            withAnimation { locationManager.scoutModeActive = true }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: isBottomPanelExpanded ? panelExpandedHeight : panelCollapsedHeight)
        .background(Color.uberSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: -4)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if value.translation.height < -40 {
                            isBottomPanelExpanded = true
                        } else if value.translation.height > 40 {
                            isBottomPanelExpanded = false
                        }
                    }
                }
        )
        .padding(.horizontal, 0)
    }

    private var panelCollapsedHeight: CGFloat {
        locationManager.scoutModeActive ? screenHeight * 0.68 : screenHeight * 0.44
    }
    private var panelExpandedHeight: CGFloat { screenHeight * 0.88 }

    // MARK: - Modal content

    @ViewBuilder
    private func modalContent(for modal: ModalSheet) -> some View {
        switch modal {
        case .savePicker:
            if let street = resolvedStreet {
                SidePickerView(
                    coordinate: locationManager.coordinate,
                    streetName: street.name,
                    entries: streetEntries,
                    locationManager: locationManager,
                    streetOrientation: street.orientation,
                    onConfirm: { side, confirmedEntries in
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            createSpot(street: street, side: side, confirmedEntries: confirmedEntries)
                        }
                    }
                )
                .presentationDetents([.large])
            }

        case .saveConfirm:
            if let spot = pendingSpot {
                SaveConfirmView(
                    spot: spot,
                    onSetReminders: {
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeModal = .reminderSetup
                        }
                    },
                    onShare: {
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeModal = .parkedSummary
                        }
                    },
                    onDone: {
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeModal = .parkedSummary
                        }
                    }
                )
                .presentationDetents([.large])
            }

        case .reminderSetup:
            if let spot = pendingSpot {
                ReminderSetupView(
                    spot: spot,
                    onSave: {
                        Task { await notificationManager.scheduleAlerts(for: spot) }
                        Task { await liveActivityManager.updateActivity(for: spot) }
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeModal = .parkedSummary
                        }
                    },
                    onSkip: {
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeModal = .parkedSummary
                        }
                    }
                )
                .presentationDetents([.large])
            }

        case .parkedSummary:
            if let spot = pendingSpot {
                ParkedSummaryView(
                    spot: spot,
                    onDone: {
                        activeModal = nil
                        pendingSpot = nil
                    },
                    notificationManager: notificationManager
                )
                .presentationDetents([.large])
            }
        }
    }

    // MARK: - Actions

    private func triggerSaveFlow() {
        isResolvingStreet = true
        Task {
            do {
                let street = try await BlockMatcher.resolve(coordinate: locationManager.coordinate)
                let allEntries = await cleaningDataManager.loadSchedule(
                    streetName: street.normalizedName,
                    borough: street.borough,
                    coordinate: locationManager.coordinate
                )

                // Pre-filter to signs within ~300 m (984 ft) of the user, matching
                // the same proximity window scout mode uses for its nearbyEntries display.
                // Entries with NULL sign coords are kept so the cross-street fallback still works.
                let coord = locationManager.coordinate
                let (ux, uy) = CleaningDataManager.wgs84ToStatePlane(lat: coord.latitude, lon: coord.longitude)
                let nearby = allEntries.filter { e in
                    guard let sx = e.signXCoord, let sy = e.signYCoord else { return false }
                    return sqrt((sx - ux) * (sx - ux) + (sy - uy) * (sy - uy)) <= 984
                }
                let entries = nearby.isEmpty ? allEntries : nearby

                let best = await BlockMatcher.findBestBlock(
                    entries: entries,
                    streetName: street.normalizedName,
                    borough: street.borough,
                    userCoordinate: locationManager.coordinate
                )
                resolvedStreet = street
                streetEntries = entries
                bestBlock = best
            } catch {
                resolvedStreet = BlockMatcher.ResolvedStreet(
                    name: "Current Location",
                    normalizedName: "",
                    borough: "Manhattan",
                    addressNumber: "",
                    crossStreetFrom: "",
                    crossStreetTo: "",
                    orientation: .eastWest
                )
                streetEntries = []
                bestBlock = nil
            }
            isResolvingStreet = false
            activeModal = .savePicker
        }
    }

    private func createSpot(
        street: BlockMatcher.ResolvedStreet,
        side: SideDetector.StreetSide,
        confirmedEntries: [StreetCleaningEntry]? = nil
    ) {
        // If entries were passed directly from the picker (already proximity-filtered and
        // shown to the user), use them as-is. Otherwise fall back to blockMatchedEntries
        // (scout mode path, which handles its own filtering).
        let pool = confirmedEntries ?? streetEntries
        let sideEntries = pool.filter { $0.normalizedSide == side }
        let blockEntries = blockMatchedEntries(sideEntries, street: street)
        let source = blockEntries.isEmpty ? sideEntries : blockEntries

        // Sort by next cleaning date so dedupedEntries.first is always the most imminent entry,
        // ensuring the stored time window matches the next actual cleaning event.
        let sorted = source.sorted {
            ($0.nextCleaningDate() ?? .distantFuture) < ($1.nextCleaningDate() ?? .distantFuture)
        }

        // One entry per cleaning day — avoid duplicates from multiple signs on the same block.
        var seenDays = Set<Int>()
        let dedupedEntries = sorted.filter { entry in
            guard let day = entry.weekdayInt, !seenDays.contains(day) else { return false }
            seenDays.insert(day)
            return true
        }

        // Use cross streets from the dataset entry (via findBestBlock) when available;
        // they're more reliable than the reverse-geocoded nearbyCrossStreets result.
        // Dataset values are ALL-CAPS, so convert to Title Case for display.
        func titleCase(_ s: String) -> String {
            s.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        }
        let crossFrom = bestBlock.map { titleCase($0.from) } ?? street.crossStreetFrom
        let crossTo   = bestBlock.map { titleCase($0.to)   } ?? street.crossStreetTo

        let spot = ParkingSpot(
            coordinate: locationManager.coordinate,
            streetName: street.name,
            crossStreetFrom: crossFrom,
            crossStreetTo: crossTo,
            side: side,
            cleaningDays: dedupedEntries.compactMap { $0.weekdayInt },
            cleaningStartHour: dedupedEntries.first?.startHour ?? 8,
            cleaningStartMinute: dedupedEntries.first?.startMinute ?? 0,
            cleaningEndHour: dedupedEntries.first?.endHour ?? 9,
            cleaningEndMinute: dedupedEntries.first?.endMinute ?? 30
        )
        spot.parkingHeading = locationManager.heading
        spot.refreshNextCleaningDate()
        modelContext.insert(spot)
        syncWidgetData(with: spot)
        liveActivityManager.startIfNeeded(for: spot)
        // Request notification permission on first save — contextually relevant
        if notificationManager.authorizationStatus == .notDetermined {
            Task { _ = await notificationManager.requestPermission() }
        }
        pendingSpot = spot
        activeModal = .saveConfirm
    }

    /// Filters entries to the user's specific block.
    /// Prefers NY State Plane coordinate proximity when available;
    /// falls back to cross-street name matching.
    private func blockMatchedEntries(_ entries: [StreetCleaningEntry], street: BlockMatcher.ResolvedStreet) -> [StreetCleaningEntry] {
        let userCoord = locationManager.coordinate

        // --- State Plane proximity (most reliable) ---
        // Convert user WGS84 to approximate EPSG:2263 (US survey feet) and
        // compare against each sign's stored x/y coords.
        // 300 m ≈ 984 ft; threshold is generous enough for block-level matching.
        let (userX, userY) = CleaningDataManager.wgs84ToStatePlane(lat: userCoord.latitude, lon: userCoord.longitude)
        let thresholdFt: Double = 984  // 300 m
        let byProximity = entries.filter { entry in
            guard let sx = entry.signXCoord, let sy = entry.signYCoord else { return false }
            let dx = sx - userX, dy = sy - userY
            return sqrt(dx * dx + dy * dy) <= thresholdFt
        }
        if !byProximity.isEmpty { return byProximity }

        // --- Best block match (geocoded intersection proximity) ---
        if let best = bestBlock {
            let bf = BlockMatcher.normalize(best.from)
            let bt = BlockMatcher.normalize(best.to)
            let byBestBlock = entries.filter { entry in
                let ef = BlockMatcher.normalize(entry.fromStreet)
                let et = BlockMatcher.normalize(entry.toStreet)
                return ef == bf || ef == bt || et == bf || et == bt
            }
            if !byBestBlock.isEmpty { return byBestBlock }
        }

        // --- Cross-street name fallback ---
        guard !street.crossStreetFrom.isEmpty else { return [] }
        let cf = BlockMatcher.normalize(street.crossStreetFrom)
        let ct = BlockMatcher.normalize(street.crossStreetTo)
        return entries.filter { entry in
            let ef = BlockMatcher.normalize(entry.fromStreet)
            let et = BlockMatcher.normalize(entry.toStreet)
            return ef == cf || ef == ct || et == cf || et == ct
        }
    }


    private func syncWidgetData() {
        syncWidgetData(with: spots.first)
    }

    private func syncWidgetData(with spot: ParkingSpot?) {
        if let spot = spot {
            ParkingWidgetData(
                streetName: spot.streetName,
                sideDisplayName: {
                    guard let side = spot.streetSide else { return "" }
                    let rel = side.relativeLabel(facing: spot.parkingHeading)
                    return rel.map { "\($0) side (\(side.displayName))" } ?? "\(side.displayName) side"
                }(),
                moveByDisplay: spot.moveByDisplay,
                scheduleDisplay: {
                    guard let next = spot.nextCleaningDate else { return "" }
                    let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE"
                    func t(_ h: Int, _ m: Int) -> String {
                        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
                        let p = h < 12 ? "AM" : "PM"
                        return m == 0 ? "\(h12) \(p)" : "\(h12):\(String(format: "%02d", m)) \(p)"
                    }
                    return "\(dayFmt.string(from: next)) \(t(spot.cleaningStartHour, spot.cleaningStartMinute)) – \(t(spot.cleaningEndHour, spot.cleaningEndMinute))"
                }(),
                cleaningDate: spot.nextCleaningDate,
                isCleaningSoon: spot.isCleaningSoon,
                isParked: true
            ).save()
        } else {
            ParkingWidgetData.clear()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func clearSpot(_ spot: ParkingSpot) {
        Task { await notificationManager.cancelAlerts(for: spot.id) }
        Task { await liveActivityManager.endActivity() }
        spot.isActive = false
        try? modelContext.save()
    }

    private func navigateToCar(_ spot: ParkingSpot) {
        let url = URL(string: "maps://?ll=\(spot.latitude),\(spot.longitude)&q=My+Car")!
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    /// Called when the user taps an action button on a notification.
    private func handleNotificationAction(_ action: ParkingNotificationAction) {
        switch action {
        case .clearSpot(let id):
            guard let spot = spots.first(where: { $0.id == id }) else { return }
            clearSpot(spot)
        case .navigateTo(let id):
            guard let spot = spots.first(where: { $0.id == id }) else { return }
            navigateToCar(spot)
        }
    }
}

// MARK: - No Spot Panel

struct NoSpotPanel: View {
    let isLoading: Bool
    let onSaveTap: () -> Void
    let onScoutTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WHERE DID YOU PARK?")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.uberGray3)

            Text("Save your spot")
                .font(.system(size: 28, weight: .black))
                .tracking(-0.8)
                .foregroundStyle(Color.uberWhite)

            Text("We'll track street cleaning for the exact side you parked on.")
                .font(.system(size: 13))
                .foregroundStyle(Color.uberGray2)

            UberButton(
                title: "Save spot here",
                icon: "location.fill",
                isLoading: isLoading,
                action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSaveTap()
                }
            )

            UberButton(
                title: "Use my location and find parking",
                icon: "dot.radiowaves.left.and.right",
                style: .secondary,
                action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onScoutTap()
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

// MARK: - ASP Suspended Banner

struct ASPSuspendedBanner: View {
    let holidayName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.uberGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text("ASP SUSPENDED TODAY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.uberGreen)
                Text(holidayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.uberGray2)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.uberGreen.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.uberGreen.opacity(0.25), lineWidth: 1)
        )
    }
}

