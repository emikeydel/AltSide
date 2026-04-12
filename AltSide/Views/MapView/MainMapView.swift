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
    @State private var showAddressPicker = false
    @State private var scoutInitialSide: SideDetector.StreetSide? = nil
    @State private var showWelcome = false
    @State private var hasZoomedToUser = false
    @State private var overrideCoordinate: CLLocationCoordinate2D? = nil
    /// Tracks the map center coordinate as the user drags — always the intended save location.
    @State private var pinCoordinate: CLLocationCoordinate2D? = nil
    /// Block-face segments for the current street — drawn as coloured polylines on the map.
    @State private var blockSegments: [BlockSegment] = []
    /// Grid cells (~330 m) for which background segments have already been loaded.
    /// Prevents redundant fetches when the user stays in the same area.
    @State private var loadedSegmentCells: Set<String> = []

    /// The coordinate used for saving: address-picker override → pin on map → GPS.
    private var activeCoordinate: CLLocationCoordinate2D {
        overrideCoordinate ?? pinCoordinate ?? locationManager.coordinate
    }

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    private var savedSpot: ParkingSpot? { spots.first }

    var body: some View {
        baseContent
            .onChange(of: motionManager.justParked, handleJustParkedChange)
            .onChange(of: bluetoothManager.justDisconnectedFromCar, handleBluetoothDisconnectChange)
            .onChange(of: notificationManager.pendingAction, handlePendingActionChange)
            .task(id: spots.first?.id) { syncWidgetData() }
            .onChange(of: spots) { _, _ in syncWidgetData() }
            .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
                if let spot = spots.first { liveActivityManager.startIfNeeded(for: spot) }
            }
            .onChange(of: scenePhase, handleScenePhaseChange)
            .onChange(of: locationManager.coordinate.latitude, handleLatitudeChange)
            .onChange(of: locationManager.heading, handleHeadingChange)
            .onChange(of: locationManager.scoutModeActive, handleScoutModeActiveChange)
    }

    private var baseContent: some View {
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

                    // Always-on center pin — shows where the spot will be saved
                    if savedSpot == nil && !locationManager.scoutModeActive {
                        centerPinOverlay
                            .zIndex(4)
                            .allowsHitTesting(false)
                    }

                    // Info button — top left (hidden in scout mode, moved to panel header)
                    if !locationManager.scoutModeActive {
                        VStack {
                            HStack {
                                Button(action: { showWelcome = true }) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.sweepySurface2)
                                            .frame(width: 36, height: 36)
                                            .shadow(radius: 4)
                                        Text("?")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(Color.sweepyGray2)
                                    }
                                }
                                .padding(.leading, 16)
                                .padding(.top, 60)
                                Spacer()
                            }
                            Spacer()
                        }
                        .zIndex(5)
                    }

                    bottomPanelOverlay

                    if showOutsideNYC {
                        OutsideNYCView { coordinate, _ in
                            overrideCoordinate = coordinate
                            let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coordinate, distance: 400))
                            withAnimation { cameraPosition = cam }
                            showOutsideNYC = false
                        }
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
        .sheet(isPresented: $showAddressPicker) {
            AddressPickerSheet { coordinate in
                overrideCoordinate = coordinate
                let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coordinate, distance: 400))
                cameraPosition = cam
                motionManager.startMonitoring()
                bluetoothManager.startMonitoring()
                triggerSaveFlow()
            }
            .presentationDetents([.large])
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            // Block-face polylines — green = safe, amber = cleaning soon
            ForEach(blockSegments) { segment in
                MapPolyline(coordinates: [segment.fromCoord, segment.toCoord])
                    .stroke(
                        segment.isSoon ? Color.sweepyAmber : Color.sweepyGreen,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
            }

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
        }
        .mapStyle(.standard)
        .environment(\.colorScheme, .light)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: panelCollapsedHeight)
        }
        .mapControls {
            if overrideCoordinate == nil {
                MapUserLocationButton()
            }
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { @MainActor context in
            guard savedSpot == nil, !locationManager.scoutModeActive else { return }
            pinCoordinate = context.camera.centerCoordinate
        }
        .onMapCameraChange(frequency: .onEnd) { @MainActor context in
            guard savedSpot == nil, !locationManager.scoutModeActive else { return }
            Task { @MainActor in
                await loadBackgroundSegments(from: context.camera.centerCoordinate)
            }
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
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Color.sweepyGreen)
                        .frame(width: 40, height: 40)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    Image(systemName: "car.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                Rectangle()
                    .fill(Color.sweepyGreen)
                    .frame(width: 2, height: 6)
            }
            Spacer()
            Color.clear.frame(height: panelCollapsedHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        locationManager: locationManager,
                        cleaningDataManager: cleaningDataManager,
                        onHelpTap: { showWelcome = true },
                        onSegmentsLoaded: { segs in blockSegments = segs },
                        onSaveWithSide: { side, entries, street in
                            resolvedStreet = street
                            scoutInitialSide = side
                            let segments = blockSegments
                            Task { @MainActor in
                                let snapped = street.snappedCoordinate
                                let userLoc = CLLocation(latitude: snapped.latitude, longitude: snapped.longitude)
                                let nearestSeg = segments.min {
                                    userLoc.distance(from: CLLocation(latitude: $0.centroid.latitude, longitude: $0.centroid.longitude))
                                    < userLoc.distance(from: CLLocation(latitude: $1.centroid.latitude, longitude: $1.centroid.longitude))
                                }
                                if let seg = nearestSeg {
                                    bestBlock = (from: seg.fromStreet, to: seg.toStreet)
                                    let blockFiltered = entries.filter { e in
                                        (BlockMatcher.fuzzyMatch(e.fromStreet, seg.fromStreet) && BlockMatcher.fuzzyMatch(e.toStreet, seg.toStreet)) ||
                                        (BlockMatcher.fuzzyMatch(e.fromStreet, seg.toStreet)   && BlockMatcher.fuzzyMatch(e.toStreet, seg.fromStreet))
                                    }
                                    streetEntries = CleaningDataManager.closestSignDedup(
                                        blockFiltered.isEmpty ? entries : blockFiltered,
                                        coordinate: snapped
                                    )
                                } else {
                                    let best = await BlockMatcher.findBestBlock(
                                        entries: entries,
                                        streetName: street.normalizedName,
                                        borough: street.borough,
                                        userCoordinate: activeCoordinate
                                    )
                                    bestBlock = best
                                    streetEntries = entries
                                }
                                withAnimation { locationManager.scoutModeActive = false }
                                activeModal = .savePicker
                            }
                        }
                    )
                } else {
                    NoSpotPanel(
                        isLoading: isResolvingStreet || cleaningDataManager.isLoading,
                        onSaveTap: {
                            motionManager.startMonitoring()
                            bluetoothManager.startMonitoring()
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
                    locationManager: locationManager,
                    streetOrientation: street.orientation,
                    onConfirm: { side, confirmedEntries in
                        scoutInitialSide = nil
                        activeModal = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            createSpot(street: street, side: side, confirmedEntries: confirmedEntries)
                        }
                    },
                    initialSide: scoutInitialSide,
                    onHelpTap: { showWelcome = true },
                    onRefresh: {
                        let fresh = await cleaningDataManager.loadSchedule(
                            streetName: street.normalizedName,
                            borough: street.borough,
                            coordinate: street.snappedCoordinate
                        )
                        streetEntries = fresh
                        return fresh
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
                    },
                    notificationManager: notificationManager
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
        if phase == .active, let spot = spots.first {
            liveActivityManager.startIfNeeded(for: spot)
        }
    }

    private func handleHeadingChange(_: Double, _ heading: Double) {
        guard locationManager.scoutModeActive, heading >= 0 else { return }
        updateScoutCamera()
    }

    private func handleLatitudeChange(_: Double, _ lat: Double) {
        guard lat != 0, overrideCoordinate == nil else { return }
        if locationManager.scoutModeActive {
            updateScoutCamera()
            return
        }
        if !showOutsideNYC {
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
            let cam = MapCameraPosition.camera(MapCamera(centerCoordinate: coord, distance: 400))
            withAnimation { cameraPosition = cam }
        }
        // Load coloured block segments in the background so the map shows schedule info immediately.
        // Debounced inside loadBackgroundSegments — only re-fetches after moving > 100 m.
        if savedSpot == nil {
            Task { @MainActor in await loadBackgroundSegments(from: locationManager.coordinate) }
        }
    }

    private func handleScoutModeActiveChange(_: Bool, _ active: Bool) {
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

                let nearby = CleaningDataManager.proximityFiltered(allEntries, coordinate: snapped)
                let pool = nearby.isEmpty ? allEntries : nearby

                // Build block-face segments from sign coordinates (for display + block matching).
                let segments = CleaningDataManager.buildSegments(pool, snappedCoordinate: snapped)
                let userLoc = CLLocation(latitude: snapped.latitude, longitude: snapped.longitude)

                // Find the block face whose centroid is closest to the snapped coordinate.
                // This identifies the user's specific block without extra geocoding calls.
                let nearestSeg = segments.min {
                    userLoc.distance(from: CLLocation(latitude: $0.centroid.latitude, longitude: $0.centroid.longitude))
                    < userLoc.distance(from: CLLocation(latitude: $1.centroid.latitude, longitude: $1.centroid.longitude))
                }

                let blockFiltered: [StreetCleaningEntry]
                let blockFrom: String
                let blockTo: String

                if let seg = nearestSeg {
                    // Filter pool to entries on this specific block face (includes null-coord entries)
                    blockFiltered = pool.filter { e in
                        (BlockMatcher.fuzzyMatch(e.fromStreet, seg.fromStreet) && BlockMatcher.fuzzyMatch(e.toStreet, seg.toStreet)) ||
                        (BlockMatcher.fuzzyMatch(e.fromStreet, seg.toStreet)   && BlockMatcher.fuzzyMatch(e.toStreet, seg.fromStreet))
                    }
                    blockFrom = seg.fromStreet
                    blockTo   = seg.toStreet
                } else {
                    // No geocoded signs — fall back to geocoding-based block matching
                    let best = await BlockMatcher.findBestBlock(
                        entries: pool,
                        streetName: street.normalizedName,
                        borough: street.borough,
                        userCoordinate: saveCoord ?? activeCoordinate
                    )
                    blockFiltered = best.map { b in pool.filter { e in
                        (BlockMatcher.fuzzyMatch(e.fromStreet, b.from) && BlockMatcher.fuzzyMatch(e.toStreet, b.to)) ||
                        (BlockMatcher.fuzzyMatch(e.fromStreet, b.to)   && BlockMatcher.fuzzyMatch(e.toStreet, b.from))
                    }} ?? pool
                    blockFrom = best?.from ?? ""
                    blockTo   = best?.to   ?? ""
                }

                let deduped = CleaningDataManager.closestSignDedup(
                    blockFiltered.isEmpty ? pool : blockFiltered,
                    coordinate: snapped
                )

                resolvedStreet = street
                bestBlock = blockFrom.isEmpty ? nil : (from: blockFrom, to: blockTo)
                streetEntries = deduped
                blockSegments = segments
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
        confirmedEntries: [StreetCleaningEntry]? = nil
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
            coordinate: street.snappedCoordinate,
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
            Task { @MainActor in _ = await notificationManager.requestPermission() }
        }
        pendingSpot = spot
        activeModal = .saveConfirm
    }



    /// Loads block-face segments for `coordinate` and a 3×3 grid of nearby sample points,
    /// then merges the results into `blockSegments`.
    ///
    /// Deduplication is cell-based: the map is divided into ~330 m cells and each cell is
    /// fetched at most once per session.  Calling this on every map-camera-change is safe —
    /// cells already loaded return immediately without any network work.
    private func loadBackgroundSegments(from coordinate: CLLocationCoordinate2D) async {
        // Skip entirely if the origin is outside NYC.
        guard CleaningDataManager.borough(for: coordinate) != "" else { return }

        // ~330 m cell — larger than a NYC block so nearby pans reuse the same cell.
        let cellSize = 0.003
        func cellKey(_ c: CLLocationCoordinate2D) -> String {
            "\(Int(c.latitude  / cellSize))|\(Int(c.longitude / cellSize))"
        }

        let key = cellKey(coordinate)
        guard !loadedSegmentCells.contains(key) else { return }
        loadedSegmentCells.insert(key)

        // 3×3 grid at 250 m spacing — covers ≈ 500 m in every direction from the origin.
        // Each point typically resolves to a different street (parallel or perpendicular),
        // so 9 simultaneous geocoding + schedule calls populate a meaningful chunk of the map.
        let step   = 250.0
        let latOff = step / 111_139.0
        let lonOff = step / (111_139.0 * cos(coordinate.latitude * .pi / 180))
        let offsets: [(Double, Double)] = [
            (-latOff, -lonOff), (-latOff, 0), (-latOff,  lonOff),
            (      0, -lonOff), (      0, 0), (      0,  lonOff),
            ( latOff, -lonOff), ( latOff, 0), ( latOff,  lonOff),
        ]

        var collected: [BlockSegment] = []
        await withTaskGroup(of: [BlockSegment].self) { group in
            for (dlat, dlon) in offsets {
                let sample = CLLocationCoordinate2D(
                    latitude:  coordinate.latitude  + dlat,
                    longitude: coordinate.longitude + dlon
                )
                // Skip sample points that fall outside NYC borough bounds.
                guard CleaningDataManager.borough(for: sample) != "" else { continue }
                group.addTask { [mgr = cleaningDataManager] in
                    guard let street = try? await BlockMatcher.resolve(coordinate: sample) else { return [] }
                    // Double-check: resolved borough must be a real NYC borough.
                    guard !street.borough.isEmpty else { return [] }
                    let entries = await mgr.loadSchedule(
                        streetName: street.normalizedName,
                        borough: street.borough,
                        coordinate: street.snappedCoordinate
                    )
                    let nearby = CleaningDataManager.proximityFiltered(entries, coordinate: street.snappedCoordinate)
                    let pool = nearby.isEmpty ? entries : nearby
                    let segments = CleaningDataManager.buildSegments(pool, snappedCoordinate: street.snappedCoordinate)
                    // Drop segments whose centroid is more than 400 m from the fetch point —
                    // eliminates stray lines from distant blocks on long streets.
                    let anchor = CLLocation(latitude: street.snappedCoordinate.latitude,
                                           longitude: street.snappedCoordinate.longitude)
                    return segments.filter {
                        CLLocation(latitude: $0.centroid.latitude, longitude: $0.centroid.longitude)
                            .distance(from: anchor) < 400
                    }
                }
            }
            for await segs in group { collected.append(contentsOf: segs) }
        }

        var seen = Set<String>(blockSegments.map { $0.id })
        let newSegs = collected.filter { seen.insert($0.id).inserted }
        guard !newSegs.isEmpty else { return }
        blockSegments.append(contentsOf: newSegs)
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
        Task { @MainActor in await notificationManager.cancelAlerts(for: spot.id) }
        Task { @MainActor in await liveActivityManager.endActivity() }
        spot.isActive = false
        try? modelContext.save()
        overrideCoordinate = nil
        blockSegments = []
        loadedSegmentCells = []   // force reload when map reappears
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

