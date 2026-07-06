import Foundation

/// RFC 7233 single-range parsing — the subset media players actually send.
public enum ByteRangeParse: Sendable, Equatable {
    case none
    case invalid
    case partial(Range<Int>)

    public static func parse(header: String?, fileSize: Int) -> ByteRangeParse {
        guard let header else { return .none }
        guard fileSize > 0, header.hasPrefix("bytes=") else { return .invalid }

        // Players send single ranges; if multiple are present serve the first.
        guard let spec = header.dropFirst("bytes=".count).split(separator: ",").first else {
            return .invalid
        }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .invalid }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // Suffix form: "bytes=-N" → final N bytes.
            guard let suffixLength = Int(endText), suffixLength > 0 else { return .invalid }
            return .partial(max(0, fileSize - suffixLength)..<fileSize)
        }

        guard let start = Int(startText), start >= 0, start < fileSize else { return .invalid }
        if endText.isEmpty {
            return .partial(start..<fileSize)
        }
        guard let end = Int(endText), end >= start else { return .invalid }
        return .partial(start..<min(end + 1, fileSize))
    }
}
