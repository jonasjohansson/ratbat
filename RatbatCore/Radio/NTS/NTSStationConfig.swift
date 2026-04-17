#if os(macOS)
import Foundation

/// Blueprint for a generative NTS-backed station.
///
/// Tells ``NTSStationController`` which tags to scrape, optional year
/// filters (v2), and whether to shuffle the scraped pool of shows +
/// tracklistings. `id` is the station identity used by ``HistoryStore``
/// for dedup, so it should remain stable across launches — persist the
/// whole config via `Codable` rather than regenerating the UUID.
///
/// `ClosedRange<Int>` doesn't round-trip cleanly through `Codable`
/// (and crossing actor boundaries as `Sendable` gets noisier too), so
/// we store bounds as `yearMin` / `yearMax` and let the controller
/// compose a range at use-time if needed.
public struct NTSStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var tags: [String]
    public var yearMin: Int?
    public var yearMax: Int?
    public var shufflePool: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        tags: [String],
        yearMin: Int? = nil,
        yearMax: Int? = nil,
        shufflePool: Bool = true
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.yearMin = yearMin
        self.yearMax = yearMax
        self.shufflePool = shufflePool
    }
}
#endif
