# Build guide: kodros-mac-cu

This tool builds and runs on macOS only. It was not built on the Linux workstation that prepared this guide.

## You need

- macOS 14 or later on Apple Silicon.
- `swiftc`, from Xcode or the Command Line Tools (`xcode-select --install`).
- Accessibility permission for the terminal you run it from: System Settings, Privacy and Security, Accessibility.
- For `capture`: Screen Recording permission for the same terminal.

## Build and install

```bash
git clone https://github.com/thefiredev-cloud/kodros-mac-cu.git
cd kodros-mac-cu
./install.sh
```

`install.sh` does four things:

1. Compiles `mac-cu.swift` and `JsonText.swift` with `swiftc -O -target arm64-apple-macosx14.0`.
2. Writes the binary to `$MAC_CU_BIN`, or `~/.local/bin` if that is unset. Make sure that folder is on your `PATH`.
3. Copies `skill/SKILL.md` to `~/.agents/skills/mac-cu/SKILL.md` so agent tools that read that folder find the usage rules.
4. Runs `mac-cu pos` and prints `installed mac-cu to <folder>` when it works.

To build without installing:

```bash
swiftc -O -target arm64-apple-macosx14.0 mac-cu.swift JsonText.swift -o /tmp/mac-cu
```

## Test

```bash
swiftc JsonText.swift tests/json_text_main.swift -o /tmp/jt && /tmp/jt
```

Only the JSON encoder has an automated test. The GUI commands are tested by hand.

## Try it

```bash
mac-cu apps
mac-cu elements Safari
mac-cu click --element 9 --app Safari
mac-cu get Safari 9
mac-cu capture /tmp/shot.png --app Safari --som
```

Every command prints one line of JSON. The full subcommand list, exit codes and safety notes are in [docs/COMMANDS.md](docs/COMMANDS.md). Rules for agents are in [skill/SKILL.md](skill/SKILL.md).

## Safety

mac-cu drives the real desktop. There is no sandbox, dry run or confirmation prompt. A small blocklist stops a few destructive `type` strings and the lock and log-out shortcuts. It guards against mistakes. It is not a security boundary. Run it only on a machine and account you control.

## Troubleshooting

- Commands return nothing useful or fail on clicks: the terminal lacks Accessibility permission.
- `capture` fails: the terminal lacks Screen Recording permission.
- `swiftc: command not found`: install the Command Line Tools.
