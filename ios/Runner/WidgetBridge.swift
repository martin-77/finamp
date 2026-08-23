import Flutter
import Foundation
import WidgetKit

extension AppDelegate {
    func setupWidgetChannel() {
        let channel = FlutterMethodChannel(
            name: "finamp/ios_widget",
            binaryMessenger: flutterEngine.binaryMessenger
        )

        FinampWidgetActionDispatcher.handler = { action, rating in
            let arguments: [String: Any] = [
                "action": action.rawValue,
                "rating": rating as Any
            ]

            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in

                channel.invokeMethod(
                    "performAction",
                    arguments: arguments
                ) { result in
                    if let error = result as? FlutterError {
                        continuation.resume(
                            throwing: NSError(
                                domain: "FinampWidget",
                                code: 1,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        error.message ?? error.code
                                ]
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "updateState":
                guard let arguments = call.arguments as? [String: Any] else {
                    result(FlutterError(
                        code: "INVALID_ARGS",
                        message: "Widget state must be a dictionary",
                        details: nil
                    ))
                    return
                }

                do {
                    try FinampWidgetStateWriter.writeState(arguments)
                    result(nil)
                } catch {
                    result(FlutterError(
                        code: "WIDGET_STATE_WRITE_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }

            case "updateArtwork":
                guard
                    let arguments = call.arguments as? [String: Any],
                    let itemID = arguments["itemID"] as? String,
                    let typedData = arguments["bytes"] as? FlutterStandardTypedData
                else {
                    result(FlutterError(
                        code: "INVALID_ARTWORK_ARGS",
                        message: "Widget artwork requires itemID and bytes",
                        details: nil
                    ))
                    return
                }

                do {
                    try FinampWidgetStateWriter.writeArtwork(
                        typedData.data,
                        itemID: itemID
                    )
                    result(nil)
                } catch {
                    result(FlutterError(
                        code: "WIDGET_ARTWORK_WRITE_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

private enum FinampWidgetStateWriter {
    private static var appGroup: String {
        "group.\(Bundle.main.bundleIdentifier ?? "com.unicornsonlsd.finamp-ios").widget"
    }

    static func writeState(_ arguments: [String: Any]) throws {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            throw NSError(
                domain: "FinampWidget",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open app-group defaults"]
            )
        }

        let decoder = JSONDecoder()
        let oldState: FinampWidgetState
        if let existing = defaults.data(forKey: FinampWidgetShared.stateKey),
           let decoded = try? decoder.decode(FinampWidgetState.self, from: existing) {
            oldState = decoded
        } else {
            oldState = .empty
        }

        var state = oldState
        state.itemID = arguments["itemID"] as? String
        state.title = arguments["title"] as? String ?? "Finamp"
        state.artist = arguments["artist"] as? String ?? ""
        state.album = arguments["album"] as? String ?? ""
        state.isPlaying = arguments["isPlaying"] as? Bool ?? false
        state.showStarRatings = arguments["showStarRatings"] as? Bool ?? false
        state.isFavorite = arguments["isFavorite"] as? Bool ?? false
        state.starRating = (arguments["starRating"] as? NSNumber)?.doubleValue

        if oldState.itemID != state.itemID, let oldID = oldState.itemID {
            removeCover(itemID: oldID)
        }

        try save(state, to: defaults)
        reloadWidget()
    }

    static func writeArtwork(_ data: Data, itemID: String) throws {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            throw NSError(
                domain: "FinampWidget",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open app-group defaults"]
            )
        }

        guard
            let existing = defaults.data(forKey: FinampWidgetShared.stateKey),
            var state = try? JSONDecoder().decode(FinampWidgetState.self, from: existing),
            state.itemID == itemID
        else {
            return
        }

        guard let destination = coverURL(itemID: itemID) else {
            throw NSError(
                domain: "FinampWidget",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve widget artwork destination"]
            )
        }

        if let existingData = try? Data(contentsOf: destination),
           existingData == data {
            return
        }

        try data.write(to: destination, options: .atomic)
        state.coverRevision &+= 1
        try save(state, to: defaults)
        reloadWidget()
    }

    private static func save(
        _ state: FinampWidgetState,
        to defaults: UserDefaults
    ) throws {
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: FinampWidgetShared.stateKey)
    }

    private static func reloadWidget() {
        // WidgetKit reloads an interactive widget after AppIntent.perform()
        // returns. Keep explicit app-driven updates too, but don't enqueue the
        // reload for later: callers must only return once the shared state and
        // its matching timeline invalidation have both been submitted.
        WidgetCenter.shared.reloadTimelines(ofKind: FinampWidgetShared.kind)
    }

    private static func coverURL(itemID: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("\(FinampWidgetShared.coverFileName)-\(itemID)")
            .appendingPathExtension("jpg")
    }

    private static func removeCover(itemID: String) {
        guard let url = coverURL(itemID: itemID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
