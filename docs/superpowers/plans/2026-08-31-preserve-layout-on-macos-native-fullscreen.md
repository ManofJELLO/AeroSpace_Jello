# Preserve Layout On macOS Native Fullscreen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a window enters macOS native fullscreen and later exits, restore the workspace's tiled layout exactly — same tree structure, same slot, same sizes.

**Architecture:** Snapshot the workspace's whole tiling tree into a `FrozenContainer` on the way into fullscreen (before the window is unbound, so it is still in the tree at its original index and weight), and rebuild the tree from that snapshot on the way out. Reuses `FrozenContainer` and `restoreTreeRecursive` from `Sources/AppBundle/tree/frozen/`, which already solve the same shape of problem for lock-screen restore. Snapshots are discarded whenever anything else mutates the layout, so the fallback is always today's behavior.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, macOS Accessibility API. Build/test via `./build-debug.sh`, `./swift-test.sh`, `./test.sh`, `./format.sh`, `./lint.sh`.

**Spec:** `docs/superpowers/specs/2026-08-31-preserve-layout-on-macos-native-fullscreen-design.md`

## Global Constraints

- Everything runs on `@MainActor`. Tree mutation is main-actor-isolated throughout this codebase.
- Never use `Task.init` / `Task {` / `Task(` — `lint.sh` rejects it. Use `Task.startUnstructured`.
- Builds run with `-Xswiftc -warnings-as-errors`. An unused variable or unreachable branch fails the build.
- `lint.sh` runs `periphery` (dead-code detection). Every new top-level declaration must have a real call site, or the lint fails.
- Run `./format.sh` before every commit. It runs `swiftformat` in place and the repo's CI checks for uncommitted files afterwards.
- Config option name is exactly `preserve-layout-on-macos-native-fullscreen`, Swift property exactly `preserveLayoutOnMacosNativeFullscreen`, default `true`. Not version-gated.
- Scope is macOS native fullscreen only. Native minimize and app-hide share the same `LayoutReason.macos` code path and are deliberately left on today's behavior.
- Work on branch `preserve-layout-on-macos-native-fullscreen` (already created).

## Orientation: how this subsystem works today

Read this before Task 1. You will not be able to make sensible edits without it.

A workspace's tiled windows live in a tree under `workspace.rootTilingContainer`. Each node has an `adaptiveWeight`, which is **an absolute point size, not a ratio**. `layoutTiles` (`Sources/AppBundle/layout/layoutRecursive.swift:118`) rewrites every child's weight on every layout pass so they sum to the container's size.

When macOS reports a window as natively fullscreen, `normalizeLayoutReason` (`Sources/AppBundle/normalizeLayoutReason.swift:36`) records `window.layoutReason = .macos(prevParentKind:)` and **unbinds** the window from its tiling container, binding it into `workspace.macOsNativeFullscreenWindowsContainer`. That is what destroys the layout: the siblings' weights get permanently rewritten by the next layout pass, and if the container was left with a single child, `unbindEmptyAndAutoFlatten` (`Sources/AppBundle/tree/normalizeContainers.swift:12`) deletes the container entirely.

On exit, `exitMacOsNativeUnconventionalState` (`Sources/AppBundle/normalizeLayoutReason.swift:54`) switches on the remembered `prevParentKind` and, for `.tilingContainer`, calls `relayoutWindow(forceTile: true)` — which re-binds the window with `WEIGHT_AUTO` next to the most-recently-used window. Unrelated slot, unrelated size.

AeroSpace's own `fullscreen` command is a different thing entirely — it sets a flag and leaves the window in the tree. Do not touch it.

## File Structure

**New files**

- `Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift` — the whole feature: snapshot store, capture, restore, invalidation, and the shared "enter fullscreen" helper. Lives next to `closedWindowsCache.swift`, whose machinery it reuses.
- `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift` — behavior tests driving the real `normalizeLayoutReason()`.

**Modified files**

