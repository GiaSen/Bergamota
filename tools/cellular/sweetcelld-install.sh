#!/bin/sh
# Install sweetcelld in CommCenter's place on the Mi 8 (live on the phone's root; takes effect at the next boot):
#   /usr/local/bin/sweetcelld, launchd.plist with CommCenter's job swapped (launchd-sweetcelld.py), and MobileGestalt's
#   cellular-data = 1 (mg-override.py; Settings shows its Cellular pane only with it). The files it replaces are kept
#   on the phone as /var/root/launchd.plist.before-sweetcelld and /var/root/MobileGestalt.before-sweetcelld.plist
#   (made once: a second run keeps the first backups).
#   tools/cellular/sweetcelld-install.sh             build + install
#   tools/cellular/sweetcelld-install.sh --uninstall put both files back (the binary stays; reboot after either)
set -eu
cd "$(dirname "$0")/../.."
host=${SWEET_HOST:-root@192.168.7.2}
lp=/System/Library/xpc/launchd.plist
mg=/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ "${1:-}" = --uninstall ]; then
	ssh "$host" "test -f /var/root/launchd.plist.before-sweetcelld && cp /var/root/launchd.plist.before-sweetcelld $lp && \
		cp /var/root/MobileGestalt.before-sweetcelld.plist '$mg' && sync && echo restored"
	exit 0
fi
tools/cellular/sweetcelld/build.sh
ssh "$host" "mkdir -p /usr/local/bin /private/var/sweetcell; \
	test -f /var/root/launchd.plist.before-sweetcelld || cp $lp /var/root/launchd.plist.before-sweetcelld; \
	test -f /var/root/MobileGestalt.before-sweetcelld.plist || cp '$mg' /var/root/MobileGestalt.before-sweetcelld.plist"
scp -O -q research/sweetnet/ios18/sweetcelld "$host:/usr/local/bin/sweetcelld"
scp -O -q "$host:/var/root/launchd.plist.before-sweetcelld" "$tmp/launchd.plist"
scp -O -q "$host:/var/root/MobileGestalt.before-sweetcelld.plist" "$tmp/mg.plist"
python3 -I tools/cellular/launchd-sweetcelld.py "$tmp/launchd.plist" "$tmp/launchd.new"
python3 -I tools/cellular/mg-override.py "$tmp/mg.plist" "$tmp/mg.new" cellular-data=1
scp -O -q "$tmp/launchd.new" "$host:$lp"
scp -O -q "$tmp/mg.new" "$host:$mg"
ssh "$host" "chown root:wheel $lp /usr/local/bin/sweetcelld; chmod 644 $lp; chmod 755 /usr/local/bin/sweetcelld; sync; ls -l $lp /usr/local/bin/sweetcelld"
echo "installed: reboot the phone for launchd to start sweetcelld"
