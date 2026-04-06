import CoreLocation

/// Infers which side of the street the user is parked on from compass heading
/// and street orientation. Cross-checks with address number parity (NYC convention).
enum SideDetector {

    enum StreetSide: String, CaseIterable {
        case north, south, east, west

        var displayName: String { rawValue.capitalized }

        /// Odd-numbered addresses are on the north/west side in NYC.
        /// Even-numbered addresses are on the south/east side.
        var addressParity: String {
            switch self {
            case .north, .west: return "Odd-numbered buildings"
            case .south, .east: return "Even-numbered buildings"
            }
        }

        var compassLabel: String {
            switch self {
            case .north: return "N"
            case .south: return "S"
            case .east: return "E"
            case .west: return "W"
            }
        }
    }

    enum StreetOrientation {
        case eastWest   // crosstown streets (e.g. W 79th St)
        case northSouth // avenues (e.g. Broadway, 5th Ave)
    }

    /// Detects which side of the street based on heading and street orientation.
    ///
    /// For E-W streets (most NYC crosstown streets):
    ///   heading 0–180  (facing north/east) → parked on SOUTH side
    ///   heading 180–360 (facing south/west) → parked on NORTH side
    ///
    /// For N-S avenues:
    ///   heading 90–270 (facing east/south) → parked on WEST side
    ///   heading 270–90 (facing west/north) → parked on EAST side
    static func detectSide(heading: CLLocationDirection, orientation: StreetOrientation) -> StreetSide {
        let normalizedHeading = heading.truncatingRemainder(dividingBy: 360)
        switch orientation {
        case .eastWest:
            return normalizedHeading >= 0 && normalizedHeading < 180 ? .south : .north
        case .northSouth:
            return normalizedHeading >= 90 && normalizedHeading < 270 ? .west : .east
        }
    }

    /// Infers street orientation from a street name. NYC avenues tend to run N-S;
    /// streets (and named crosstown streets) run E-W.
    static func inferOrientation(from streetName: String) -> StreetOrientation {
        let upper = streetName.uppercased()
        let avenueSuffixes = ["AVENUE", "AVE", "BOULEVARD", "BLVD", "DRIVE", "DR", "PLACE", "PL"]
        let numbered = upper.contains("STREET") || upper.contains("ST ") || upper.first?.isNumber == true

        if numbered { return .eastWest }
        for suffix in avenueSuffixes {
            if upper.hasSuffix(suffix) || upper.contains(" \(suffix) ") { return .northSouth }
        }
        return .eastWest // NYC default
    }

    /// Cross-checks a detected side against address number parity (NYC convention).
    /// Returns `true` if they agree.
    static func parityAgrees(side: StreetSide, addressNumber: String) -> Bool {
        guard let number = Int(addressNumber.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) else {
            return true // can't check, assume ok
        }
        let isOdd = number % 2 != 0
        switch side {
        case .north, .west: return isOdd
        case .south, .east: return !isOdd
        }
    }
}
