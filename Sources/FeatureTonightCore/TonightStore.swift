import CoreModels
import CoreNetworking
import Foundation

/// What "Tonight" keeps per profile: the decision memory and the last request.
/// Small, written after every decision.
public struct TonightPersistedState: Codable, Hashable, Sendable {
    public var memory: TonightMemory
    public var request: TonightRequest

    public init(memory: TonightMemory = TonightMemory(), request: TonightRequest = TonightRequest()) {
        self.memory = memory
        self.request = request
    }
}

public protocol TonightStoring: Sendable {
    func load() async -> TonightPersistedState
    func save(_ state: TonightPersistedState) async
    /// The last complete library snapshot, so the screen opens without a rescan.
    func loadLibrary() async -> TonightLibrarySnapshot?
    func saveLibrary(_ snapshot: TonightLibrarySnapshot) async
}

/// Per profile: the decisions as a small JSON file under Application Support,
/// the library snapshot as a rebuildable cache under Caches. A corrupt decision
/// file is moved aside instead of overwritten, so a decoding bug cannot erase
/// the viewer's Never and Save marks.
public actor TonightFileStore: TonightStoring {
    private let stateURL: URL?
    private let libraryURL: URL?

    /// - Parameter profileNamespace: the profile's storage namespace; `nil` for
    ///   the default profile.
    public init(profileNamespace: String?, stateDirectory: URL? = nil, cacheDirectory: URL? = nil) {
        func base(_ directory: FileManager.SearchPathDirectory) -> URL? {
            FileManager.default.urls(for: directory, in: .userDomainMask).first?
                .appendingPathComponent("Plozz", isDirectory: true)
                .appendingPathComponent("Tonight", isDirectory: true)
        }
        let raw = profileNamespace?.isEmpty == false ? profileNamespace! : "default"
        let name = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "default"
        stateURL = (stateDirectory ?? base(.applicationSupportDirectory))?.appendingPathComponent("\(name).json")
        libraryURL = (cacheDirectory ?? base(.cachesDirectory))?.appendingPathComponent("\(name)-library.json")
    }

    public func load() async -> TonightPersistedState {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return TonightPersistedState() }
        do {
            return try JSONDecoder().decode(TonightPersistedState.self, from: data)
        } catch {
            let aside = stateURL.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: stateURL, to: aside)
            PlozzLog.app.error("Tonight state could not be decoded; moved aside")
            return TonightPersistedState()
        }
    }

    public func save(_ state: TonightPersistedState) async {
        write(state, to: stateURL)
    }

    public func loadLibrary() async -> TonightLibrarySnapshot? {
        guard let libraryURL, let data = try? Data(contentsOf: libraryURL) else { return nil }
        return try? JSONDecoder().decode(TonightLibrarySnapshot.self, from: data)
    }

    public func saveLibrary(_ snapshot: TonightLibrarySnapshot) async {
        write(snapshot, to: libraryURL)
    }

    private func write(_ value: some Encodable, to url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            PlozzLog.app.error("Tonight data could not be saved: \(String(describing: type(of: error)))")
        }
    }
}

/// In-memory store for previews and tests.
public actor TonightMemoryStore: TonightStoring {
    private var state: TonightPersistedState
    private var library: TonightLibrarySnapshot?

    public init(_ state: TonightPersistedState = TonightPersistedState(), library: TonightLibrarySnapshot? = nil) {
        self.state = state
        self.library = library
    }

    public func load() async -> TonightPersistedState { state }
    public func save(_ state: TonightPersistedState) async { self.state = state }
    public func loadLibrary() async -> TonightLibrarySnapshot? { library }
    public func saveLibrary(_ snapshot: TonightLibrarySnapshot) async { library = snapshot }
}
