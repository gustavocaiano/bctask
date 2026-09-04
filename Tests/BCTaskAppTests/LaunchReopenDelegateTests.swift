import Testing
import Foundation
import AppKit
import BCTaskCore
@testable import BCTask

/// Lifecycle/install lane, focused evidence for the delegate hooks:
/// - finishing launch starts the controller and shows/focuses the retained
///   main surface immediately (no menu-bar click required),
/// - the reopen hook (`applicationShouldHandleReopen`) surfaces the *existing*
///   main panel forward: same retained surface, no rebuild, no duplicate,
/// - the activation hook (`applicationDidBecomeActive`) also surfaces the
///   same retained panel when the app becomes active without a reopen
///   (e.g. a sibling calling `NSRunningApplication.activate`),
/// - both hooks degrade to benign no-ops after terminal teardown.
///
/// Determinism strategy: the delegate is constructed around an injected
/// `AppModel` backed by a per-suite disposable temp store (same fixture
/// pattern as `Phase3PanelLifecycleTests`), so no run touches the user's
/// real Application Support storage and no process-global AppKit state is
/// mutated outside the controller's own terminal `stop()` teardown (which
/// is itself the suite's proven deterministic strip path). Launch methods
/// are invoked directly; `NSApplication.run()` is never entered in tests.
@Suite("Delegate launch/reopen/activation lifecycle")
@MainActor
struct BCTaskAppLaunchReopenTests {
    @Test func didFinishLaunchingStartsControllerAndShowsMainPanel() throws {
        let (delegate, dir) = makeDelegate()
        defer { resetStorePermissions(dir) }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: nil)
        )
        let controller = try #require(delegate.controllerForTesting)
        #expect(controller.keyMonitorInstalledForTesting)
        let panel = try #require(controller.mainPanelForTesting)
        #expect(panel.isVisible)

        // Terminal teardown matches the real delegate path and strips the
        // surface shown by the launch hook.
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification, object: nil)
        )
        #expect(controller.mainPanelForTesting == nil)
        #expect(controller.keyMonitorInstalledForTesting == false)
    }

    @Test func reopenSurfacesExistingMainPanelWithoutRebuilding() throws {
        let (delegate, dir) = makeDelegate()
        defer { resetStorePermissions(dir) }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: nil)
        )
        let controller = try #require(delegate.controllerForTesting)
        let panelBeforeReopen = try #require(controller.mainPanelForTesting)
        let contentBeforeReopen = try #require(controller.mainContentControllerForTesting)

        // Simulate LaunchServices reopening an already-running accessory app
        // (Spotlight/Finder/`open -a`): the same retained surface must come
        // forward, idempotently.
        let handled = delegate.applicationShouldHandleReopen(
            NSApplication.shared, hasVisibleWindows: false
        )
        #expect(handled == false, "delegate handled the reopen itself")
        let panelAfterReopen = try #require(controller.mainPanelForTesting)
        #expect(panelAfterReopen === panelBeforeReopen, "reopen must reuse the retained surface")
        #expect(controller.mainContentControllerForTesting === contentBeforeReopen)
        #expect(panelAfterReopen.isVisible)

        // A second reopen is equally idempotent; no duplicate windows.
        let handledAgain = delegate.applicationShouldHandleReopen(
            NSApplication.shared, hasVisibleWindows: false
        )
        #expect(handledAgain == false)
        #expect(controller.mainPanelForTesting === panelBeforeReopen)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification, object: nil)
        )
        #expect(controller.mainPanelForTesting == nil)
    }

    @Test func didBecomeActiveSurfacesSameRetainedMainPanel() throws {
        let (delegate, dir) = makeDelegate()
        defer { resetStorePermissions(dir) }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: nil)
        )
        let controller = try #require(delegate.controllerForTesting)
        let panelBeforeHide = try #require(controller.mainPanelForTesting)
        let contentBefore = try #require(controller.mainContentControllerForTesting)
        try #require(panelBeforeHide.isVisible)

        // Simulate the panel being ordered out without teardown (e.g. the
        // user hid it, then a sibling activated the already-running app).
        panelBeforeHide.orderOut(nil)
        #expect(!panelBeforeHide.isVisible)

        // Activation notification: the same retained panel/content must come
        // forward, idempotently (no rebuild, no duplicate).
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification, object: nil)
        )
        let panelAfterActivation = try #require(controller.mainPanelForTesting)
        #expect(panelAfterActivation === panelBeforeHide, "activation must reuse the retained surface")
        #expect(controller.mainContentControllerForTesting === contentBefore)
        #expect(panelAfterActivation.isVisible)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification, object: nil)
        )
        #expect(controller.mainPanelForTesting == nil)
    }

    @Test func didBecomeActiveAfterTeardownIsABenignNoOp() throws {
        let (delegate, dir) = makeDelegate()
        defer { resetStorePermissions(dir) }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: nil)
        )
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification, object: nil)
        )
        try #require(delegate.controllerForTesting?.mainPanelForTesting == nil)

        // Activation after terminal teardown must not resurrect any surface.
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification, object: nil)
        )
        #expect(delegate.controllerForTesting?.mainPanelForTesting == nil)
    }

    @Test func reopenAfterTeardownIsABenignNoOp() throws {
        let (delegate, dir) = makeDelegate()
        defer { resetStorePermissions(dir) }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: nil)
        )
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification, object: nil)
        )
        try #require(delegate.controllerForTesting?.mainPanelForTesting == nil)

        // Reopen after terminal teardown must not resurrect any surface.
        let handled = delegate.applicationShouldHandleReopen(
            NSApplication.shared, hasVisibleWindows: false
        )
        #expect(handled == false)
        #expect(delegate.controllerForTesting?.mainPanelForTesting == nil)
    }

    // MARK: - Fixture helpers

    /// Builds the delegate around a disposable temp-store model and returns
    /// the temporary store directory for permission-reset teardown.
    private func makeDelegate() -> (delegate: BCTaskApp, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BCTaskLaunchReopen-\(UUID().uuidString)", isDirectory: true)
        let fileStore = TaskFileStore(directory: dir)
        let model = AppModel(storage: { fileStore })
        return (BCTaskApp(model: model, router: TaskCommandRouter()), dir)
    }

    private func resetStorePermissions(_ dir: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path
        )
        try? FileManager.default.removeItem(at: dir)
    }
}
