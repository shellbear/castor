import Testing
@testable import CastorEngine

@Test func versionIsSet() {
    #expect(!Castor.version.isEmpty)
}
