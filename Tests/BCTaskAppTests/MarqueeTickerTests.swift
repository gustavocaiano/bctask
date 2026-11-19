import Testing
import AppKit
@testable import BCTask

@Suite("Menu-bar ticker marquee")
struct MarqueeTickerTests {
    @Test func titleThatFitsSitsStillAndCentered() {
        let metrics = MarqueeMetrics(viewportWidth: 148, textWidth: 60)

        #expect(!metrics.scrolls)
        #expect(metrics.restingX == 44)
        #expect(metrics.loopDistance == 0)
        #expect(metrics.loopDuration == 0)
    }

    @Test func titleExactlyAsWideAsTheViewportSitsStill() {
        #expect(!MarqueeMetrics(viewportWidth: 148, textWidth: 148).scrolls)
    }

    @Test func overflowingTitleLoopsSeamlesslyFromItsLeadingEdge() {
        let metrics = MarqueeMetrics(viewportWidth: 148, textWidth: 320)

        #expect(metrics.scrolls)
        #expect(metrics.restingX == 0)
        // The trailing copy starts one title plus one gap later, so a loop of
        // exactly that distance lands it on the title's resting spot.
        #expect(metrics.loopDistance == 320 + MarqueeMetrics.loopGap)
        #expect(metrics.loopDuration == MarqueeMetrics.restDuration + 360 / Double(MarqueeMetrics.pointsPerSecond))
    }

    @Test @MainActor func labelScrollsOnlyWhileItsTextOverflows() {
        let label = MarqueeLabelView(
            frame: NSRect(x: 0, y: 0, width: StatusItemPanelsController.pinnedTickerWidth, height: 22)
        )

        label.text = "Ship it"
        #expect(!label.isScrollingForTesting)

        label.text = "Reply to every open review comment on the onboarding pull request"
        #expect(label.isScrollingForTesting)

        label.text = "Ship it"
        #expect(!label.isScrollingForTesting, "a title that fits again stops the loop")
    }

    @Test @MainActor func labelReadsLineBreaksAsSpaces() {
        let label = MarqueeLabelView(
            frame: NSRect(x: 0, y: 0, width: StatusItemPanelsController.pinnedTickerWidth, height: 22)
        )

        // Each line fits on its own; together they overflow, so the ticker
        // must scroll instead of clipping everything after the break.
        label.text = "Ship the notes"
        #expect(!label.isScrollingForTesting)
        label.text = "then tell the team"
        #expect(!label.isScrollingForTesting)

        label.text = "Ship the notes\nthen tell the team"
        #expect(label.isScrollingForTesting)
    }
}
