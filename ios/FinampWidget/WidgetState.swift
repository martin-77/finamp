import Foundation

enum FinampWidgetShared {
    static let kind = "FinampNowPlayingWidget"
    static let stateFileName = "now-playing-state.json"
    static let coverFileName = "now-playing-cover"
    static let diagnosticReadFileName = "widget-last-read.json"

    static var appGroupIdentifier: String {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "FinampWidgetAppGroup") as? String,
            !value.isEmpty
        else {
            preconditionFailure("FinampWidgetAppGroup is missing from the widget extension Info.plist")
        }
        return value
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static var stateURL: URL? {
        containerURL?.appendingPathComponent(stateFileName)
    }

    static var diagnosticReadURL: URL? {
        containerURL?.appendingPathComponent(diagnosticReadFileName)
    }
}

struct FinampWidgetState: Codable, Equatable {
    var itemID: String?
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var showStarRatings: Bool
    var isFavorite: Bool
    var starRating: Double?
    var coverRevision: Int
    var diagnosticTrackSequence: Int?

    static let empty = FinampWidgetState(
        itemID: nil,
        title: "Finamp",
        artist: "",
        album: "",
        isPlaying: false,
        showStarRatings: false,
        isFavorite: false,
        starRating: nil,
        coverRevision: 0,
        diagnosticTrackSequence: nil
    )

    static func load(source: String = "unknown") -> FinampWidgetState {
        guard
            let stateURL = FinampWidgetShared.stateURL,
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(
                FinampWidgetState.self,
                from: data
            )
        else {
            recordDiagnostic(
                state: .empty,
                source: source,
                coverExists: false
            )
            NSLog(
                "[FINAMP-WIDGET-DIAG] extension load source=%@ state=empty",
                source
            )
            return .empty
        }

        let coverExists = coverExists(for: state)

        recordDiagnostic(
            state: state,
            source: source,
            coverExists: coverExists
        )
        NSLog(
            "[FINAMP-WIDGET-DIAG] extension load source=%@ item=%@ title=%@ artist=%@ album=%@ playing=%@ revision=%d trackSeq=%@ coverExists=%@",
            source,
            state.itemID ?? "nil",
            state.title,
            state.artist,
            state.album,
            String(state.isPlaying),
            state.coverRevision,
            String(describing: state.diagnosticTrackSequence),
            String(coverExists)
        )

        return state
    }

    static func recordDiagnostic(
        state: FinampWidgetState,
        source: String,
        coverExists explicitCoverExists: Bool? = nil
    ) {
        guard let url = FinampWidgetShared.diagnosticReadURL else { return }

        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "source": source,
            "itemID": state.itemID as Any,
            "title": state.title,
            "artist": state.artist,
            "album": state.album,
            "isPlaying": state.isPlaying,
            "coverRevision": state.coverRevision,
            "trackSequence": state.diagnosticTrackSequence as Any,
            "coverExists": explicitCoverExists ?? coverExists(for: state)
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    func save() throws {
        guard let stateURL = FinampWidgetShared.stateURL else {
            throw NSError(
                domain: "FinampWidget",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve widget state destination"]
            )
        }

        let data = try JSONEncoder().encode(self)
        try data.write(to: stateURL, options: .atomic)
    }

    private static func coverExists(for state: FinampWidgetState) -> Bool {
        guard
            let itemID = state.itemID,
            let container = FinampWidgetShared.containerURL
        else {
            return false
        }

        let coverURL = container
            .appendingPathComponent("\(FinampWidgetShared.coverFileName)-\(itemID)")
            .appendingPathExtension("jpg")
        return FileManager.default.fileExists(atPath: coverURL.path)
    }
}
