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

        // Parse street name and house number from shortAddress
        // shortAddress is typically "123 West 79th Street, New York"
        let shortAddress = item.address?.shortAddress ?? item.name ?? ""
        let (streetName, houseNumber) = parseStreetAndNumber(from: shortAddress)

        // City/borough from addressRepresentations
        let cityName = item.addressRepresentations?.cityName ?? ""
        let borough  = mapToBorough(cityName: cityName, fullAddress: item.address?.fullAddress ?? "")

        let normalized  = normalize(streetName)
        let orientation = SideDetector.inferOrientation(from: streetName)
        let (from, to)  = await nearbyCrossStreets(coordinate: coordinate,
                                                    streetName: streetName,
                                                    houseNumber: houseNumber)

        return ResolvedStreet(
            name: streetName,
            normalizedName: normalized,
            borough: borough,
            addressNumber: houseNumber,
            crossStreetFrom: from,
            crossStreetTo: to,
            orientation: orientation
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

    /// Finds the (from, to) cross-street pair closest to `userCoordinate` by forward-geocoding
    /// the intersection of each unique from-street with the main street.
    /// Used when sign coordinates are NULL (un-geocoded signs) so proximity filtering fails.
    static func findBestBlock(
        entries: [StreetCleaningEntry],
        streetName: String,
        borough: String,
        userCoordinate: CLLocationCoordinate2D
    ) async -> (from: String, to: String)? {
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
        let hint = CLCircularRegion(center: userCoordinate, radius: 50_000, identifier: "nyc")
        var bestBlock: (from: String, to: String)? = nil
        var bestDistance = Double.infinity

        func tc(_ s: String) -> String { s.split(separator: " ").map { $0.capitalized }.joined(separator: " ") }

        for block in blocks {
            // Try two query formats: full intersection then just the cross-street name.
            // Use non-throwing continuation so a partial-result error doesn't discard valid placemarks.
            let queries = [
                "\(tc(block.from)) and \(tc(streetName)), \(borough), NY",
                "\(tc(block.from)), \(borough), NY",
            ]
            var loc: CLLocation? = nil
            for query in queries {
                let placemarks = await withCheckedContinuation { (cont: CheckedContinuation<[CLPlacemark], Never>) in
                    CLGeocoder().geocodeAddressString(query, in: hint) { results, _ in
                        cont.resume(returning: results ?? [])
                    }
                }
                if let l = placemarks.first?.location { loc = l; break }
            }
            if let l = loc {
                let dist = userLocation.distance(from: l)
                if dist < bestDistance { bestDistance = dist; bestBlock = block }
            }
        }
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
    private static func parseStreetAndNumber(from address: String) -> (street: String, number: String) {
        // Take only the part before the first comma
        let streetPart = address.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? address
        let words = streetPart.components(separatedBy: " ")
        if let first = words.first, Int(first) != nil {
            return (words.dropFirst().joined(separator: " "), first)
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
        return "Manhattan"
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
