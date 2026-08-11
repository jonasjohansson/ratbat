#if os(macOS)
import Foundation

/// Curated tag vocabularies offered by the station sheets.
///
/// One per generative source, because the sources genuinely disagree about
/// what a genre is: Last.fm's vocabulary is chart-weighted, NTS leans
/// broadcast-programming, and Bandcamp's long tail is full of scenes the
/// other two have never heard of. The palettes lived as `private static`
/// arrays inside the three "Add station" sheets until the edit sheet
/// needed the same lists — a station edited from a palette the user never
/// saw when creating it would read as a different station.
///
/// Tags outside a palette still round-trip fine; ``FacetedQueryEditor``
/// renders them as removable chips.
public enum StationTagPalette {

    /// Broadcast-programming vocabulary — how NTS itself files shows.
    public static let nts: [String] = [
        "ambient", "electronic", "techno", "house",
        "jazz", "experimental", "hip hop", "ECM",
        "new age", "downtempo", "drum and bass",
        "soul", "funk", "disco", "post-punk",
        "minimal", "drone", "dub", "global",
        "field recordings", "lo-fi", "piano",
        "classical", "modern classical", "noise"
    ]

    /// Chart-weighted vocabulary, including the decade tags Last.fm's
    /// users actually apply as genres.
    public static let lastFM: [String] = [
        "techno", "house", "deep house", "minimal",
        "ambient", "drone", "downtempo", "trip hop",
        "jazz", "jazz fusion", "soul", "funk",
        "disco", "krautrock", "psychedelic",
        "experimental", "electronic", "idm",
        "drum and bass", "dubstep", "dub",
        "hip hop", "new wave", "post-punk",
        "indie", "shoegaze", "dream pop",
        "classical", "modern classical", "piano",
        "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"
    ]

    /// Scenes where Bandcamp's long tail actually lives — microgenres with
    /// active tag feeds and effectively no presence in a chart vocabulary.
    /// Clustered loosely by vibe so the picker reads as a tour of the
    /// site's niches rather than an alphabetical list.
    public static let bandcamp: [String] = [
        "techno", "house", "ambient", "dungeon synth",
        "vaporwave", "hyperpop", "drone", "dub techno",
        "outsider house", "idm", "breakcore", "footwork",
        "witch house", "hauntology", "slowcore", "shoegaze",
        "post-rock", "field recording", "lo-fi", "experimental"
    ]
}
#endif
