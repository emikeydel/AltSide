import CoreLocation

/// One block-face (a specific side of a street between two cross streets) with its
/// cleaning schedule entries and the two sign coordinates that define its extent on the map.
struct BlockSegment: Identifiable {
    let id: String                          // "fromStreet|toStreet|side"
    let fromCoord: CLLocationCoordinate2D   // sign coord near one intersection
    let toCoord: CLLocationCoordinate2D     // sign coord near the other intersection
    let centroid: CLLocationCoordinate2D    // average of all sign coords on this face
    let side: SideDetector.StreetSide
    let fromStreet: String
    let toStreet: String
    let entries: [StreetCleaningEntry]

    /// Earliest upcoming cleaning date across all entries for this block face.
    var nextCleaningDate: Date? {
        entries.compactMap { $0.nextCleaningDate() }.min()
    }

    /// True when the next cleaning is today or tomorrow (< 2 calendar days away).
    var isSoon: Bool {
        guard let next = nextCleaningDate else { return false }
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: next)).day ?? 99
        return days < 2
    }
}
