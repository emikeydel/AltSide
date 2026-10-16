import CoreLocation
import MapKit

/// Resolves a GPS coordinate to a street name and block,
/// then matches it against the cached NYC cleaning dataset.
enum BlockMatcher {

    struct ResolvedStreet {
        let name: String           // e.g. "West 79th Street"
        let normalizedName: String // e.g. "WEST 79 STREET"
        let borough: String
        let addressNumber: String  // e.g. "220"
        let crossStreetFrom: String
        let crossStreetTo: String
        let orientation: SideDetector.StreetOrientation
        /// The coordinate used for bounding-box sign queries — the original GPS/pin location.
        let snappedCoordinate: CLLocationCoordinate2D
    }

    /// Reverse-geocodes a coordinate into a ResolvedStreet using CLGeocoder.
    static func resolve(coordinate: CLLocationCoordinate2D) async throws -> ResolvedStreet {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else { throw BlockMatcherError.noResult }

        // CLGeocoder's placemark.location is an address-range centroid, not a road snap —
        // it can be hundreds of metres from the actual pin. Use the original coordinate so
        // the bounding-box query is centred on where the user actually parked.
        let snapped = coordinate
        let shortAddress = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let (streetName, houseNumber) = parseStreetAndNumber(from: shortAddress)
        // Use subAdministrativeArea (county) — CLGeocoder's locality may return a neighborhood
        // name ("Carroll Gardens", "Flushing") rather than the borough.
        let borough: String = {
            // Coordinate bounding-box is more reliable than CLGeocoder's subAdministrativeArea —
            // CLGeocoder sometimes returns "New York" (Manhattan's county) for Brooklyn, Queens,
            // and Bronx addresses, causing the wrong borough to be queried.
            let coordBorough = CleaningDataManager.borough(for: coordinate)
            if !coordBorough.isEmpty { return coordBorough }

            // Fallback: parse geocoder county/locality fields.
            switch placemark.subAdministrativeArea?.uppercased() {
            case "NEW YORK": return "Manhattan"
            case "KINGS":    return "Brooklyn"
            case "QUEENS":   return "Queens"
            case "BRONX":    return "Bronx"
            case "RICHMOND": return "Staten Island"
            default:
                let combined = [placemark.subLocality, placemark.locality, placemark.administrativeArea]
                    .compactMap { $0 }.joined(separator: " ")
                return mapToBorough(cityName: combined, fullAddress: "")
            }
        }()

        // Throw if the coordinate is outside NYC — avoids fetching "COUNTY ROAD 3100" etc.
        guard !borough.isEmpty else { throw BlockMatcherError.noResult }

        let normalized  = normalize(streetName)
        let orientation = SideDetector.inferOrientation(from: streetName)
        let (from, to)  = await nearbyCrossStreets(coordinate: snapped,
                                                    streetName: streetName,
                                                    houseNumber: houseNumber)

        return ResolvedStreet(
            name: streetName,
            normalizedName: normalized,
            borough: borough,
            addressNumber: houseNumber,
            crossStreetFrom: from,
            crossStreetTo: to,
            orientation: orientation,
            snappedCoordinate: snapped
        )
    }

