import Testing
@testable import BCTaskCore

/// Uniquely named discovery canary. `scripts/test.sh` refuses to report
/// success unless Swift Testing actually discovered and ran this test.
@Suite("Discovery canary")
struct DiscoveryCanaryTests {
    @Test func swiftTestingDiscoveryCanaryRunsMustAppearInSummary() {
        #expect(true)
    }
}
