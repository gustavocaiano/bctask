import Testing
import AppKit
@testable import BCTask

@MainActor
@Suite("Pinned panel placement")
struct PinnedPanelPlacementTests {
    private let primary = (frame: NSRect(x: 0, y: 0, width: 1_440, height: 900), visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 876))
    private let secondary = (frame: NSRect(x: 1_440, y: 0, width: 1_440, height: 900), visibleFrame: NSRect(x: 1_440, y: 0, width: 1_440, height: 876))
    private let panelSize = CGSize(width: 320, height: 230)

    @Test func livePinnedCardsChooseTheirOwnScreenAndExtendTheCascade() throws {
        let existing = NSRect(x: 2_400, y: 600, width: 320, height: 230)

        let origin = try #require(
            StatusItemPanelsController.anchoredPinnedPanelOrigin(
                existingFrames: [existing],
                savedAnchor: NSRect(x: 100, y: 600, width: 320, height: 230),
                panelSize: panelSize,
                screens: [primary, secondary]
            )
        )
        let frame = NSRect(origin: origin, size: panelSize)

        #expect(secondary.visibleFrame.contains(frame))
        #expect(!existing.intersects(frame), "a new card should not cover the live card it follows")
    }

    @Test func savedUserAnchorChoosesTheLastPinnedScreenWhenNoCardsAreOpen() throws {
        let savedAnchor = NSRect(x: 2_400, y: 600, width: 320, height: 230)

        let origin = try #require(
            StatusItemPanelsController.anchoredPinnedPanelOrigin(
                existingFrames: [],
                savedAnchor: savedAnchor,
                panelSize: panelSize,
                screens: [primary, secondary]
            )
        )

        #expect(origin == NSPoint(x: 2_376, y: 576))
    }

    @Test func disconnectedSavedAnchorFallsBackToTheLegacyPlacementPath() {
        let disconnectedAnchor = NSRect(x: 5_000, y: 600, width: 320, height: 230)

        #expect(
            StatusItemPanelsController.anchoredPinnedPanelOrigin(
                existingFrames: [],
                savedAnchor: disconnectedAnchor,
                panelSize: panelSize,
                screens: [primary, secondary]
            ) == nil
        )
    }

    @Test func userPlacementAnchorRoundTripsThroughDefaults() {
        let defaults = UserDefaults.standard
        let key = StatusItemPanelsController.pinnedPanelPlacementAnchorDefaultsKey
        let frame = NSRect(x: 1_900, y: 420, width: 320, height: 230)
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        StatusItemPanelsController.savePinnedPanelPlacementAnchor(frame, defaults: defaults)

        #expect(StatusItemPanelsController.pinnedPanelPlacementAnchor(defaults: defaults) == frame)
    }
}
