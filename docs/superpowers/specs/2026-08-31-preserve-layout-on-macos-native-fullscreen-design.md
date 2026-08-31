# Preserve tiled layout across macOS native fullscreen

## Problem

When a window enters macOS native fullscreen (green button, an app fullscreening itself, or
the `macos-native-fullscreen` command) and later exits, the workspace's tiled layout is not
restored. The window returns to an arbitrary slot, and its former siblings keep the sizes they
grew into while it was away.

### Root cause

Weights in the tree are absolute point sizes, not ratios. `layoutTiles`
(`Sources/AppBundle/layout/layoutRecursive.swift:118`) rewrites every sibling's weight on each
layout pass so they sum to the container's size:

```swift
child.setWeight(orientation, child.getWeight(orientation) + delta)
```

Entering fullscreen unbinds the window from its tiling container
(`Sources/AppBundle/normalizeLayoutReason.swift:36`). The next layout pass therefore
permanently rewrites the remaining siblings' weights. Exiting calls
`relayoutWindow(forceTile: true)`, which re-binds the window with `WEIGHT_AUTO` at
"most-recently-used window's index + 1" — a slot and a size unrelated to where it came from.

Worked example, container width 1200:

| | window | sibling A | sibling B |
|---|---|---|---|
| before fullscreen | 200 | 500 | 500 |
| window unbound, after one layout pass | — | 600 | 600 |
| after exit (`WEIGHT_AUTO` = avg = 600, then normalized) | 400 | 400 | 400 |

Structure is lost too, not just numbers. If the container held exactly two children, unbinding
leaves one child and `unbindEmptyAndAutoFlatten`
(`Sources/AppBundle/tree/normalizeContainers.swift:12`) deletes the container outright. This is
the most common case — a plain two-window split — and it is why recording only the window's own
slot is not sufficient.

AeroSpace's own `fullscreen` command is unaffected: it sets a flag and leaves the window bound
in the tree (`Sources/AppBundle/command/impl/FullscreenCommand.swift:29`). This spec covers
macOS native fullscreen only.

## Scope

In scope: macOS native fullscreen.

Out of scope: native minimize and app-hide. They share the same `LayoutReason.macos`
unbind/rebind path and lose layout the same way, but they are deliberately left on today's
behavior to keep the blast radius small. A snapshot for a minimized window can sit for a very
long time, which makes staleness a harder problem than it is for fullscreen.

## Approach

Snapshot the workspace's whole tiling tree on entry, restore it on exit.

Rejected alternatives:

- **Record only the window's `BindingData` plus its siblings' weights.** Cheaper, but the
  recorded parent reference dangles in the two-window case described above, because flattening
  has deleted that container. Salvaging it requires additionally suppressing flattening while
  fullscreen — a second, subtler mechanism.
- **Never unbind the window; keep it in the tiling tree and skip it during layout.** Its slot
  still consumes space, leaving a visible hole in the layout, and it contradicts how the
  codebase models this state: focus, move, `list-windows`, and `layout` all branch on the
  window living in `macosFullscreenWindowsContainer`.

The chosen approach reuses `FrozenContainer` and `restoreTreeRecursive`, which already exist in
`Sources/AppBundle/tree/frozen/` and already solve this shape of problem for lock-screen
restore. It restores structure rather than patching numbers, so container flattening and any
cascading restructure are handled for free.

## Components

### Snapshot store

New file `Sources/AppBundle/tree/frozen/macosFullscreenLayoutCache.swift`.

```swift
struct MacosFullscreenLayoutSnapshot {
    let workspaceName: String
    let rootTilingNode: FrozenContainer
}

@MainActor private var snapshots: [UInt32 /*windowId*/: MacosFullscreenLayoutSnapshot] = [:]
```

Keyed per window, so windows fullscreened on different workspaces do not interfere.

Public surface:

- `captureMacosFullscreenLayout(window:workspace:)`
- `restoreMacosFullscreenLayout(window:workspace:) -> Bool`
- `resetMacosFullscreenLayoutSnapshots()`
- `dropMacosFullscreenLayoutSnapshot(windowId:)`

### Capture

Called *before* the window is unbound, so the frozen tree still contains it at its original
index and weight. Two entry points, both get the call:

- `Sources/AppBundle/normalizeLayoutReason.swift:36` — app-initiated fullscreen
- `Sources/AppBundle/command/impl/MacosNativeFullscreenCommand.swift:37` — the command

### Restore

Attempted from `exitMacOsNativeUnconventionalState` when `prevParentKind == .tilingContainer`.
Returns `false` — falling back to today's `relayoutWindow(forceTile: true)` — when:

- the config option is off, or
- no snapshot exists for this window, or
- the window returned to a workspace whose name differs from `snapshot.workspaceName`.

On success:

