#!/bin/bash
# Render the app icon (tools/identity/icon.html) at 1024 px with headless Chrome and write every size of the Bergamota
# app's AppIcon set, plus tools/identity/icon-1024.png (README, web). Needs Google Chrome and sips (macOS).
#   tools/identity/mkicon.sh [CHROME]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
chrome=${1:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}
set_dir=$here/../../apps/Bergamota/Bergamota/Assets.xcassets/AppIcon.appiconset
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$tmp/prof" \
	--force-device-scale-factor=1 --default-background-color=00000000 --window-size=1024,1024 --virtual-time-budget=3000 \
	--screenshot="$tmp/icon.png" "file://$here/icon.html" >/dev/null 2>&1 || true
[ -s "$tmp/icon.png" ] || { echo "mkicon.sh: Chrome rendered nothing" >&2; exit 1; }
cp "$tmp/icon.png" "$here/icon-1024.png"
for s in 16 32 128 256 512; do
	sips -z $s $s "$tmp/icon.png" --out "$set_dir/icon_${s}x${s}@1x.png" >/dev/null
	sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
echo "wrote $set_dir and $here/icon-1024.png"
