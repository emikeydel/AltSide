import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.laidoffdad.sweepy", category: "Permits")

/// One construction job that takes curb space on a block — several DOT permit rows
/// (equipment, materials, roadway occupancy…) for the same contractor and dates are
/// merged into one.
struct StreetPermit: Identifiable, Hashable {
    let id: String
    /// Normalized, e.g. "BERGEN STREET".
    let street: String
    let fromStreet: String
    let toStreet: String
    let start: Date
    let end: Date
    let permittee: String
    /// Friendly labels, e.g. ["Equipment", "Materials", "Roadway occupied"].
    let kinds: [String]

    var blockKey: String { CleaningDataManager.blockKey(from: fromStreet, to: toStreet) }
    var isActiveNow: Bool { start <= .now && end >= .now }
    var startsLater: Bool { start > .now }
}

/// Construction permits from NYC DOT "Street Construction Permits (2022 – Present)".
///
/// Endpoint: https://data.cityofnewyork.us/resource/tqtj-sjs8.json (same Socrata app token
/// as the sign data). Permits have no usable geometry, so they're matched to blocks by
/// street + cross-street names — see `CleaningDataManager.BlockSchedule.blockKeys`.
///
/// Only permit types that take curb/roadway space are fetched. A permit is permission,
/// not a guarantee: the curb may only be blocked on some days, and the side isn't known.
/// Film shoots aren't covered — the city's film permit dataset lags by months.
@Observable
final class StreetPermitManager {

    private let endpoint = "https://data.cityofnewyork.us/resource/tqtj-sjs8.json"
    private let cacheTTL: TimeInterval = 3 * 3600
    /// Show permits active now or starting within this many days.
    static let lookaheadDays = 7

    /// Keyed "BOROUGH|STREET".
    private var cache: [String: (fetched: Date, permits: [StreetPermit])] = [:]

    /// DOT permit type → friendly label. Anything not listed (sidewalk work, tree pits,
    /// utility repairs without a roadway permit…) is ignored to avoid crying wolf.
    static let curbPermitTypes: [String: String] = [
        "PLACE EQUIPMENT OTHER THAN CRANE OR SHOV": "Equipment",
        "PLACE MATERIAL ON STREET": "Materials",
        "OCCUPANCY OF ROADWAY AS STIPULATED": "Roadway occupied",
        "PLACE OPEN CONSTRUCTION DEBRIS CONTAINER ON STREET": "Dumpster",
        "COMMERCIAL REFUSE CONTAINER": "Dumpster",
        "PLACE CONSTRUCTION OFFICE TRAILER ON STREET": "Trailer",
        "PLACE CRANE OR SHOVEL ON STREET": "Crane",
        "D.D.C. CONTRACTOR MAJOR RECONSTRUCTION": "Street reconstruction",
        "DDC CONTRACTOR MAJOR RECONSTRUCTION-PROT": "Street reconstruction",
        "CONTRACT ROADWAY MILLING": "Repaving",
        "DOT USE ONLY-FULL ROADWAY CLOSURE APPL'S": "Full road closure",
        "PLACE/REMOVE BIKE SHARE STATION ON ST": "Citi Bike station work",
    ]

    // MARK: - Public API

