#!/bin/sh
# Copy the Mi 8's IPA firmware (ipa_fws.mdt + .b00-.b04, from its Android /vendor/firmware) onto the phone's iOS root,
# where xnu 3073's kern.sweet_ipa stage 3 reads it: /usr/local/share/firmware (as tools/gpu-fw-push.sh does for the
# GPU's zap shader). Taken from the vendor partition backup with e2fsprogs' debugfs; never committed to git.
#   tools/dipper-ipa-fw.sh [VENDOR_IMG]      default backup/dipper/vendor.img
# Needs the phone booted with SSH up (root@192.168.7.2; SWEET_HOST overrides) and `brew install e2fsprogs`.
set -eu
cd "$(dirname "$0")/.."
img=${1:-backup/dipper/vendor.img}
host=${SWEET_HOST:-root@192.168.7.2}
debugfs=$(command -v debugfs || echo /opt/homebrew/opt/e2fsprogs/sbin/debugfs)
[ -x "$debugfs" ] || { echo "no debugfs (brew install e2fsprogs)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in ipa_fws.mdt ipa_fws.b00 ipa_fws.b01 ipa_fws.b02 ipa_fws.b03 ipa_fws.b04; do
	"$debugfs" -R "dump /firmware/$f $tmp/$f" "$img" >/dev/null 2>&1
	[ -s "$tmp/$f" ] || { echo "$f not in $img" >&2; exit 1; }
done
dest=/usr/local/share/firmware
ssh "$host" "mkdir -p $dest"
for f in "$tmp"/ipa_fws.*; do
	ssh "$host" "cat > $dest/$(basename "$f") && chmod 644 $dest/$(basename "$f")" < "$f"
	echo "pushed $(basename "$f") ($(wc -c < "$f" | tr -d ' ') bytes)"
done
ssh "$host" "sync; ls -l $dest/ipa_fws.*"
