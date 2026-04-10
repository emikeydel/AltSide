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

    // MARK: - Coordinate conversion

    /// Approximate WGS84 → EPSG:2263 (NY State Plane Long Island, US survey feet).
    /// refX empirically calibrated from geocoded NYC parking sign coordinates
    /// (Bergen St Cobble Hill signs confirmed at x≈986000–987000 in the dataset).
    /// Accuracy ≈ ±500 ft across NYC — sufficient for the ±1500 ft bounding box query.
    static func wgs84ToStatePlane(lat: Double, lon: Double) -> (x: Double, y: Double) {
        let refLat = 40.7061, refLon = -73.9969
        let refX = 985_000.0, refY = 196_920.0
        let ftPerDegLat = 364_000.0
        let ftPerDegLon = cos(refLat * .pi / 180) * 364_000.0  // ≈ 275,500 ft/deg
        return (
            x: refX + (lon - refLon) * ftPerDegLon,
            y: refY + (lat - refLat) * ftPerDegLat
        )
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
        return support.appendingPathComponent("nyc_nfid_v8_\(safe).json")
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
        if let d = try? c.decode(Double.self, forKey: .signXCoord) {
            signXCoord = d
        } else {
            signXCoord = (try? c.decode(String.self, forKey: .signXCoord)).flatMap { Double($0) }
        }
        if let d = try? c.decode(Double.self, forKey: .signYCoord) {
            signYCoord = d
        } else {
            signYCoord = (try? c.decode(String.self, forKey: .signYCoord)).flatMap { Double($0) }
        }
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
                signYCoord: signYCoord
            )
        }
    }
}
