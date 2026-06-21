# frame - Pure Assembly X11 Display Server

<img src="img/frame.svg" align="left" width="150" height="150">

![Version](https://img.shields.io/badge/version-0.0.2-blue)
![Phase](https://img.shields.io/badge/phase-2%2F14-yellow)
![Assembly](https://img.shields.io/badge/language-x86__64%20Assembly-purple)
![License](https://img.shields.io/badge/license-Unlicense-green)
![Platform](https://img.shields.io/badge/platform-Linux%20x86__64-blue)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

X11 display server written in x86_64 Linux assembly. No libc, no
toolkits, no FreeType, no Mesa, no Xlib. Just NASM source, direct
syscalls, the X11 wire protocol on a Unix socket, and the kernel's
DRM/KMS + evdev interfaces.

Long-range goal: serve enough of the X11 wire protocol (core + SHAPE +
RENDER + XKB + COMPOSITE + DAMAGE + RANDR + MIT-SHM + XInput2) to host
the whole [CHasm](https://github.com/isene/chasm) desktop plus
arbitrary X clients — Firefox, VS Code, GIMP, Inkscape — all
software-rendered, all on a stack written end-to-end in asm.

<br clear="left"/>

## Status: phase 1 of 14

| # | Phase | Status |
|---|-------|--------|
| 1 | Connection setup + Unix socket bind | ✓ shipped |
| 2 | DRM/KMS probe (read-only ioctls, no master) | ✓ shipped |
| 2b | DRM/KMS modeset (CreateDumb + AddFB + SetCRTC, needs VT) | next |
| 3 | evdev input + KeyPress / Motion routing | |
| 4 | Window tree + Configure / Reparent / SubstructureRedirect | |
| 5 | Atoms + GetProperty / ChangeProperty / selections | |
| 6 | SHAPE extension | |
| 7 | GCs + drawing primitives | |
| 8 | DRM/KMS atomic modeset upgrade | |
| 9 | RENDER subset for glass emoji + ARGB | |
| 10 | Cursor sprite + keyboard layout + clipboard | |
| 11 | XKB (Firefox-compatible) | |
| 12 | DAMAGE + COMPOSITE + FIXES | |
| 13 | RANDR + MIT-SHM + XInput2 | |
| 14 | First Firefox launch | |

Phase 4 is the "tile runs on frame" milestone — self-hosting CHasm.
Phase 14 is the "Firefox runs on a 50k-line asm X server" milestone.

## Phase 1: what works

```bash
make
./frame                 # listens on display :7 (configurable: ./frame N)
DISPLAY=:7 xdpyinfo     # connects, gets setup reply, sends QueryExtension
```

`frame` accepts an X11 client, validates its 12-byte connection-setup
request (byte-order `l`, protocol 11.0, drains any auth tail), and
emits a structurally valid setup reply describing:

- One screen, 1920×1080, root window XID `0x80`
- Two depths: 24 (TrueColor RGB) and 32 (TrueColor ARGB for glass
  transparency)
- One pixmap format (depth 24 in 32 bpp)

Subsequent requests are logged to stderr (`req opcode=N len=M`) and
silently dropped. Real dispatch lands in phase 4 once the wire is
proven and the DRM backend is in.

## Phase 2: DRM/KMS probe

```bash
./frame --probe
```

Opens `/dev/dri/cardN`, enumerates resources, lists connectors:

```
frame: opened /dev/dri/card1, driver i915 v1.6.0
frame: resources: 4 CRTCs, 5 connectors, 21 encoders
frame: framebuffer range 0x0 to 16384x16384
  connector 507: eDP-1 → connected, 1 modes, preferred 1920x1200 @ 120 Hz
  connector 516: DisplayPort-1 → disconnected, 0 modes
  ...
```

Uses three read-only ioctls — `DRM_IOCTL_VERSION`,
`DRM_IOCTL_MODE_GETRESOURCES`, `DRM_IOCTL_MODE_GETCONNECTOR`. None
require DRM master, so this runs safely alongside an active Xorg.
Proves the kernel-interface struct layouts and ioctl encoding ahead
of phase 2b's `CREATE_DUMB` + `ADDFB` + `SETCRTC` (which do need
master, hence a VT for testing).

## How it's built

Pure NASM, no libc, single static ELF. Following CHasm conventions:

```bash
nasm -f elf64 frame.asm -o frame.o && ld frame.o -o frame
```

State is BSS-allocated (no malloc). Per-client connection state lives
in fixed slots; multi-client work in phase 4.

## License

[Unlicense](https://unlicense.org/) - public domain.

## Credits

Created by Geir Isene (https://isene.org) with pair-programming via
Claude Code.
