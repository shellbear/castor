import Testing
@testable import CastorEngine

@Suite struct ByteRangeTests {
    let size = 1000

    @Test func noHeaderMeansFullFile() {
        #expect(ByteRangeParse.parse(header: nil, fileSize: size) == .none)
    }

    @Test func boundedRange() {
        #expect(ByteRangeParse.parse(header: "bytes=0-499", fileSize: size) == .partial(0..<500))
    }

    @Test func openEndedRange() {
        #expect(ByteRangeParse.parse(header: "bytes=500-", fileSize: size) == .partial(500..<1000))
    }

    @Test func suffixRange() {
        #expect(ByteRangeParse.parse(header: "bytes=-100", fileSize: size) == .partial(900..<1000))
    }

    @Test func endClampedToFileSize() {
        #expect(ByteRangeParse.parse(header: "bytes=900-4999", fileSize: size) == .partial(900..<1000))
    }

    @Test func startBeyondEOFIsInvalid() {
        #expect(ByteRangeParse.parse(header: "bytes=1000-", fileSize: size) == .invalid)
    }

    @Test func malformedHeadersAreInvalid() {
        #expect(ByteRangeParse.parse(header: "bytes=", fileSize: size) == .invalid)
        #expect(ByteRangeParse.parse(header: "items=0-5", fileSize: size) == .invalid)
        #expect(ByteRangeParse.parse(header: "bytes=abc-def", fileSize: size) == .invalid)
        #expect(ByteRangeParse.parse(header: "bytes=500-100", fileSize: size) == .invalid)
    }

    @Test func firstRangeOfMultipleWins() {
        #expect(ByteRangeParse.parse(header: "bytes=0-99,200-299", fileSize: size) == .partial(0..<100))
    }
}
