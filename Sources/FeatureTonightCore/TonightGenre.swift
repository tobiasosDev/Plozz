import Foundation

/// The genre vocabulary the taste model reasons in.
///
/// Servers, Trakt and TMDb name genres differently and in the server's own
/// language ("Science Fiction", "Sci-Fi & Fantasy", "Krimi"). Everything is
/// folded onto this closed set so a Plex "Komödie" and a Trakt "comedy" are the
/// same signal. Unknown genres are dropped rather than invented.
public enum TonightGenre: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case action
    case adventure
    case animation
    case comedy
    case crime
    case documentary
    case drama
    case family
    case fantasy
    case history
    case horror
    case music
    case mystery
    case romance
    case scienceFiction = "science-fiction"
    case thriller
    case war
    case western

    public static func < (lhs: TonightGenre, rhs: TonightGenre) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Lower-cased, diacritic-folded spellings that map onto this genre. Also
    /// used to match free-text moods against a film's genres.
    public var aliases: [String] {
        switch self {
        case .action: return ["action", "action & adventure", "action and adventure", "martial arts"]
        case .adventure: return ["adventure", "abenteuer"]
        case .animation: return ["animation", "anime", "zeichentrick", "animated"]
        case .comedy: return ["comedy", "komodie", "komoedie", "sitcom"]
        case .crime: return ["crime", "krimi", "film noir", "film-noir", "kriminalfilm"]
        case .documentary: return ["documentary", "dokumentarfilm", "dokumentation", "doku", "docu"]
        case .drama: return ["drama"]
        case .family: return ["family", "familie", "kinder", "kids", "children", "familienfilm"]
        case .fantasy: return ["fantasy"]
        case .history: return ["history", "historie", "historisch", "biography", "biografie", "biopic", "war & politics"]
        case .horror: return ["horror"]
        case .music: return ["music", "musical", "musik", "musikfilm"]
        case .mystery: return ["mystery", "suspense"]
        case .romance: return ["romance", "liebesfilm", "romantik", "romantic", "lovestory", "love story"]
        case .scienceFiction:
            return ["science fiction", "science-fiction", "sci fi", "sci-fi", "scifi", "sci-fi & fantasy", "sci fi & fantasy"]
        case .thriller: return ["thriller"]
        case .war: return ["war", "kriegsfilm", "krieg"]
        case .western: return ["western"]
        }
    }

    /// The TMDb genre id, kept for matching TMDb-sourced candidates.
    public var tmdbID: Int {
        switch self {
        case .action: return 28
        case .adventure: return 12
        case .animation: return 16
        case .comedy: return 35
        case .crime: return 80
        case .documentary: return 99
        case .drama: return 18
        case .family: return 10751
        case .fantasy: return 14
        case .history: return 36
        case .horror: return 27
        case .music: return 10402
        case .mystery: return 9648
        case .romance: return 10749
        case .scienceFiction: return 878
        case .thriller: return 53
        case .war: return 10752
        case .western: return 37
        }
    }

    private static let byAlias: [String: TonightGenre] = {
        var map: [String: TonightGenre] = [:]
        for genre in TonightGenre.allCases {
            map[genre.rawValue] = genre
            for alias in genre.aliases { map[alias] = genre }
        }
        return map
    }()

    /// Maps a provider genre name onto the vocabulary, or `nil` when unknown.
    public static func normalize(_ raw: String) -> TonightGenre? {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = byAlias[folded] { return direct }
        // "Action/Adventure", "Sci-Fi | Fantasy" and similar compound labels.
        return nil
    }

    /// Normalizes a list of provider genres, keeping their first-seen order and
    /// splitting compound labels such as "Action/Adventure".
    public static func normalize(_ raws: [String]) -> [TonightGenre] {
        var out: [TonightGenre] = []
        for raw in raws {
            if let genre = normalize(raw) {
                if !out.contains(genre) { out.append(genre) }
                continue
            }
            for part in raw.split(whereSeparator: { "/|,".contains($0) }) {
                if let genre = normalize(String(part)), !out.contains(genre) { out.append(genre) }
            }
        }
        return out
    }
}
