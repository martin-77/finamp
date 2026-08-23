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

    static let empty = FinampWidgetState(
        itemID: nil,
        title: "Finamp",
        artist: "",
        album: "",
        isPlaying: false,
        showStarRatings: false,
        isFavorite: false,
        starRating: nil,
        coverRevision: 0
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
            recordDiagnosticRead(
                state: .empty,
                coverExists: false,
                source: source
            )
            NSLog(
                "[FINAMP-WIDGET-DIAG] extension load source=%@ state=empty",
                source
            )
            return .empty
        }

        let coverExists: Bool
        if let itemID = state.itemID, let container = FinampWidgetShared.containerURL {
            let coverURL = container
                .appendingPathComponent("\(FinampWidgetShared.coverFileName)-\(itemID)")
                .appendingPathExtension("jpg")
            coverExists = FileManager.default.fileExists(atPath: coverURL.path)
        } else {
            coverExists = false
        }

        recordDiagnosticRead(
            state: state,
            coverExists: coverExists,
            source: source
        )
        NSLog(
            "[FINAMP-WIDGET-DIAG] extension load source=%@ item=%@ title=%@ playing=%@ revision=%d coverExists=%@",
            source,
            state.itemID ?? "nil",
            state.title,
            String(state.isPlaying),
            state.coverRevision,
            String(coverExists)
        )

        return state
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

    private static func recordDiagnosticRead(
        state: FinampWidgetState,
        coverExists: Bool,
        source: String
    ) {
        guard let url = FinampWidgetShared.diagnosticReadURL else { return }

        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "source": source,
            "itemID": state.itemID as Any,
            "title": state.title,
            "isPlaying": state.isPlaying,
            "coverRevision": state.coverRevision,
            "coverExists": coverExists
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