    /// Normalizes a street name to match NYC Open Data format.
    static func normalize(_ name: String) -> String {
        var result = name.uppercased()

        // Strip ordinal suffixes: "79TH" → "79", "3RD" → "3", "182ND" → "182"
        // nfid-uabd stores "WEST 79 STREET" not "WEST 79TH STREET"
        if let re = try? NSRegularExpression(pattern: #"(\d+)(ST|ND|RD|TH)\b"#) {
            result = re.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        }

        // Expand street-type abbreviations using word boundaries so they match
        // at end-of-string ("5 AVE"), mid-string ("AVE B"), and with punctuation ("AVE.").
        // Using \b prevents "AVENUE" from being re-expanded to "AVENUENUE".
        let abbrevs: [(pattern: String, replacement: String)] = [
            (#"\bAVE\.?\b"#,  "AVENUE"),
            (#"\bBLVD\.?\b"#, "BOULEVARD"),
            (#"\bDR\.?\b"#,   "DRIVE"),
            (#"\bPL\.?\b"#,   "PLACE"),
            (#"\bRD\.?\b"#,   "ROAD"),
            // ST only at end of string: "WEST 34 ST" → "WEST 34 STREET"
            // Avoids "ST NICHOLAS" → "STREET NICHOLAS" (Saint abbreviation at start)
            (#"\bST\.?$"#, "STREET"),
            // Directional prefix abbreviations before a digit: "W 79" → "WEST 79", "E 14" → "EAST 14"
            // Only when followed by whitespace+digit so "AVENUE W" is not changed.
            (#"\bW(?=\s+\d)"#, "WEST"),
            (#"\bE(?=\s+\d)"#, "EAST"),
        ]
        for (pattern, replacement) in abbrevs {
            if let re = try? NSRegularExpression(pattern: pattern) {
                result = re.stringByReplacingMatches(in: result,
                    range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }

        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // In-memory cache for findBestBlock — avoids repeat geocoding for the same street.
    private static var bestBlockCache: [String: (result: (from: String, to: String)?, date: Date)] = [:]
    private static let bestBlockCacheTTL: TimeInterval = 300 // 5 minutes

    /// Finds the (from, to) cross-street pair closest to `userCoordinate` by forward-geocoding
    /// the intersection of each unique from-street with the main street.
    /// Used when sign coordinates are NULL (un-geocoded signs) so proximity filtering fails.
    static func findBestBlock(
        entries: [StreetCleaningEntry],
        streetName: String,
        borough: String,
        userCoordinate: CLLocationCoordinate2D
    ) async -> (from: String, to: String)? {
        // Round to 3 decimal places (≈110 m) so nearby positions on the same block
        // share a cache entry, but different blocks on the same street don't collide.
        let cacheKey = String(format: "%@|%@|%.3f|%.3f",
                              streetName, borough,
                              userCoordinate.latitude, userCoordinate.longitude)
        if let cached = bestBlockCache[cacheKey], Date().timeIntervalSince(cached.date) < bestBlockCacheTTL {
            return cached.result
        }
        // Collect unique (from, to) block pairs
        var seen = Set<String>()
        var blocks: [(from: String, to: String)] = []
        for entry in entries {
            let key = "\(entry.fromStreet)|\(entry.toStreet)"
            if seen.insert(key).inserted {
                blocks.append((from: entry.fromStreet, to: entry.toStreet))
            }
        }
        guard !blocks.isEmpty else { return nil }
        if blocks.count == 1 { return blocks[0] }
        // Cap to 15 unique blocks — each needs up to 2 MapKit searches (30 max),
        // safely under the 50-requests/60 s rate limit.
        let capped = blocks.prefix(15)

        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let hintRegion = MKCoordinateRegion(
            center: userCoordinate,
            latitudinalMeters: 100_000,
            longitudinalMeters: 100_000
        )
        var bestBlock: (from: String, to: String)? = nil
        var bestDistance = Double.infinity

        func tc(_ s: String) -> String { s.split(separator: " ").map { $0.capitalized }.joined(separator: " ") }

        for block in capped {
            let queries = [
                "\(tc(block.from)) and \(tc(streetName)), \(borough), NY",
                "\(tc(block.from)), \(borough), NY",
            ]
            var loc: CLLocation? = nil
            for query in queries {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = hintRegion
                if let response = try? await MKLocalSearch(request: request).start(),
                   let location = response.mapItems.first?.placemark.location {
                    loc = location; break
                }
            }
            if let l = loc {
                let dist = userLocation.distance(from: l)
                if dist < bestDistance { bestDistance = dist; bestBlock = block }
            }
        }
        let storeKey = String(format: "%@|%@|%.3f|%.3f",
                              streetName, borough,
                              userCoordinate.latitude, userCoordinate.longitude)
        bestBlockCache[storeKey] = (result: bestBlock, date: Date())
        return bestBlock
    }

    /// Fuzzy match: returns true if two normalized street names refer to the same street.
    static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        let compA = na.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        let compB = nb.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return compA == compB
    }

    // MARK: - Private helpers

    /// Splits "123 West 79th Street, New York" → ("West 79th Street", "123")
    /// Also handles address ranges like "369–389 Baltic Street" → ("Baltic Street", "369")
    private static func parseStreetAndNumber(from address: String) -> (street: String, number: String) {
        // Take only the part before the first comma
        let streetPart = address.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? address
        let words = streetPart.components(separatedBy: " ")
        guard let first = words.first else { return (streetPart, "") }

        // Plain number: "123 West 79th Street"
        if Int(first) != nil {
            return (words.dropFirst().joined(separator: " "), first)
        }

        // Address range with en-dash or hyphen: "369–389 Baltic Street", "369-389 Baltic Street"
        // Extract the leading number from the range token for use as the house-number anchor.
        let rangeSeparators = CharacterSet(charactersIn: "–—-")
        let rangeParts = first.components(separatedBy: rangeSeparators)
        if rangeParts.count == 2,
           let leadingNum = rangeParts.first, Int(leadingNum) != nil {
            return (words.dropFirst().joined(separator: " "), leadingNum)
        }

        return (streetPart, "")
    }

    private static func mapToBorough(cityName: String, fullAddress: String) -> String {
        let upper = "\(cityName) \(fullAddress)".uppercased()
        if upper.contains("MANHATTAN") || upper.contains("NEW YORK") { return "Manhattan" }
        if upper.contains("BROOKLYN")  { return "Brooklyn" }
        if upper.contains("QUEENS")    { return "Queens" }
        if upper.contains("BRONX")     { return "Bronx" }
        if upper.contains("STATEN")    { return "Staten Island" }
        return ""
    }

    /// Finds the cross streets bounding the user's block by searching for the same
    /// house number on nearby perpendicular streets.
    ///
    /// Searching for "54" near 54 Bergen Street returns results like "54 Smith Street"
    /// and "54 Hoyt Street" — the cross streets that intersect Bergen Street close to
    /// house number 54. Much more reliable than searching for the street name itself,
    /// which only returns addresses on the same street.
    private static func nearbyCrossStreets(
        coordinate: CLLocationCoordinate2D,
        streetName: String,
        houseNumber: String
    ) async -> (String, String) {
        // Require a house number — without it we have no anchor for the search.
        guard !houseNumber.isEmpty else { return ("", "") }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = houseNumber   // e.g. "54"
        request.resultTypes = .address
        // 300 m region: large enough to catch both bounding cross streets (NYC blocks are ~200 m)
        request.region = MKCoordinateRegion(center: coordinate,
                                            latitudinalMeters: 300,
                                            longitudinalMeters: 300)

        guard let items = try? await MKLocalSearch(request: request).start().mapItems else {
            return ("", "")
        }

        // Extract street names from results; exclude the user's own street.
        let crossStreets = items.compactMap { item -> String? in
            guard let shortAddr = item.placemark.shortAddress else { return nil }
            let (street, _) = parseStreetAndNumber(from: shortAddr)
            return street
        }
        .filter { !$0.isEmpty && !fuzzyMatch($0, streetName) }

        // Deduplicate while preserving order.
        var seen = Set<String>()
        let unique = crossStreets.filter { seen.insert(normalize($0)).inserted }

        return (unique.first ?? "", unique.dropFirst().first ?? "")
    }

    enum BlockMatcherError: Error {
        case noResult
    }
}

// MARK: - Shared MapKit helpers

extension MKPlacemark {
    /// e.g. "123 West 79th Street"
    var shortAddress: String? {
        [subThoroughfare, thoroughfare]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
