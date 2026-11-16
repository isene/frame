#!/bin/bash
# A hidden two-screen frame (3840x1080) with a wallpaper whose every
# pixel tells its own place; four pixels read back must match.
F=${1:-$(dirname "$(readlink -f "$0")")/../frame}
T=$(mktemp -d /tmp/frame-wall.XXXX); mkdir "$T/home"
python3 - "$T/wall.raw" <<'PY'
import sys
w, h = 3840, 1080
row = bytearray(w * 4)
with open(sys.argv[1], "wb") as f:
    for y in range(h):
        for x in range(w):
            row[x*4:x*4+4] = bytes((x & 255, y & 255, x >> 8, 255))
        f.write(row)
PY
printf 'background = %s\n' "$T/wall.raw" > "$T/home/.framerc"
D=71; while [ -e /tmp/.X11-unix/X$D ]; do D=$((D + 1)); done
HOME=$T/home "$F" $D --fbtest2 --noinput 2> "$T/frame.log" &
FPID=$!
for _ in {1..25}; do [ -S /tmp/.X11-unix/X$D ] && break; sleep 0.2; done
DISPLAY=:$D HOME=$T/home scrot "$T/shot.png" 2>/dev/null
python3 - "$T/shot.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
print("screen", im.size)
bad = 0
for x, y in ((0, 0), (700, 300), (1919, 1079), (1920, 0), (2600, 500), (3839, 1079)):
    want = (x >> 8, y & 255, x & 255)
    got = im.getpixel((x, y))
    if got != want: bad += 1
    print(x, y, "ok" if got == want else f"WRONG got {got} want {want}")
print("wrong:", bad)
sys.exit(1 if bad else 0)
PY
rc=$?
kill $FPID; sleep 0.3
rm -rf "$T" /tmp/.X11-unix/X$D
exit $rc
