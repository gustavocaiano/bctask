import Testing
import AppKit
@testable import BCTask

@MainActor
@Suite("Pinned card placement")
struct PinnedPanelPlacementTests {
    /// Visible frames below a 24 pt menu bar, side by side.
    private let primary = NSRect(x: 0, y: 0, width: 1_440, height: 876)
    private let secondary = NSRect(x: 1_440, y: 0, width: 1_440, height: 876)
    /// A card's frame: the ideal content plus its title bar.
    private let panelSize = CGSize(width: 320, height: 258)

    @Test func cardDropsCenteredJustBelowItsTicker() {
        let ticker = NSRect(x: 900, y: 876, width: 160, height: 24)

        let origin = StatusItemPanelsController.pinnedCardOrigin(below: ticker, panelSize: panelSize, visibleFrame: primary)

        #expect(origin == NSPoint(x: 820, y: 876 - StatusItemPanelsController.pinnedCardGap - 258))
    }

    @Test func cardOfATickerNearTheScreenEdgeStaysOnScreen() {
        let ticker = NSRect(x: 1_270, y: 876, width: 160, height: 24)

        let origin = StatusItemPanelsController.pinnedCardOrigin(below: ticker, panelSize: panelSize, visibleFrame: primary)

        #expect(origin.x == 1_440 - 320)
        #expect(primary.contains(NSRect(origin: origin, size: panelSize)))
    }

    @Test func cardFollowsItsTickerOntoASecondScreen() {
        let ticker = NSRect(x: 2_500, y: 876, width: 160, height: 24)

        let origin = StatusItemPanelsController.pinnedCardOrigin(below: ticker, panelSize: panelSize, visibleFrame: secondary)

        #expect(origin.x == 2_420)
        #expect(secondary.contains(NSRect(origin: origin, size: panelSize)))
    }
}
