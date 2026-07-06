import Foundation
import Network

public struct CastDevice: Identifiable, Sendable, Hashable {
    public let id: String
    /// Friendly name from the TXT record ("Living Room TV").
    public let name: String
    /// Model from the TXT record ("Chromecast Ultra", "Chromecast with Google TV").
    public let model: String?
    let endpoint: NWEndpoint

    public var capabilities: DeviceCapabilities {
        var caps = DeviceCapabilities.chromecast(model: model)
        caps.displayName = name
        return caps
    }
}

/// Bonjour discovery of Cast devices (`_googlecast._tcp`).
public enum CastDiscovery {
    public static func devices() -> AsyncStream<[CastDevice]> {
        AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil),
                using: parameters
            )
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(mapResults(results))
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                browser.cancel()
            }
            browser.start(queue: DispatchQueue(label: "castor.cast.discovery"))
        }
    }

    private static func mapResults(_ results: Set<NWBrowser.Result>) -> [CastDevice] {
        results.compactMap { result -> CastDevice? in
            guard case let .service(serviceName, _, _, _) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                txt = record.dictionary
            }
            return CastDevice(
                id: txt["id"] ?? serviceName,
                name: txt["fn"] ?? serviceName,
                model: txt["md"],
                endpoint: result.endpoint
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
