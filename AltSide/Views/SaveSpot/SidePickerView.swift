import SwiftUI
import MapKit

struct SidePickerView: View {
    let coordinate: CLLocationCoordinate2D
    let streetName: String
    let entries: [StreetCleaningEntry]
    var locationManager: LocationManager
    let streetOrientation: SideDetector.StreetOrientation
    let onConfirm: (SideDetector.StreetSide, [StreetCleaningEntry]) -> Void

    var initialSide: SideDetector.StreetSide? = nil
    var onHelpTap: (() -> Void)? = nil
    /// Called when user taps refresh; should return fresh entries for this street.
    var onRefresh: (() async -> [StreetCleaningEntry])? = nil
    /// Pre-computed street bearing (degrees from north) passed by the caller when it already
    /// has the full segment pool — avoids recomputing from the sparse deduped entries.
    var precomputedBearing: Double? = nil

    @State private var selectedSide: SideDetector.StreetSide = .north
    @State private var isAutoDetecting: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var refreshedEntries: [StreetCleaningEntry]? = nil
    @State private var miniMapCamera: MapCameraPosition = .automatic
    @State private var pinCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @State private var computedBearing: Double? = nil
    @State private var mapVisible = true
    @Environment(\.dismiss) private var dismiss

    private var displayEntries: [StreetCleaningEntry] { refreshedEntries ?? entries }

    // MARK: - Side ordering

    /// The two sides relevant to this street (N+S for E-W streets, E+W for avenues).
    private var primarySides: [SideDetector.StreetSide] {
        streetOrientation == .eastWest ? [.north, .south] : [.east, .west]
    }

    /// Always [leftSide, rightSide] so buttons match physical sides of the screen.
    /// Reorders automatically when heading crosses the midpoint.
    private var orderedSides: [SideDetector.StreetSide] {
        let h = locationManager.heading
        guard h >= 0 else { return primarySides }
        // Find which primary side is to the left
        let left = primarySides.first {
            $0.relativeLabel(facing: h) == "Left"
        }
        guard let left else { return primarySides }
        let right = primarySides.first { $0 != left }!
        return [left, right]
    }

