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
        /// Coordinate snapped to the street centerline by MapKit's reverse geocoder.
        /// More reliable than raw GPS for sign-proximity filtering.
        let snappedCoordinate: CLLocationCoordinate2D
    }

    /// Reverse-geocodes a coordinate into a ResolvedStreet using iOS 26 MapKit API.
    static func resolve(coordinate: CLLocationCoordinate2D) async throws -> ResolvedStreet {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // iOS 26: MKReverseGeocodingRequest replaces CLGeocoder
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw BlockMatcherError.noResult
        }
        let mapItems = try await request.mapItems
        guard let item = mapItems.first else { throw BlockMatcherError.noResult }

        // item.location.coordinate is snapped to the street centerline by MapKit —
        // more reliable than the raw GPS coordinate for sign-proximity filtering.
        let snapped = item.location.coordinate

        // Parse street name and house number from shortAddress
        // shortAddress is typically "123 West 79th Street, New York"
        let shortAddress = item.address?.shortAddress ?? item.name ?? ""
        let (streetName, houseNumber) = parseStreetAndNumber(from: shortAddress)

        // City/borough from addressRepresentations
        let cityName = item.addressRepresentations?.cityName ?? ""
        let borough  = mapToBorough(cityName: cityName, fullAddress: item.address?.fullAddress ?? "")
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

        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let hintRegion = MKCoordinateRegion(
            center: userCoordinate,
            latitudinalMeters: 100_000,
            longitudinalMeters: 100_000
        )
        var bestBlock: (from: String, to: String)? = nil
        var bestDistance = Double.infinity

        func tc(_ s: String) -> String { s.split(separator: " ").map { $0.capitalized }.joined(separator: " ") }

        for block in blocks {
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
                   let location = response.mapItems.first?.location {
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
            guard let shortAddr = item.address?.shortAddress else { return nil }
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
    /// "123 West 79th Street, New York"  →  "123 West 79th Street"
    var shortAddress: String? {
        [subThoroughfare, thoroughfare, locality]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