1. `let existing = workspace.rootTilingContainer.allLeafWindowsRecursive`
2. `prevRoot.unbindFromParent()` (hold `prevRoot` in a local so it is not collected early)
3. Rebuild from `snapshot.rootTilingNode` via `restoreTreeRecursive(skipMissingWindows: true)`
4. Every window in `existing` that did not land in the new tree is an orphan →
   `relayoutWindow(on: workspace, forceTile: true)`
5. `window.markAsMostRecentChild()`
6. Drop the snapshot

Windows skipped during the rebuild in step 3:

- **Windows that no longer exist.** `CloseCommand` does not fire the invalidation signal, and a
  window dying externally does not either, so a snapshot can genuinely outlive its windows.
- **Windows whose `layoutReason` is still `.macos`.** Without this, fullscreening app A then app
  B, then exiting A, would yank B out of its fullscreen Space back into the tiling tree.

Windows *opened* while fullscreen also do not fire the invalidation signal. Step 4 is what keeps
them: they are re-tiled alongside the restored layout rather than discarded.

### Tolerant `restoreTreeRecursive`

`Sources/AppBundle/tree/frozen/closedWindowsCache.swift:90` currently returns `false` and leaves
a half-built tree on the first missing window. Add a `skipMissingWindows: Bool = false`
parameter. The default preserves the existing lock-screen call site's behavior exactly.

### Invalidation

`resetMacosFullscreenLayoutSnapshots()` is called at the same three sites that already fire
`resetClosedWindowsCache()`:

- `Sources/AppBundle/shell/Shell.swift:103`
- `Sources/AppBundle/mouse/moveWithMouse.swift:28`
- `Sources/AppBundle/mouse/resizeWithMouse.swift:41`

One deliberate difference: in `Shell.swift` the call goes **before** `command.run(...)`, not
after. Otherwise `eval 'macos-native-fullscreen'` would create a snapshot and then have
`EvalCommand`'s own `shouldResetClosedWindowsCache = true` destroy it on the way out.
Invalidating first is also the more accurate semantics for this cache: what matters is that the
layout stayed untouched *between* capture and restore. `resetClosedWindowsCache()` keeps its
current position and behavior.

`MacWindow.garbageCollect` (`Sources/AppBundle/tree/MacWindow.swift:79`) also calls
`dropMacosFullscreenLayoutSnapshot(windowId:)` — a dead window will never exit fullscreen.

### Config

New key `preserve-layout-on-macos-native-fullscreen`, default `true`. Not version-gated.

- `Sources/AppBundle/config/Config.swift` — `var preserveLayoutOnMacosNativeFullscreen: Bool = true`
- `Sources/AppBundle/config/parseConfig.swift` — parser table entry using `parseBool`
- `docs/config-examples/default-config.toml` — documented key
- `docs/guide.adoc` — prose describing the behavior and the escape hatch

### Testability change

`Sources/AppBundle/normalizeLayoutReason.swift:29` calls `window.macAppUnsafe.nsApp.isHidden`,
and `macAppUnsafe` is `app as! MacApp` (`Sources/AppBundle/tree/AbstractApp.swift:30`), which
crashes on `TestWindow`. Swift's `&&` short-circuits on the way *into* fullscreen but not on the
way out, so the exit path — exactly the path this spec changes — is currently untestable.

Add `var isHiddenApp: Bool { get }` to the `AbstractApp` protocol:

- `MacApp` → `nsApp.isHidden`
- `TestApp` → stored property, default `false`

Update `normalizeLayoutReason.swift:29` and `GlobalObserver.swift:29` to use it.

## Testing

New `Sources/AppBundleTests/tree/MacosFullscreenLayoutTest.swift`, driving the real
`normalizeLayoutReason()` through `TestWindow.isMacosFullscreenForTest`:

1. Three windows with unequal weights in one container; fullscreen the middle one; exit. Tree
   shape, indices, and weights are identical to before.
2. Nested container with exactly two children and
   `config.enableNormalizationFlattenContainers = true`. This is the flattening case that
   defeats a slot-only fix. (`setUpWorkspacesForTests` disables flattening by default, so the
   test must opt in.)
3. Snapshot invalidated mid-fullscreen via `resetMacosFullscreenLayoutSnapshots()`; exit falls
   back to today's MRU placement.
4. Window opened during fullscreen; on exit it is still tiled and the rest of the layout is
   restored.
5. Window closed during fullscreen; it is skipped and the rest is restored.
6. Windows A and B both fullscreen; exiting A leaves B fullscreen.
7. `preserve-layout-on-macos-native-fullscreen = false` reproduces today's behavior exactly.

## Known limitation

Nested fullscreens degrade gracefully but not perfectly. If A enters fullscreen, then B enters,
then A exits, B's snapshot was taken after A had already left the tree — so B's later exit
re-tiles A by MRU rather than restoring it. This is never worse than current behavior, and the
case is rare enough that documenting it beats adding snapshot chaining.
