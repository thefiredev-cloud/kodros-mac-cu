#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
dest="${MAC_CU_BIN:-$HOME/.local/bin}"
mkdir -p "$dest"
swiftc -O -target arm64-apple-macosx14.0 mac-cu.swift JsonText.swift -o "$dest/mac-cu"
mkdir -p "$HOME/.agents/skills/mac-cu"
cp skill/SKILL.md "$HOME/.agents/skills/mac-cu/SKILL.md"
"$dest/mac-cu" pos > /dev/null && echo "installed mac-cu to $dest"
