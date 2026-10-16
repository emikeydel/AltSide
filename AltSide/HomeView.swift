import SwiftUI
import MapKit

/// First screen on launch: today's ASP status in big type, the next suspension,
/// and a draggable map pin that shows the cleaning schedule for whatever street
/// it lands on — so you can hunt for a block worth parking on.
///
/// Shown as an overlay on top of `MainMapView` (which stays mounted so auto-park
/// detection, notifications and the save flow keep working underneath).
struct HomeView: View {
    let savedSpot: ParkingSpot?
    let onParkHere: (CLLocationCoordinate2D) -> Void
    let onOpenCar: () -> Void
    let onHelp: () -> Void

    @Environment(\.locationManager) private var locationManager
    @Environment(\.cleaningDataManager) private var cleaningDataManager
    @Environment(\.aspStatus) private var aspStatus
    @Environment(\.permits) private var permitManager

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .camera(MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        distance: 3_000
    )))
    /// Live map centre while dragging — where the pin is.
    @State private var pinCoordinate: CLLocationCoordinate2D?
    /// Set only when a drag ends, so lookups don't fire on every frame.
    @State private var anchorCoordinate: CLLocationCoordinate2D?
    @State private var hasCenteredOnUser = false
    @State private var segments: [BlockSegment] = []
    /// One marker per block with an active/upcoming construction permit.
    @State private var permitMarkers: [PermitMarker] = []
    @State private var lookup: StreetLookup = .idle
    @State private var showAddressSearch = false
    /// Map toggle for construction-permit markers. Off by default to keep the map clean;
    /// the street card's construction banner shows regardless.
    @AppStorage("showPermitsOnMap") private var showPermitsOnMap = false

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(.horizontal, 16)
                .padding(.top, SweepyNavBar.height + 16)
                .padding(.bottom, 14)

            mapSection

            streetCard
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
        }
        .background(Color.sweepyBlack.ignoresSafeArea())
        .task(id: anchorKey) { await refresh() }
        .task { await aspStatus.refresh() }
        .onChange(of: locationManager.coordinate.latitude) { _, _ in centerOnUserOnce() }
        .onAppear { centerOnUserOnce() }
        .sheet(isPresented: $showAddressSearch) {
            AddressPickerSheet(
                onLocationSelected: { coordinate in
                    withAnimation {
                        cameraPosition = .camera(MapCamera(centerCoordinate: coordinate, distance: 500))
                    }
                },
                onHelpTap: onHelp
            )
            .presentationDetents([.large])
        }
    }

    // MARK: - Today's status

    private enum TodayStatus {
        case suspended(reason: String, details: String?)
        case sunday
        case inEffect
    }

    /// Live NYC 311 status when available (catches snow/emergency suspensions),
    /// otherwise the bundled holiday calendar.
    private var todayStatus: TodayStatus {
        if let live = aspStatus.today {
            if live.isSuspended {
                return .suspended(reason: ASPSuspensionCalendar.holidayName(on: .now) ?? "ASP suspended",
                                  details: live.details)
            }
            if live.isNotInEffect { return .sunday }
            return .inEffect
        }
        if let holiday = ASPSuspensionCalendar.holidayName(on: .now) { return .suspended(reason: holiday, details: nil) }
        if Calendar.current.component(.weekday, from: .now) == 1 { return .sunday }
        return .inEffect
    }

    /// Upcoming suspensions that actually cancel cleaning — a holiday on a Sunday
    /// changes nothing, since there's no cleaning on Sundays anyway.
    private var upcomingSuspensions: [(date: Date, holiday: String)] {
        aspStatus.upcomingSuspensions(limit: 8)
            .filter { Calendar.current.component(.weekday, from: $0.date) != 1 }
            .prefix(3)
            .map { $0 }
    }

    /// Where the status comes from, so a stale or offline answer is visible.
    private var sourceLine: String {
        if aspStatus.today != nil, let updated = aspStatus.lastUpdated {
            let when = Calendar.current.isDateInToday(updated)
                ? updated.formatted(date: .omitted, time: .shortened)
                : updated.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return "Live from NYC 311 · updated \(when)"
        }
        return "From the NYC DOT holiday calendar"
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.sweepyGray3)
                Spacer()
            }

            statusHeadline

            HStack(spacing: 5) {
                Circle()
                    .fill(aspStatus.today != nil ? Color.sweepyGreen : Color.sweepyGray3)
                    .frame(width: 6, height: 6)
                Text(sourceLine)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sweepyGray3)
            }

            nextSuspensionRow
        }
    }

    @ViewBuilder
    private var statusHeadline: some View {
        switch todayStatus {
        case .suspended(let reason, let details):
            headline(top: "Street cleaning", accent: "SUSPENDED", bottom: "today", color: .sweepyGreen,
                     detail: details ?? "\(reason) — no need to move your car.")
        case .sunday:
            headline(top: "No street", accent: "CLEANING", bottom: "today", color: .sweepyGreen,
                     detail: "Alternate side parking is never in effect on Sundays.")
        case .inEffect:
            headline(top: "Street cleaning", accent: "IS ON", bottom: "today", color: .sweepyAmber,
                     detail: "Check your side of the street below.")
        }
    }

    private func headline(top: String, accent: String, bottom: String, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Break after the first line ("Street cleaning") and keep the accent words
            // together with non-breaking spaces so "IS ON" never splits.
            let accentText = Text(accent.replacingOccurrences(of: " ", with: "\u{00A0}")).foregroundStyle(color)
            Text("\(top)\n\(accentText)\u{00A0}\(bottom)")
                .foregroundStyle(Color.sweepyWhite)
                .font(.system(size: 36, weight: .black))
                .tracking(-1.1)
                .lineSpacing(-4)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.sweepyGray2)
        }
    }

    @ViewBuilder
    private var nextSuspensionRow: some View {
        if let next = upcomingSuspensions.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXT SUSPENSION")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Color.sweepyGray3)
                        Text(next.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.system(size: 20, weight: .black))
                            .tracking(-0.6)
                            .foregroundStyle(Color.sweepyWhite)
                        Text(next.holiday)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sweepyGray2)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(relativeDays(to: next.date))
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.sweepyGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.sweepyGreenDim)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if upcomingSuspensions.count > 1 {
                    Text("Then " + upcomingSuspensions.dropFirst()
                        .map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())) · \($0.holiday)" }
                        .joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sweepyGray3)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .background(Color.sweepySurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.sweepyBorder, lineWidth: 1))
        } else {
            Text("No suspensions loaded past \(String(ASPSuspensionCalendar.lastKnownYear)).")
                .font(.system(size: 12))
                .foregroundStyle(Color.sweepyGray3)
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        ZStack {
            Map(position: $cameraPosition) {
                UserAnnotation()
                if let spot = savedSpot {
                    Annotation("My Car", coordinate: spot.coordinate) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.sweepyWhite))
                    }
                }
                ForEach(segments) { segment in
                    MapPolyline(coordinates: [segment.fromCoord, segment.toCoord])
                        .stroke(Urgency(segment.entries).color,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                // Construction permits: a small cone mid-block, leaving the cleaning colours readable.
                ForEach(showPermitsOnMap ? permitMarkers : []) { marker in
                    Annotation("", coordinate: marker.coordinate, anchor: .center) {
                        permitIcon(size: 20)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .environment(\.colorScheme, .light)
            .onMapCameraChange(frequency: .continuous) { context in
                pinCoordinate = context.camera.centerCoordinate
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                anchorCoordinate = context.camera.centerCoordinate
            }

            // Pin fixed at the map centre — drag the map underneath it.
            Image(systemName: "mappin")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.sweepyRed)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(y: -15)
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    legend
                    Spacer()
                    VStack(spacing: 8) {
                        circleButton(systemName: "magnifyingglass") { showAddressSearch = true }
                        circleButton(systemName: "location.fill", tint: .sweepyGreen) { recenter() }
                        permitToggle
                    }
                }
                Spacer()
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .frame(minHeight: 200)
    }

    /// Shows/hides construction-permit markers on the map.
    private var permitToggle: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) { showPermitsOnMap.toggle() }
        } label: {
            Image(systemName: "cone.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showPermitsOnMap ? .white : Color.sweepyGray2)
                .frame(width: 36, height: 36)
                .background(Circle().fill(showPermitsOnMap ? Color.sweepyAmber : Color.sweepySurface2))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .accessibilityLabel("Construction permits")
        .accessibilityValue(showPermitsOnMap ? "Shown" : "Hidden")
    }

    private func permitIcon(size: CGFloat) -> some View {
        Image(systemName: "cone.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.sweepyAmber))
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach([Urgency.soon, .fewDays, .later], id: \.self) { u in
                HStack(spacing: 4) {
                    Capsule().fill(u.color).frame(width: 12, height: 4)
                    Text(u.legend)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.sweepyGray1)
                }
            }
            if showPermitsOnMap {
                HStack(spacing: 4) {
                    permitIcon(size: 14)
                    Text("Permit")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.sweepyGray1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Street card

    private var isPinAtUser: Bool {
        guard let pin = pinCoordinate,
              locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways else { return false }
        let user = locationManager.coordinate
        return CLLocation(latitude: pin.latitude, longitude: pin.longitude)
            .distance(from: CLLocation(latitude: user.latitude, longitude: user.longitude)) < 40
    }

    private var streetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch lookup {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking this street…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.sweepyGray2)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)

            case .outsideNYC:
                message(title: "Outside NYC", body: "Drag the map to an NYC street to see its cleaning schedule.")

            case .failed:
                message(title: "Couldn't find this street", body: "Try moving the pin onto the middle of a block.")

            case .loaded(let info):
                streetHeader(info)
                if let first = info.permits.first {
                    permitBanner(first, more: info.permits.count - 1)
                }
                if info.entries.isEmpty {
                    Text("No street cleaning signs on this block.")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.sweepyGreen)
                } else {
                    HStack(spacing: 10) {
                        ForEach(info.sides, id: \.self) { side in
                            sideTile(side, entries: info.entries.filter { $0.normalizedSide == side })
                        }
                    }
                }
            }

            primaryAction
        }
    }

    private func streetHeader(_ info: StreetInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isPinAtUser ? "YOU'RE ON" : "PIN IS ON")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.sweepyGray3)
            Text(info.name)
                .font(.system(size: 24, weight: .black))
                .tracking(-0.7)
                .foregroundStyle(Color.sweepyWhite)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !info.fromStreet.isEmpty && !info.toStreet.isEmpty {
                Text("\(titleCase(info.fromStreet)) → \(titleCase(info.toStreet))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyGray3)
                    .lineLimit(1)
            }
        }
    }

    private func permitBanner(_ permit: StreetPermit, more: Int) -> some View {
        let date = permit.startsLater
            ? "Starts " + permit.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : "Until " + permit.end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cone.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.sweepyAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Construction on this block · \(date)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.sweepyWhite)
                Text(permit.kinds.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.sweepyGray2)
                Text(titleCase(permit.permittee) + (more > 0 ? " · +\(more) more permit\(more == 1 ? "" : "s")" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.sweepyGray3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sweepyAmberDim)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sideTile(_ side: SideDetector.StreetSide, entries: [StreetCleaningEntry]) -> some View {
        let sorted = entries.sorted { ($0.weekdayInt ?? 0) < ($1.weekdayInt ?? 0) }
        let days = sorted.compactMap { $0.weekdayInt }.map { ScheduleFormatter.dayNames[$0] }.joined(separator: " · ")
        let cleaningNow = entries.contains { $0.isActiveRightNow() } && !ASPSuspensionCalendar.isSuspended(on: .now)
        let next = entries.compactMap { $0.nextEffectiveCleaningDate() }.min()
        let urgency = cleaningNow ? Urgency.soon : Urgency(next)
        let status: String = {
            if cleaningNow { return "Cleaning now" }
            guard let next else { return "No cleaning" }
            return "Next: " + relativeDays(to: next)
        }()

        return VStack(alignment: .leading, spacing: 4) {
            Text("\(side.displayName.uppercased()) SIDE")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.sweepyGray3)
            Text(days.isEmpty ? "None" : days)
                .font(.system(size: 20, weight: .black))
                .tracking(-0.6)
                .foregroundStyle(Color.sweepyWhite)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let first = sorted.first {
                Text(ScheduleFormatter.time(first.startHour, first.startMinute) + " – "
                     + ScheduleFormatter.time(first.endHour, first.endMinute))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.sweepyGray2)
            }
            Text(status)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(urgency.color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(urgency.color.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let spot = savedSpot {
            Button(action: onOpenCar) {
                HStack(spacing: 12) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(spot.isCleaningSoon ? Color.sweepyAmber : Color.sweepyGreen))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR CAR")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Color.sweepyGray3)
                        Text(spot.streetName)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.sweepyWhite)
                            .lineLimit(1)
                        if let next = spot.nextCleaningDate {
                            Text("Move by " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.sweepyGray2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.sweepyGray3)
                }
                .padding(12)
                .background(Color.sweepySurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sweepyBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            SweepyButton(title: "I parked here", icon: "car.fill") {
                onParkHere(pinCoordinate ?? locationManager.coordinate)
            }
        }
    }

    private func message(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .black))
                .tracking(-0.6)
                .foregroundStyle(Color.sweepyWhite)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(Color.sweepyGray2)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private func circleButton(systemName: String, tint: Color = .sweepyGray2, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.sweepySurface2))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }

    // MARK: - Loading

    /// Rounded to ~10 m so tiny nudges don't refetch.
    private var anchorKey: String {
        guard let c = anchorCoordinate else { return "" }
        return "\(Int(c.latitude * 10_000))_\(Int(c.longitude * 10_000))"
    }

    private func refresh() async {
        guard let coord = anchorCoordinate else { return }
        guard !CleaningDataManager.borough(for: coord).isEmpty else {
            lookup = .outsideNYC
            segments = []
            permitMarkers = []
            return
        }
        if case .loaded = lookup {} else { lookup = .loading }

        async let nearby = cleaningDataManager.loadNearbySegments(coordinate: coord)
        do {
            let street = try await BlockMatcher.resolve(coordinate: coord)
            let all = await cleaningDataManager.loadSchedule(
                streetName: street.normalizedName, borough: street.borough, coordinate: coord
            )
            let block = CleaningDataManager.blockSchedule(all, streetName: street.normalizedName, coordinate: coord)
            guard !Task.isCancelled else { return }
            // The resolver can land on a different street than Apple's geocoder (e.g. at a
            // corner); show the street whose schedule we're actually displaying.
            let name: String = {
                guard let dataName = block.entries.first?.streetName,
                      !BlockMatcher.fuzzyMatch(dataName, street.normalizedName) else { return street.name }
                return titleCase(dataName)
            }()
            let sides = Set(block.entries.compactMap { $0.normalizedSide })
            lookup = .loaded(StreetInfo(
                name: name,
                fromStreet: block.fromStreet,
                toStreet: block.toStreet,
                entries: block.entries,
                sides: sides.contains(.east) || sides.contains(.west) ? [.west, .east] : [.north, .south],
                streetName: block.streetName,
                blockKeys: block.blockKeys,
                permits: []
            ))
        } catch {
            guard !Task.isCancelled else { return }
            lookup = .failed
        }
        let segs = await nearby
        guard !Task.isCancelled else { return }
        segments = segs
        await loadPermits(segments: segs, borough: CleaningDataManager.borough(for: coord))
    }

    /// Construction permits for the pin's block and every street drawn on the map.
    private func loadPermits(segments segs: [BlockSegment], borough: String) async {
        var streets = Set(segs.compactMap { $0.entries.first?.streetName })
        if case .loaded(let info) = lookup, !info.streetName.isEmpty { streets.insert(info.streetName) }
        guard !streets.isEmpty else { return }

        let permits = await permitManager.permits(onStreets: Array(streets), borough: borough)
        guard !Task.isCancelled else { return }

        if case .loaded(var info) = lookup {
            info.permits = StreetPermitManager.matching(permits, street: info.streetName, blockKeys: info.blockKeys)
            lookup = .loaded(info)
        }

        // Match map faces, expanding each face's name across split-block naming.
        let byStreet = Dictionary(grouping: segs) { BlockMatcher.normalize($0.entries.first?.streetName ?? "") }
        var permitted: [BlockSegment] = []
        for (street, faces) in byStreet where !street.isEmpty {
            let onStreet = permits.filter { BlockMatcher.fuzzyMatch($0.street, street) }
            guard !onStreet.isEmpty else { continue }
            let streetKeys = Set(faces.map { CleaningDataManager.blockKey(from: $0.fromStreet, to: $0.toStreet) })
            for face in faces {
                let keys = CleaningDataManager.expandBlockKeys(
                    [CleaningDataManager.blockKey(from: face.fromStreet, to: face.toStreet)], streetKeys: streetKeys)
                if onStreet.contains(where: { keys.contains($0.blockKey) }) { permitted.append(face) }
            }
        }
        // Both curbs of a block are usually flagged — keep one marker per ~50 m.
        var markers: [PermitMarker] = []
        for face in permitted {
            let c = CLLocation(latitude: face.centroid.latitude, longitude: face.centroid.longitude)
            let nearby = markers.contains {
                CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: c) < 50
            }
            if !nearby { markers.append(PermitMarker(id: face.id, coordinate: face.centroid)) }
        }
        permitMarkers = markers
    }

    private func centerOnUserOnce() {
        guard !hasCenteredOnUser,
              locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways else { return }
        hasCenteredOnUser = true
        recenter()
    }

    private func recenter() {
        withAnimation {
            cameraPosition = .camera(MapCamera(centerCoordinate: locationManager.coordinate, distance: 500))
        }
    }

    // MARK: - Helpers

    private func relativeDays(to date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "Today " + date.formatted(.dateTime.hour().minute())
        case 1:    return "Tomorrow"
        default:   return "in \(days) days"
        }
    }

    private func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}

