# mac-cu command reference

Usage is `mac-cu <subcommand> [arguments]`. Coordinates are screen coordinates with the origin at the top left, the same space `pos` reports. Each result is one line of JSON starting with `"ok":true` or `"ok":false`, except the plain-text form of `elements` (see below).

`<app>` is an app name, a bundle identifier, or a process ID. Matching is case-insensitive. An exact name or bundle ID wins, then a substring match.

| Subcommand | Arguments | Behavior |
| --- | --- | --- |
| `apps` | none | Lists apps that have on-screen windows, with `name` and `pid`. |
| `windows` | `<app>` | Lists the app's on-screen windows with `id`, `title`, and `frame` as `[x,y,width,height]`. |
| `elements` | `<app> [filter] [--json]` | Walks the app's accessibility tree and numbers each element that has a positive width and height. `filter` must be the first argument after `<app>`. It keeps elements whose role or label contains the text, case-insensitively. `--json` prints one JSON object. Otherwise it prints a header line and one line per element: `#N Role "label" @ (x,y,wxh) actions=[...]`. See the notes after this table. |
| `get` | `<app> <N> [attribute]` | Reads an accessibility attribute of element N. The default attribute is `AXValue`. |
| `set` | `<app> <N> <text>` | Writes text to the `AXValue` of element N through the accessibility API. It does not need keyboard focus, and apps may not treat it as typing. Extra words are joined with spaces. |
| `click` | `<x> <y>` or `--element <N> --app <app> [--method ax\|coords] [--modifiers list]` | Left click. With `--element`, the default method `ax` runs `AXPress` when the element offers it. Otherwise it clicks the element's center. `--modifiers` takes a comma-separated list of `cmd`, `shift`, `opt` (or `option`, `alt`), `ctrl` (or `control`) and applies only to coordinate clicks on an element. |
| `doubleclick` | same as `click` | Double click. Always uses a coordinate click, never `AXPress`. |
| `rightclick` | same as `click` | Right click. Always uses a coordinate click. |
| `move` | `<x> <y>` | Moves the pointer. |
| `drag` | `<x1> <y1> <x2> <y2>` | Left-button drag from the first point to the second in 10 steps. |
| `scroll` | `<ticks> [x y]` | Scrolls by line. Negative values scroll down. The default is -3, which is also used when `<ticks>` is not an integer. With `x y`, the pointer moves there first. |
| `type` | `<text>` | Types text into whatever has keyboard focus, one character at a time. Extra words are joined with spaces. Blocked patterns are listed below. |
| `key` | `<name>` | Presses one key. Names: `a`, `c`, `delete`, `down`, `enter`, `esc`, `escape`, `k`, `l`, `left`, `q`, `return`, `right`, `space`, `tab`, `up`, `v`, `w`, `x`, `z`. |
| `hotkey` | `<mods+key>` such as `cmd+shift+c` | Presses a key chord. Modifiers are `cmd` (or `command`), `shift`, `opt` (or `option`, `alt`), `ctrl` (or `control`). The key must be one of the `key` names. |
| `wait` | `<seconds>` | Sleeps. The limit is 60 seconds. |
| `wait` | `<app> --text "needle" [--timeout 15]` | Polls the app's accessibility tree every 0.5 seconds until an element label contains the text. The default timeout is 15 seconds and the limit is 120. On timeout it exits with code 4. |
| `capture` | `[path] [--app <app>] [--som]` | Saves a PNG and prints its `path` and pixel `size`. The default path is `/tmp/mac-cu-capture.png`. Without `--app`, it captures the display under the pointer. With `--app`, it captures the app's first on-screen window on layer 0, or its first on-screen window of any layer if none is on layer 0. `--som` draws a numbered box on each element, matching the `elements` numbering, and requires `--app`. Images are rendered at 2x. |
| `pos` | none | Prints the pointer position as `x`, `y` with `"space":"top-left"`. |

Running `mac-cu` with no arguments prints a usage line and exits with code 2. The usage line lists only some subcommands, so use this table as the full list.

Exit codes: 0 on success, 1 on most failures, 2 for missing or unknown subcommands, 3 for missing Accessibility permission, 4 for a `wait` timeout.

Element numbers come from the moment you ran `elements`. Every command that takes `--element` or `<N>` walks the tree again and counts from the start, so run `elements` again after the interface changes and before you click by number.

Notes on `elements`:

- The walk stops after 300 elements and does not go deeper than 10 levels below each window. The cap applies before `filter`, so a filtered list can miss elements past the 300th.
- Numbers are assigned before filtering. A filtered line keeps its number from the full list, which is the number `click`, `get`, and `set` expect.
- A label is the first non-empty value of the description, title, or role description. If all are empty, the first 60 characters of the element's value are used.
- In `--json` output, each element has `index`, `role`, `label`, `frame` as `[x,y,width,height]`, and `actions` as one comma-joined string.

## Safety details

mac-cu drives the real desktop of the logged-in user. It posts events through the system HID event tap, so clicks and keystrokes land in whatever window is under the pointer or has focus, and they compete with a person using the same machine. There is no sandbox, no dry-run mode, and no confirmation prompt.

Two small blocklists exist in the source:

- `type` refuses text that matches any of these patterns, case-insensitively and anywhere in the string: `rm -rf /`, `sudo rm`, `curl ... | sh` or `| bash` or `| zsh`, the same for `wget`, `mkfs`, `dd if=`, `> /dev/sd`, `shutdown`, and `reboot`. Whitespace inside a pattern can be any run of spaces or tabs. A match prints `blocked pattern in type text` and exits with code 1.
- `hotkey` refuses any chord that includes `ctrl+cmd+q` (lock screen) or `shift+cmd+q` (log out). A match prints `blocked shortcut: lock screen / log out` and exits with code 1.

These checks are a guard against common mistakes. They do not make the tool safe against a hostile or confused agent:

- They match substrings, so harmless text that contains `shutdown` or `reboot` is refused, and a command split across several `type` calls is not caught.
- `set` writes text without any pattern check.
- Other shortcuts, such as `cmd+q` or `cmd+w`, are allowed.
- Clicking permission prompts, password fields, and payment screens is allowed. `skill/SKILL.md` tells agents not to click those unless the user asked, but nothing in the code enforces that rule.

If you run an agent with this tool, use a dedicated machine or user account where possible, keep a person within reach of the keyboard, and verify each step with `elements` or `get`.

Known limits:

- JSON strings escape backslash, double quote, and control characters U+0000 through U+001F. `tests/json_text_main.swift` checks that a parsed value matches the input. It does not launch the tool.
- The text form of `elements` prints a header line that is not closed JSON. Use `--json` for machine parsing.
- If ScreenCaptureKit does not list the window that `capture --app` picked, `capture` fails with `capture failed (screen recording permission?)` and writes the reason to stderr. It does not fall back to the display. Without `--app`, a missing display also fails the same way.
- `doubleclick` posts two press and release pairs and does not set the event's click count, so some apps may read them as two single clicks.
- The JSON encoder has a round-trip test. The Mac GUI commands do not.