- `Sources/AppBundle/tree/AbstractApp.swift` — add `isHiddenApp` to the protocol (testability).
- `Sources/AppBundle/tree/MacApp.swift` — implement `isHiddenApp`.
- `Sources/AppBundle/GlobalObserver.swift` — use `isHiddenApp`.
- `Sources/AppBundle/normalizeLayoutReason.swift` — use `isHiddenApp`; route enter through the shared helper; attempt restore on exit.
- `Sources/AppBundle/command/impl/MacosNativeFullscreenCommand.swift` — route enter through the shared helper.
- `Sources/AppBundle/tree/frozen/closedWindowsCache.swift` — make `restoreTreeRecursive` tolerant behind an opt-in parameter.
- `Sources/AppBundle/tree/MacWindow.swift` — drop a dead window's snapshot.
- `Sources/AppBundle/shell/Shell.swift`, `Sources/AppBundle/mouse/moveWithMouse.swift`, `Sources/AppBundle/mouse/resizeWithMouse.swift` — invalidation.
- `Sources/AppBundle/config/Config.swift`, `Sources/AppBundle/config/parseConfig.swift` — the config option.
- `docs/config-examples/default-config.toml`, `docs/guide.adoc` — docs.
- `Sources/AppBundleTests/tree/TestApp.swift` — implement `isHiddenApp`.

---

### Task 1: Make `normalizeLayoutReason` testable

`normalizeLayoutReason.swift:29` calls `window.macAppUnsafe.nsApp.isHidden`, and `macAppUnsafe` is `app as! MacApp` (`Sources/AppBundle/tree/AbstractApp.swift:30`). `TestApp` is not a `MacApp`, so that force-cast traps.

Swift's `&&` short-circuits, so the expression is never reached on the way *into* fullscreen (`isMacosFullscreen` is `true`). It **is** reached on the way out, when all three flags are false. The exit path is exactly what the rest of this plan changes, so it must become testable first.

**Files:**
- Modify: `Sources/AppBundle/tree/AbstractApp.swift`
- Modify: `Sources/AppBundle/tree/MacApp.swift`
- Modify: `Sources/AppBundle/normalizeLayoutReason.swift:29`
- Modify: `Sources/AppBundle/GlobalObserver.swift:29`
- Modify: `Sources/AppBundleTests/tree/TestApp.swift`
- Create: `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AbstractApp.isHiddenApp: Bool { get }`, implemented by `MacApp` and `TestApp`. `TestApp` exposes a settable `isHiddenApp` so future tests can flip it.

- [ ] **Step 1: Write the failing test**

Create `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift`:

```swift
@testable import AppBundle
import Common
import XCTest

@MainActor
final class MacosFullscreenLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testExitingFullscreenPutsTheWindowBackInTheTilingTree() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2],
        )
    }
}
```

`layoutDescription` and `LayoutDescription` are declared at file scope in `Sources/AppBundleTests/command/MoveCommandTest.swift:326` and are visible across the whole test target. Do not redeclare them.

- [ ] **Step 2: Run test to verify it fails**

Run: `./swift-test.sh 2>&1 | grep -A5 MacosFullscreenLayoutTest`

Expected: the test crashes the test process with a force-cast trap, something like `Could not cast value of type 'AppBundleTests.TestApp' to 'AppBundle.MacApp'`. A hard crash rather than a clean XCTest failure is the expected red state here.

- [ ] **Step 3: Add `isHiddenApp` to the protocol**

In `Sources/AppBundle/tree/AbstractApp.swift`, add the requirement to the protocol body (after `var bundlePath: String? { get }`):

```swift
    /// Whether the owning macOS application is hidden (cmd-h).
    /// Declared on the protocol rather than reached through `macAppUnsafe` so that the
    /// non-fullscreen branches of `normalizeLayoutReason` are reachable from tests.
    var isHiddenApp: Bool { get }
```

- [ ] **Step 4: Implement it in `MacApp`**

In `Sources/AppBundle/tree/MacApp.swift`, next to the other `/*conforms*/` computed properties (around line 23):

```swift
    /*conforms*/ var isHiddenApp: Bool { nsApp.isHidden }
```

- [ ] **Step 5: Implement it in `TestApp`**

In `Sources/AppBundleTests/tree/TestApp.swift`, add a stored property next to `_windows`:

```swift
    var isHiddenApp: Bool = false
```

- [ ] **Step 6: Use it at both call sites**

In `Sources/AppBundle/normalizeLayoutReason.swift:29`, replace `window.macAppUnsafe.nsApp.isHidden` so the line reads:

```swift
            !config.automaticallyUnhideMacosHiddenApps && window.app.isHiddenApp
```

In `Sources/AppBundle/GlobalObserver.swift:29`, replace `w.macAppUnsafe.nsApp.isHidden` with:

```swift
                       w.app.isHiddenApp,
```

Leave line 32 (`MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1`) alone — it iterates `MacApp` instances directly and has nothing to do with the `Window` abstraction.

- [ ] **Step 7: Run the test to verify it passes**

Run: `./swift-test.sh 2>&1 | tail -20`

Expected: `✅ Swift tests have passed successfully`

- [ ] **Step 8: Format, lint, commit**

