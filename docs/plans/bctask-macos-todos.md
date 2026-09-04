# BCTask macOS menu-bar app plan

## Product contract

BCTask is a lightweight, menu-bar-only macOS todo app. Clicking its menu-bar icon toggles a movable, app-like task panel; clicking again dismisses it. Tasks move through **Todo**, **Doing**, and **Done**, shown either as a list or a three-column kanban. A done task becomes archived one hour after its recorded completion time. The archive remains browsable. Any active task can be pinned into its own always-on-top floating card and unpinned later.

The interface is intentionally small, dark, cyan-accented, keyboard-friendly, and free of third-party runtime dependencies.

## Accepted technical direction

- Native Swift 6 with SwiftUI and a small AppKit bridge, targeting macOS 13 or later.
- An AppKit status item toggles a movable SwiftUI-hosted panel; `LSUIElement = true` hides the Dock/app-switcher icon. This replaces the initially planned anchored `MenuBarExtra(.window)` after user smoke feedback.
- A Codable JSON document under Application Support is written atomically. The domain and archival policy stay independent of SwiftUI so they can be tested deterministically.
- Each task records status, creation/update timestamps, optional completion/archive timestamps, and pinned state. Reopening a task clears completion/archive timestamps. Archiving a pinned task closes its panel.
- Archival is deadline-based, not timer-dependent: persist `completedAt`, sweep on startup/activation and mutations, and run a low-frequency in-process sweep while the app is active. This catches up correctly after sleep or relaunch.
- A main-actor panel coordinator owns one `NSPanel` per pinned task, uses floating window level, and restores persisted pins on launch. The SwiftUI pinned-card design is established before AppKit wiring.
- No drag-and-drop in the first version. Explicit compact status actions keep both list and kanban behavior clear and lightweight.
- The machine has Swift 6.3.2 command-line tools on arm64 but not the full Xcode app. The repository therefore uses Swift Package Manager for build/tests plus a small script that assembles and ad-hoc-signs `BCTask.app`. An Xcode project is not required for this delivery.

## Evidence path

The main claims and minimum evidence are:

1. **State and one-hour archival are correct:** deterministic unit tests with an injected `now`, including before/exactly-after the deadline, reopen/reset, relaunch catch-up, and persistence round trips.
2. **The app remains buildable and lightweight:** `swift test`, debug/release `swift build`, no third-party package dependencies, bundle assembly, `plutil` verification, and `codesign --verify`.
3. **Menu/list/kanban/archive operations use one consistent store:** store-level integration tests plus a launch smoke test of the assembled app.
4. **Pinned cards use floating panels without corrupting state:** coordinator-focused tests where practical, build/static inspection of panel configuration, and launch smoke evidence. Visual always-on-top behavior may still require a final human smoke check because the current environment has no reliable native-menu-bar UI automation harness.
5. **The visual system is minimal, dark, cyan, and accessible:** designer-owned implementation, accessibility labels/tooltips, reduced-motion-safe interactions, build verification, and a final visual smoke check.

## Delivery phases and gates

### Phase 1 — Native foundation and deterministic state

**Owner:** `@fixer` owns repository/app scaffolding, Swift package targets, domain model, JSON persistence, archival policy, minimal menu-bar app shell, bundle script, and foundation tests. No visual polish is in scope.

**Validation owner:** command-validation lane runs the focused Swift tests/build and bundle metadata checks; the orchestrator reconciles evidence.

**Oracle gate 1:** review architecture, data-loss risks, timestamp semantics, archive boundary behavior, deployment assumptions, and unnecessary complexity.

**Why this gate:** persistence and time semantics must be stable before UI work binds to them.

### Phase 2 — Complete primary experience and visual system

**Owner:** `@designer` owns and implements the visible SwiftUI experience: larger app-like/resizable surface contract, task entry, list/kanban switch, list-row ellipsis actions, traffic-light Todo/Doing/Done cues, archive browsing/restoring, task pin control, pinned-card view, dark/cyan system, keyboard-focus semantics, shortcut command handling, spacing, typography, interaction states, and empty states. Domain and persistence contracts from Phase 1 remain unchanged unless a blocker is recorded.

**Validation owner:** command-validation lane runs tests/build/bundle smoke checks; the orchestrator reviews user-facing copy without flattening design intent.

**Oracle gate 2:** review store/UI integration, workflow completeness, accessibility risks, and whether the design stays appropriately simple and lightweight.

**Why this gate:** it verifies the full everyday workflow before platform-specific floating-window lifecycle work is added.

### Phase 3 — Floating panels, lifecycle catch-up, and release hardening

**Owner:** `@fixer` owns mechanical AppKit wiring that preserves Phase 2 design: status-item click toggling of the movable main panel, native keyboard command bridging, per-task `NSPanel` coordination, pin restoration/unpin/close behavior, archive-triggered panel closure, lifecycle/periodic sweeps, launch behavior, release bundle hardening, tests, and concise build/run documentation. Any visual judgment routes back to `@designer`.

**Validation owner:** command-validation lane runs full tests, debug/release builds, bundle/signature checks, and launch/no-crash smoke evidence; the orchestrator reconciles final scope and limitations.

**Oracle gate 3:** review panel ownership/lifetime, main-actor safety, sleep/relaunch archival correctness, data consistency, cleanup, readability, and release readiness.

**Why this gate:** AppKit window lifecycle and timer catch-up are the highest-risk integration boundary.

## Oracle budget and remediation policy

- Three mandatory initial Oracle reviews: one after each phase.
- At most two conditional re-reviews per phase, for a theoretical maximum of nine Oracle calls.
- Material actionable findings, including simplify/readability feedback, are batched into one bounded remediation pass and validated with focused evidence.
- Re-review only when remediation changes the reviewed decision/risk or the original concern cannot otherwise be verified. Mechanical, already-proven fixes do not consume a re-review.

## Phase boundary policy

After each phase: reconcile writer output, run focused validation, update `.slim/deepwork/macos-menu-todos.md`, request the Oracle gate, batch material remediation, and revalidate. Do not start the next phase while any phase lane or review is unreconciled. Git commits are not created without separate user authorization.
