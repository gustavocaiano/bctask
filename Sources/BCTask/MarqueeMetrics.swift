import Foundation

/// Pure geometry for a menu-bar ticker (see `MarqueeLabelView`): whether a
/// title scrolls inside its fixed-width viewport, where it rests, and how far
/// and how long one seamless loop runs.
struct MarqueeMetrics: Equatable {
    /// Clear space kept between the text and each end of the ticker.
    static let horizontalInset: CGFloat = 6
    /// Blank run between the end of the title and its looping copy.
    static let loopGap: CGFloat = 40
    /// Scroll speed: slow enough to read a moving title.
    static let pointsPerSecond: CGFloat = 30
    /// Pause at the start of every loop, so the title's beginning stays readable.
    static let restDuration: TimeInterval = 1.5

    let viewportWidth: CGFloat
    let textWidth: CGFloat

    /// Only a title wider than its viewport moves; one that fits sits still.
    var scrolls: Bool { textWidth > viewportWidth }

    /// Resting x of the title inside the viewport: centered when it fits,
    /// flush with the leading edge when it scrolls.
    var restingX: CGFloat {
        scrolls ? 0 : ((viewportWidth - textWidth) / 2).rounded(.down)
    }

    /// One loop carries the trailing copy exactly onto the title's resting
    /// spot, so the restart is invisible.
    var loopDistance: CGFloat { scrolls ? textWidth + Self.loopGap : 0 }

    /// Rest plus travel at `pointsPerSecond`; zero when the title sits still.
    var loopDuration: TimeInterval {
        scrolls ? Self.restDuration + TimeInterval(loopDistance / Self.pointsPerSecond) : 0
    }
}