    var body: some View {
        ZStack {
            Color.sweepyBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                CardHeader()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        // Street name header
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("WHICH SIDE?")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1.5)
                                    .foregroundStyle(Color.sweepyGray3)
                                Text(streetName)
                                    .font(.system(size: 22, weight: .black))
                                    .tracking(-0.5)
                                    .foregroundStyle(Color.sweepyWhite)
                            }
                            Spacer()
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
                            Button(action: { tearDownMap { dismiss() } }) {
                                Text("Cancel")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.sweepyGray3)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.sweepySurface2)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 20)

                        // Mini map
                        miniMap

                        // Side buttons — left button is always the left side of the street
                        HStack(spacing: 10) {
                            ForEach(orderedSides, id: \.self) { side in
                                let index = orderedSides.firstIndex(of: side)!
                                sideButton(side, relativeLabel: index == 0 ? "Left" : "Right")
                            }
                        }
                        .animation(.spring(duration: 0.35), value: orderedSides)

                        // CTA
                        SweepyButton(
                            title: ctaTitle,
                            icon: "location.fill",
                            action: {
                                let side = selectedSide
                                let entries = displayEntries
                                tearDownMap { onConfirm(side, entries) }
                            }
                        )

                        // Auto-detect button
                        Button(action: autoDetect) {
                            HStack(spacing: 8) {
                                if isAutoDetecting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(Color.sweepyGray2)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "location.north.fill")
                                        .font(.system(size: 12))
                                }
                                Text(isAutoDetecting ? "Detecting…" : "Use compass to auto-detect")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Color.sweepyGray2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.sweepySurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.sweepyBorder, lineWidth: 1)
                            )
                        }

                        // Schedule card for selected side
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("SCHEDULE")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1.5)
                                    .foregroundStyle(Color.sweepyGray3)
                                Spacer()
                                // Show refresh when no schedule found for this side
                                if entriesFor(selectedSide).isEmpty {
                                    Button(action: { Task { @MainActor in await doRefresh() } }) {
                                        HStack(spacing: 5) {
                                            if isRefreshing {
                                                ProgressView()
                                                    .progressViewStyle(.circular)
                                                    .tint(Color.sweepyGray2)
                                                    .scaleEffect(0.65)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.system(size: 11, weight: .semibold))
                                            }
                                            Text(isRefreshing ? "Checking…" : "Retry")
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.sweepyGray2)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.sweepySurface2)
                                        .clipShape(Capsule())
                                    }
                                    .disabled(isRefreshing)
                                }
                            }
                            ScheduleCardView(entries: displayEntries, side: selectedSide)
                        }
                        .padding(.bottom, 8)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedSide)
        .onAppear {
            // Camera fixed at street center; pin starts here until bearing is ready.
            miniMapCamera = .camera(MapCamera(
                centerCoordinate: coordinate, distance: 75, heading: 0, pitch: 0
            ))
            pinCoordinate = coordinate
            if let side = initialSide {
                selectedSide = side
            } else {
                autoDetect()
            }
            // Compute bearing off the hot path so the sheet renders immediately,
            // then animate the pin to the correct side.
            Task { @MainActor in
                computedBearing = precomputedBearing ?? streetBearingFromSegments()
                withAnimation(.spring(duration: 0.4)) {
                    pinCoordinate = sideCoordinate(for: selectedSide)
                }
            }
        }
        .onChange(of: selectedSide) { _, _ in recenterMiniMap() }
    }

    // MARK: - Side Button

    private func sideButton(_ side: SideDetector.StreetSide, relativeLabel: String) -> some View {
        let isSelected = selectedSide == side
        let sideEntries = entriesFor(side)
        let nextEntry = sideEntries.min { ($0.nextCleaningDate() ?? .distantFuture) < ($1.nextCleaningDate() ?? .distantFuture) }
        let isSoon = nextEntry?.nextCleaningDate().map { $0.timeIntervalSinceNow < 48 * 3600 } ?? false

        // Recommend the side with the most time before next cleaning
        let otherSide = primarySides.first { $0 != side }
        let otherNext = otherSide.flatMap { s in
            entriesFor(s).compactMap { $0.nextCleaningDate() }.min()
        }?.timeIntervalSinceNow ?? 0
        let myNext = nextEntry?.nextCleaningDate()?.timeIntervalSinceNow ?? 0
        let isRecommended = myNext > 0 && myNext > otherNext

        let accentColor: Color = isSoon ? Color.sweepyAmber : Color.sweepyGreen
        let borderColor: Color = isSelected ? accentColor : (isRecommended ? Color.sweepyGreen.opacity(0.4) : Color.sweepyBorder)
        let bgColor: Color     = isSelected ? (isSoon ? Color.sweepyAmberDim : Color.sweepyGreenDim) : (isRecommended ? Color.sweepyGreen.opacity(0.06) : Color.sweepySurface2)

        return Button(action: { withAnimation(.spring(duration: 0.25)) { selectedSide = side } }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(relativeLabel)
                        .font(.system(size: 28, weight: .black))
                        .tracking(-1)
                        .foregroundStyle(isSelected ? accentColor : Color.sweepyWhite)
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
                Text(side.displayName + " side")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sweepyWhite)
                if let entry = nextEntry {
                    Text(entry.weekDay)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sweepyWhite)
                    Text(entry.timeWindowDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sweepyGray2)
                } else {
                    Text("No schedule")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sweepyGray3)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
    }

    // MARK: - Mini Map

    private var miniMap: some View {
        Map(position: $miniMapCamera) {
            Annotation("", coordinate: pinCoordinate, anchor: .center) {
                ZStack {
                    Circle()
                        .fill(Color.sweepyGreen.opacity(0.2))
                        .frame(width: 48, height: 48)
                    Circle()
                        .fill(Color.sweepyGreen)
                        .frame(width: 32, height: 32)
                    Image(systemName: "car.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.sweepyGreen.opacity(0.4), radius: 6)
            }
        }
        .mapStyle(.standard)
        .mapControls {}
        .disabled(true)
        .ignoresSafeArea()
        .opacity(mapVisible ? 1 : 0)
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
        )
    }


    // MARK: - Auto Detect

    private func autoDetect() {
        isAutoDetecting = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            let detected = SideDetector.detectSide(
                heading: locationManager.heading,
                orientation: streetOrientation
            )
            withAnimation(.spring(duration: 0.3)) {
                selectedSide = detected
            }
            isAutoDetecting = false
        }
    }

    // MARK: - Helpers

    /// Hides the Metal-backed Map view one frame before executing `action`.
    /// Prevents the GPU drawable from being torn down mid-render when the sheet
    /// is dismissed quickly, which causes a Metal assertion crash.
    private func tearDownMap(_ action: @escaping () -> Void) {
        mapVisible = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(32))
            action()
        }
    }

    private func recenterMiniMap() {
        withAnimation(.spring(duration: 0.35)) {
            pinCoordinate = sideCoordinate(for: selectedSide)
        }
    }

    /// Computes street bearing from BlockSegment geometry — fromCoord/toCoord are already
    /// diagonal-aware endpoints built by CleaningDataManager.buildSegments().
    /// Uses the segment nearest to the user's coordinate for the most accurate local bearing.
    private func streetBearingFromSegments() -> Double? {
        let segments = CleaningDataManager.buildSegments(displayEntries, snappedCoordinate: coordinate)
        guard !segments.isEmpty else { return nil }
        let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let seg = segments.min(by: {
            userLoc.distance(from: CLLocation(latitude: $0.centroid.latitude, longitude: $0.centroid.longitude)) <
            userLoc.distance(from: CLLocation(latitude: $1.centroid.latitude, longitude: $1.centroid.longitude))
        }) else { return nil }
        // Bearing along the segment = street direction
        let φ1 = seg.fromCoord.latitude  * .pi / 180
        let φ2 = seg.toCoord.latitude    * .pi / 180
        let Δλ = (seg.toCoord.longitude - seg.fromCoord.longitude) * .pi / 180
        let y  = sin(Δλ) * cos(φ2)
        let x  = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Offsets `coordinate` ~12 m perpendicular to the actual street direction.
    private func sideCoordinate(for side: SideDetector.StreetSide) -> CLLocationCoordinate2D {
        let meters = 6.0
        let cosLat = cos(coordinate.latitude * .pi / 180)

        if let along = computedBearing {
            let perpCW  = (along + 90).truncatingRemainder(dividingBy: 360)
            let perpCCW = (along - 90 + 360).truncatingRemainder(dividingBy: 360)
            let cwRad   = perpCW * .pi / 180
            let bearing: Double
            switch side {
            case .north: bearing = cos(cwRad) > 0 ? perpCW : perpCCW
            case .south: bearing = cos(cwRad) < 0 ? perpCW : perpCCW
            case .east:  bearing = sin(cwRad) > 0 ? perpCW : perpCCW
            case .west:  bearing = sin(cwRad) < 0 ? perpCW : perpCCW
            }
            let rad = bearing * .pi / 180
            return CLLocationCoordinate2D(
                latitude:  coordinate.latitude  + (meters * cos(rad)) / 111_139.0,
                longitude: coordinate.longitude + (meters * sin(rad)) / (111_139.0 * cosLat)
            )
        }

        // Fallback: cardinal offsets when no segments are available.
        let latDelta = meters / 111_139.0
        let lonDelta = meters / (111_139.0 * cosLat)
        switch side {
        case .north: return CLLocationCoordinate2D(latitude: coordinate.latitude + latDelta, longitude: coordinate.longitude)
        case .south: return CLLocationCoordinate2D(latitude: coordinate.latitude - latDelta, longitude: coordinate.longitude)
        case .east:  return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude + lonDelta)
        case .west:  return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude - lonDelta)
        }
    }

    private func entriesFor(_ side: SideDetector.StreetSide) -> [StreetCleaningEntry] {
        displayEntries.filter { $0.normalizedSide == side }
    }

    private func doRefresh() async {
        guard let onRefresh else { return }
        isRefreshing = true
        refreshedEntries = await onRefresh()
        isRefreshing = false
    }

    private var ctaTitle: String {
        let sideEntries = entriesFor(selectedSide)
        if let next = sideEntries.compactMap({ $0.nextCleaningDate() }).min() {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return "Save spot — move by \(f.string(from: next))"
        }
        return "Save this spot"
    }
}
