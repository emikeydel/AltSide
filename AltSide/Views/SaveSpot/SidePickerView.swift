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

    @State private var selectedSide: SideDetector.StreetSide = .north
    @State private var isAutoDetecting: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var refreshedEntries: [StreetCleaningEntry]? = nil
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
                            Button(action: { dismiss() }) {
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
                            action: { onConfirm(selectedSide, displayEntries) }
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
            if let side = initialSide {
                selectedSide = side
            } else {
                autoDetect()
            }
        }
    }

    // MARK: - Side Button

    private func sideButton(_ side: SideDetector.StreetSide, relativeLabel: String) -> some View {
        let isSelected = selectedSide == side
        let sideEntries = entriesFor(side)
        let isSoon = sideEntries.compactMap { $0.nextCleaningDate() }.min().map {
            $0.timeIntervalSinceNow < 48 * 3600
        } ?? false

        let accentColor: Color = isSoon ? Color.sweepyAmber : Color.sweepyGreen
        let borderColor: Color = isSelected ? accentColor : Color.sweepyBorder
        let bgColor: Color     = isSelected ? (isSoon ? Color.sweepyAmberDim : Color.sweepyGreenDim) : Color.sweepySurface2

        return Button(action: { withAnimation(.spring(duration: 0.25)) { selectedSide = side } }) {
            VStack(spacing: 6) {
                Text(relativeLabel)
                    .font(.system(size: 28, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(isSelected ? accentColor : Color.sweepyWhite)
                Text(side.displayName + " side")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sweepyWhite)
                Text(side.addressParity)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.sweepyGray3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
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
        ZStack {
            Map(initialPosition: .camera(MapCamera(
                centerCoordinate: coordinate, distance: 100, heading: 0, pitch: 0
            ))) {
                Annotation("", coordinate: sideCoordinate) {
                    ZStack {
                        Circle().fill(Color.sweepyGreen).frame(width: 28, height: 28)
                        Image(systemName: "car.fill").font(.system(size: 14)).foregroundStyle(.black)
                    }
                }
            }
            .mapStyle(.standard)
            .disabled(true)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
        )
    }

    private var sideCoordinate: CLLocationCoordinate2D {
        let offset = 0.00007
        switch selectedSide {
        case .north: return CLLocationCoordinate2D(latitude: coordinate.latitude + offset, longitude: coordinate.longitude)
        case .south: return CLLocationCoordinate2D(latitude: coordinate.latitude - offset, longitude: coordinate.longitude)
        case .east:  return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude + offset)
        case .west:  return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude - offset)
        }
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
