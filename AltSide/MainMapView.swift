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

    @Environment(\.locationManager) private var locationManager
    @Environment(\.motionManager) private var motionManager
    @Environment(\.bluetoothManager) private var bluetoothManager
    @Environment(\.cleaningDataManager) private var cleaningDataManager
    @Environment(\.notificationManager) private var notificationManager
    @Environment(\.liveActivityManager) private var liveActivityManager

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .camera(MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        distance: 50_000
    )))
    @State private var activeModal: ModalSheet?
    @State private var pendingSpot: ParkingSpot?
    @State private var resolvedStreet: BlockMatcher.ResolvedStreet?
    @State private var streetEntries: [StreetCleaningEntry] = []
    @State private var bestBlock: (from: String, to: String)?
    @State private var streetBearing: Double? = nil
    @State private var isResolvingStreet = false
    @State private var isBottomPanelExpanded = false
    @State private var screenHeight: CGFloat = 800
    @State private var showOutsideNYC = false
    @State private var userDismissedOutsideNYC = false
    @State private var showAddressPicker = false
    @State private var scoutInitialSide: SideDetector.StreetSide? = nil
    @State private var showWelcome = false
    /// Home (status + street browser) is the first screen on launch. MainMapView stays
    /// mounted underneath so auto-park detection and notification routing keep working.
    @State private var showHome = true
    @State private var backgroundedAt: Date? = nil
    @State private var hasZoomedToUser = false
    @State private var overrideCoordinate: CLLocationCoordinate2D? = nil
    /// Tracks the map center coordinate as the user drags — always the intended save location.
    @State private var pinCoordinate: CLLocationCoordinate2D? = nil
    /// The coordinate used for saving: address-picker override → pin on map → GPS.
    private var activeCoordinate: CLLocationCoordinate2D {
        overrideCoordinate ?? pinCoordinate ?? locationManager.coordinate
    }

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("tipPopupSuppressed") private var tipPopupSuppressed = false
    @State private var showTipPopup = false
    @State private var scoutSegments: [BlockSegment] = []
    @State private var browseSegments: [BlockSegment] = []
    /// Anchor set only when the map drag ENDS — prevents per-frame API hammering.
    @State private var browseAnchorCoord: CLLocationCoordinate2D? = nil

    private var savedSpot: ParkingSpot? { spots.first }

    /// Grid-cell key derived from the on-end anchor so the fetch only fires
    /// when the user lifts their finger and lands in a new ~500 m cell.
    private var browseGridKey: String {
        guard savedSpot == nil, !locationManager.scoutModeActive,
              let coord = browseAnchorCoord, coord.latitude != 0 else { return "" }
        return "\(Int(coord.latitude * 200))_\(Int(coord.longitude * 200))"
    }

    var body: some View {
        baseContent
            .onChange(of: motionManager.justParked, handleJustParkedChange)
            .onChange(of: bluetoothManager.justDisconnectedFromCar, handleBluetoothDisconnectChange)
            .onChange(of: notificationManager.pendingAction, handlePendingActionChange)
            .task(id: spots.first?.id) { syncWidgetData() }
            .task(id: browseGridKey) {
                guard !browseGridKey.isEmpty, let coord = browseAnchorCoord else {
                    browseSegments = []
                    return
                }
                // Don't clear before await — old segments stay visible during cache lookup.
                // Replace (not accumulate) to prevent Metal buffer overflow.
                let newSegs = await cleaningDataManager.loadNearbySegments(coordinate: coord)
                browseSegments = newSegs
            }
            .onChange(of: spots) { _, _ in syncWidgetData() }
            .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
                if let spot = spots.first {
                    liveActivityManager.startIfNeeded(for: spot)
                    Task { await liveActivityManager.checkUrgentAlerts(for: spot) }
                }
            }
            .onChange(of: scenePhase, handleScenePhaseChange)
            .onChange(of: locationManager.coordinate.latitude, handleLatitudeChange)
            .onChange(of: locationManager.authorizationStatus, handleAuthorizationChange)
            .onChange(of: locationManager.heading, handleHeadingChange)
            .onChange(of: locationManager.scoutModeActive, handleScoutModeActiveChange)
    }

    private var baseContent: some View {
        ZStack {
            if let spot = savedSpot {
                SavedSpotView(
                    spot: spot,
                    onClear: { clearSpot(spot) },
                    onNavigate: { navigateToCar(spot) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ZStack(alignment: .bottom) {
                    map

                    if !locationManager.scoutModeActive && overrideCoordinate == nil {
                        centerPinOverlay
                            .zIndex(4)
                            .allowsHitTesting(false)
                    }

                    if !locationManager.scoutModeActive {
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    overrideCoordinate = nil
                                    pinCoordinate = nil
                                    let coord = locationManager.coordinate
                                    withAnimation {
                                        cameraPosition = .camera(MapCamera(centerCoordinate: coord, distance: 400))
                                    }
                                    // If the user's real location is outside NYC, re-show the outside-NYC screen
                                    if !showOutsideNYC && !userDismissedOutsideNYC {
                                        let borough = CleaningDataManager.borough(for: coord)
                                        if borough.isEmpty {
                                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                                showOutsideNYC = true
                                            }
                                        }
                                    }
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.sweepySurface2)
                                            .frame(width: 36, height: 36)
                                            .shadow(radius: 4)
                                        Image(systemName: "location.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.sweepyGreen)
                                    }
                                }
                                .padding(.trailing, 16)
                                .padding(.top, SweepyNavBar.height + 8)
                            }
                            Spacer()
                        }
                        .zIndex(5)
                    }

                    bottomPanelOverlay

                    if showOutsideNYC {
                        OutsideNYCView(
                            onLocationSelected: { coordinate, _ in
                                overrideCoordinate = coordinate
                                let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coordinate, distance: 400))
                                withAnimation { cameraPosition = cam }
                                showOutsideNYC = false
                            },
                            onDismiss: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    showOutsideNYC = false
                                }
                                userDismissedOutsideNYC = true
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(10)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
            }
        }
        .overlay {
            if showHome {
                HomeView(
                    savedSpot: savedSpot,
                    onParkHere: { coord in parkFromHome(at: coord) },
                    onOpenCar: { withAnimation { showHome = false } },
                    onHelp: { showWelcome = true }
                )
                .transition(.opacity)
            }
        }
        // Main nav — one bar above every scene so Home is always in the same place.
        .overlay(alignment: .top) {
            SweepyNavBar(
                selected: showHome ? .home : .parking,
                hasSavedSpot: savedSpot != nil,
                onSelect: { tab in
                    withAnimation {
                        switch tab {
                        case .home:
                            if locationManager.scoutModeActive { locationManager.scoutModeActive = false }
                            showHome = true
                        case .parking:
                            showHome = false
                        }
                    }
                },
                onHelp: { showWelcome = true }
            )
        }
        .animation(.easeInOut(duration: 0.25), value: showHome)
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
        .sheet(isPresented: $showTipPopup) {
            TipPopupView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddressPicker) {
            AddressPickerSheet(
                onLocationSelected: { coordinate in
                    overrideCoordinate = coordinate
                    pinCoordinate = coordinate
                    let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coordinate, distance: 400))
                    withAnimation { cameraPosition = cam }
                },
                onHelpTap: { showWelcome = true }
            )
            .presentationDetents([.large])
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            if overrideCoordinate == nil {
                UserAnnotation()
            }
            if let override = overrideCoordinate {
                Annotation("Selected Location", coordinate: override) {
                    ZStack {
                        Circle()
                            .fill(Color.sweepyGreen.opacity(0.2))
                            .frame(width: 48, height: 48)
                        Circle()
                            .fill(Color.sweepyGreen)
                            .frame(width: 32, height: 32)
                        Image(systemName: "mappin.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.sweepyGreen.opacity(0.5), radius: 8)
                }
            }
            if let spot = savedSpot {
                Annotation("My Car", coordinate: spot.coordinate) {
                    savedSpotPin(for: spot)
                }
            }
            ForEach(scoutSegments) { segment in
                let coords = [segment.fromCoord, segment.toCoord]
                MapPolyline(coordinates: coords)
                    .stroke(segment.isSoon ? Color.sweepyAmber : Color.sweepyGreen,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            ForEach(browseSegments) { segment in
                MapPolyline(coordinates: [segment.fromCoord, segment.toCoord])
                    .stroke(segment.isSoon ? Color.sweepyAmber : Color.sweepyGreen,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
        .mapStyle(.standard)
        .environment(\.colorScheme, .light)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: panelCollapsedHeight)
        }
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { @MainActor context in
            guard savedSpot == nil, !locationManager.scoutModeActive else { return }
            pinCoordinate = context.camera.centerCoordinate
            if overrideCoordinate != nil {
                overrideCoordinate = context.camera.centerCoordinate
            }
        }
        .onMapCameraChange(frequency: .onEnd) { @MainActor context in
            guard savedSpot == nil, !locationManager.scoutModeActive else { return }
            browseAnchorCoord = context.camera.centerCoordinate
        }
        .ignoresSafeArea()
    }

    private func savedSpotPin(for spot: ParkingSpot) -> some View {
        let color: Color = spot.isCleaningSoon ? Color.sweepyAmber : Color.sweepyGreen
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

    // MARK: - Center Pin Overlay

    /// Green pin fixed at the map's visual center (above the panel).
    /// Two equal Spacers + a panel-height placeholder correctly centre the pin
    /// in the visible area, matching MapKit's safeAreaInset camera coordinate.
    private var centerPinOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.sweepyGreen.opacity(0.2))
                    .frame(width: 56, height: 56)
                Circle()
                    .fill(Color.sweepyGreen)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                Image(systemName: "car.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Color.clear.frame(height: panelCollapsedHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    // MARK: - Bottom Panel Overlay (replaces persistent sheet)

    private var bottomPanelOverlay: some View {
        VStack(spacing: 0) {
            // Drag handle — only shown in scout mode (no reason to expand the NoSpotPanel)
            if locationManager.scoutModeActive {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isBottomPanelExpanded.toggle()
                    }
                }) {
                    Capsule()
                        .fill(Color.sweepyGray3.opacity(0.5))
                        .frame(width: 36, height: 4)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

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
                        onHelpTap: { showWelcome = true },
                        onSaveWithSide: { side, entries, street in
                            resolvedStreet = street
                            streetEntries = entries
                            bestBlock = nil
                            withAnimation { locationManager.scoutModeActive = false }
                            let coord = activeCoordinate
                            createSpot(street: street, side: side, confirmedEntries: entries, userCoordinate: coord)
                        },
                        onSegmentsUpdated: { segments in
                            scoutSegments = segments
                        }
                    )
                } else {
                    NoSpotPanel(
                        isLoading: isResolvingStreet || cleaningDataManager.isLoading,
                        onSaveTap: {
                            triggerSaveFlow(at: pinCoordinate)
                        },
                        onScoutTap: {
                            motionManager.startMonitoring()
                            bluetoothManager.startMonitoring()
                            withAnimation { locationManager.scoutModeActive = true }
                        },
                        onAddressTap: {
                            showAddressPicker = true
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: isBottomPanelExpanded ? panelExpandedHeight : panelCollapsedHeight)
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: -4)
        .gesture(locationManager.scoutModeActive ?
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
            : nil
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
                    coordinate: activeCoordinate,
                    streetName: street.name,
                    entries: streetEntries,
                    streetOrientation: street.orientation,
                    onConfirm: { side, confirmedEntries in
                        scoutInitialSide = nil
                        let savedCoord = activeCoordinate
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            createSpot(street: street, side: side, confirmedEntries: confirmedEntries, userCoordinate: savedCoord)
                        }
                    },
                    initialSide: scoutInitialSide,
                    onHelpTap: { showWelcome = true },
                    onCancel: {
                        overrideCoordinate = nil
                        pinCoordinate = nil
                        let coord = locationManager.coordinate
                        withAnimation {
                            cameraPosition = .camera(MapCamera(centerCoordinate: coord, distance: 400))
                        }
                    },
                    onRefresh: {
                        let all = await cleaningDataManager.loadSchedule(
                            streetName: street.normalizedName,
                            borough: street.borough,
                            coordinate: street.snappedCoordinate
                        )
                        let fresh = CleaningDataManager.blockSchedule(
                            all, streetName: street.normalizedName, coordinate: street.snappedCoordinate
                        ).entries
                        streetEntries = fresh
                        return fresh
                    },
                    precomputedBearing: streetBearing
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
                        pendingSpot = nil
                        showTipIfNeeded()
                    },
                    onCancel: {
                        activeModal = nil
                        if let spot = pendingSpot {
                            Task { @MainActor in await notificationManager.cancelAlerts(for: spot.id) }
                            spot.isActive = false
                            try? modelContext.save()
                        }
                        pendingSpot = nil
                        overrideCoordinate = nil
                        // Reset camera — same animation as initial app launch
                        hasZoomedToUser = false
                        cameraPosition = .camera(MapCamera(
                            centerCoordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
                            distance: 50_000
                        ))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let coord = locationManager.coordinate
                            let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coord, distance: 400))
                            withAnimation(.easeInOut(duration: 1.2)) { cameraPosition = cam }
                            hasZoomedToUser = true
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
                        Task { @MainActor in await notificationManager.scheduleAlerts(for: spot) }
                        Task { @MainActor in await liveActivityManager.updateActivity(for: spot) }
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
                    },
                    onCancel: {
                        activeModal = nil
                        if let spot = pendingSpot {
                            Task { @MainActor in await notificationManager.cancelAlerts(for: spot.id) }
                            spot.isActive = false
                            try? modelContext.save()
                        }
                        pendingSpot = nil
                        overrideCoordinate = nil
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
                        showTipIfNeeded()
                    }
                )
                .presentationDetents([.large])
            }
        }
    }

    // MARK: - Actions

    private func handleJustParkedChange(_: Bool, _ parked: Bool) {
        if parked && savedSpot == nil { triggerSaveFlow() }
    }

    private func handleBluetoothDisconnectChange(_: Bool, _ disconnected: Bool) {
        if disconnected && savedSpot == nil { triggerSaveFlow() }
    }

    private func handlePendingActionChange(_: ParkingNotificationAction?, _ action: ParkingNotificationAction?) {
        guard let action else { return }
        handleNotificationAction(action)
        notificationManager.pendingAction = nil
    }

    private func handleScenePhaseChange(_: ScenePhase, _ phase: ScenePhase) {
        if phase == .background { backgroundedAt = .now }
        if phase == .active, let spot = spots.first {
            liveActivityManager.startIfNeeded(for: spot)
        }
        // Reopening the app after a while lands on Home, unless a flow is in progress.
        if phase == .active, let since = backgroundedAt, Date.now.timeIntervalSince(since) > 300,
           activeModal == nil, !locationManager.scoutModeActive {
            showHome = true
        }
        if phase == .active { backgroundedAt = nil }
    }

    /// "I parked here" on Home: move the save map to the pin and start the save flow.
    private func parkFromHome(at coord: CLLocationCoordinate2D) {
        overrideCoordinate = nil
        pinCoordinate = coord
        browseAnchorCoord = coord
        hasZoomedToUser = true   // don't let the first GPS fix yank the map back
        cameraPosition = .camera(MapCamera(centerCoordinate: coord, distance: 400))
        triggerSaveFlow(at: coord)
    }

    private func handleHeadingChange(_: Double, _ heading: Double) {
        guard locationManager.scoutModeActive, heading >= 0 else { return }
        updateScoutCamera()
    }

    private func handleAuthorizationChange(_: CLAuthorizationStatus, _ status: CLAuthorizationStatus) {
        guard !showOutsideNYC, !userDismissedOutsideNYC, overrideCoordinate == nil else { return }
        if status == .denied || status == .restricted {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showOutsideNYC = true
            }
        }
    }

    private func handleLatitudeChange(_: Double, _ lat: Double) {
        guard lat != 0, overrideCoordinate == nil else { return }
        if locationManager.scoutModeActive {
            updateScoutCamera()
            return
        }
        if !showOutsideNYC && !userDismissedOutsideNYC {
            let borough = CleaningDataManager.borough(for: locationManager.coordinate)
            if borough.isEmpty {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showOutsideNYC = true
                }
            }
        }
        if !hasZoomedToUser {
            hasZoomedToUser = true
            let coord = locationManager.coordinate
            pinCoordinate = coord
            browseAnchorCoord = coord   // trigger initial browse segment load
            let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coord, distance: 400))
            withAnimation { cameraPosition = cam }
        }
    }

    private func handleScoutModeActiveChange(_: Bool, _ active: Bool) {
        if active {
            browseSegments = []
        } else {
            scoutSegments = []
        }
        guard active, overrideCoordinate == nil else { return }
        updateScoutCamera()
    }

    private func updateScoutCamera() {
        let heading = locationManager.heading >= 0 ? locationManager.heading : 0
        cameraPosition = .camera(MapCamera(
            centerCoordinate: locationManager.coordinate,
            distance: 400,
            heading: heading,
            pitch: 0
        ))
    }

