import SwiftUI
import BCTaskCore

/// Designer-owned visible-experience surface for BCTask.
///
/// Phase 2 owns the contents of this file: menu-bar identity and surface
/// sizing, and all visible views inside the movable main panel. `BCTaskApp.swift`
/// is reserved for Phase 3 lifecycle/panel wiring, and `AppModel.swift` for
/// model/lifecycle concerns.
///
/// The interface uses SF Symbols and programmatic colors/typography. The
/// application icon is a durable bundled resource assembled from `Support`.
enum AppExperience {
    /// Accessibility label and tooltip for the image-only menu-bar control.
    static let menuBarTitle = "BCTask"
    /// Template SF Symbol used for the image-only menu-bar icon.
    static let menuBarSymbol = "checkmark"
    /// Phase 3 must apply this as the movable main panel's `contentMinSize`.
    /// The floor keeps three Kanban lanes and multi-line list rows readable.
    static let surfaceMinimumSize = CGSize(width: 720, height: 520)
    /// Phase 3 should use this for the panel's initial content size while
    /// preserving the user's later resize through normal AppKit autosaving.
    static let surfaceIdealSize = CGSize(width: 860, height: 680)
}

/// Root view hosted inside the movable main panel.
struct AppMenuSurfaceView: View {
    @ObservedObject var model: AppModel
    @StateObject private var commandRouter: TaskCommandRouter

    init(model: AppModel, commandRouter: TaskCommandRouter? = nil) {
        self.model = model
        _commandRouter = StateObject(wrappedValue: commandRouter ?? TaskCommandRouter())
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(commandRouter)
            .frame(
                minWidth: AppExperience.surfaceMinimumSize.width,
                idealWidth: AppExperience.surfaceIdealSize.width,
                maxWidth: .infinity,
                minHeight: AppExperience.surfaceMinimumSize.height,
                idealHeight: AppExperience.surfaceIdealSize.height,
                maxHeight: .infinity
            )
            .preferredColorScheme(.dark)
    }
}
