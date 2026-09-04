import SwiftUI
import BCTaskCore

/// Programmatic UI tokens give every visible surface one deliberate
/// black/cyan language; the bundled app icon lives separately in `Support`.
enum BCTaskTheme {
    static let canvas = Color(red: 0.018, green: 0.018, blue: 0.018)
    static let canvasLift = Color(red: 0.045, green: 0.045, blue: 0.045)
    static let surface = Color(red: 0.065, green: 0.065, blue: 0.065)
    static let surfaceRaised = Color(red: 0.095, green: 0.095, blue: 0.095)
    static let surfaceHover = Color(red: 0.135, green: 0.135, blue: 0.135)

    static let accent = Color(red: 0.27, green: 0.89, blue: 0.95)
    static let accentStrong = Color(red: 0.04, green: 0.76, blue: 0.86)
    static let statusTodo = Color(red: 1.00, green: 0.43, blue: 0.43)
    static let statusDoing = Color(red: 0.98, green: 0.78, blue: 0.28)
    static let statusDone = Color(red: 0.43, green: 0.88, blue: 0.68)
    static let danger = Color(red: 1.00, green: 0.49, blue: 0.48)

    static let textPrimary = Color(red: 0.96, green: 0.96, blue: 0.96)
    static let textSecondary = Color(red: 0.72, green: 0.72, blue: 0.72)
    static let textTertiary = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.11)

    static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .todo: statusTodo
        case .doing: statusDoing
        case .done: statusDone
        }
    }
}

extension TaskStatus {
    var displayName: String {
        switch self {
        case .todo: "Todo"
        case .doing: "Doing"
        case .done: "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .todo: "circle"
        case .doing: "arrow.forward.circle"
        case .done: "checkmark.circle"
        }
    }

    var selectedSymbolName: String {
        switch self {
        case .todo: "circle.fill"
        case .doing: "arrow.forward.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}

struct BCTaskBackground: View {
    var body: some View {
        ZStack {
            BCTaskTheme.canvas
            LinearGradient(
                colors: [
                    BCTaskTheme.canvasLift.opacity(0.52),
                    BCTaskTheme.canvas.opacity(0.26),
                    BCTaskTheme.canvas,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [BCTaskTheme.accent.opacity(0.055), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

struct BCTaskButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    let kind: Kind
    var compact = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, compact ? 11 : 14)
            .frame(minHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isFocused ? BCTaskTheme.accent : borderColor, lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }

    private var foregroundColor: Color {
        kind == .primary ? BCTaskTheme.canvas : BCTaskTheme.textPrimary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch kind {
        case .primary:
            return isPressed ? BCTaskTheme.accentStrong : BCTaskTheme.accent
        case .secondary:
            return isPressed ? BCTaskTheme.surfaceHover : BCTaskTheme.surfaceRaised
        case .quiet:
            return isPressed ? BCTaskTheme.surfaceHover : .clear
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: BCTaskTheme.accent.opacity(0.36)
        case .secondary: BCTaskTheme.hairlineStrong
        case .quiet: .clear
        }
    }
}

struct BCTaskIconButtonStyle: ButtonStyle {
    var isActive = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isActive ? BCTaskTheme.accent : BCTaskTheme.textSecondary)
            .frame(width: 40, height: 40)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? BCTaskTheme.surfaceHover
                            : (isActive ? BCTaskTheme.accent.opacity(0.11) : .clear)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isFocused
                            ? BCTaskTheme.accent
                            : (isActive ? BCTaskTheme.accent.opacity(0.20) : .clear),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
