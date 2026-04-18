import Foundation
import OSLog

/// MusicBrainz wrapper — supplies authoritative year + region metadata
/// for candidates surfaced by other sources (Last.fm, Bandcamp).
///
/// Two public lookup methods, both returning `Optional` so the caller
/// can fail-open when MB doesn't know (common for Bandcamp bedroom-
/// producer tracks). Actor-serialized and rate-limited to 1.05s between
/// outbound requests — MB's public server caps at 1 req/sec and throttles
/// hard on the User-Agent if missing.
public actor MusicBrainzClient {

    public enum Error: Swift.Error, Sendable {
        case badResponse(URL)
    }

    private let userAgent: String
    private let session: URLSession
    private let logger = Logger(subsystem: "se.jonasjohansson.ratbat", category: "musicbrainz")
    private static let apiBase = URL(string: "https://musicbrainz.org/ws/2/")!

    private var recordingCache: [String: Int?] = [:]
    private var artistCache: [String: String?] = [:]
    private var lastRequestAt: Date?

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    // MARK: - Public

    public func firstReleaseYear(artist: String, title: String) async -> Int? {
        let key = "\(artist.lowercased())\u{1}\(title.lowercased())"
        if let hit = recordingCache[key] { return hit }

        let query = "artist:\"\(escape(artist))\" AND recording:\"\(escape(title))\""
        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("recording"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = comps.url else {
            recordingCache[key] = .some(nil)
            return nil
        }

        do {
            let data = try await throttledFetch(url)
            let year = Self.parseFirstReleaseYear(from: data)
            recordingCache[key] = .some(year)
            return year
        } catch {
            logger.info("firstReleaseYear failed for \(artist, privacy: .public) — \(title, privacy: .public): \(String(describing: error), privacy: .public)")
            // Don't cache failures — transient issues deserve a retry
            // next refill.
            return nil
        }
    }

    public func countryCode(forArtist artist: String) async -> String? {
        let key = artist.lowercased()
        if let hit = artistCache[key] { return hit }

        var comps = URLComponents(url: Self.apiBase.appendingPathComponent("artist"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(escape(artist))\""),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = comps.url else {
            artistCache[key] = .some(nil)
            return nil
        }

        do {
            let data = try await throttledFetch(url)
            let code = Self.parseCountryCode(from: data)
            artistCache[key] = .some(code)
            return code
        } catch {
            logger.info("countryCode failed for \(artist, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Internal (exposed for @testable tests)

    static func parseFirstReleaseYear(from data: Data) -> Int? {
        struct Envelope: Decodable {
            struct Recording: Decodable {
                let firstReleaseDate: String?
                enum CodingKeys: String, CodingKey {
                    case firstReleaseDate = "first-release-date"
                }
            }
            let recordings: [Recording]?
        }
        guard
            let env = try? JSONDecoder().decode(Envelope.self, from: data),
            let first = env.recordings?.first,
            let date = first.firstReleaseDate,
            date.count >= 4,
            let year = Int(date.prefix(4))
        else { return nil }
        return year
    }

    static func parseCountryCode(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Artist: Decodable {
                struct Area: Decodable {
                    let isoCodes: [String]?
                    enum CodingKeys: String, CodingKey {
                        case isoCodes = "iso-3166-1-codes"
                    }
                }
                let area: Area?
                let country: String?
            }
            let artists: [Artist]?
        }
        guard
            let env = try? JSONDecoder().decode(Envelope.self, from: data),
            let first = env.artists?.first
        else { return nil }
        // Prefer `area.iso-3166-1-codes[0]`; fall back to top-level `country`.
        return first.area?.isoCodes?.first ?? first.country
    }

    // MARK: - Private

    private func escape(_ s: String) -> String {
        // Lucene escaping — backslash-prefix characters that are syntactic
        // in the MB query DSL. Good-enough set for artist/title inputs.
        var out = ""
        for ch in s {
            if "\\+-&|!(){}[]^\"~*?:/".contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    private func throttledFetch(_ url: URL) async throws -> Data {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let minGap: TimeInterval = 1.05
            if elapsed < minGap {
                try await Task.sleep(nanoseconds: UInt64((minGap - elapsed) * 1_000_000_000))
            }
        }
        lastRequestAt = Date()

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.badResponse(url)
        }
        return data
    }
}