```bash
./format.sh
./lint.sh
git add Sources/AppBundle/tree/AbstractApp.swift Sources/AppBundle/tree/MacApp.swift \
        Sources/AppBundle/normalizeLayoutReason.swift Sources/AppBundle/GlobalObserver.swift \
        Sources/AppBundleTests/tree/TestApp.swift Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift
git commit -m "Add AbstractApp.isHiddenApp so normalizeLayoutReason is testable"
```

---

### Task 2: Add the `preserve-layout-on-macos-native-fullscreen` config option

Add the option and its docs now, so later tasks have something to read. Nothing consumes it yet.

**Files:**
- Modify: `Sources/AppBundle/config/Config.swift:46`
- Modify: `Sources/AppBundle/config/parseConfig.swift:147`
- Modify: `docs/config-examples/default-config.toml:47`
- Modify: `docs/guide.adoc:417-427`
- Test: `Sources/AppBundleTests/config/ConfigTest.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `config.preserveLayoutOnMacosNativeFullscreen: Bool` (default `true`), read by Tasks 3 and 4.

- [ ] **Step 1: Write the failing test**

Append to `Sources/AppBundleTests/config/ConfigTest.swift`, inside the `ConfigTest` class:

```swift
    func testPreserveLayoutOnMacosNativeFullscreen() {
        assertEquals(parseConfig("").config.preserveLayoutOnMacosNativeFullscreen, true)

        let result = parseConfig("preserve-layout-on-macos-native-fullscreen = false")
        assertEquals(result.errors, [])
        assertEquals(result.config.preserveLayoutOnMacosNativeFullscreen, false)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./swift-test.sh 2>&1 | grep -i "preserveLayout\|error:" | head`

Expected: a compile error — `value of type 'Config' has no member 'preserveLayoutOnMacosNativeFullscreen'`.

- [ ] **Step 3: Add the `Config` property**

In `Sources/AppBundle/config/Config.swift`, immediately after `var automaticallyUnhideMacosHiddenApps: Bool = false` (line 46):

```swift
    var preserveLayoutOnMacosNativeFullscreen: Bool = true
```

- [ ] **Step 4: Add the parser entry**

In `Sources/AppBundle/config/parseConfig.swift`, immediately after the `"automatically-unhide-macos-hidden-apps"` entry (line 147):

```swift
    "preserve-layout-on-macos-native-fullscreen": Parser(\.preserveLayoutOnMacosNativeFullscreen, parseBool),
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./swift-test.sh 2>&1 | tail -20`

Expected: `✅ Swift tests have passed successfully`

- [ ] **Step 6: Document the key in the default config**

In `docs/config-examples/default-config.toml`, immediately after the `automatically-unhide-macos-hidden-apps = false` block (line 47):

```toml

# When a window enters macOS native fullscreen (the green button) and later exits it,
# restore the workspace layout exactly as it was before, instead of re-tiling the window
# next to the most recently focused one.
# Set to false to get the pre-0.20 behavior back.
# See https://nikitabobko.github.io/AeroSpace/guide#macos-native-fullscreen
preserve-layout-on-macos-native-fullscreen = true
```

`ConfigTest.testParseDefaultConfig` parses this file and asserts zero errors and zero warnings, so a typo here fails the suite.

- [ ] **Step 7: Document the behavior in the guide**

In `docs/guide.adoc`, insert a new subsection between the end of `=== Floating windows` (line 427, the paragraph ending `...an additional binding for focusing floating windows.`) and `[#emulation-of-virtual-workspaces]` (line 429):

```adoc
[#macos-native-fullscreen]
=== macOS native fullscreen

When a window enters macOS native fullscreen (the green button, an app fullscreening itself, or the xref:commands.adoc#macos-native-fullscreen[macos-native-fullscreen] command), it leaves the <<tree,tiling tree>> for its own macOS Space.

AeroSpace snapshots the workspace's tiling tree at that moment and restores it when the window comes back, so the window returns to the exact slot and size it left, and its siblings keep theirs.

The snapshot is discarded as soon as anything else changes that layout — any layout-changing command, or moving or resizing a window with the mouse. When that happens, exiting fullscreen falls back to placing the window next to the most recently focused one. Windows that merely opened while the app was fullscreen are kept and tiled alongside the restored layout.

Configured by `preserve-layout-on-macos-native-fullscreen`:

[source,toml]
----
preserve-layout-on-macos-native-fullscreen = false
----
```

- [ ] **Step 8: Verify the docs build**

Run: `./build-docs.sh`

Expected: exits 0 with no asciidoctor warnings about the new anchor.

- [ ] **Step 9: Format, lint, commit**

```bash
./format.sh
./lint.sh
git add Sources/AppBundle/config/Config.swift Sources/AppBundle/config/parseConfig.swift \
        Sources/AppBundleTests/config/ConfigTest.swift \
        docs/config-examples/default-config.toml docs/guide.adoc
git commit -m "Add preserve-layout-on-macos-native-fullscreen config option"
```

---

### Task 3: Snapshot and restore the tiling tree

The core of the feature. After this task, the layout is restored in the happy path; tolerance for windows that appeared or disappeared comes in Task 4.

This task also fixes a small pre-existing bug: `MacosNativeFullscreenCommand` binds the window into the fullscreen container **without** setting `layoutReason`, so the next `normalizeLayoutReason` pass records `prevParentKind: .macosFullscreenWindowsContainer` (the "wtf case, should never be possible" branch) rather than `.tilingContainer`. Restore keys off `prevParentKind`, so without this fix the feature would silently never fire for the command. Both entry points now go through one shared helper.

**Files:**
- Create: `Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift`
- Modify: `Sources/AppBundle/tree/frozen/closedWindowsCache.swift:88-111`
- Modify: `Sources/AppBundle/normalizeLayoutReason.swift:34-36`, `:54-73`
- Modify: `Sources/AppBundle/command/impl/MacosNativeFullscreenCommand.swift:36-38`
- Test: `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift`

**Interfaces:**
- Consumes: `config.preserveLayoutOnMacosNativeFullscreen` (Task 2); `FrozenContainer(_ container: TilingContainer)` and `restoreTreeRecursive` from `closedWindowsCache.swift`.
- Produces:
  - `enterMacosNativeFullscreen(window: Window, workspace: Workspace, adaptiveWeight: CGFloat)`
  - `restoreMacosFullscreenLayout(window: Window, workspace: Workspace, _ cm: CancellationMode) async throws -> Bool`
  - `resetMacosFullscreenLayoutSnapshots()`
  - `dropMacosFullscreenLayoutSnapshot(windowId: UInt32)`
  - `restoreTreeRecursive(frozenContainer:parent:index:skipUnrestorableWindows:)` — new trailing parameter, defaulting to `false`.

- [ ] **Step 1: Write the failing tests**

Add both to `MacosFullscreenLayoutTest`:

```swift
    func testRestoresSlotAndWeights() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))

        // Stand in for the layout pass that rewrites sibling weights while the window is away
        w1.hWeight = 600
        w3.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3)]),
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
        assertEquals(w3.hWeight, 500)
    }

    func testRestoresContainerThatWasFlattenedAway() async throws {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        let w2 = TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: nested)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        workspace.normalizeContainers()
        // The two-window container was left with one child and flattened away
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3)]))

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )
    }

    func testConfigOptionOffKeepsOldBehavior() async throws {
        config.preserveLayoutOnMacosNativeFullscreen = false
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w1.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2],
        )
        assertEquals(w1.hWeight, 600) // not restored
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./swift-test.sh 2>&1 | grep -B2 -A8 "MacosFullscreenLayoutTest"`

Expected: `testRestoresSlotAndWeights` and `testRestoresContainerThatWasFlattenedAway` FAIL (restored tree does not match; weights are 600/600 rather than 200/500/500). `testConfigOptionOffKeepsOldBehavior` already PASSES — it pins today's behavior so later tasks cannot regress it.

- [ ] **Step 3: Make `restoreTreeRecursive` tolerant**

In `Sources/AppBundle/tree/frozen/closedWindowsCache.swift`, replace the whole `restoreTreeRecursive` function (lines 88-111) with:

```swift
@discardableResult
@MainActor
func restoreTreeRecursive(
    frozenContainer: FrozenContainer,
    parent: NonLeafTreeNodeObject,
    index: Int,
    /// Skip windows that no longer exist, or that are currently in a macOS unconventional state
    /// (fullscreen/minimized/hidden), instead of aborting the whole restore
    skipUnrestorableWindows: Bool = false,
) -> Bool {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )

    var childIndex = 0
    for child in frozenContainer.children {
        switch child {
            case .window(let w):
                guard let window = MacWindow.get(byId: w.id), window.layoutReason == .standard else {
                    if skipUnrestorableWindows { continue }
                    // Stop the loop if can't find the window, because otherwise all the subsequent windows will have incorrect index
                    return false
                }
                window.bind(to: container, adaptiveWeight: w.weight, index: childIndex)
            case .container(let c):
                // There is no reason to continue
                if !restoreTreeRecursive(
                    frozenContainer: c,
                    parent: container,
                    index: childIndex,
                    skipUnrestorableWindows: skipUnrestorableWindows,
                ) { return false }
        }
        childIndex += 1
    }
    return true
}
```

Three things changed and all three matter:

1. `childIndex` replaces the old `enumerated()` index, and only advances for children that actually got bound — otherwise a skipped window shifts every later sibling into a gap.
2. The `window.layoutReason == .standard` check. Without it, fullscreening app A then app B and then exiting A would yank B out of its fullscreen Space back into the tiling tree, because B is still in A's snapshot.
3. `private` is dropped so the new file can call it.

The `skipUnrestorableWindows: false` default means the existing lock-screen call site at line 74 keeps its exact current behavior — with one intended addition: it now also refuses to tile a window that is mid-fullscreen, which was a latent bug there too. Do not change that call site.

- [ ] **Step 4: Create the snapshot cache**

Create `Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift`:

```swift
import AppKit
import Common

/// Preserves the workspace tiling layout across macOS native fullscreen.
///
/// Entering macOS native fullscreen unbinds the window from its tiling container. Because weights are absolute
/// point sizes that `layoutTiles` rewrites on every pass, the siblings' sizes are permanently changed, and
/// container flattening may delete the parent container outright. So the whole tiling tree is snapshotted on the
/// way in and rebuilt on the way out.
struct MacosFullscreenLayoutSnapshot {
    let workspaceName: String
    let rootTilingNode: FrozenContainer
}

@MainActor private var snapshots: [UInt32: MacosFullscreenLayoutSnapshot] = [:]

/// Moves the window into the workspace's macOS-native-fullscreen container, remembering both where it came from
/// and what the workspace looked like, so that the layout can be restored on exit.
///
/// The `layoutReason` assignment is what makes `exitMacOsNativeUnconventionalState` take the `.tilingContainer`
/// branch later. `MacosNativeFullscreenCommand` used to skip it, which left `prevParentKind` recorded as
/// `.macosFullscreenWindowsContainer` by the next normalization pass.
@MainActor
func enterMacosNativeFullscreen(window: Window, workspace: Workspace, adaptiveWeight: CGFloat) {
    if config.preserveLayoutOnMacosNativeFullscreen && window.parent is TilingContainer {
        snapshots[window.windowId] = MacosFullscreenLayoutSnapshot(
            workspaceName: workspace.name,
            rootTilingNode: FrozenContainer(workspace.rootTilingContainer),
        )
    }
    if case .standard = window.layoutReason, let parent = window.parent {
        window.layoutReason = .macos(prevParentKind: parent.kind)
    }
    window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
}

/// Returns `true` if the layout was restored. Callers fall back to `relayoutWindow` when it returns `false`.
@MainActor
func restoreMacosFullscreenLayout(window: Window, workspace: Workspace, _ cm: CancellationMode) async throws -> Bool {
    guard config.preserveLayoutOnMacosNativeFullscreen else { return false }
    guard let snapshot = snapshots.removeValue(forKey: window.windowId) else { return false }
    guard snapshot.workspaceName == workspace.name else { return false }

    // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
    let prevRoot = workspace.rootTilingContainer
    let potentialOrphans = prevRoot.allLeafWindowsRecursive + [window]
    prevRoot.unbindFromParent()
    restoreTreeRecursive(
        frozenContainer: snapshot.rootTilingNode,
        parent: workspace,
        index: INDEX_BIND_LAST,
        skipUnrestorableWindows: true,
    )

    // Windows that appeared while the app was fullscreen aren't in the snapshot. Tile them rather than drop them.
    for orphan in potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive {
        try await orphan.relayoutWindow(on: workspace, cm, forceTile: true)
    }
    window.markAsMostRecentChild()
    return true
}

@MainActor
func dropMacosFullscreenLayoutSnapshot(windowId: UInt32) {
    snapshots.removeValue(forKey: windowId)
}

/// Any other change to the layout makes every snapshot stale. Called from the same places as
/// ``resetClosedWindowsCache()``.
@MainActor
func resetMacosFullscreenLayoutSnapshots() {
    snapshots = [:]
}
```

Notes for the implementer:

- `window` is included in `potentialOrphans` deliberately. At this point it is still bound to `macOsNativeFullscreenWindowsContainer` with `layoutReason == .standard` (the caller resets it first). If for any reason it does not land in the rebuilt tree, this guarantees it still gets tiled rather than stranded in the fullscreen container forever.
- `-` on arrays is the repo's existing set-difference helper; `closedWindowsCache.swift:76` uses the same idiom.
- `MacWindow.get(byId:)` inside `restoreTreeRecursive` resolves to the inherited `Window.get(byId:)` (`Sources/AppBundle/tree/Window.swift:22`), which searches the tree under `isUnitTest`. That is why these tests work at all.

- [ ] **Step 5: Route both entry points through the helper**

In `Sources/AppBundle/normalizeLayoutReason.swift`, replace the `case isMacosFullscreen:` arm (lines 34-36):

```swift
                    case isMacosFullscreen:
                        enterMacosNativeFullscreen(window: window, workspace: workspace, adaptiveWeight: WEIGHT_DOESNT_MATTER)
```

In `Sources/AppBundle/command/impl/MacosNativeFullscreenCommand.swift`, replace the enter branch (lines 36-38):

```swift
        if newState { // Enter fullscreen
            enterMacosNativeFullscreen(window: window, workspace: workspace, adaptiveWeight: 1)
        } else { // Exit fullscreen
```

- [ ] **Step 6: Attempt restore on exit**

In `Sources/AppBundle/normalizeLayoutReason.swift`, in `exitMacOsNativeUnconventionalState`, replace the `.tilingContainer` arm:

```swift
        case .tilingContainer:
            if try await restoreMacosFullscreenLayout(window: window, workspace: workspace, cm) { return }
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
```

`window.layoutReason = .standard` is already assigned at the top of that function, before this switch. Do not move it — `restoreTreeRecursive`'s `layoutReason == .standard` check depends on it.

- [ ] **Step 7: Run tests to verify they pass**

Run: `./swift-test.sh 2>&1 | tail -20`

Expected: `✅ Swift tests have passed successfully`

- [ ] **Step 8: Format, lint, commit**

```bash
./format.sh
./lint.sh
git add Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift \
        Sources/AppBundle/tree/frozen/closedWindowsCache.swift \
        Sources/AppBundle/normalizeLayoutReason.swift \
        Sources/AppBundle/command/impl/MacosNativeFullscreenCommand.swift \
        Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift
git commit -m "Restore tiling layout when a window exits macOS native fullscreen"
```

---

### Task 4: Tolerate windows that appeared or disappeared during fullscreen

Task 3 wrote the tolerance logic. This task proves it, and covers the nested-fullscreen case.

Nothing here should require production changes — if a test fails, the bug is in Task 3's code and belongs fixed here.

**Files:**
- Test: `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift`
- Modify (only if a test fails): `Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift`, `Sources/AppBundle/tree/frozen/closedWindowsCache.swift`

**Interfaces:**
- Consumes: everything Task 3 produced.
- Produces: nothing new.

- [ ] **Step 1: Write the tests**

Add all three to `MacosFullscreenLayoutTest`:

```swift
    func testWindowOpenedDuringFullscreenIsKept() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2, 3],
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
    }

    func testWindowClosedDuringFullscreenIsSkipped() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        w3.closeAxWindow() // TestWindow.closeAxWindow just unbinds

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
    }

    func testExitingOneFullscreenLeavesTheOtherFullscreen() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w3.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertTrue(w3.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
    }
```

- [ ] **Step 2: Run the tests**

Run: `./swift-test.sh 2>&1 | tail -20`

Expected: `✅ Swift tests have passed successfully`.

If `testWindowOpenedDuringFullscreenIsKept` fails with window 3 missing, the orphan loop in `restoreMacosFullscreenLayout` is wrong. If `testWindowClosedDuringFullscreenIsSkipped` fails with a mangled tree, `childIndex` in `restoreTreeRecursive` is advancing on skipped children. If `testExitingOneFullscreenLeavesTheOtherFullscreen` fails with window 3 in the tiling tree, the `layoutReason == .standard` guard is missing or is being evaluated before the caller resets `window.layoutReason`.

- [ ] **Step 3: Commit**

```bash
./format.sh
./lint.sh
git add Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift \
        Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift \
        Sources/AppBundle/tree/frozen/closedWindowsCache.swift
git commit -m "Cover windows opening, closing, and nesting during macOS native fullscreen"
```

---

### Task 5: Invalidate snapshots when anything else changes the layout

A snapshot is only safe while the layout it describes is untouched. Hook the same three sites that already invalidate `closedWindowsCache`.

**Files:**
- Modify: `Sources/AppBundle/shell/Shell.swift:100-103`
- Modify: `Sources/AppBundle/mouse/moveWithMouse.swift:28`
- Modify: `Sources/AppBundle/mouse/resizeWithMouse.swift:41`
- Modify: `Sources/AppBundle/tree/MacWindow.swift:79-83`
- Test: `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift`

**Interfaces:**
- Consumes: `resetMacosFullscreenLayoutSnapshots()` and `dropMacosFullscreenLayoutSnapshot(windowId:)` from Task 3.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Add all three to `MacosFullscreenLayoutTest`. Only the first exercises the wiring this task adds; the other two pin the fallback contract it depends on.

```swift
    func testLayoutChangingCommandInvalidatesTheSnapshot() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        // flatten-workspace-tree has shouldResetClosedWindowsCache = true and rebinds
        // every tiled window with adaptiveWeight 1, so it both invalidates and is observable
        _ = await parseCommand("flatten-workspace-tree").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(w1.hWeight, 1)

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2, 3],
        )
        assertEquals(w1.hWeight, 1) // the command's sizes won, the snapshot did not come back
    }

    func testResettingSnapshotsFallsBackToOldBehavior() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w1.hWeight = 600

        resetMacosFullscreenLayoutSnapshots()

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2],
        )
        assertEquals(w1.hWeight, 600) // not restored
    }

    func testDroppingOneSnapshotFallsBackToOldBehavior() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        dropMacosFullscreenLayoutSnapshot(windowId: w2.windowId)
        w1.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(w1.hWeight, 600) // not restored
    }
```

`parseCommand(...).cmdOrDie` returns a `Shell<any Command>`, so `.run(.defaultEnv, .emptyStdin)` goes through `Shell.run` — the code path Step 3 modifies. `ShellRunTest` drives commands the same way, which is how we know `refreshModel_nonCancellable()` is safe under test. It calls `normalizeContainers()` but no layout pass, so weights stay exactly as the command left them.

- [ ] **Step 2: Run the tests and check the red state**

Run: `./swift-test.sh 2>&1 | grep -A8 "testLayoutChangingCommandInvalidatesTheSnapshot\|testResettingSnapshots\|testDroppingOneSnapshot"`

Expected: `testLayoutChangingCommandInvalidatesTheSnapshot` FAILS — the final assertion sees `w1.hWeight == 200`, because nothing has told the cache that `flatten-workspace-tree` invalidated it, so the snapshot still wins.

`testResettingSnapshotsFallsBackToOldBehavior` and `testDroppingOneSnapshotFallsBackToOldBehavior` already PASS. They call the reset functions directly, which Task 3 already implemented. They are here to pin the fallback contract, not to drive new code, and they must keep passing through the rest of this task.

- [ ] **Step 3: Invalidate on layout-changing commands**

In `Sources/AppBundle/shell/Shell.swift`, in the `.cmd` arm of `run(_:_:)`, add the reset **before** the command runs:

```swift
            case .cmd(let command):
                // Before, not after: `eval 'macos-native-fullscreen'` would otherwise have EvalCommand's own
                // shouldResetClosedWindowsCache destroy the snapshot the inner command just took.
                if command.shouldResetClosedWindowsCache { resetMacosFullscreenLayoutSnapshots() }
                let exitCode = Int32ExitCode(rawValue: await command.run(env, io).rawValue)
                if command.shouldResetClosedWindowsCache { resetClosedWindowsCache() }
                await refreshModel_nonCancellable()
                return exitCode
```

Leave the existing `resetClosedWindowsCache()` call exactly where it is. `MacosNativeFullscreenCommand.shouldResetClosedWindowsCache` is already `false`, so the command does not wipe its own snapshot.

- [ ] **Step 4: Invalidate on mouse manipulation**

In `Sources/AppBundle/mouse/moveWithMouse.swift`, directly under `resetClosedWindowsCache()` (line 28):

```swift
    resetMacosFullscreenLayoutSnapshots()
```

In `Sources/AppBundle/mouse/resizeWithMouse.swift`, directly under `resetClosedWindowsCache()` (line 41):

```swift
    resetMacosFullscreenLayoutSnapshots()
```

- [ ] **Step 5: Drop a dead window's snapshot**

In `Sources/AppBundle/tree/MacWindow.swift`, in `garbageCollect`, immediately after the early-return guard:

```swift
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        dropMacosFullscreenLayoutSnapshot(windowId: windowId) // A dead window will never exit fullscreen
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
```

- [ ] **Step 6: Run the full suite**

Run: `./swift-test.sh 2>&1 | tail -20`

Expected: `✅ Swift tests have passed successfully`

- [ ] **Step 7: Run the whole verification pipeline**

Run: `./test.sh`

Expected: `✅ All tests have passed successfully`. This is the build with `-warnings-as-errors`, the full test suite, `lint.sh` (including periphery dead-code detection), `generate.sh`, and the uncommitted-files check. If `generate.sh` writes anything, commit those files too.

- [ ] **Step 8: Commit**

```bash
./format.sh
git add Sources/AppBundle/shell/Shell.swift Sources/AppBundle/mouse/moveWithMouse.swift \
        Sources/AppBundle/mouse/resizeWithMouse.swift Sources/AppBundle/tree/MacWindow.swift \
        Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift
git commit -m "Invalidate fullscreen layout snapshots when the layout changes"
```

---

### Task 6: Verify against the real app

Unit tests drive `normalizeLayoutReason` directly with a fake window. The Accessibility API is the part they cannot fake, so exercise the real thing once.

**Files:** none.

**Interfaces:**
- Consumes: the built debug binary.
- Produces: nothing.

- [ ] **Step 1: Build and run the debug app**

Run: `./run-debug.sh`

Grant Accessibility permission if macOS prompts.

- [ ] **Step 2: Check the unequal-sizes case**

Open three windows on one workspace. Resize them so they are visibly unequal — make the middle one narrow. Fullscreen the middle one with the green button, wait for the Space animation to finish, then exit fullscreen.

Expected: the window returns to the middle slot at its original narrow width; the other two keep their widths.

- [ ] **Step 3: Check the two-window flattening case**

On a fresh workspace, open two windows side by side, then `aerospace split vertical` on one and open a third so you have a nested container of two. Fullscreen one of the nested pair and exit.

Expected: the nested container comes back with both windows in it, not flattened.

- [ ] **Step 4: Check the command path**

Run `./run-cli.sh macos-native-fullscreen` on a focused tiled window, wait, then run it again to exit.

Expected: same restoration as the green button. This is the path that needed the `layoutReason` fix in Task 3 — if it re-tiles by MRU instead, that fix did not land.

- [ ] **Step 5: Check the fallback**

Fullscreen a window, switch back to the workspace, run `aerospace balance-sizes`, then exit fullscreen.

Expected: the window is re-tiled next to the most recently focused window and the balanced sizes are left alone. The deliberate change wins over the snapshot.

- [ ] **Step 6: Check the escape hatch**

Add `preserve-layout-on-macos-native-fullscreen = false` to your config, `aerospace reload-config`, and repeat step 2.

Expected: the pre-change behavior — the window comes back next to the most recently focused window with an averaged size.

- [ ] **Step 7: Report**

Report exactly what you observed for each step, including anything that did not match. Do not commit anything in this task.

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| Snapshot store (`MacosFullscreenLayoutSnapshot`, keyed by window id) | 3 |
| Capture at both entry points via shared helper; `layoutReason` fix for the command | 3 |
| Restore: workspace-name guard, config guard, missing-snapshot guard | 3 |
| Restore algorithm steps 1-6 (unbind prevRoot, rebuild, orphans, MRU, drop) | 3 |
| Skip closed windows | 4 |
| Skip windows still in `.macos` state | 4 |
| Tolerant `restoreTreeRecursive` with opt-in parameter | 3 |
| Invalidation at Shell + both mouse sites, before-not-after in Shell | 5 |
| `garbageCollect` drops the dead window's snapshot | 5 |
| Config option in Config.swift, parseConfig.swift, default-config.toml, guide.adoc | 2 |
| `isHiddenApp` on `AbstractApp` for testability | 1 |
| Spec tests 1-7 | 1 (round-trip), 3 (1, 2, 7), 4 (4, 5, 6), 5 (3, plus real Shell wiring) |
| Known limitation: nested fullscreen degrades to MRU | documented in spec; test in Task 4 pins the safe half |

No spec requirement is unassigned.

**Naming consistency**

`preserveLayoutOnMacosNativeFullscreen` / `preserve-layout-on-macos-native-fullscreen`, `enterMacosNativeFullscreen`, `restoreMacosFullscreenLayout`, `resetMacosFullscreenLayoutSnapshots`, `dropMacosFullscreenLayoutSnapshot`, `skipUnrestorableWindows`, `MacosFullscreenLayoutSnapshot` — each spelled identically everywhere it appears above.

Note the deliberate rename from the spec's first draft: the `restoreTreeRecursive` parameter is `skipUnrestorableWindows`, not `skipMissingWindows`, because it skips two distinct categories (gone, and still in a macOS unconventional state). The spec has been updated to match.