    /// Permits active now or starting within `lookaheadDays` on any of `streets`
    /// (normalized names, e.g. from `BlockSegment.entries.first?.streetName`).
    func permits(onStreets streets: [String], borough: String) async -> [StreetPermit] {
        let boroughKey = borough.uppercased()
        let wanted = Set(streets.map { BlockMatcher.normalize($0) }.filter { !$0.isEmpty })
        let now = Date()
        let missing = wanted.filter { street in
            guard let hit = cache["\(boroughKey)|\(street)"] else { return true }
            return now.timeIntervalSince(hit.fetched) > cacheTTL
        }
        if !missing.isEmpty {
            if let fetched = await fetch(streets: Array(missing), borough: boroughKey) {
                let byStreet = Dictionary(grouping: fetched, by: \.street)
                for street in missing {
                    cache["\(boroughKey)|\(street)"] = (now, byStreet[street] ?? [])
                }
            }
        }
        let horizon = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now) ?? now
        return wanted
            .flatMap { cache["\(boroughKey)|\($0)"]?.permits ?? [] }
            .filter { $0.end >= now && $0.start <= horizon }
            .sorted { $0.start < $1.start }
    }

    /// Permits whose block is one of `blockKeys` on `street`.
    static func matching(_ permits: [StreetPermit], street: String, blockKeys: Set<String>) -> [StreetPermit] {
        permits.filter { BlockMatcher.fuzzyMatch($0.street, street) && blockKeys.contains($0.blockKey) }
    }

    // MARK: - Fetch

    private func fetch(streets: [String], borough: String) async -> [StreetPermit]? {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

        // The dataset stores some names padded ("   3 AVENUE", "WEST   79 STREET") and
        // some not ("3 AVENUE") — query every variant.
        var names = Set<String>()
        for s in streets {
            names.insert(s)
            names.insert(CleaningDataManager.datasetFormatName(s))
            let parts = s.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]) {
                names.insert(String(format: "%4d", n) + " " + parts[1])
            }
        }
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now) ?? now
        let whereClause = "boroughname = \(quoted(borough))"
            + " AND onstreetname in (\(names.sorted().map(quoted).joined(separator: ",")))"
            + " AND permittypedesc in (\(Self.curbPermitTypes.keys.sorted().map(quoted).joined(separator: ",")))"
            + " AND issuedworkenddate >= '\(Self.soqlDate(now))'"
            + " AND issuedworkstartdate <= '\(Self.soqlDate(horizon))'"

        var comps = URLComponents(string: endpoint)
        comps?.queryItems = [
            URLQueryItem(name: "$where", value: whereClause),
            URLQueryItem(name: "$select", value: "onstreetname,fromstreetname,tostreetname,permittypedesc,issuedworkstartdate,issuedworkenddate,permitteename"),
            URLQueryItem(name: "$limit", value: "5000"),
        ]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Secrets.nycOpenDataAppToken, forHTTPHeaderField: "X-App-Token")
        request.timeoutInterval = 20

        // Socrata intermittently answers "service-unavailable" — one retry.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    log.error("Permits HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) (attempt \(attempt))")
                    try? await Task.sleep(for: .seconds(1.5))
                    continue
                }
                let rows = try JSONDecoder().decode([PermitRow].self, from: data)
                let permits = Self.merge(rows)
                log.info("Permits: \(rows.count) rows → \(permits.count) jobs on \(streets.count) streets")
                return permits
            } catch {
                log.error("Permits fetch failed: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }

    /// Collapses one contractor's many permit rows for a block into a single job.
    private static func merge(_ rows: [PermitRow]) -> [StreetPermit] {
        var jobs: [String: (row: PermitRow, start: Date, end: Date, kinds: [String])] = [:]
        for row in rows {
            guard let street = row.onstreetname, let from = row.fromstreetname, let to = row.tostreetname,
                  let type = row.permittypedesc, let kind = curbPermitTypes[type],
                  let start = parseDate(row.issuedworkstartdate), let end = parseDate(row.issuedworkenddate)
            else { continue }
            let key = [BlockMatcher.normalize(street), CleaningDataManager.blockKey(from: from, to: to),
                       row.permitteename ?? ""].joined(separator: "#")
            if var job = jobs[key] {
                job.start = min(job.start, start)
                job.end = max(job.end, end)
                if !job.kinds.contains(kind) { job.kinds.append(kind) }
                jobs[key] = job
            } else {
                jobs[key] = (row, start, end, [kind])
            }
        }
        return jobs.map { key, job in
            StreetPermit(
                id: key,
                street: BlockMatcher.normalize(job.row.onstreetname ?? ""),
                fromStreet: BlockMatcher.normalize(job.row.fromstreetname ?? ""),
                toStreet: BlockMatcher.normalize(job.row.tostreetname ?? ""),
                start: job.start,
                end: job.end,
                permittee: (job.row.permitteename ?? "").trimmingCharacters(in: .whitespaces),
                kinds: job.kinds
            )
        }
    }

    // MARK: - Dates (dataset uses floating New York local time)

    private static let nyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? { s.flatMap { nyFormatter.date(from: $0) } }
    private static func soqlDate(_ d: Date) -> String { nyFormatter.string(from: d) }
}

private struct PermitRow: Decodable {
    let onstreetname: String?
    let fromstreetname: String?
    let tostreetname: String?
    let permittypedesc: String?
    let issuedworkstartdate: String?
    let issuedworkenddate: String?
    let permitteename: String?
}
