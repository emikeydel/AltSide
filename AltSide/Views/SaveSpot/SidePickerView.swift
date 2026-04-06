import SwiftUI
import MapKit

struct SidePickerView: View {
    let coordinate: CLLocationCoordinate2D
    let streetName: String
    let entries: [StreetCleaningEntry]
    let heading: CLLocationDirection
    let streetOrientation: SideDetector.StreetOrientation
    let onConfirm: (SideDetector.StreetSide) -> Void

    @State private var selectedSide: SideDetector.StreetSide = .north
    @State private var isAutoDetecting: Bool = false
    @Environment(\.dismiss) private var dismiss

    private var northEntries: [StreetCleaningEntry] { entries.filter { $0.normalizedSide == .north } }
    private var southEntries: [StreetCleaningEntry] { entries.filter { $0.normalizedSide == .south } }
    private var eastEntries:  [StreetCleaningEntry] { entries.filter { $0.normalizedSide == .east  } }
    private var westEntries:  [StreetCleaningEntry] { entries.filter { $0.normalizedSide == .west  } }

    private var primarySides: [SideDetector.StreetSide] {
        streetOrientation == .eastWest ? [.north, .south] : [.east, .west]
    }

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.uberGray3.opacity(0.5))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        // Street name header
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WHICH SIDE?")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(Color.uberGray3)
                            Text(streetName)
                                .font(.system(size: 22, weight: .black))
                                .tracking(-0.5)
                                .foregroundStyle(Color.uberWhite)
                        }
                        .padding(.top, 20)

                        // Mini map
                        miniMap

                        // Side buttons
                        HStack(spacing: 10) {
                            ForEach(primarySides, id: \.self) { side in
                                sideButton(side)
                            }
                        }

                        // Auto-detect button
                        Button(action: autoDetect) {
                            HStack(spacing: 8) {
                                if isAutoDetecting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(Color.uberGray2)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "location.north.fill")
                                        .font(.system(size: 12))
                                }
                                Text(isAutoDetecting ? "Detecting…" : "Use compass to auto-detect")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Color.uberGray2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.uberSurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        }

                        // Schedule card for selected side
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SCHEDULE")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(Color.uberGray3)
                            ScheduleCardView(entries: entries, side: selectedSide)
                        }

                        // CTA
                        UberButton(
                            title: ctaTitle,
                            icon: "location.fill",
                            action: { onConfirm(selectedSide) }
                        )
                        .padding(.bottom, 8)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Side Button

    private func sideButton(_ side: SideDetector.StreetSide) -> some View {
        let isSelected = selectedSide == side
        let sideEntries = entriesFor(side)
        let isSoon = sideEntries.compactMap { $0.nextCleaningDate() }.min().map {
            $0.timeIntervalSinceNow < 48 * 3600
        } ?? false

        let accentColor: Color = isSoon ? Color.uberAmber : Color.uberGreen
        let borderColor: Color = isSelected ? accentColor : Color.white.opacity(0.1)
        let bgColor: Color = isSelected ? (isSoon ? Color.uberAmberDim : Color.uberGreenDim) : Color.uberSurface2

        return Button(action: { withAnimation(.spring(duration: 0.25)) { selectedSide = side } }) {
            VStack(spacing: 8) {
                Text(side.compassLabel)
                    .font(.system(size: 28, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(isSelected ? accentColor : Color.uberGray2)
                Text(side.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.uberWhite : Color.uberGray3)
                Text(side.addressParity)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.uberGray3)
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
            Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 120, heading: 0, pitch: 0))) {
                Annotation("", coordinate: sideCoordinate) {
                    ZStack {
                        Circle().fill(Color.uberGreen).frame(width: 28, height: 28)
                        Image(systemName: "car.fill").font(.system(size: 14)).foregroundStyle(.black)
                    }
                }
            }
            .mapStyle(.standard)
            .environment(\.colorScheme, .dark)
            .disabled(true)
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }

    /// Offset the car annotation slightly toward the selected side for visual feedback.
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
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            let detected = SideDetector.detectSide(heading: heading, orientation: streetOrientation)
            withAnimation(.spring(duration: 0.3)) {
                selectedSide = detected
            }
            isAutoDetecting = false
        }
    }

    // MARK: - Helpers

    private func entriesFor(_ side: SideDetector.StreetSide) -> [StreetCleaningEntry] {
        entries.filter { $0.normalizedSide == side }
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
