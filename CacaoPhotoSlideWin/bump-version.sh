#!/bin/zsh
# Windows 版のバージョンを揃える（Mac 版の project.yml と同じ版にする）。使い方: ./bump-version.sh [x.y.z]（省略時は Mac 版と同じ）
set -euo pipefail
cd "$(dirname "$0")"
new=${1:-$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' ../project.yml | head -1)}
cur=$(sed -n 's/.*"version": "\(.*\)",/\1/p' src-tauri/tauri.conf.json | head -1)
sed -i '' "s/\"version\": \"$cur\"/\"version\": \"$new\"/; s/Windows 版 $cur/Windows 版 $new/" src-tauri/tauri.conf.json package.json
sed -i '' "s/^version = \"$cur\"/version = \"$new\"/" src-tauri/Cargo.toml
echo "$cur → $new"
