# Configuration

Open **Open Config…** from the menu bar, or edit
`~/Library/Application Support/Paperi/config.json`. All keys are optional.
Choose **Reload Config** after saving. Invalid entries appear in the menu/status.

```json
{
  "gap": 8,
  "outerGap": 8,
  "bottom": "thumbnail",
  "exclude": ["us.zoom.xos"],
  "float": [{"app": "com.apple.finder", "titleContains": "Copy"}],
  "tile": [{"app": "com.apple.systempreferences"}],
  "focusAfterClose": "left",
  "focusScrollDuration": 0.22,
  "gesture": {
    "enabled": true,
    "fingers": 3,
    "travel": 0.4,
    "commitThreshold": 0.5,
    "flickVelocity": 1.5,
    "invert": false,
    "swipeUpToClose": true,
    "swipeDown": "newWindow",
    "swipeDownRight": "closeTab",
    "swipeDownLeft": "minimize",
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
| `singleton` | Array of app bundle IDs whose in-content tab bars should be treated as a plain window. |
| `gap`, `outerGap` | Space between windows and around the layout, in points. |
| `focusAfterClose` | `left` (default), `right`, or `system`. A surviving tab or stacked window keeps the column focused. |
| `focusScrollDuration` | Focus animation in seconds, default `0.22`; `0` disables it. |
| `bottom` | `none`, `dot`, or `thumbnail` (default). Dots stay visible; actual window thumbnails appear for two seconds after layout changes, including focus, window creation/removal, and rearrangement. Click a thumbnail to focus and reveal that window. Thumbnails also appear immediately when a horizontal swipe activates and stay visible through the gesture. Both hide with one window. Thumbnails require Screen Recording permission. Choose from **Show Config → Bottom** or edit this key. |
| `swapHighlight` | Drag preview color as `#RRGGBB` or `#RRGGBBAA`. |

## Gestures

Gestures are on by default with three fingers. `fingers` accepts `3` or `4`.
`travel` is the fraction of trackpad travel for a full gesture; `commitThreshold`
is the progress needed to commit (default `0.5`). A sufficiently long, fast flick
can also commit; `flickVelocity` controls that speed threshold. `invert` reverses
horizontal navigation.

`swipeDown`, `swipeDownRight`, and `swipeDownLeft` each accept `closeTab`,
`newWindow`, `minimize`, or `none`. Their defaults are new window, close tab,
and minimize respectively. Turn right or left after moving down without lifting;
a turn can begin before the downward action is armed. A turn needs a clearly
sideways move (about 6% of the trackpad width, within roughly 27° of
horizontal), so drift while lifting keeps the downward action. Releasing a short
turn cancels both actions; a quick sideways flick commits only after moving
past the point where the turn began. Downward gestures also show hints when a popup or the
desktop has focus; actions target the frontmost app. Minimizing requires a window.

`tabCloseApps` defaults to an empty array. Add apps such as Chrome here to make
swipe up show the tab-close pill and send ⌘W instead of closing the entire window.
Native macOS tab groups are handled automatically. ⌘W can close the window when
it has no tabs remaining.

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

Other commands include `focus up|down`, `swap left|right|up|down`,
`height +|-`, `center`, `split`, `slurp`, `barf`, `retile`, `pause`, `resume`,
and `stop`. `paperi check-apps` explains which visible windows are eligible.
