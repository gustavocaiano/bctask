import AppKit
import QuartzCore

/// Text of a pinned task's menu-bar ticker: a fixed-width label that sits
/// still when its title fits and otherwise scrolls it right to left in a
/// seamless loop, like an LED sign. Core Animation runs the loop in the
/// render server, so the app does not wake up for every frame.
///
/// Layer-hosting on purpose: the view owns its layer tree, so AppKit never
/// resets the scrolling layer underneath the running animation.
final class MarqueeLabelView: NSView {
    private static let loopAnimationKey = "BCTaskMarqueeLoop"

    var text = "" {
        didSet {
            if text != oldValue { relayout(force: true) }
        }
    }

    private struct AppliedLayout: Equatable {
        let metrics: MarqueeMetrics
        let size: CGSize
        let scale: CGFloat
    }

    private let font = NSFont.menuBarFont(ofSize: 0)
    private let viewport = CALayer()
    private let strip = CALayer()
    private let title = CATextLayer()
    private let loopCopy = CATextLayer()
    /// Geometry the current loop was built for; an unchanged layout pass
    /// leaves the running loop alone instead of restarting it.
    private var applied: AppliedLayout?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Assigning the layer before enabling layers makes this view
        // layer-hosting.
        layer = CALayer()
        wantsLayer = true
        viewport.masksToBounds = true
        layer?.addSublayer(viewport)
        viewport.addSublayer(strip)
        for textLayer in [title, loopCopy] {
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .none
            textLayer.isWrapped = false
            strip.addSublayer(textLayer)
        }
        relayout(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Clicks belong to the status-bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(force: false)
    }

    /// A new window can bring a new backing scale, and the loop is re-added
    /// in case the layer tree was detached on the way.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout(force: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout(force: false)
    }

    /// The menu bar turns light or dark with the wallpaper and the system
    /// appearance, independently of the app's own dark surfaces.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTextColor()
    }

    var isScrollingForTesting: Bool {
        strip.animation(forKey: Self.loopAnimationKey) != nil
    }

    private func relayout(force: Bool) {
        let inset = MarqueeMetrics.horizontalInset
        // A title can carry line breaks (pasted, or edited outside the app);
        // the ticker has room for one line, so they read as spaces.
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let textWidth = line.isEmpty
            ? 0
            : ceil((line as NSString).size(withAttributes: [.font: font]).width) + 1
        let metrics = MarqueeMetrics(
            viewportWidth: max(0, bounds.width - 2 * inset),
            textWidth: textWidth
        )
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let layout = AppliedLayout(metrics: metrics, size: bounds.size, scale: scale)
        guard force || layout != applied else { return }
        applied = layout

        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineY = ((bounds.height - lineHeight) / 2).rounded()

        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit fades between layouts
        viewport.frame = CGRect(x: inset, y: 0, width: metrics.viewportWidth, height: bounds.height)
        strip.frame = CGRect(
            x: 0,
            y: 0,
            width: metrics.restingX + metrics.loopDistance + textWidth,
            height: bounds.height
        )
        for (textLayer, x) in [(title, metrics.restingX), (loopCopy, metrics.restingX + metrics.loopDistance)] {
            textLayer.string = line
            textLayer.contentsScale = scale
            textLayer.frame = CGRect(x: x, y: lineY, width: textWidth, height: lineHeight)
        }
        loopCopy.isHidden = !metrics.scrolls
        strip.removeAnimation(forKey: Self.loopAnimationKey)
        if metrics.scrolls {
            strip.add(Self.loopAnimation(for: metrics), forKey: Self.loopAnimationKey)
        }
        CATransaction.commit()
        applyTextColor()
    }

    private func applyTextColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.85)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        title.foregroundColor = color
        loopCopy.foregroundColor = color
        CATransaction.commit()
    }

    /// Rest at the start, then slide left until the trailing copy sits where
    /// the title began, and repeat. 30 fps is plenty for 30 pt/s and spares
    /// a high-refresh display from redrawing the menu bar at full rate.
    private static func loopAnimation(for metrics: MarqueeMetrics) -> CAAnimation {
        let loop = CAKeyframeAnimation(keyPath: "transform.translation.x")
        loop.values = [CGFloat(0), CGFloat(0), -metrics.loopDistance]
        loop.keyTimes = [
            NSNumber(value: 0),
            NSNumber(value: MarqueeMetrics.restDuration / metrics.loopDuration),
            NSNumber(value: 1),
        ]
        loop.calculationMode = .linear
        loop.duration = metrics.loopDuration
        loop.repeatCount = .infinity
        loop.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        return loop
    }
}
