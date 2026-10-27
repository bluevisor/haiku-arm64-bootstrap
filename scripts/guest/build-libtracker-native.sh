#!/bin/bash
# Build libtracker.so natively on the Haiku arm64 VM (for local Tracker
# patches such as Quick Look, patch 0017) and install it where only Tracker
# loads it.
#   bash build-libtracker-native.sh <haiku-src-root>
# <haiku-src-root> holds src/kits/tracker and
# src/add-ons/input_server/filters/shortcut_catcher at the VM's hrev.
#
# Installs a copy of Tracker in ~/config/non-packaged/apps/TrackerQuickLook
# with the patched lib/libtracker.so beside it, and a user launch override
# that starts Tracker from there. Other apps (Deskbar, anything using
# BFilePanel) keep the system libtracker.
set -euo pipefail
SRC=$(cd "$1" && pwd)
T=$SRC/src/kits/tracker
SC=$SRC/src/add-ons/input_server/filters/shortcut_catcher
OUT=${OUT:-$HOME/src/libtracker-out}
JOBS=${JOBS:-8}
# full private headers (the installed haiku_devel set lacks kernel/util etc.)
P=${HAIKU_PRIVATE_HEADERS:-$HOME/src/guest-tools/headers/private}
mkdir -p "$OUT/obj"

SOURCES=$(sed -n '/SharedLibrary \$(libtracker) :/,/^\t\t\t:/p' "$T/Jamfile" \
	| grep -o '[A-Za-z]*\.cpp')
SOURCES="$SOURCES QuickLookWindow.cpp"

FLAGS="-O2 -fPIC -fasynchronous-unwind-tables -Wno-multichar -D_BUILDING_tracker=1
	-D_SUPPORTS_RESOURCES=1 -I$T -I$T/infowindow -I$SC
	-I$P/interface -I$P/mount -I$P/shared -I$P/storage -I$P/support
	-I$P/tracker -I$P/system -I$P/system/arch/arm64 -I$P/app -I$P/kernel
	-I$P -I$P/libroot"

compile() {
	local f=$1 src
	for dir in "$T" "$T/infowindow" "$SC"; do
		[ -f "$dir/$f" ] && src=$dir/$f && break
	done
	g++ $FLAGS -c "$src" -o "$OUT/obj/${f%.cpp}.o"
}
export -f compile; export FLAGS T SC OUT

# Haiku has no /dev/fd and xargs -P works; keep it simple and portable
printf '%s\n' $SOURCES BitFieldTesters.cpp CommandActuators.cpp KeyInfos.cpp \
	ParseCommandLine.cpp | xargs -P "$JOBS" -I{} bash -c 'compile {}'

g++ -shared -o "$OUT/libtracker.so" -Wl,-soname,libtracker.so "$OUT"/obj/*.o \
	-lbe -llocalestub -lshared -ltranslation -lcolumnlistview -lstdc++

# icons + catalog signature: same as the stock library's resources (the rdef
# files need the C preprocessor, which plain rc does not run)
xres -o "$OUT/libtracker.so" /boot/system/lib/libtracker.so

# Install. launch_daemon puts its inherited environment first, so a job "env"
# cannot override LIBRARY_PATH; but that path starts with %A/lib (the app's
# own folder). So Tracker runs from a copy of its binary in a folder whose
# lib/ holds the patched library, and only Tracker sees it.
APP=$HOME/config/non-packaged/apps/TrackerQuickLook
mkdir -p "$APP/lib"
cp /boot/system/Tracker "$APP/Tracker.tmp"
copyattr /boot/system/Tracker "$APP/Tracker.tmp"
mv -f "$APP/Tracker.tmp" "$APP/Tracker"
cp "$OUT/libtracker.so" "$APP/lib/libtracker.so.tmp"
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
