# Configuration

Open **Settings…** from the menu bar to edit layout, appearance, application rules, gestures, and shortcuts. Changed settings offer **Restore Default**; **Apply Changes** saves and reloads the configuration. **Restore All Defaults** resets the configuration. Start at Login is under General.

Choose **Open config.json…** in Settings (or **Open Config…** in the menu), or edit
`~/Library/Application Support/Paperi/config.json`. All keys are optional.
Choose **Reload Config** after saving. Invalid entries appear in the menu/status.

```json
{
  "gap": 8,
  "outerGap": 8,
  "bottomDotsVisibility": "auto",
  "exclude": ["us.zoom.xos"],
  "float": [{"app": "com.apple.finder", "titleContains": "Copy"}],
  "tile": [{"app": "com.apple.systempreferences"}],
  "focusAfterClose": "left",
  "focusScrollDuration": 0.22,
  "autoCenter": true,
  "autoCenterThreshold": 0.75,
  "gesture": {
    "snapshotStyle": "native",
    "enabled": true,
    "fingers": 3,
    "travel": 0.4,
    "columnTravel": 0.3,
    "commitThreshold": 0.5,
    "flickVelocity": 1.5,
    "invert": false,
    "swipeUpToClose": true,
    "swipeDown": "newWindow",
    "swipeDownRight": "splitRight",
    "swipeDownLeft": "minimize",
    "tap": "tray",
    "tabCloseApps": ["com.google.Chrome"]
  },
  "hotkeys": {
    "ctrl-alt-l": "width + 0.2",
    "alt-cmd-j": null
  }
}
```

## Windows and layout

