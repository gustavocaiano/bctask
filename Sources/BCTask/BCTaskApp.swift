import AppKit
import SwiftUI

/// Phase 3 application shell: an AppKit status-item lifecycle for the
/// menu-bar-only utility app. The bundle Info.plist keeps `LSUIElement=true`,
/// so the app stays out of the Dock and app switcher.
///
/// All scene/presentation decisions live in the designer-owned
/// `AppExperience.swift`; this file owns application lifetime only. The
/// `StatusItemPanelsController` installs the status item, the retained main
/// panel, pinned-task panels, the shortcut monitor, and catch-up sweeps.
@main
enum BCTaskMain {
    static func main() {
        // The process entry point runs on the main thread before AppKit
        // installs its own main-actor context; the delegate must construct
        // main-actor state (`AppModel`, controller) there.
        MainActor.assumeIsolated {
            BCTaskApp.launchAndRun()
        }
    }
}

@MainActor
final class BCTaskApp: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let router: TaskCommandRouter
    private var controller: StatusItemPanelsController?

    /// Test/fixture seam: build the delegate around an injected model and
    /// router so deterministic tests can exercise the launch/reopen path
    /// against a temporary store instead of the user's standard storage.
    init(model: AppModel, router: TaskCommandRouter) {
        self.model = model
        self.router = router
    }

    /// Internal testing seam over the installed controller lifecycle.
    var controllerForTesting: StatusItemPanelsController? { controller }

    static func launchAndRun() {
        let app = NSApplication.shared
        // Menu-bar-only behavior, also when launched through `swift run`.
        app.setActivationPolicy(.accessory)
        // Production wiring: default model (standard Application Support
        // store) and default command router.
        let delegate = BCTaskApp(model: AppModel(), router: TaskCommandRouter())
        // NSApplication.delegate is weak: the run loop below is the app's
        // whole lifetime, so the delegate is pinned explicitly for the entire
        // blocking call instead of relying on frame lifetime.
        withExtendedLifetime(delegate) {
            app.delegate = delegate
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemPanelsController(model: model, router: router)
        self.controller = controller
        controller.start()
        // The main surface must appear focused immediately at launch, not
        // only after the first menu-bar click (show/focus is idempotent on
        // the retained panel).
        controller.showMainPanel()
    }

    /// Activation hook: when the app becomes active (e.g. a sibling process
    /// calls `NSRunningApplication.activate` on us, as Lineup does), the
    /// retained main panel may still be ordered out. Surfacing it here makes
    /// activation an additional re-show path alongside reopen.
    /// `showMainPanel()` is idempotent on the retained surface; this is a
    /// benign no-op before setup or after terminal teardown.
    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.showMainPanel()
    }

    /// Reopen hook: reopening an already-running accessory app (Spotlight,
    /// Finder, `open -a`) must surface the existing main panel, not start a
    /// second process. `showMainPanel()` is idempotent on the retained
    /// surface; a no-op if the controller is already torn down. Returning
    /// `false` records that this delegate handled the reopen itself, so
    /// AppKit's default generic window-reopen path is not layered on top.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let controller else { return false }
        controller.showMainPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Explicit teardown removes lifecycle seams, strips and closes
        // panels, and removes the retained status item. Dropping the
        // controller afterwards makes any late delegate callback (e.g. a
        // reopen or activation arriving during teardown) a guaranteed
        // no-op instead of resurrecting a surface.
        controller?.stop()
        controller = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar utility: hiding the main panel must not quit the app.
        false
    }
}
