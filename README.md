# AeroSpace Beta [![Build](https://github.com/nikitabobko/AeroSpace/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/nikitabobko/AeroSpace/actions/workflows/build.yml)

<img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="40%" align="right">

AeroSpace is an i3-like tiling window manager for macOS

Videos:
- [YouTube 91 sec Demo](https://www.youtube.com/watch?v=UOl7ErqWbrk)
- [YouTube Guide by Josean Martinez](https://www.youtube.com/watch?v=-FoWClVHG5g)

Docs:
- [AeroSpace Guide](https://nikitabobko.github.io/AeroSpace/guide)
- [AeroSpace Commands](https://nikitabobko.github.io/AeroSpace/commands)
- [AeroSpace Goodies](https://nikitabobko.github.io/AeroSpace/goodies)

> [!NOTE]
> This is a fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace) with two additions that are not
> upstream: a [Hyprland-style master layout](#master-layout) and
> [tiled-layout restore across macOS native fullscreen](#tiled-layout-survives-macos-native-fullscreen).
> Everything else tracks upstream, so the upstream guide, commands reference and config all still apply.
> Note that the hosted docs linked above describe upstream, not this fork - the fork additions are documented in
> [`docs/`](./docs) in this repository.

## Fork additions

Install this fork from the personal tap (the upstream cask installs upstream AeroSpace, without these additions):

```
brew install --cask ManofJELLO/tap/aerospace-jello
```

The fork is built by [`release.sh`](./release.sh), which skips man page and shell completion generation, so those
aren't included.

### Master layout

A dynamic master/stack layout modelled after
[Hyprland's master layout](https://wiki.hyprland.org/Configuring/Dwindle-Master-Layouts/#master), available as a third
layout alongside `tiles` and `accordion`.
A `master` container splits its children into a *master area* holding the first `count` windows, and a *stack* holding
everything else.
Each group is stacked across the split, and the master area takes `fraction` of the container.

```
master.orientation = 'left'          master.orientation = 'center'
+----------+-------------+           +------+------------+------+
|          |     S1      |           |  S1  |            |  S2  |
|          +-------------+           +------+     M      +------+
|    M     |     S2      |           |  S3  |            |  S4  |
|          +-------------+           +------+            +------+
|          |     S3      |           |  S5  |            |      |
+----------+-------------+           +------+------------+------+
```

Unlike `tiles`, you never build the tree by hand.
Opening a window puts it into the stack, and everything else is driven from the keyboard:

| Command | What it does |
| --- | --- |
| `layout master`, `layout h_master`, `layout v_master` | Switch a container into the master layout |
| `master swap-with-master` | Promote the focused window to master. Press again to go back |
| `master focus-master` | Focus the master. Press again to return to the stack |
| `master add-master`, `master remove-master`, `master set-count` | Resize the master area by window count. `set-count` takes `2`, `+1` or `-1` |
| `master set-fraction` | Move the boundary between the master area and the stack. Takes a percent: `60`, `+5`, `-5` |
| `master set-orientation` | Move the master area to another side: `left`, `right`, `top`, `bottom`, `center`, `next`, `prev` |
| `master rotate-next`, `master rotate-prev` | Shift every window one slot, so a different one becomes master. Focus stays on the master spot |

The general purpose commands work inside a master container too.
`focus` moves within a column and crosses between the master area and the stack, `move` swaps a window with its
neighbour (promoting or demoting it across the split), and `resize` along the split axis moves the master/stack
boundary, as does dragging that boundary with the mouse.

Dragging a window with the mouse inserts it where you drop it and shifts the rest along, so dropping onto the master
area promotes the window to master. The layout only changes when you release the button, so dragging somewhere and
back again cancels the move. That matches Hyprland's `drop_at_cursor`; `tiles` and `accordion` keep
AeroSpace's usual behavior of swapping the dragged window with the one underneath.

Defaults for new master containers come from the `[master]` config table:

```toml
default-root-container-layout = 'master'

[master]
orientation = 'left'              # left|right|top|bottom|center
count = 1                         # windows in the master area
fraction = 55                     # percent of the container taken by the master area, 5..95
center-stack-threshold = 2        # stack windows 'center' needs before it takes effect. 0 means always
center-fallback = 'left'          # what 'center' is laid out as below that threshold. left|right|top|bottom
new-window-position = 'stack-end' # master|stack-start|stack-end|after-focused
```

These match Hyprland's defaults one for one (`mfact 0.55`, `orientation left`, `new_status slave`,
`slave_count_for_center_master 2`, `center_master_fallback left`).

`fraction` is an integer percent rather than a `0.55`-style float because the config parser has no float type.

Full documentation: [`docs/guide.adoc`](./docs/guide.adoc) (Layouts section) and
[`docs/aerospace-master.adoc`](./docs/aerospace-master.adoc), which also maps every Hyprland `layoutmsg` to its
AeroSpace equivalent.

### Tiled layout survives macOS native fullscreen

When a window enters macOS native fullscreen it leaves the tiling tree for its own macOS Space.
Upstream then has nothing to put it back into, so on exit the window is simply tiled in next to the most recently
focused window, which can reshuffle the workspace.

This fork snapshots the workspace's tiling tree when the window leaves, and restores it when the window comes back.
The window returns to the slot and size it left, its siblings keep theirs, and their most-recently-used order is
preserved too.

The snapshot is discarded once a layout-changing command runs, or a window is moved or resized with the mouse.
When that happens, exiting fullscreen falls back to the upstream behavior.
Windows that open while the app is fullscreen aren't in the snapshot, so they get tiled in alongside the restored
layout; windows that close are left out of it.

Enabled by default. Set it to `false` for the upstream behavior:

```toml
preserve-layout-on-macos-native-fullscreen = false
```

Full documentation: [`docs/guide.adoc`](./docs/guide.adoc) (macOS native fullscreen section).

## Key features

- Tiling window manager based on a [tree paradigm](https://nikitabobko.github.io/AeroSpace/guide#tree)
- [i3](https://i3wm.org/) inspired
- Fast workspaces switching without animations and without the necessity to disable SIP
- AeroSpace employs its [own emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) instead of relying on native macOS Spaces due to [their considerable limitations](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)
- Plain text configuration (dotfiles friendly). See: [default-config.toml](https://nikitabobko.github.io/AeroSpace/guide#default-config)
- CLI first (manpages and shell completion included)
- Doesn't require disabling SIP (System Integrity Protection)
- [Proper multi-monitor support](https://nikitabobko.github.io/AeroSpace/guide#multiple-monitors) (i3-like paradigm)

## Installation

Install via [Homebrew](https://brew.sh/) to get autoupdates (Preferred)

```
brew install --cask nikitabobko/tap/aerospace
```

> [!NOTE]
> The instructions in this section install **upstream** AeroSpace, which doesn't include the
> [fork additions](#fork-additions). To install this fork instead, use
> `brew install --cask ManofJELLO/tap/aerospace-jello`.

In multi-monitor setup please make sure that monitors [are properly arranged](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement).

Other installation options: https://nikitabobko.github.io/AeroSpace/guide#installation

> [!NOTE]
> By using AeroSpace, you acknowledge that it's not [notarized](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
>
> Notarization is a "security" feature by Apple.
> You send binaries to Apple, and they either approve them or not.
> In reality, notarization is about building binaries the way Apple likes it.
>
> I don't have anything against notarization as a concept.
> I specifically don't like the way Apple does notarization.
> I don't have time to deal with Apple.
>
> [Homebrew installation script](https://github.com/nikitabobko/homebrew-tap/blob/main/Casks/aerospace.rb) is configured to
> automatically delete `com.apple.quarantine` attribute, that's why the app should work out of the box, without any warnings that
> "Apple cannot check AeroSpace for malicious software"

## Community, discussions, issues

AeroSpace project doesn't accept Issues directly - we ask you to create a [Discussion](https://github.com/nikitabobko/AeroSpace/discussions) first.
Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for more details.

Community discussions happen at GitHub Discussions.
There you can discuss bugs, propose new features, ask your questions, show off your setup, or just chat.

There are 7 channels:
-   [#all](https://github.com/nikitabobko/AeroSpace/discussions).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions.atom?discussions_q=sort%3Adate_created).
    Feed with all discussions.
-   [#announcements](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements.atom?discussions_q=category%3Aannouncements+sort%3Adate_created).
    Only maintainers can post here.
    Highly moderated traffic.
-   [#announcements-releases](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements-releases).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements-releases.atom?discussions_q=category%3Aannouncements-releases+sort%3Adate_created).
    Announcements about non-patch releases.
    Only maintainers can post here.
-   [#feature-ideas](https://github.com/nikitabobko/AeroSpace/discussions/categories/feature-ideas).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/feature-ideas.atom?discussions_q=category%3Afeature-ideas+sort%3Adate_created).
-   [#general](https://github.com/nikitabobko/AeroSpace/discussions/categories/general).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/general.atom?discussions_q=sort%3Adate_created+category%3Ageneral).
-   [#potential-bugs](https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs.atom?discussions_q=category%3Apotential-bugs+sort%3Adate_created).
    If you think that you have encountered a bug, you can discuss your bugs here.
-   [#questions-and-answers](https://github.com/nikitabobko/AeroSpace/discussions/categories/questions-and-answers).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/questions-and-answers.atom?discussions_q=category%3Aquestions-and-answers+sort%3Adate_created).
    Everyone is welcome to ask questions.
    Everyone is encouraged to answer other people's questions.

## Project status

Public Beta. AeroSpace can be used as a daily driver, but expect breaking changes until 1.0 is reached.

What stops us from 1.0 release:
- [x] https://github.com/nikitabobko/AeroSpace/issues/131 Performance. Implement thread-per-application to circumvent macOS blocking AX API.
- [ ] https://github.com/nikitabobko/AeroSpace/issues/1215 _Big refactoring_. Rewrite mutable double-linked core tree data structure to immutable single-linked persistent tree.
  Important for: stability and potential performance
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/1216 The big refactoring will help us to fix stability issue that windows may randomly jump to the focused workspace
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/68 The big refactoring will help us to support macOS native tabs
- [x] https://github.com/nikitabobko/AeroSpace/issues/278 Implement shell-like combinators.
  Ignore a lot of crazy fuss in the issue,
  We are most probably going with the minimal approach to only introduce common shell-combinators: `||`, `&&`, `;` and `eval` command to send multiple commands in one go.
- [ ] https://github.com/nikitabobko/AeroSpace/issues/1012 Investigate a possibility to use `CGEvent.tapCreate` API for global hotkeys
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/28 Maybe it will allow to distinguish left and right modifiers. Maybe not

Big and important issues which will go after 1.0 release:
- [ ] https://github.com/nikitabobko/AeroSpace/issues/2 sticky windows
- [ ] https://github.com/nikitabobko/AeroSpace/issues/260 Dynamic TWM

## Development

A notes on how to setup the project, build it, how to run the tests, etc. can be found here: [dev-docs/development.md](./dev-docs/development.md)

## Project values

**Values**
- AeroSpace is targeted at advanced users and developers
- Keyboard centric
- Breaking changes (configuration files, CLI, behavior) are avoided as much as possible, but it must not let the software stagnate.
  Thus breaking changes can happen, but with careful considerations and helpful message.
  [Semver](https://semver.org/) major version is bumped in case of a breaking change (It's all guaranteed once AeroSpace reaches 1.0 version, until then breaking changes just happen)
- AeroSpace doesn't use GUI, unless necessarily
  - AeroSpace will never provide a GUI for configuration.
    For advanced users, it's easier to edit a configuration file in text editor rather than navigating through checkboxes in GUI.
  - Status menu icon is ok, because visual feedback is needed
- Provide _practical_ features. Fancy appearance features are not _practical_ (e.g. window borders, transparency, animations, etc.)
- "dark magic" (aka "private APIs", "code injections", etc.) must be avoided as much as possible
  - Right now, AeroSpace uses only a single private API to get window ID of accessibility object `_AXUIElementGetWindow`.
    Everything else is [macOS public accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h).
  - AeroSpace will never require you to disable SIP (System Integrity Protection).
  - The goal is to make AeroSpace easily maintainable, and resistant to macOS updates.

**Non Values**
- Play nicely with existing macOS features.
  If limitations are imposed then AeroSpace won't play nicely with existing macOS features
  (For example, AeroSpace doesn't acknowledge the existence of macOS Spaces, and it uses [emulation of its own workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces))
- Ricing.
  AeroSpace provides only a very minimal support for ricing - gaps and a few callbacks for integrations with bars.
  The current maintainer doesn't care about ricing.
  Ricing issues are not a priority, and they are mostly ignored.
  The ricing stance can change only with the appearance of more maintainers.

## macOS compatibility table

* AeroSpace binary runs on: macOS 13+
* AeroSpace debug build from sources is supported on: macOS 14+
* AeroSpace release build from sources is supported on: macOS 15+ (Requires Xcode 26+)

## Sponsorship

AeroSpace is developed and maintained in my free time.
If you find it useful, [consider sponsoring](https://github.com/sponsors/nikitabobko#sponsors).

## People who have write access

In alphabetical order:

- [@mobile-ar](https://github.com/mobile-ar)
- [@nikitabobko](https://github.com/nikitabobko)
- [@rickyz](https://github.com/rickyz)

## Tip of the day

```bash
defaults write -g NSWindowShouldDragOnGesture -bool true
```

Now, you can move windows by holding `ctrl`+`cmd` and dragging any part of the window (not necessarily the window title)

Source: [reddit](https://www.reddit.com/r/MacOS/comments/k6hiwk/keyboard_modifier_to_simplify_click_drag_of/)

## Related projects

- [Amethyst](https://github.com/ianyh/Amethyst) - tiling window manager à la xmonad
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) - Instant space switching by synthesizing trackpad gesture with an artificially high velocity
- [yabai](https://github.com/koekeishiya/yabai) - a tiling window manager for macOS based on binary space partitioning
