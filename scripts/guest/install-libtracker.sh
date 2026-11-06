#!/bin/bash
# Install a libtracker.so with local Tracker patches (Quick Look, patch 0017)
# so that only Tracker loads it.
#   bash install-libtracker.sh <libtracker.so>
# The library comes from build-haiku-system.sh (/build/out/hrevN/libtracker.so)
# or build-libtracker-native.sh. It must match the installed hrev. Takes effect
# the next time Tracker starts (reboot, or kill Tracker's team).
set -euo pipefail
LIB=$1

# Install. launch_daemon puts its inherited environment first, so a job "env"
# cannot override LIBRARY_PATH; but that path starts with %A/lib (the app's
# own folder). So Tracker runs from a copy of its binary in a folder whose
# lib/ holds the patched library, and only Tracker sees it.
APP=$HOME/config/non-packaged/apps/TrackerQuickLook
mkdir -p "$APP/lib"
cp /boot/system/Tracker "$APP/Tracker.tmp"
copyattr /boot/system/Tracker "$APP/Tracker.tmp"
mv -f "$APP/Tracker.tmp" "$APP/Tracker"
cp "$LIB" "$APP/lib/libtracker.so.tmp"
mv -f "$APP/lib/libtracker.so.tmp" "$APP/lib/libtracker.so"

LAUNCH=$HOME/config/settings/launch
mkdir -p "$LAUNCH"
cat > "$LAUNCH/tracker-quicklook" <<EOF
# Run Tracker with the locally patched libtracker (Quick Look, patch 0017).
# Delete this file and reboot to go back to the stock Tracker.
service x-vnd.Be-TRAK {
	launch $APP/Tracker
}
EOF
rm -f "$LAUNCH/tracker-libtracker"
echo "installed $APP; restart Tracker (kill its team; launch_daemon relaunches it) to use it"
