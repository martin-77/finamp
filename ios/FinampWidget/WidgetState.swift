import Foundation

enum FinampWidgetShared {
    static let kind = "FinampNowPlayingWidget"
    static let stateKey = "finamp.widget.state.v1"
    static let coverFileName = "now-playing-cover"

    static var appGroupIdentifier: String {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "FinampWidgetAppGroup") as? String,
            !value.isEmpty
        else {
            preconditionFailure("FinampWidgetAppGroup is missing from the widget extension Info.plist")
        }
        return value
    }

    static var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            preconditionFailure("Unable to open Finamp widget app-group defaults")
        }
        return defaults
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
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

    static func load() -> FinampWidgetState {
        guard
            let data = FinampWidgetShared.defaults.data(
                forKey: FinampWidgetShared.stateKey
            ),
            let state = try? JSONDecoder().decode(
                FinampWidgetState.self,
                from: data
            )
        else {
            return .empty
        }

        return state
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        FinampWidgetShared.defaults.set(data, forKey: FinampWidgetShared.stateKey)
    }
}
