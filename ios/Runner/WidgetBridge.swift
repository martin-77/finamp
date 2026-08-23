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

                Task {
                    do {
                        try await FinampWidgetStateWriter.write(arguments)
                        result(nil)
                    } catch {
                        result(FlutterError(
                            code: "WIDGET_STATE_WRITE_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

private enum FinampWidgetStateWriter {
    static func write(_ arguments: [String: Any]) async throws {
        let appGroup = "group.\(Bundle.main.bundleIdentifier ?? "com.unicornsonlsd.finamp-ios").widget"
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
            removeCover(itemID: oldID, appGroup: appGroup)
        }

        if let itemID = state.itemID,
           let artURIString = arguments["artURI"] as? String,
           let artURL = URL(string: artURIString) {
            let changed = try await persistCover(
                from: artURL,
                itemID: itemID,
                appGroup: appGroup
            )
            if changed {
                state.coverRevision &+= 1
            }
        }

        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: FinampWidgetShared.stateKey)


        await MainActor.run {
            WidgetCenter.shared.reloadTimelines(ofKind: FinampWidgetShared.kind)
        }
    }

    private static func coverURL(itemID: String, appGroup: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("\(FinampWidgetShared.coverFileName)-\(itemID)")
            .appendingPathExtension("jpg")
    }

    private static func removeCover(itemID: String, appGroup: String) {
        guard let url = coverURL(itemID: itemID, appGroup: appGroup) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func persistCover(
        from sourceURL: URL,
        itemID: String,
        appGroup: String
    ) async throws -> Bool {
        guard let destination = coverURL(itemID: itemID, appGroup: appGroup) else {
            return false
        }

        let data: Data
        if sourceURL.isFileURL {
            data = try Data(contentsOf: sourceURL)
        } else {
            var request = URLRequest(url: sourceURL)
            request.cachePolicy = .returnCacheDataElseLoad
            let (downloadedData, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw NSError(
                    domain: "FinampWidget",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Cover request failed"]
                )
            }
            data = downloadedData
        }

        if let existingData = try? Data(contentsOf: destination),
           existingData == data {
            return false
        }

        try data.write(to: destination, options: .atomic)
        return true
    }
}
