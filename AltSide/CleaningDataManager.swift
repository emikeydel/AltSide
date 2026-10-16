import Foundation
import CoreLocation
import Observation
import OSLog

private let log = Logger(subsystem: "com.laidoffdad.sweepy", category: "CleaningData")

/// Fetches and caches NYC alternate side parking schedules on demand, one street at a time.
///
/// Data source: NYC DOT "Parking Regulation Locations and Signs" (dataset nfid-uabd)
/// https://data.cityofnewyork.us/resource/nfid-uabd.json
///
/// Each street's schedule is fetched once, cached to disk, and held in memory for the session.
@Observable
final class CleaningDataManager {
    var isLoading: Bool = false
    var loadError: String?

    private var streetCache: [String: [StreetCleaningEntry]] = [:]
    private let cacheAgeLimit: TimeInterval = 7 * 24 * 3600
    private let endpoint = "https://data.cityofnewyork.us/resource/nfid-uabd.json"

    // MARK: - Public API

    /// Loads (or returns cached) cleaning schedule for a specific street near a coordinate.
    /// The coordinate is used to build an API bounding box so only nearby signs are fetched.
    /// Cache is bucketed in ~450 m grid cells so nearby saves reuse cached data.
    @discardableResult
    func loadSchedule(streetName: String, borough: String, coordinate: CLLocationCoordinate2D) async -> [StreetCleaningEntry] {
        let (userX, userY) = Self.wgs84ToStatePlane(lat: coordinate.latitude, lon: coordinate.longitude)
        let key = cacheKey(streetName: streetName, borough: borough, x: userX, y: userY)

        if let cached = streetCache[key] { return cached }

        if let disk = loadFromDisk(key: key), !isDiskCacheStale(key: key) {
            streetCache[key] = disk
            log.info("📂 Disk cache hit — \(disk.count) entries for \(streetName)")
            return disk
        }

        let entries = await fetchFromAPI(streetName: streetName, borough: borough, userX: userX, userY: userY)
        streetCache[key] = entries
        saveToDisk(entries, key: key)
        return entries
    }

    // MARK: - Nearby segments (all streets in a radius — used for map polyline overlay)

    private var nearbySegmentCache: [String: [BlockSegment]] = [:]