// MARK: - Supporting types

private struct StreetInfo {
    let name: String
    let fromStreet: String
    let toStreet: String
    let entries: [StreetCleaningEntry]
    let sides: [SideDetector.StreetSide]
    let streetName: String
    let blockKeys: Set<String>
    var permits: [StreetPermit]
}

private struct PermitMarker: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
}

private enum StreetLookup {
    case idle, loading, outsideNYC, failed
    case loaded(StreetInfo)
}

/// How soon a block gets cleaned — drives map line colour so good parking stands out.
private enum Urgency: Hashable {
    case soon      // today or tomorrow
    case fewDays   // 2–3 days
    case later     // 4+ days, or no cleaning

    init(_ next: Date?) {
        guard let next else { self = .later; return }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: next)).day ?? 99
        self = days <= 1 ? .soon : (days <= 3 ? .fewDays : .later)
    }

    init(_ entries: [StreetCleaningEntry]) {
        self.init(entries.compactMap { $0.nextEffectiveCleaningDate() }.min())
    }

    var color: Color {
        switch self {
        case .soon:    .sweepyRed
        case .fewDays: .sweepyAmber
        case .later:   .sweepyGreen
        }
    }

    var legend: String {
        switch self {
        case .soon:    "≤1 day"
        case .fewDays: "2–3 days"
        case .later:   "4+ days"
        }
    }
}
