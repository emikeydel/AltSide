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

        // Keep records that are either:
        //   (a) un-geocoded (NULL coords) — can't place them, include for cross-street fallback
        //   (b) geocoded AND within ±1500 ft (~450 m) of the user
        // This excludes geocoded signs from distant neighbourhoods (e.g. Crown Heights
        // showing the wrong time) while still returning local un-geocoded signs.
        let buf = 1500.0
        let box = "sign_x_coord > \(Int(userX - buf)) AND sign_x_coord < \(Int(userX + buf))"
               + " AND sign_y_coord > \(Int(userY - buf)) AND sign_y_coord < \(Int(userY + buf))"
        // Include un-geocoded (NULL) records so blocks without sign coords are returned.
        // Geocoded records are filtered to ±1500 ft (~450 m) of the user to exclude
        // distant blocks on the same street (e.g. Crown Heights vs Cobble Hill on Bergen St).
        let whereClause = "sign_description LIKE '%BROOM%'"
            + " AND (sign_x_coord IS NULL OR (\(box)))"

        var comps = URLComponents(string: endpoint)
        comps?.queryItems = [
            URLQueryItem(name: "on_street", value: datasetName),
            URLQueryItem(name: "borough",   value: datasetBorough),
            URLQueryItem(name: "$where",    value: whereClause),
            URLQueryItem(name: "$limit",    value: "1000"),
            URLQueryItem(name: "$select",   value: "on_street,from_street,to_street,side_of_street,sign_description,borough,sign_x_coord,sign_y_coord"),
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
            var from: String, to: String
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
            let faceKey  = "\(entry.fromStreet)|\(entry.toStreet)|\(side)"
            // Canonical block key: normalize then sort from/to so the same physical block
            // always maps to the same key regardless of direction or abbreviation differences
            // (e.g. "COURT ST" vs "COURT STREET", or from/to listed in different order).
            let blockKey = ([entry.fromStreet, entry.toStreet] as [String])
                .map { BlockMatcher.normalize($0) }
                .sorted()
                .joined(separator: "|")
            if groups[faceKey] == nil {
                groups[faceKey] = FaceAcc(from: entry.fromStreet, to: entry.toStreet, side: side)
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

            // Helper: extend a single anchor coord into a ±60 m stub in the street's orientation.
            func stub(around c: CLLocationCoordinate2D) -> (CLLocationCoordinate2D, CLLocationCoordinate2D) {
                let half = 60.0
                let halfLat = half / 111_139.0
                let halfLon = half / (111_139.0 * cos(c.latitude * .pi / 180))
                if isEastWest {
                    return (CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude - halfLon),
                            CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + halfLon))
                } else {
                    return (CLLocationCoordinate2D(latitude: c.latitude - halfLat, longitude: c.longitude),
                            CLLocationCoordinate2D(latitude: c.latitude + halfLat, longitude: c.longitude))
                }
            }

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
                // ── 1 real coord: extend to a stub centred on the sign ──────────────
                (from, to) = stub(around: face.coords[0])

            } else {
                // ── No coords: synthesise from opposite side via kerbOffset ──────────
                let blockKey  = ([face.from, face.to] as [String])
                    .map { BlockMatcher.normalize($0) }
                    .sorted()
                    .joined(separator: "|")
                let allCoords = blockCoords[blockKey] ?? []

                guard !allCoords.isEmpty else { return nil }

                // Build the baseline aligned to the street axis.
                // Normalise the perpendicular axis to the mean so mixed N+S curb coords
                // don't produce a diagonal baseline (e.g. westmost from N curb, eastmost
                // from S curb would slant the segment for an E-W street).
                let p1: CLLocationCoordinate2D
                let p2: CLLocationCoordinate2D
                if allCoords.count >= 2 {
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
                } else {
                    (p1, p2) = stub(around: allCoords[0])
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

    /// Approximate WGS84 → EPSG:2263 (NY State Plane Long Island, US survey feet).
    /// Accuracy ≈ ±500 ft across NYC — sufficient for the ±1500 ft bounding box query.
    static func wgs84ToStatePlane(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let refLat = 40.7061, refLon = -73.9969
        let refX = 985_000.0, refY = 196_920.0
        let ftPerDegLat = 364_000.0
        let ftPerDegLon = cos(refLat * .pi / 180) * 364_000.0
        return (
            x: refX + (lon - refLon) * ftPerDegLon,
            y: refY + (lat - refLat) * ftPerDegLat
        )
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
        return support.appendingPathComponent("nyc_nfid_v10_\(safe).json")
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
