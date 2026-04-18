#if os(macOS)
import Foundation

/// Blueprint for a generative Bandcamp-backed radio station.
///
/// Mirrors ``LastFMStationConfig`` in shape: identity + a shared
/// ``FacetedQuery`` for genre/era/region + one source-specific lifecycle
/// flag (`sort`). Persisted inside ``Station`` on disk via
/// ``StationStore``; the facet shape is the same so legacy/new migrations
/// (if ever needed) would layer on `CodingKeys` here the same way
/// ``LastFMStationConfig`` does.
public struct BandcampStationConfig: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var query: FacetedQuery
    public var sort: BandcampClient.Sort
    public var shufflePool: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        query: FacetedQuery,
        sort: BandcampClient.Sort = .date,
        shufflePool: Bool = true
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.sort = sort
        self.shufflePool = shufflePool
    }
}
#endif
