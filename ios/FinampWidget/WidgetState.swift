import Darwin
import Foundation
import UIKit

enum FinampWidgetShared {
    static let kind = "FinampNowPlayingWidget"
    static let stateFileName = "now-playing-state.json"
    static let coverFileName = "now-playing-cover"
    static let diagnosticReadFileName = "widget-last-read.json"
    static let diagnosticTraceFileName = "widget-trace.json"
    static let diagnosticTraceLockFileName = "widget-trace.lock"

    static var appGroupIdentifier: String {
        if
            let value = Bundle.main.object(forInfoDictionaryKey: "FinampWidgetAppGroup") as? String,
            !value.isEmpty
        {
            return value
        }

        let fallbackBundleID = Bundle.main.bundleIdentifier
            ?? "com.unicornsonlsd.finamp-ios"
        return "group.\(fallbackBundleID).widget"
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

    static var diagnosticTraceURL: URL? {
        containerURL?.appendingPathComponent(diagnosticTraceFileName)
    }

    static var diagnosticTraceLockURL: URL? {
        containerURL?.appendingPathComponent(diagnosticTraceLockFileName)
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
    var diagnosticStateSequence: Int?

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
        diagnosticTrackSequence: nil,
        diagnosticStateSequence: nil
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

        let coverExists = diagnosticCoverExists(for: state)

        recordDiagnostic(
            state: state,
            source: source,
            coverExists: coverExists
        )
        NSLog(
            "[FINAMP-WIDGET-DIAG] extension load source=%@ item=%@ title=%@ artist=%@ album=%@ playing=%@ revision=%d trackSeq=%@ stateSeq=%@ coverExists=%@",
            source,
            state.itemID ?? "nil",
            state.title,
            state.artist,
            state.album,
            String(state.isPlaying),
            state.coverRevision,
            String(describing: state.diagnosticTrackSequence),
            String(describing: state.diagnosticStateSequence),
            String(coverExists)
        )

        return state
    }

    static func recordDiagnostic(
        state: FinampWidgetState,
        source: String,
        coverExists explicitCoverExists: Bool? = nil
    ) {
        FinampWidgetDiagnostics.recordExtensionSource(
            source,
            state: state,
            coverExists: explicitCoverExists
        )
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

    static func diagnosticCoverExists(for state: FinampWidgetState) -> Bool {
        diagnosticCoverURL(for: state).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }

    static func diagnosticCoverDecodeStatus(for state: FinampWidgetState) -> String {
        guard let coverURL = diagnosticCoverURL(for: state) else {
            return "missing"
        }
        guard FileManager.default.fileExists(atPath: coverURL.path) else {
            return "missing"
        }
        return UIImage(contentsOfFile: coverURL.path) == nil ? "failed" : "ok"
    }

    private static func diagnosticCoverURL(for state: FinampWidgetState) -> URL? {
        guard
            let itemID = state.itemID,
            let container = FinampWidgetShared.containerURL
        else {
            return nil
        }

        return container
            .appendingPathComponent("\(FinampWidgetShared.coverFileName)-\(itemID)")
            .appendingPathExtension("jpg")
    }
}

private struct FinampWidgetDiagnosticTrace: Codable {
    var nextSequence: Int
    var events: [FinampWidgetDiagnosticEvent]

    static let empty = FinampWidgetDiagnosticTrace(
        nextSequence: 1,
        events: []
    )
}

private struct FinampWidgetDiagnosticEvent: Codable {
    let sequence: Int
    let timestamp: TimeInterval
    let event: String
    let generationID: String?
    let origin: String?
    let itemID: String?
    let isPlaying: Bool
    let coverRevision: Int
    let trackSequence: Int?
    let stateSequence: Int?
    let coverExists: Bool
    let coverDecode: String?
    let note: String?
}

private struct FinampWidgetDiagnosticMarker: Codable {
    let timestamp: TimeInterval
    let source: String
    let eventSequence: Int
    let event: String
    let generationID: String?
    let origin: String?
    let itemID: String?
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let coverRevision: Int
    let trackSequence: Int?
    let stateSequence: Int?
    let coverExists: Bool
    let coverDecode: String?
}

enum FinampWidgetDiagnostics {
    private static let maxEvents = 300
    private static let markerTraceEventCount = 24

    static func recordExtensionSource(
        _ source: String,
        state: FinampWidgetState,
        coverExists: Bool? = nil
    ) {
        let parsed = parseExtensionSource(source)
        let coverDecode = parsed.event == "ROOT_INIT"
            ? FinampWidgetState.diagnosticCoverDecodeStatus(for: state)
            : nil

        record(
            event: parsed.event,
            state: state,
            generationID: parsed.generationID,
            origin: parsed.origin,
            coverExists: coverExists,
            coverDecode: coverDecode,
            note: parsed.note
        )
    }

    static func record(
        event: String,
        state: FinampWidgetState,
        generationID: String? = nil,
        origin: String? = nil,
        coverExists explicitCoverExists: Bool? = nil,
        coverDecode explicitCoverDecode: String? = nil,
        note: String? = nil
    ) {
        guard
            let traceURL = FinampWidgetShared.diagnosticTraceURL,
            let markerURL = FinampWidgetShared.diagnosticReadURL
        else {
            return
        }

        withTraceLock {
            var trace = loadTrace(from: traceURL)
            if let lastSequence = trace.events.last?.sequence,
               trace.nextSequence <= lastSequence {
                trace.nextSequence = lastSequence + 1
            }

            let resolvedOrigin = origin ?? resolveOrigin(
                generationID: generationID,
                events: trace.events
            )
            let coverExists = explicitCoverExists
                ?? FinampWidgetState.diagnosticCoverExists(for: state)
            let diagnosticEvent = FinampWidgetDiagnosticEvent(
                sequence: trace.nextSequence,
                timestamp: Date().timeIntervalSince1970,
                event: event,
                generationID: generationID,
                origin: resolvedOrigin,
                itemID: state.itemID,
                isPlaying: state.isPlaying,
                coverRevision: state.coverRevision,
                trackSequence: state.diagnosticTrackSequence,
                stateSequence: state.diagnosticStateSequence,
                coverExists: coverExists,
                coverDecode: explicitCoverDecode,
                note: note
            )

            trace.nextSequence += 1
            trace.events.append(diagnosticEvent)
            if trace.events.count > maxEvents {
                trace.events.removeFirst(trace.events.count - maxEvents)
            }

            guard let traceData = try? JSONEncoder().encode(trace) else {
                return
            }
            try? traceData.write(to: traceURL, options: .atomic)

            let compactTrace = trace.events
                .suffix(markerTraceEventCount)
                .map(compactEvent)
                .joined(separator: " | ")
            let marker = FinampWidgetDiagnosticMarker(
                timestamp: diagnosticEvent.timestamp,
                source: "seq=\(diagnosticEvent.sequence) event=\(diagnosticEvent.event) trace=\(compactTrace)",
                eventSequence: diagnosticEvent.sequence,
                event: diagnosticEvent.event,
                generationID: diagnosticEvent.generationID,
                origin: diagnosticEvent.origin,
                itemID: state.itemID,
                title: state.title,
                artist: state.artist,
                album: state.album,
                isPlaying: state.isPlaying,
                coverRevision: state.coverRevision,
                trackSequence: state.diagnosticTrackSequence,
                stateSequence: state.diagnosticStateSequence,
                coverExists: diagnosticEvent.coverExists,
                coverDecode: diagnosticEvent.coverDecode
            )

            guard let markerData = try? JSONEncoder().encode(marker) else {
                return
            }
            try? markerData.write(to: markerURL, options: .atomic)
        }
    }

    private static func parseExtensionSource(
        _ source: String
    ) -> (event: String, generationID: String?, origin: String?, note: String?) {
        if source.hasPrefix("timeline:") {
            return (
                "TIMELINE",
                String(source.dropFirst("timeline:".count)),
                "timeline",
                nil
            )
        }
        if source.hasPrefix("snapshot:") {
            return (
                "SNAPSHOT",
                String(source.dropFirst("snapshot:".count)),
                "snapshot",
                nil
            )
        }
        if source.hasPrefix("render:") {
            return (
                "ROOT_INIT",
                String(source.dropFirst("render:".count)),
                nil,
                nil
            )
        }
        return ("EXTENSION_READ", nil, nil, source)
    }

    private static func resolveOrigin(
        generationID: String?,
        events: [FinampWidgetDiagnosticEvent]
    ) -> String? {
        guard let generationID else { return nil }

        return events.reversed().first {
            $0.generationID == generationID &&
                ($0.event == "TIMELINE" || $0.event == "SNAPSHOT")
        }?.origin
    }

    private static func loadTrace(from url: URL) -> FinampWidgetDiagnosticTrace {
        guard
            let data = try? Data(contentsOf: url),
            let trace = try? JSONDecoder().decode(
                FinampWidgetDiagnosticTrace.self,
                from: data
            )
        else {
            return .empty
        }
        return trace
    }

    private static func compactEvent(_ event: FinampWidgetDiagnosticEvent) -> String {
        var parts = ["#\(event.sequence)", event.event]
        if let stateSequence = event.stateSequence {
            parts.append("s=\(stateSequence)")
        }
        if let trackSequence = event.trackSequence {
            parts.append("t=\(trackSequence)")
        }
        if let itemID = event.itemID {
            parts.append("i=\(String(itemID.prefix(8)))")
        }
        parts.append("p=\(event.isPlaying ? 1 : 0)")
        parts.append("r=\(event.coverRevision)")
        parts.append("c=\(event.coverExists ? 1 : 0)")
        if let coverDecode = event.coverDecode {
            parts.append("d=\(coverDecode)")
        }
        if let generationID = event.generationID {
            parts.append("g=\(String(generationID.prefix(8)))")
        }
        if let origin = event.origin {
            parts.append("o=\(origin)")
        }
        if let note = event.note, !note.isEmpty {
            parts.append("n=\(sanitize(note))")
        }
        return parts.joined(separator: ",")
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: ",", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func withTraceLock(_ body: () -> Void) {
        guard let lockURL = FinampWidgetShared.diagnosticTraceLockURL else {
            body()
            return
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            body()
            return
        }

        _ = Darwin.lockf(descriptor, F_LOCK, 0)
        defer {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = Darwin.close(descriptor)
        }
        body()
    }
}