private func triggerSaveFlow(at saveCoord: CLLocationCoordinate2D? = nil) {
        showHome = false
        bestBlock = nil
        isResolvingStreet = true
        Task { @MainActor in
            do {
                let street = try await BlockMatcher.resolve(coordinate: saveCoord ?? activeCoordinate)
                let snapped = street.snappedCoordinate
                let allEntries = await cleaningDataManager.loadSchedule(
                    streetName: street.normalizedName,
                    borough: street.borough,
                    coordinate: snapped
                )

                // Narrow the bbox fetch (every street nearby) down to this street's block.
                let block = CleaningDataManager.blockSchedule(
                    allEntries, streetName: street.normalizedName, coordinate: snapped
                )

                // Street bearing from the matched block — SidePickerView only receives deduped
                // entries, which are too sparse to compute a reliable bearing from.
                streetBearing = block.streetBearing

                var deduped = block.entries
                var blockFrom = block.fromStreet
                var blockTo   = block.toStreet

                if deduped.isEmpty {
                    // Resolved street has no data at all. Fall back to MapKit matching
                    // against nearby geocoded blocks (signs with NULL-coord gaps).
                    let geocoded = allEntries.filter { $0.signXCoord != nil && $0.signYCoord != nil }
                    let nearby   = CleaningDataManager.proximityFiltered(geocoded, coordinate: snapped)
                    let geoPool  = nearby.isEmpty ? geocoded : nearby
                    if let best = await BlockMatcher.findBestBlock(
                        entries: geoPool,
                        streetName: street.normalizedName,
                        borough: street.borough,
                        userCoordinate: saveCoord ?? activeCoordinate
                    ) {
                        let matched = geoPool.filter { e in
                            (BlockMatcher.fuzzyMatch(e.fromStreet, best.from) && BlockMatcher.fuzzyMatch(e.toStreet, best.to)) ||
                            (BlockMatcher.fuzzyMatch(e.fromStreet, best.to)   && BlockMatcher.fuzzyMatch(e.toStreet, best.from))
                        }
                        deduped   = CleaningDataManager.closestSignDedup(matched, coordinate: snapped)
                        blockFrom = best.from
                        blockTo   = best.to
                    }
                }

                resolvedStreet = street
                bestBlock = blockFrom.isEmpty ? nil : (from: blockFrom, to: blockTo)
                streetEntries = deduped
            } catch {
                resolvedStreet = BlockMatcher.ResolvedStreet(
                    name: "Current Location",
                    normalizedName: "",
                    borough: "Manhattan",
                    addressNumber: "",
                    crossStreetFrom: "",
                    crossStreetTo: "",
                    orientation: .eastWest,
                    snappedCoordinate: activeCoordinate
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
        confirmedEntries: [StreetCleaningEntry]? = nil,
        userCoordinate: CLLocationCoordinate2D? = nil
    ) {
        // Entries are already deduped to one per (side, weekday) by triggerSaveFlow.
        let pool = confirmedEntries ?? streetEntries
        let source = pool.filter { $0.normalizedSide == side }

        // Sort so the most imminent cleaning is first — used to pick the stored time window.
        let dedupedEntries = source.sorted {
            ($0.nextCleaningDate() ?? .distantFuture) < ($1.nextCleaningDate() ?? .distantFuture)
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
            coordinate: userCoordinate ?? street.snappedCoordinate,
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
        // Request notification permission on first save — contextually relevant.
        if notificationManager.authorizationStatus == .notDetermined {
            Task { @MainActor in _ = await notificationManager.requestPermission() }
        }
        // Start motion/Bluetooth monitoring after first save so auto-detect works
        // for future parking sessions. Deferred to here so the prompts don't appear
        // before the user has actually saved a spot.
        motionManager.startMonitoring()
        bluetoothManager.startMonitoring()
        pendingSpot = spot
        activeModal = .saveConfirm
    }



    private func showTipIfNeeded() {
        guard !tipPopupSuppressed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showTipPopup = true
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
                    return "\(dayFmt.string(from: next)) \(ScheduleFormatter.time(spot.cleaningStartHour, spot.cleaningStartMinute)) – \(ScheduleFormatter.time(spot.cleaningEndHour, spot.cleaningEndMinute))"
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
        Task { @MainActor in await notificationManager.cancelAlerts(for: spot.id) }
        Task { @MainActor in await liveActivityManager.endActivity() }
        liveActivityManager.resetAlertState(for: spot.id.uuidString)
        spot.isActive = false
        try? modelContext.save()
        overrideCoordinate = nil
        // Reset to NYC level, then zoom to street level — same as initial app launch
        hasZoomedToUser = false
        cameraPosition = .camera(MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            distance: 50_000
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let coord = locationManager.coordinate
            let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coord, distance: 400))
            withAnimation(.easeInOut(duration: 1.2)) { cameraPosition = cam }
            hasZoomedToUser = true
        }
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
    let onAddressTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WHERE DID YOU PARK?")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.sweepyGray3)

            Text("Save your spot")
                .font(.system(size: 28, weight: .black))
                .tracking(-0.8)
                .foregroundStyle(Color.sweepyWhite)

            Text("We'll track street cleaning for the exact side you parked on.")
                .font(.system(size: 13))
                .foregroundStyle(Color.sweepyGray2)

            SweepyButton(
                title: "Save spot here",
                icon: "location.fill",
                isLoading: isLoading,
                action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSaveTap()
                }
            )

            SweepyButton(
                title: "Scout mode",
                icon: "steeringwheel",
                style: .dark,
                action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onScoutTap()
                }
            )

            SweepyButton(
                title: "Enter a specific address",
                icon: "magnifyingglass",
                style: .ghost,
                action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onAddressTap()
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
    }
}

// MARK: - ASP Suspended Banner

struct ASPSuspendedBanner: View {
    let holidayName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.sweepyGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text("ASP SUSPENDED TODAY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.sweepyGreen)
                Text(holidayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyGray2)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.sweepyGreen.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.sweepyGreen.opacity(0.25), lineWidth: 1)
        )
    }
}

