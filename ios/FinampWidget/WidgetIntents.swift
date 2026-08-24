import AppIntents
import Foundation
import WidgetKit

enum FinampWidgetAction: String, Codable, Sendable {
    case togglePlayback
    case previous
    case next
    case toggleFavorite
    case setRating
    case clearRating
}

enum FinampWidgetActionDispatcher {
    @MainActor
    static var handler: ((FinampWidgetAction, Double?) async throws -> Void)?

    @MainActor
    static func perform(
        _ action: FinampWidgetAction,
        rating: Double? = nil,
        visibleSource: String? = nil
    ) async throws {
        recordVisibleActionSource(visibleSource, action: action)

        guard let handler else {
            throw NSError(
                domain: "FinampWidget",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Widget action handler is unavailable"
                ]
            )
        }

        // The handler returns only after Finamp has completed the action and
        // persisted one final coherent shared-state snapshot. Reload exactly
        // once afterwards so WidgetKit cannot keep rendering the previous
        // timeline when no later artwork/state event happens to trigger one.
        try await handler(action, rating)
        WidgetCenter.shared.reloadTimelines(ofKind: FinampWidgetShared.kind)
    }

    private static func recordVisibleActionSource(
        _ source: String?,
        action: FinampWidgetAction
    ) {
        guard let source, !source.isEmpty else { return }

        let fields = source.split(separator: ";").reduce(
            into: [String: String]()
        ) { result, component in
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            result[String(parts[0])] = String(parts[1])
        }

        let itemID = fields["i"].flatMap { $0 == "-" ? nil : $0 }
        let state = FinampWidgetState(
            itemID: itemID,
            title: "<visible-widget-source>",
            artist: "",
            album: "",
            isPlaying: fields["p"] == "1",
            showStarRatings: false,
            isFavorite: false,
            starRating: nil,
            coverRevision: Int(fields["r"] ?? "") ?? 0,
            diagnosticTrackSequence: Int(fields["t"] ?? ""),
            diagnosticStateSequence: Int(fields["s"] ?? "")
        )
        let coverDecode = fields["d"]

        FinampWidgetDiagnostics.record(
            event: "VISIBLE_ACTION_SOURCE",
            state: state,
            generationID: fields["g"],
            origin: "visible",
            coverExists: coverDecode == "ok" || coverDecode == "failed",
            coverDecode: coverDecode,
            note: action.rawValue
        )
    }
}

@available(iOS 17.0, *)
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"

    @Parameter(title: "Widget Source")
    var diagnosticSource: String?

    init() {
        diagnosticSource = nil
    }

    init(diagnosticSource: String) {
        self.diagnosticSource = diagnosticSource
    }

    func perform() async throws -> some IntentResult {
        try await FinampWidgetActionDispatcher.perform(
            .togglePlayback,
            visibleSource: diagnosticSource
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"

    @Parameter(title: "Widget Source")
    var diagnosticSource: String?

    init() {
        diagnosticSource = nil
    }

    init(diagnosticSource: String) {
        self.diagnosticSource = diagnosticSource
    }

    func perform() async throws -> some IntentResult {
        try await FinampWidgetActionDispatcher.perform(
            .previous,
            visibleSource: diagnosticSource
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"

    @Parameter(title: "Widget Source")
    var diagnosticSource: String?

    init() {
        diagnosticSource = nil
    }

    init(diagnosticSource: String) {
        self.diagnosticSource = diagnosticSource
    }

    func perform() async throws -> some IntentResult {
        try await FinampWidgetActionDispatcher.perform(
            .next,
            visibleSource: diagnosticSource
        )
        return .result()
    }
}

// iOS 27 introduces explicit process targeting for App Intents.
// Metadata writes stay in Finamp's main process so the widget extension never
// owns Jellyfin credentials or a second network stack.
@available(iOS 27.0, *)
struct ToggleFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Favorite"
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Widget Source")
    var diagnosticSource: String?

    init() {
        diagnosticSource = nil
    }

    init(diagnosticSource: String) {
        self.diagnosticSource = diagnosticSource
    }

    func perform() async throws -> some IntentResult {
        try await FinampWidgetActionDispatcher.perform(
            .toggleFavorite,
            visibleSource: diagnosticSource
        )
        return .result()
    }
}

@available(iOS 27.0, *)
struct SetStarRatingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Rating"
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Stars")
    var stars: Double

    @Parameter(title: "Widget Source")
    var diagnosticSource: String?

    init() {
        diagnosticSource = nil
    }

    init(stars: Double) {
        self.stars = stars
        diagnosticSource = nil
    }

    init(stars: Double, diagnosticSource: String) {
        self.stars = stars
        self.diagnosticSource = diagnosticSource
    }

    func perform() async throws -> some IntentResult {
        guard (1...5).contains(stars) else {
            throw NSError(
                domain: "FinampWidget",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Rating must be between 1 and 5 stars"]
            )
        }
        try await FinampWidgetActionDispatcher.perform(
            .setRating,
            rating: stars,
            visibleSource: diagnosticSource
        )
        return .result()
    }
}

@available(iOS 27.0, *)
struct ClearStarRatingIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Rating"
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Widget Source")
    var diagnosticSource: String?

    init() {
        diagnosticSource = nil
    }

    init(diagnosticSource: String) {
        self.diagnosticSource = diagnosticSource
    }

    func perform() async throws -> some IntentResult {
        try await FinampWidgetActionDispatcher.perform(
            .clearRating,
            visibleSource: diagnosticSource
        )
        return .result()
    }
}
