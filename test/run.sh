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
gcc -O1 -o "$T/see-through" "$here/see-through.c" -lX11 || exit 1
gcc -O1 -o "$T/caps-lock" "$here/caps-lock.c" -lX11 || exit 1
mkfifo "$T/pad"
printf 'keymap = no\n' > "$T/home/.framerc"   # caps-lock types AltGr+e = euro sign

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

# frame mixes a see-through window with what is under it. It did that in
# the screen buffer, which the real panel reads back about 350 times slower
# than plain memory: a focus change beside a see-through glass took over a
# second. Plain memory here cannot show the delay, so frame counts every
# pixel it mixes in the screen buffer, and that count must stay 0.
echo "== v0.1.42: a see-through window is not mixed in the screen buffer"
is "the screen shows the window mixed with the background" \
   "$("$T/see-through")" "inside 870f17, outside 102030"
kill -USR1 $FPID; sleep 0.3
is "no pixel was mixed in the screen buffer" \
   "$(grep -a FBSTATE "$T/frame.log" | tail -1 | sed -n 's/.* readback=\([0-9]*\).*/\1/p')" 0
rm -f /tmp/frame${D}_*.raw

# ~/bin/toggle-capslock asks for the caps lock light, then locks Lock.
# frame answered neither request: the script hung, and caps lock never
# came on. Letter keys did not read Lock either.
echo "== v0.1.43: caps lock goes on and off"
out=$("$T/caps-lock" "$T/pad")
is "the light is answered, and follows caps lock" "${out%%,*}" "light 0 1 0"
is "with caps lock on, letters are capitals, AltGr and digits are not" \
   "${out#*, }" "on: A a E EuroSign 1, off: a"

echo
if [ $fails -eq 0 ]; then echo "frame tests: all good"; else echo "frame tests: $fails failed"; fi
exit $((fails > 0))
