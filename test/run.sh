#!/bin/bash
# Frame's tests. Each check is a fault that was once reported, and it fails
# on the build from before its fix.
#
#   test/run.sh                       the frame built beside this
#   FRAME=/path/frame test/run.sh
#
# Everything runs on a scratch frame that draws to plain memory and reads
# no real keyboard or touchpad. Nothing here may reach a real desktop.

here=$(cd "$(dirname "$0")" && pwd)
FRAME=${FRAME:-$here/../frame}
unset DISPLAY WAYLAND_DISPLAY

T=$(mktemp -d)
mkdir "$T/home" "$T/stub" "$T/run"
for dummy in xdg-open bare-open notify-send; do
    printf '#!/bin/sh\nexit 0\n' > "$T/stub/$dummy"
    chmod +x "$T/stub/$dummy"
done
export HOME=$T/home PATH=$T/stub:$PATH XDG_RUNTIME_DIR=$T/run
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
gcc -O1 -o "$T/tap" "$here/tap.c" -lX11 || exit 1
gcc -O1 -o "$T/focus-unmap" "$here/focus-unmap.c" -lX11 || exit 1
gcc -O1 -o "$T/prop-watch" "$here/prop-watch.c" -lX11 || exit 1
mkfifo "$T/pad"

D=41; while [ -e /tmp/.X11-unix/X$D ]; do D=$((D + 1)); done
"$FRAME" $D --fbtest --noinput --testinput "$T/pad" 2> "$T/frame.log" &
FPID=$!
trap 'kill $FPID 2>/dev/null; rm -rf "$T" /tmp/.X11-unix/X$D' EXIT
for _ in {1..25}; do [ -S /tmp/.X11-unix/X$D ] && break; sleep 0.2; done
export DISPLAY=:$D

fails=0
is() {                                  # is NAME GOT WANT
    if [ "$2" = "$3" ]; then echo "  ok    $1"
    else echo "  FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}

# The third field is the buttons held just before the event: 0x100 is the
# left button, 0x400 the right. A release always has its own button there.
# GTK4 keeps the mouse pinned to the clicked widget until it reads that.
echo "== v0.1.39: a tap on the touchpad is one whole click"
is "a one-finger tap lets go with the left button held" \
   "$("$T/tap" "$T/pad" tap1)" "press 1 0x000, release 1 0x100"
is "a two-finger tap lets go with the right button held" \
   "$("$T/tap" "$T/pad" tap2)" "press 3 0x000, release 3 0x400"
is "a quick press of the pad's button is one click, with no tap after it" \
   "$("$T/tap" "$T/pad" quick)" "press 1 0x000, release 1 0x100"

# tile hides the old workspace before it moves the keyboard. The hidden
# window was never told, so glass kept a held arrow key down and a game
# went on turning after the switch back.
echo "== v0.1.40: a hidden window is told it lost the keyboard"
is "a window that has the keyboard gets FocusOut when it is hidden" \
   "$("$T/focus-unmap")" "FocusIn 1, UnmapNotify 1, FocusOut 1"

# A copy bigger than one request (256 kB) is sent in pieces. Its owner
# waits for a property event on the taker's window before the next piece.
# frame told only the window's own client, so a pasted screenshot stopped
# after the first piece and the paste hung.
echo "== v0.1.41: a client is told of property changes on another's window"
is "the owner and the watcher both hear a change and a delete" \
   "$("$T/prop-watch")" "owner 2, watcher 2, after it stopped 0, a new client in its place 0"

echo
if [ $fails -eq 0 ]; then echo "frame tests: all good"; else echo "frame tests: $fails failed"; fi
exit $((fails > 0))