| Key | Meaning |
| --- | --- |
| `include` | Only manage these app bundle IDs; omitted or `null` considers all regular apps. |
| `exclude` | Skip these app bundle IDs. System UI agents are always excluded. |
| `float` | Keep matching windows outside the strip. Each rule has `app` and an optional, case-insensitive `titleContains`. |
| `tile` | Allow matching windows without a fullscreen button to tile. Dialogs and panels still stay outside the strip. |
| `singleton` | Array of app bundle IDs whose in-content tab bars should be treated as a plain window. Adds to the built-in defaults (currently `us.zoom.xos`). Explicit entries take precedence over `singletonExclude`. |
| `singletonExclude` | Array of built-in singleton app bundle IDs to return to native tab discovery. For example, `["us.zoom.xos"]` disables Zoom’s default. Defaults to `[]`. |
| `strictTabDetection` | Array of app bundle IDs, or `["*"]` for every app, that use strict native-tab detection. See [Native tab detection](#native-tab-detection). |
| `gap`, `outerGap` | Space between windows and around the layout, in points. |
| `focusAfterClose` | `left` (default), `right`, or `system`. A surviving tab or stacked window keeps the column focused. |
| `autoCenter` | Default `true`. Center a sole column; center wide focused interior columns. First and last columns in a multi-column strip keep normal positioning. Stacked windows share their column’s position. |
| `autoCenterThreshold` | Width fraction of the usable layout on the current display, default `0.75`; greater than 0 and at most 1. Applied after focus, size, or membership changes and when gestures settle. |
| `focusScrollDuration` | Focus animation in seconds, default `0.22`; `0` disables it. |
| `bottomDotsVisibility` | `visible`, `hidden`, or `auto` (default). Auto shows dots during horizontal swipes, through the landing animation, and for 650 ms afterward. Legacy `bottom: dot`, `dots`, or `thumbnail` loads as `visible`; `bottom: none` loads as `hidden`. Choose from **Settings → Appearance** or edit this key. |
| `swapHighlight` | Drag preview color as `#RRGGBB` or `#RRGGBBAA`. |

## Gestures

Gestures are on by default with three fingers. `fingers` accepts `3` or `4`.
A swipe starts only when its fingers land together, within 150 ms of the first
touching an empty trackpad. A two-finger scroll or resting finger joined later by
the other hand stays an ordinary scroll until every finger lifts.
`columnTravel` is the fraction of trackpad width the fingers move for a full
column (default `0.3`); `travel` is the same for vertical gestures (close, pull
and turn; default `0.4`). `commitThreshold`
is the progress needed to commit (default `0.5`). A sufficiently long, fast flick
can also commit; `flickVelocity` controls that speed threshold. `invert` reverses
horizontal navigation.

`snapshotStyle` accepts `native` (default) or `simple`. Native preserves macOS
window borders, highlights, and shadows. Simple uses an unframed screenshot
with an approximate shadow, avoiding native framing inspection at swipe start.
Changes apply to the next gesture. Native automatically falls back to the simple
capture when its content bounds cannot be verified.

`swipeDown`, `swipeDownRight`, and `swipeDownLeft` each accept `closeTab`,
`newWindow`, `openApp`, `minimize`, or `none`. Their defaults are new window, close tab,
and minimize respectively. Turn right or left after moving down without lifting;
a turn can begin before the downward action is armed. A turn needs a clearly
sideways move (about 6% of the trackpad width, within roughly 27° of
horizontal), so drift while lifting keeps the downward action. Releasing a short
turn cancels both actions; a quick sideways flick commits only after moving
past the point where the turn began. Downward gestures also show hints when a popup or the
desktop has focus; actions target the frontmost app. Minimizing requires a window.

To open a window of a specific app, set `swipeDown` to `openApp` and
`swipeDownApp` to its bundle ID, for example:

```json
"gesture": {
  "swipeDown": "openApp",
  "swipeDownApp": "com.apple.Terminal"
}
```

`openApp` also works for down-right and down-left; all three share the same
`swipeDownApp` target. Paperi launches the app if needed (using its normal initial
window). If already running, it activates the app and invokes New Window,
falling back to ⌘N. Window creation depends on the app's support for these actions.
The target must be installed; an unavailable target leaves the current app alone.
Use `newWindow` to target the focused app without specifying `swipeDownApp`.
Selecting `openApp` for any downward gesture requires `swipeDownApp`; omitting it rejects the configuration.

`tabCloseApps` defaults to an empty array. Add apps such as Chrome here to make
swipe up show the tab-close pill and send ⌘W instead of closing the entire window.
Native macOS tab groups are handled automatically. ⌘W can close the window when
it has no tabs remaining.

A quick tap with all gesture fingers (`tap`, default `tray`) shows the thumbnail
tray centred on the pointer, on the display under it; click a thumbnail to focus that
window, or drag one sideways to reorder the strip. The tray stays while hovered, fades
0.3 seconds after the pointer leaves, and closes at once on a click outside it. The
`tray` command (default ⌥⌘T) opens it the same way. Thumbnails require Screen
Recording permission. Only a
deliberate tap counts: fingers landing and lifting within 100 ms of each other, down
for at most 250 ms, each moving at most 2.5 mm, without a physical click, a fourth
finger, or another multi-finger gesture in the preceding 250 ms. Set `tap` to `none`
to turn it off. With three fingers, macOS's Look Up tap
(**Trackpad → Look up & data detectors → Tap with three fingers**) takes precedence
and disables Paperi's tap. Running with `--verbose` logs each tap's measurements
and why any was rejected.

Set `swipeUpToClose` to `false` to disable upward closing, or `enabled` to `false`
to disable all Paperi swipes. Two-finger scrolling remains available. If macOS
uses the same finger count for a system gesture, Paperi disables its swipe and
shows a warning. See [compatibility notes](MACOS-COMPATIBILITY.md).

## Keyboard shortcuts

`hotkeys` merges over the defaults. Use `null` to remove a binding. Key specs
combine `ctrl`, `alt`, `shift`, and `cmd` with a letter, digit, arrow,
`f1`–`f20`, `space`, `return`, `tab`, `escape`, or a punctuation name.
Values are commands accepted by `paperi msg`.

For command-line use, the installed executable is
`~/Applications/Paperi.app/Contents/MacOS/Paperi` (called `paperi` below).

```sh
paperi msg focus right
paperi msg width + 0.1
paperi msg float
paperi msg reload
paperi msg status
```

Split with left/right uses `split left` or `split right` (bare `split` means left),
with optional bindings ⌥⌘[ and ⌥⌘], disabled by default.
Centering (⌥⌘C) is also disabled by default under Advanced Layout.

Column positioning supports `align left|right|center`; `center` remains available.
Optional layout shortcuts can be enabled in Settings → Shortcuts → Advanced Layout.

Other commands include `focus up|down`, `swap left|right|up|down`,
`height +|-`, `center`, `split`, `slurp`, `barf`, `tray`, `retile`, `pause`, `resume`,
and `stop`. `move` is an alias for `swap`; `refresh` is an alias for `retile`.
`swipe left|right|up|down [travel]` simulates a swipe.
`paperi check-apps` explains which visible windows are eligible.

## Native tab detection

Before tiling a window, Paperi checks whether it belongs to a native macOS tab
group, so that a group's tabs share one column. A window is held back until that
is known. Tab bars drawn by the app itself don't count: a tab group whose tabs
all lack the native tab-button subrole, such as Microsoft Word's ribbon, is
treated as part of the window's content. An element whose role reads back
empty, as some of Zoom's controls do, can't be a tab bar either. Anything
unreadable or ambiguous still holds the window back.

If an app's native tabs end up in separate columns, or its windows jump around
when you switch tabs, add its bundle ID to `strictTabDetection`. Its windows
then wait for complete tab evidence, as in earlier versions; an app with
ribbon-style tab bars stays unmanaged unless you also add it to `singleton`. Use
`["*"]` to apply the strict rules to every app. `paperi check-apps` shows which
rules each app uses (`tabRules`) and the decision for each window.

Zoom uses independent windows by default because its meeting canvas exposes a
custom accessibility tab group. To enable native tab discovery for Zoom, set
`"singletonExclude": ["us.zoom.xos"]` and leave Zoom out of `singleton`.
`strictTabDetection` controls how tab discovery reads evidence; it does not
override singleton settings.

Set `"hotkeysEnabled": false` or turn off **Settings → Shortcuts → Enable shortcuts** to disable all global shortcuts while keeping your bindings. The default is `true`; `--no-hotkeys` takes precedence. Apply Changes saves and applies the toggle.