    /// Fetches cleaning signs for ALL streets within ~500 m of `coordinate` and returns
    /// them as `BlockSegment`s ready for map polyline rendering.
    func loadNearbySegments(coordinate: CLLocationCoordinate2D) async -> [BlockSegment] {
        let (userX, userY) = Self.wgs84ToStatePlane(lat: coordinate.latitude, lon: coordinate.longitude)
        // Grid-cell key: snap to 1640-ft (500 m) cells so adjacent saves reuse the cache.
        let key = "nearby_\(Int(userX / 1640))_\(Int(userY / 1640))"
        if let cached = nearbySegmentCache[key] {
            log.info("📍 Nearby segments cache hit — \(cached.count) segments")
            return cached
        }

        // Fetch with a larger box (~650 m) so block faces at the boundary always have
        // both of their signs captured. We then filter the resulting segments down to
        // those whose centroid falls within the original ~500 m display radius, which
        // drops the single-sign edge stubs that look misaligned on the map.
        let fetchBuf = 2140.0  // ~650 m — captures neighboring signs for edge blocks
        let displayRadius = 500.0  // metres: centroid must be within this of the query point
        let box = "sign_x_coord > \(Int(userX - fetchBuf)) AND sign_x_coord < \(Int(userX + fetchBuf))"
               + " AND sign_y_coord > \(Int(userY - fetchBuf)) AND sign_y_coord < \(Int(userY + fetchBuf))"
        let whereClause = "sign_description LIKE '%BROOM%' AND sign_x_coord IS NOT NULL AND (\(box))"

        var comps = URLComponents(string: endpoint)
        comps?.queryItems = [
            URLQueryItem(name: "$where",  value: whereClause),
            URLQueryItem(name: "$limit",  value: "2000"),
            URLQueryItem(name: "$select", value: "on_street,from_street,to_street,side_of_street,sign_description,borough,sign_x_coord,sign_y_coord"),
        ]
        guard let url = comps?.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Secrets.nycOpenDataAppToken, forHTTPHeaderField: "X-App-Token")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let raw = try JSONDecoder().decode([NfidSignRecord].self, from: data)
            let entries = raw.flatMap { $0.expand() }
            let allSegments = Self.buildSegments(entries, snappedCoordinate: coordinate)
            // Keep only segments whose centroid is within the display radius — this
            // removes edge-of-box partial stubs built from a single corner sign.
            let centerLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let segments = allSegments.filter { seg in
                let centLoc = CLLocation(latitude: seg.centroid.latitude, longitude: seg.centroid.longitude)
                return centerLoc.distance(from: centLoc) <= displayRadius
            }
            log.info("📍 Nearby fetch — \(raw.count) signs → \(allSegments.count) built → \(segments.count) in radius")
            nearbySegmentCache[key] = segments
            return segments
        } catch {
            log.error("📍 Nearby fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Borough detection (used by MainMapView + OutsideNYCView)

    /// Maps a GPS coordinate to an NYC borough using bounding boxes.
    /// Returns "" if the coordinate is outside NYC.
    static func borough(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        switch (lat, lon) {
        case (40.700...40.882, -74.021 ... -73.907): return "Manhattan"
        case (40.551...40.740, -74.042 ... -73.833): return "Brooklyn"
        case (40.489...40.812, -73.963 ... -73.700): return "Queens"
        case (40.785...40.917, -73.933 ... -73.748): return "Bronx"
        case (40.477...40.651, -74.259 ... -74.034): return "Staten Island"
        default: return ""
        }
    }

    // MARK: - API Fetch

    private func fetchFromAPI(streetName: String, borough: String, userX: Double, userY: Double) async -> [StreetCleaningEntry] {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let datasetName    = Self.datasetFormatName(streetName)
        let datasetBorough = Self.titleCaseBorough(borough)
        log.info("📡 Fetching '\(datasetName)' in \(datasetBorough) near (\(Int(userX)),\(Int(userY)))…")

        // Primary fetch: geocoded signs in the bbox (any street — needed for block-face detection)
        // PLUS null-coord signs for THIS specific street only.
        // The $limit:2000 cap used to be exhausted by null-coord signs from across the whole
        // borough before geocoded signs near the user appeared, causing sporadic empty results.
        let buf = 1500.0
        let bboxClause = "sign_x_coord > \(Int(userX - buf)) AND sign_x_coord < \(Int(userX + buf))"
               + " AND sign_y_coord > \(Int(userY - buf)) AND sign_y_coord < \(Int(userY + buf))"
        let whereClause = "sign_description LIKE '%BROOM%'"
            + " AND borough = '\(datasetBorough)'"
            + " AND ((sign_x_coord IS NOT NULL AND (\(bboxClause)))"
            + " OR (sign_x_coord IS NULL AND on_street = '\(datasetName)'))"

        var comps = URLComponents(string: endpoint)
        comps?.queryItems = [
            URLQueryItem(name: "$where",  value: whereClause),
            URLQueryItem(name: "$limit",  value: "2000"),
            URLQueryItem(name: "$select", value: "on_street,from_street,to_street,side_of_street,sign_description,borough,sign_x_coord,sign_y_coord"),
        ]
        guard let url = comps?.url else {
            log.error("❌ Failed to build URL")
            return []
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Secrets.nycOpenDataAppToken, forHTTPHeaderField: "X-App-Token")
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                log.error("❌ HTTP error: \(body)")
                loadError = "Couldn't reach NYC Open Data"
                return loadFromDisk(key: cacheKey(streetName: streetName, borough: borough, x: userX, y: userY)) ?? []
            }

            let raw = try JSONDecoder().decode([NfidSignRecord].self, from: data)
            let entries = raw.flatMap { $0.expand() }
            log.info("✅ \(raw.count) signs → \(entries.count) schedule entries for '\(streetName)'")
            return entries

        } catch {
            log.error("❌ Fetch failed: \(error.localizedDescription)")
            loadError = error.localizedDescription
            return loadFromDisk(key: cacheKey(streetName: streetName, borough: borough, x: userX, y: userY)) ?? []
        }
    }

    // MARK: - Schedule filtering

    /// Proximity filter: returns entries whose sign is within `thresholdFt` of `coordinate`.
    /// Entries with no sign coordinates are excluded (they can't be placed).
    static func proximityFiltered(
        _ entries: [StreetCleaningEntry],
        coordinate: CLLocationCoordinate2D,
        thresholdFt: Double = 984
    ) -> [StreetCleaningEntry] {
        let (ux, uy) = wgs84ToStatePlane(lat: coordinate.latitude, lon: coordinate.longitude)
        return entries.filter { e in
            // Un-geocoded signs have no coordinates — always include them; they can't be
            // filtered spatially but their schedule data is still valid for the street.
            guard let sx = e.signXCoord, let sy = e.signYCoord else { return true }
            return sqrt((sx - ux) * (sx - ux) + (sy - uy) * (sy - uy)) <= thresholdFt
        }
    }

    /// For each (side, weekday) pair keeps only the sign physically closest to `coordinate`.
    /// Eliminates entries from adjacent blocks that happen to share the same street name.
    static func closestSignDedup(
        _ entries: [StreetCleaningEntry],
        coordinate: CLLocationCoordinate2D
    ) -> [StreetCleaningEntry] {
        let (ux, uy) = wgs84ToStatePlane(lat: coordinate.latitude, lon: coordinate.longitude)
        var closest: [String: StreetCleaningEntry] = [:]
        for entry in entries {
            guard let side = entry.normalizedSide, let day = entry.weekdayInt else { continue }
            let key = "\(side)_\(day)"
            let dist: Double = {
                guard let ex = entry.signXCoord, let ey = entry.signYCoord else { return .infinity }
                return sqrt((ex - ux) * (ex - ux) + (ey - uy) * (ey - uy))
            }()
            if let existing = closest[key] {
                let exDist: Double = {
                    guard let ex = existing.signXCoord, let ey = existing.signYCoord else { return .infinity }
                    return sqrt((ex - ux) * (ex - ux) + (ey - uy) * (ey - uy))
                }()
                if dist < exDist { closest[key] = entry }
            } else {
                closest[key] = entry
            }
        }
        return Array(closest.values)
    }

    /// Result of resolving the user's position to a single block of a single street.
    struct BlockSchedule {
        /// One entry per (side, weekday) for the matched block only.
        let entries: [StreetCleaningEntry]
        /// All block-face segments built from the nearby geocoded pool (every street),
        /// for map display.
        let segments: [BlockSegment]
        /// Direction of the matched street (degrees from north), if its signs are geocoded.
        let streetBearing: Double?
        let fromStreet: String
        let toStreet: String
        /// Dataset name of the matched street, e.g. "BERGEN STREET".
        let streetName: String
        /// `blockKey`s naming this block, expanded across split/whole-block naming —
        /// used to match construction permits filed under either name.
        let blockKeys: Set<String>
    }

    /// One side of one block, measured straight from its sign coordinates.
    /// Unlike `BlockSegment` this keeps single-point faces and blocks > 250 m, which
    /// `buildSegments` drops because they draw badly on the map.
    private struct Face {
        let street: String
        let side: SideDetector.StreetSide
        let blockKey: String
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let fromStreet: String
        let toStreet: String
    }

    /// Order-independent key for a block: "COURT STREET|SMITH STREET".
    static func blockKey(from: String, to: String) -> String {
        [BlockMatcher.normalize(from), BlockMatcher.normalize(to)].sorted().joined(separator: "|")
    }

    private static func blockKey(_ e: StreetCleaningEntry) -> String {
        blockKey(from: e.fromStreet, to: e.toStreet)
    }

    /// Adds the other names a block goes by. Where a street meets a T-intersection the
    /// dataset may name one side "COURT|SMITH" and the other "COURT|BOERUM" + "BOERUM|SMITH";
    /// a permit filed under any of those should count for the whole block.
    /// `streetKeys` are all block keys seen for the same street.
    static func expandBlockKeys(_ keys: Set<String>, streetKeys: Set<String>) -> Set<String> {
        func ends(_ k: String) -> (String, String)? {
            let p = k.components(separatedBy: "|")
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        let all = streetKeys.union(keys)
        let crossStreets = Set(all.compactMap(ends).flatMap { [$0.0, $0.1] })
        var out = keys
        // Children: COURT|SMITH → COURT|BOERUM + BOERUM|SMITH when both exist.
        for k in keys {
            guard let (a, b) = ends(k) else { continue }
            for x in crossStreets where x != a && x != b {
                let k1 = blockKey(from: a, to: x), k2 = blockKey(from: x, to: b)
                if all.contains(k1) && all.contains(k2) { out.insert(k1); out.insert(k2) }
            }
        }
        // Parents: BOERUM|SMITH → COURT|SMITH when COURT|BOERUM also exists.
        for p in all {
            guard let (a, b) = ends(p) else { continue }
            for x in crossStreets where x != a && x != b {
                let k1 = blockKey(from: a, to: x), k2 = blockKey(from: x, to: b)
                if all.contains(k1) && all.contains(k2) && (keys.contains(k1) || keys.contains(k2)) {
                    out.insert(p)
                }
            }
        }
        return out
    }

    private static func faces(_ entries: [StreetCleaningEntry]) -> [Face] {
        var groups: [String: [StreetCleaningEntry]] = [:]
        for e in entries {
            guard let side = e.normalizedSide else { continue }
            groups["\(BlockMatcher.normalize(e.streetName))#\(side)#\(blockKey(e))", default: []].append(e)
        }
        return groups.values.compactMap { group in
            guard let first = group.first, let side = first.normalizedSide else { return nil }
            let coords = group.compactMap { e -> CLLocationCoordinate2D? in
                guard let x = e.signXCoord, let y = e.signYCoord else { return nil }
                let (lat, lon) = statePlaneNYLIToWgs84(x: x, y: y)
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            let isEastWest = side == .north || side == .south
            let sorted = isEastWest
                ? coords.sorted { $0.longitude < $1.longitude }
                : coords.sorted { $0.latitude  < $1.latitude  }
            guard let start = sorted.first, let end = sorted.last else { return nil }
            return Face(street: first.streetName, side: side, blockKey: blockKey(first),
                        start: start, end: end, fromStreet: first.fromStreet, toStreet: first.toStreet)
        }
    }

    /// Narrows a bbox fetch (which contains signs for EVERY street nearby) down to the
    /// block the user is standing on, then keeps one entry per (side, weekday).
    ///
    /// Shared by the iPhone save flow, Scout mode and CarPlay so all three agree.
    /// Faces are chosen by distance to the line through their signs, not a centroid —
    /// on a long block the centroid of the neighbouring block can be closer than your own.
    /// Each side is matched independently because the dataset can describe the two
    /// sides with different cross streets (e.g. Bergen St's north side is split at
    /// Boerum Pl, a T-intersection, while its south side runs Court → Smith).
    static func blockSchedule(
        _ allEntries: [StreetCleaningEntry],
        streetName: String,
        coordinate: CLLocationCoordinate2D
    ) -> BlockSchedule {
        let geocoded = allEntries.filter { $0.signXCoord != nil && $0.signYCoord != nil }
        let nearby   = proximityFiltered(geocoded, coordinate: coordinate)
        let geoPool  = nearby.isEmpty ? geocoded : nearby
        let segments = buildSegments(geoPool, snappedCoordinate: coordinate)
        let allFaces = faces(geoPool)

        func distance(_ f: Face) -> Double {
            distanceMeters(from: coordinate, toSegment: f.start, f.end)
        }

        // Prefer the reverse-geocoded street. Only fall back to whichever street is
        // physically closest when the geocoded name has no face nearby (name mismatch
        // between Apple and the DOT dataset, or the geocoder picked a cross street).
        let nearestNamed = allFaces.filter { BlockMatcher.fuzzyMatch($0.street, streetName) }.min { distance($0) < distance($1) }
        let nearestAny   = allFaces.min { distance($0) < distance($1) }
        let nearest: Face? = {
            if let named = nearestNamed, distance(named) <= 40 { return named }
            return nearestAny ?? nearestNamed
        }()

        let matchedStreet = nearest?.street ?? streetName
        // Includes null-coord signs for this street so no schedule data is lost.
        let streetPool = allEntries.filter { BlockMatcher.fuzzyMatch($0.streetName, matchedStreet) }
        guard !streetPool.isEmpty else {
            return BlockSchedule(entries: [], segments: segments, streetBearing: nil, fromStreet: "", toStreet: "",
                                 streetName: matchedStreet, blockKeys: [])
        }

        // Orientation from this street's own sign data — reliable for named streets.
        let nsCount = streetPool.filter { $0.normalizedSide == .east || $0.normalizedSide == .west }.count
        let ewCount = streetPool.filter { $0.normalizedSide == .north || $0.normalizedSide == .south }.count
        let relevantSides: [SideDetector.StreetSide] = nsCount > ewCount ? [.east, .west] : [.north, .south]

        let streetFaces = allFaces.filter { BlockMatcher.fuzzyMatch($0.street, matchedStreet) }
        var blockFiltered: [StreetCleaningEntry] = []
        for side in relevantSides {
            let sidePool = streetPool.filter { $0.normalizedSide == side }
            if let face = streetFaces.filter({ $0.side == side }).min(by: { distance($0) < distance($1) }) {
                let matched = sidePool.filter { blockKey($0) == face.blockKey }
                blockFiltered += matched.isEmpty ? sidePool : matched
            } else {
                // No geocoded signs on this side — keep this street's un-geocoded signs and
                // any within range; closestSignDedup then picks the nearest per weekday.
                let (ux, uy) = wgs84ToStatePlane(lat: coordinate.latitude, lon: coordinate.longitude)
                blockFiltered += sidePool.filter { e in
                    guard let sx = e.signXCoord, let sy = e.signYCoord else { return true }
                    return sqrt((sx - ux) * (sx - ux) + (sy - uy) * (sy - uy)) <= 984
                }
            }
        }

        // Bearing from the longest nearby face of this street (a single-sign face has none).
        let bearing: Double? = streetFaces
            .filter { distance($0) <= 60 }
            .max { lengthMeters($0.start, $0.end) < lengthMeters($1.start, $1.end) }
            .flatMap { f in
                guard lengthMeters(f.start, f.end) >= 15 else { return nil }
                let φ1 = f.start.latitude * .pi / 180
                let φ2 = f.end.latitude   * .pi / 180
                let Δλ = (f.end.longitude - f.start.longitude) * .pi / 180
                let y  = sin(Δλ) * cos(φ2)
                let x  = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
                return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            }

        let source = blockFiltered.isEmpty ? streetPool : blockFiltered
        let deduped = closestSignDedup(source, coordinate: coordinate)
        return BlockSchedule(
            entries: deduped,
            segments: segments,
            streetBearing: bearing,
            fromStreet: nearest?.fromStreet ?? source.first?.fromStreet ?? "",
            toStreet: nearest?.toStreet ?? source.first?.toStreet ?? "",
            streetName: matchedStreet,
            blockKeys: expandBlockKeys(Set(deduped.map(blockKey)), streetKeys: Set(streetPool.map(blockKey)))
        )
    }

    private static func lengthMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Metres from `p` to the line segment `a`–`b`, in a local flat-earth frame.
    static func distanceMeters(
        from p: CLLocationCoordinate2D,
        toSegment a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let mPerDegLat = 111_139.0
        let mPerDegLon = 111_139.0 * cos(p.latitude * .pi / 180)
        let ax = (a.longitude - p.longitude) * mPerDegLon, ay = (a.latitude - p.latitude) * mPerDegLat
        let bx = (b.longitude - p.longitude) * mPerDegLon, by = (b.latitude - p.latitude) * mPerDegLat
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
        let cx = ax + t * dx, cy = ay + t * dy
        return sqrt(cx * cx + cy * cy)
    }

    /// Groups entries into block-face segments for map display.
    ///
    /// • Faces with real sign coordinates use those coordinates exactly —
    ///   no axis-flattening, so diagonal streets (e.g. Brooklyn's grid) render correctly.
    /// • Faces with no sign coordinates are synthesised by shifting the opposite side's
    ///   endpoints perpendicular to the actual street direction, preserving the angle.
    /// • When neither side has coords a ±125 m axis-aligned stub is generated.
    static func buildSegments(
        _ entries: [StreetCleaningEntry],
        snappedCoordinate: CLLocationCoordinate2D
    ) -> [BlockSegment] {
        struct FaceAcc {
            var street: String, from: String, to: String
            var side: SideDetector.StreetSide
            var coords: [CLLocationCoordinate2D] = []
            var entries: [StreetCleaningEntry] = []
        }
        var groups: [String: FaceAcc] = [:]
        // All geocoded coords per block (both sides pooled) — used to derive street
        // direction when synthesising a null-coord face.
        var blockCoords: [String: [CLLocationCoordinate2D]] = [:]

        for entry in entries {
            guard let side = entry.normalizedSide else { continue }
            let faceKey  = "\(entry.streetName)|\(entry.fromStreet)|\(entry.toStreet)|\(side)"
            // Canonical block key: normalize then sort from/to so the same physical block
            // always maps to the same key regardless of direction or abbreviation differences
            // (e.g. "COURT ST" vs "COURT STREET", or from/to listed in different order).
            let blockKey = ([entry.streetName, entry.fromStreet, entry.toStreet] as [String])
                .map { BlockMatcher.normalize($0) }
                .sorted()
                .joined(separator: "|")
            if groups[faceKey] == nil {
                groups[faceKey] = FaceAcc(street: entry.streetName, from: entry.fromStreet, to: entry.toStreet, side: side)
            }
            groups[faceKey]!.entries.append(entry)
            var coord: CLLocationCoordinate2D? = nil
            if let lat = entry.signLatitude, let lon = entry.signLongitude {
                coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            } else if let sx = entry.signXCoord, let sy = entry.signYCoord {
                let (lat, lon) = statePlaneNYLIToWgs84(x: sx, y: sy)
                coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            if let c = coord {
                groups[faceKey]!.coords.append(c)
                blockCoords[blockKey, default: []].append(c)
            }
        }

        return groups.compactMap { (key, face) -> BlockSegment? in
            let isEastWest = face.side == .north || face.side == .south

            let from: CLLocationCoordinate2D
            let to:   CLLocationCoordinate2D

            if face.coords.count >= 2 {
                // ── 2+ real sign coords: use as-is (preserves diagonal street angle) ──
                let sorted = isEastWest
                    ? face.coords.sorted { $0.longitude < $1.longitude }
                    : face.coords.sorted { $0.latitude  < $1.latitude  }
                from = sorted.first!
                to   = sorted.last!

            } else if face.coords.count == 1 {
                // ── 1 real coord: skip — axis-aligned stubs look wrong on Brooklyn's
                // diagonal grid (they cross streets perpendicularly). Better to show
                // nothing for this face than a misleading stub.
                return nil

            } else {
                // ── No coords: synthesise from opposite side via kerbOffset ──────────
                let blockKey  = ([face.street, face.from, face.to] as [String])
                    .map { BlockMatcher.normalize($0) }
                    .sorted()
                    .joined(separator: "|")
                let allCoords = blockCoords[blockKey] ?? []

                // Require 2+ block coords so we have a real street direction to work
                // from — a single coord would fall back to an axis-aligned stub which
                // has the same diagonal-crossing problem as the 1-coord face case above.
                guard allCoords.count >= 2 else { return nil }

                // Build the baseline aligned to the street axis.
                // Normalise the perpendicular axis to the mean so mixed N+S curb coords
                // don't produce a diagonal baseline (e.g. westmost from N curb, eastmost
                // from S curb would slant the segment for an E-W street).
                let p1: CLLocationCoordinate2D
                let p2: CLLocationCoordinate2D
                if isEastWest {
                    let meanLat = allCoords.map { $0.latitude }.reduce(0.0, +) / Double(allCoords.count)
                    let byLon   = allCoords.sorted { $0.longitude < $1.longitude }
                    p1 = CLLocationCoordinate2D(latitude: meanLat, longitude: byLon.first!.longitude)
                    p2 = CLLocationCoordinate2D(latitude: meanLat, longitude: byLon.last!.longitude)
                } else {
                    let meanLon = allCoords.map { $0.longitude }.reduce(0.0, +) / Double(allCoords.count)
                    let byLat   = allCoords.sorted { $0.latitude < $1.latitude }
                    p1 = CLLocationCoordinate2D(latitude: byLat.first!.latitude,  longitude: meanLon)
                    p2 = CLLocationCoordinate2D(latitude: byLat.last!.latitude,   longitude: meanLon)
                }

                // Adaptive offset: when blockCoords has coords from both curbs the
                // perpendicular spread ≈ street width and the mean sits near the
                // centreline, so half the spread lands at the correct curb.
                // When only one side contributed the mean is at that curb; use a
                // fixed 15 m to cross to approximately the opposite side.
                let perpRange: Double = {
                    if isEastWest {
                        let lats = allCoords.map { $0.latitude }
                        return (lats.max()! - lats.min()!) * 111_139.0
                    } else {
                        let cosLat = cos((allCoords.map { $0.latitude }.reduce(0.0, +) / Double(allCoords.count)) * .pi / 180)
                        let lons   = allCoords.map { $0.longitude }
                        return (lons.max()! - lons.min()!) * 111_139.0 * cosLat
                    }
                }()
                let offsetMeters = perpRange > 5.0 ? (perpRange / 2.0) : 15.0

                (from, to) = kerbOffset(p1: p1, p2: p2, side: face.side, meters: offsetMeters)
            }

            let centroid = CLLocationCoordinate2D(
                latitude:  (from.latitude  + to.latitude)  / 2,
                longitude: (from.longitude + to.longitude) / 2
            )
            // Drop segments that are too long (bad sign data creating cross-block lines)
            // or too short (single corner signs creating noise stubs < 15 m).
            let segmentLength = CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            guard segmentLength >= 15, segmentLength < 250 else { return nil }

            return BlockSegment(id: key, fromCoord: from, toCoord: to, centroid: centroid,
                                side: face.side, fromStreet: face.from, toStreet: face.to,
                                entries: face.entries)
        }
    }

    /// Translates the segment `p1`→`p2` by `meters` perpendicular to its direction,
    /// toward `side`.  Uses true metric-space perpendicular so diagonal streets are handled
    /// correctly — no axis-aligned approximation.
    private static func kerbOffset(
        p1: CLLocationCoordinate2D,
        p2: CLLocationCoordinate2D,
        side: SideDetector.StreetSide,
        meters: Double
    ) -> (CLLocationCoordinate2D, CLLocationCoordinate2D) {
        let cosLat = cos((p1.latitude + p2.latitude) / 2 * .pi / 180)
        // Street direction in locally-flat (east, north) space, both axes in degree-equivalents.
        let dNorth = p2.latitude  - p1.latitude
        let dEast  = (p2.longitude - p1.longitude) * cosLat
        let len    = sqrt(dNorth * dNorth + dEast * dEast)

        let offsetDeg = meters / 111_139.0   // metres → ° latitude-equivalent

        // Left-hand (CCW 90°) perpendicular of (dEast, dNorth) is (-dNorth, dEast).
        let perpNorth: Double
        let perpEast:  Double
        if len > 1e-9 {
            perpNorth =  dEast  / len
            perpEast  = -dNorth / len
        } else {
            // Degenerate (coincident points) — axis-aligned fallback.
            switch side {
            case .north: perpNorth =  1; perpEast =  0
            case .south: perpNorth = -1; perpEast =  0
            case .east:  perpNorth =  0; perpEast =  1
            case .west:  perpNorth =  0; perpEast = -1
            }
        }

        // Flip so the offset points toward the requested side.
        let isEastWest    = (side == .north || side == .south)
        let wantsPositive = (side == .north || side == .east)
        let primaryCmp    = isEastWest ? perpNorth : perpEast
        let flip: Double  = (wantsPositive == (primaryCmp >= 0)) ? 1 : -1

        let oLat = flip * perpNorth * offsetDeg
        let oLon = flip * perpEast  * offsetDeg / cosLat

        return (
            CLLocationCoordinate2D(latitude: p1.latitude + oLat, longitude: p1.longitude + oLon),
            CLLocationCoordinate2D(latitude: p2.latitude + oLat, longitude: p2.longitude + oLon)
        )
    }

    // MARK: - Coordinate conversion

    /// Accurate WGS84 → EPSG:2263 (NY State Plane Long Island, US survey feet).
    /// Lambert Conformal Conic 2SP forward (EPSG method 9802) — exact inverse of
    /// `statePlaneNYLIToWgs84`. The previous linear approximation was off by ~400 ft
    /// (a full block) across NYC, which made "closest sign" logic pick the wrong street.
    static func wgs84ToStatePlane(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let a  = 6_378_137.0
        let f  = 1.0 / 298.257222101
        let e2 = 2*f - f*f
        let e  = sqrt(e2)

        let phi1 = (40.0 + 40.0/60.0) * .pi / 180
        let phi2 = (41.0 +  2.0/60.0) * .pi / 180
        let phi0 = (40.0 + 10.0/60.0) * .pi / 180
        let lam0 = -74.0               * .pi / 180
        let FE_m  = 300_000.0
        let ftToM = 0.304800609601219

        func mf(_ phi: Double) -> Double {
            cos(phi) / sqrt(1.0 - e2 * sin(phi) * sin(phi))
        }
        func tf(_ phi: Double) -> Double {
            let s = sin(phi)
            return tan(.pi/4.0 - phi/2.0) / pow((1.0 - e*s) / (1.0 + e*s), e/2.0)
        }

        let m1 = mf(phi1), m2 = mf(phi2)
        let t1 = tf(phi1), t2 = tf(phi2), t0 = tf(phi0)
        let n    = (Foundation.log(m1) - Foundation.log(m2)) / (Foundation.log(t1) - Foundation.log(t2))
        let bigF = m1 / (n * pow(t1, n))
        let r0   = a * bigF * pow(t0, n)

        let r     = a * bigF * pow(tf(lat * .pi / 180), n)
        let theta = n * (lon * .pi / 180 - lam0)
        let easting  = FE_m + r * sin(theta)
        let northing = r0 - r * cos(theta)
        return (x: easting / ftToM, y: northing / ftToM)
    }

    /// Accurate EPSG:2263 (NY State Plane Long Island) → WGS84 inverse.
    /// Implements the full Lambert Conformal Conic 2SP inverse (EPSG method 9802).
    /// Sub-meter accuracy anywhere in NYC — replaces the ±500 ft linear approximation
    /// for converting dataset sign coordinates back to lat/lon for map display.
    static func statePlaneNYLIToWgs84(x: Double, y: Double) -> (lat: Double, lon: Double) {
        // GRS80 ellipsoid (same as WGS84 for practical purposes)
        let a  = 6_378_137.0
        let f  = 1.0 / 298.257222101
        let e2 = 2*f - f*f
        let e  = sqrt(e2)

        // EPSG:2263 Lambert Conformal Conic 2SP parameters (all angles in radians)
        let phi1 = (40.0 + 40.0/60.0) * .pi / 180  // 40°40'N — first standard parallel
        let phi2 = (41.0 +  2.0/60.0) * .pi / 180  // 41°02'N — second standard parallel
        let phi0 = (40.0 + 10.0/60.0) * .pi / 180  // 40°10'N — latitude of false origin
        let lam0 = -74.0               * .pi / 180  // 74°W    — longitude of false origin
        // EPSG:2263 false easting is 300 000 METRES (not 300 000 feet).
        // The dataset stores X/Y in US survey feet, so convert input to metres first,
        // then subtract the 300 000 m false easting to get the true eastward offset.
        let FE_m  = 300_000.0                       // false easting, metres
        let ftToM = 0.304800609601219               // US survey foot → metre

        // Conformal latitude factor m and LCC t-factor
        func mf(_ phi: Double) -> Double {
            cos(phi) / sqrt(1.0 - e2 * sin(phi) * sin(phi))
        }
        func tf(_ phi: Double) -> Double {
            let s = sin(phi)
            return tan(.pi/4.0 - phi/2.0) / pow((1.0 - e*s) / (1.0 + e*s), e/2.0)
        }

        let m1 = mf(phi1), m2 = mf(phi2)
        let t1 = tf(phi1), t2 = tf(phi2), t0 = tf(phi0)
        // Use Foundation.log to avoid shadowing by the file-level `log` Logger instance
        let n  = (Foundation.log(m1) - Foundation.log(m2)) / (Foundation.log(t1) - Foundation.log(t2))
        let bigF = m1 / (n * pow(t1, n))
        let r0   = a * bigF * pow(t0, n)   // metres

        // Input: US survey feet → metres, apply false-origin offset
        let easting  = x * ftToM - FE_m   // FN = 0 for EPSG:2263
        let northing = y * ftToM

        let rPrime     = (n >= 0 ? 1.0 : -1.0) * sqrt(easting*easting + (r0 - northing)*(r0 - northing))
        let tPrime     = pow(rPrime / (a * bigF), 1.0/n)
        let thetaPrime = atan2(easting, r0 - northing)

        // Iterative geodetic latitude solution (converges in ≤ 5 steps)
        var phi = .pi/2.0 - 2.0*atan(tPrime)
        for _ in 0..<10 {
            let s    = sin(phi)
            let prev = phi
            phi = .pi/2.0 - 2.0*atan(tPrime * pow((1.0 - e*s) / (1.0 + e*s), e/2.0))
            if abs(phi - prev) < 1e-12 { break }
        }
        let lam = thetaPrime / n + lam0
        return (lat: phi * 180.0 / .pi, lon: lam * 180.0 / .pi)
    }

    // MARK: - Dataset name formatting

    /// Converts a normalized street name to the padded format used by the nfid-uabd dataset.
    /// Numbered streets (e.g. "WEST 79 STREET") use a 4-char right-justified number field.
    /// "WEST 79 STREET" → "WEST   79 STREET", "WEST 171 STREET" → "WEST  171 STREET"
    static func datasetFormatName(_ normalized: String) -> String {
        let directions = ["NORTH", "SOUTH", "EAST", "WEST"]
        let parts = normalized.components(separatedBy: " ")
        guard parts.count >= 3,
              directions.contains(parts[0]),
              let num = Int(parts[1])
        else { return normalized }
        let paddedNum = String(format: "%4d", num)
        let suffix = parts.dropFirst(2).joined(separator: " ")
        return parts[0] + " " + paddedNum + " " + suffix
    }

    /// Converts any borough casing to the title-case format the nfid-uabd dataset uses.
    /// "MANHATTAN" → "Manhattan", "STATEN ISLAND" → "Staten Island"
    static func titleCaseBorough(_ borough: String) -> String {
        switch borough.uppercased() {
        case "MANHATTAN":    return "Manhattan"
        case "BROOKLYN":     return "Brooklyn"
        case "QUEENS":       return "Queens"
        case "BRONX":        return "Bronx"
        case "STATEN ISLAND": return "Staten Island"
        default:             return borough
        }
    }

    // MARK: - Disk cache

    /// Cache key includes a coarse 1500 ft grid bucket so nearby spots reuse cached data.
    private func cacheKey(streetName: String, borough: String, x: Double, y: Double) -> String {
        let bx = Int(x / 1500) * 1500
        let by = Int(y / 1500) * 1500
        return "\(streetName)|\(borough)|\(bx)|\(by)"
    }

    private func cacheURL(key: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = key.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return support.appendingPathComponent("nyc_nfid_v12_\(safe).json")
    }

    private func saveToDisk(_ entries: [StreetCleaningEntry], key: String) {
        guard !entries.isEmpty else { return }
        do {
            let url = cacheURL(key: key)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            log.info("💾 Cached \(entries.count) entries → \(url.lastPathComponent)")
        } catch {
            log.error("❌ Cache write failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk(key: String) -> [StreetCleaningEntry]? {
        let url = cacheURL(key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([StreetCleaningEntry].self, from: data)
    }

    private func isDiskCacheStale(key: String) -> Bool {
        let path = cacheURL(key: key).path
        guard let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return true }
        return Date().timeIntervalSince(mod) > cacheAgeLimit
    }
}

// MARK: - Raw API record from nfid-uabd

private struct NfidSignRecord: Decodable {
    let onStreet: String
    let fromStreet: String
    let toStreet: String
    let sideOfStreet: String
    let signDescription: String
    let borough: String
    let signXCoord: Double?
    let signYCoord: Double?

    enum CodingKeys: String, CodingKey {
        case onStreet       = "on_street"
        case fromStreet     = "from_street"
        case toStreet       = "to_street"
        case sideOfStreet   = "side_of_street"
        case signDescription = "sign_description"
        case borough
        case signXCoord     = "sign_x_coord"
        case signYCoord     = "sign_y_coord"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onStreet        = (try? c.decode(String.self, forKey: .onStreet))        ?? ""
        fromStreet      = (try? c.decode(String.self, forKey: .fromStreet))      ?? ""
        toStreet        = (try? c.decode(String.self, forKey: .toStreet))        ?? ""
        sideOfStreet    = (try? c.decode(String.self, forKey: .sideOfStreet))    ?? ""
        signDescription = (try? c.decode(String.self, forKey: .signDescription)) ?? ""
        borough         = (try? c.decode(String.self, forKey: .borough))         ?? ""
        // The API returns numbers; tolerate both Number and String encoding
        func decodeDouble(_ key: CodingKeys) -> Double? {
            if let d = try? c.decode(Double.self, forKey: key) { return d }
            return (try? c.decode(String.self, forKey: key)).flatMap { Double($0) }
        }
        signXCoord = decodeDouble(.signXCoord)
        signYCoord = decodeDouble(.signYCoord)
    }

    /// Expands one sign record into zero or more StreetCleaningEntry objects (one per cleaning day).
    func expand() -> [StreetCleaningEntry] {
        // Normalize street name: collapse multiple spaces (dataset uses padded numbers)
        let normalizedStreet = onStreet
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return SignDescriptionParser.parse(signDescription).map { schedule in
            StreetCleaningEntry(
                id: UUID(),
                streetName: normalizedStreet,
                fromStreet: fromStreet,
                toStreet: toStreet,
                sideOfStreet: sideOfStreet,
                weekDay: schedule.weekDay,
                fromHour: schedule.fromHour,
                fromMinutes: schedule.fromMinutes,
                toHour: schedule.toHour,
                toMinutes: schedule.toMinutes,
                borough: borough,
                signXCoord: signXCoord,
                signYCoord: signYCoord,
                signLatitude: nil,
                signLongitude: nil
            )
        }
    }
}
