import Testing

/// Uniquely named discovery canary for the app-model test target —
/// `scripts/test.sh` refuses success unless this too actually ran.
@Suite("App-model discovery canary")
struct AppModelCanaryTests {
    @Test func swiftTestingAppModelDiscoveryCanary() {
        #expect(true)
    }
}
