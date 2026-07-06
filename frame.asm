; ============================================================================
; frame — pure x86_64 NASM X11 display server for the CHasm suite.
;
; Long-range goal: serve enough of the X11 wire protocol (core + SHAPE +
; RENDER + XKB + COMPOSITE + DAMAGE + RANDR + MIT-SHM + XInput2) to host
; tile + glass + spot + the asmites + arbitrary X clients including
; Firefox / VS Code / GIMP. DRM/KMS for output, evdev for input, software
; compositor in between. No libc, no toolkits, no dynamic linking.
;
; Phase 1 (this file): connection setup. Listen on /tmp/.X11-unix/X<N>,
; accept clients, validate the 12-byte connection setup request, emit a
; valid setup reply describing one screen with a 24-bit TrueColor root
; visual and a 32-bit TrueColor ARGB visual (for glass transparency).
; Subsequent requests are logged to stderr and silently dropped so we
; can see what clients ask for next without crashing.
;
; Display number: argv[1] (default 7). Pick something unused so this
; can coexist with a running Xorg on :0.
;
; Build: nasm -f elf64 frame.asm -o frame.o && ld frame.o -o frame
; Run:   ./frame                # uses display :7
;        DISPLAY=:7 xeyes       # connect a test client
; ============================================================================

BITS 64
DEFAULT REL

; ---- Linux x86_64 syscalls -------------------------------------------------
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_SENDTO      44
%define MSG_DONTWAIT    0x40
; EV_SEND — non-blocking event write: sendto(edi=fd, rsi=buf, rdx=len,
; MSG_DONTWAIT). A client that stops draining its socket (a stalled GTK4
; app) must NOT block the single-threaded server — its next event write
; would otherwise hang the WHOLE server (frozen screen + dead input). On
; would-block the event is simply DROPPED; events are lossy by nature, so
; a missed motion/crossing is harmless and the client resyncs. Replies
; stay blocking (request-driven; the client IS waiting on them).
%macro EV_SEND 0
    mov rax, SYS_SENDTO
    mov r10d, MSG_DONTWAIT
    xor r8d, r8d
    xor r9d, r9d
    syscall
    cmp rax, -11                 ; EAGAIN: client socket full, event dropped —
    jne %%ok                     ; count it (SIGUSR1 FBSTATE line reports it;
    inc dword [ev_dropped]       ; diagnosing "client went stale" reports)
%%ok:
%endmacro
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_LSEEK       8
%define SYS_UNLINK      87
%define SYS_EXIT        60
%define SYS_RT_SIGACTION   13
%define SYS_RT_SIGRETURN   15
%define SIGINT          2
%define SIGTERM         15
%define SIGHUP          1
%define SIGUSR1         10
%define SA_RESTORER     0x04000000
%define SYS_SOCKET      41
%define SYS_BIND        49
%define SYS_LISTEN      50
%define SYS_ACCEPT      43
%define SYS_GETSOCKNAME 51
%define SYS_RECVFROM    45
%define SYS_IOCTL       16

%define AF_UNIX         1
%define SOCK_STREAM     1
%define DEFAULT_DISPLAY 7
%define O_RDWR          0x2

; ---- DRM/KMS ABI ----------------------------------------------------------
; Linux ioctl encoding: (dir<<30) | (size<<16) | (type<<8) | nr
; type 'd' = 0x64, dir _IOWR = 3.
;
; struct drm_version            = 64 bytes  → 0xC0406400
; struct drm_mode_card_res      = 64 bytes  → 0xC04064A0
; struct drm_mode_get_connector = 80 bytes  → 0xC05064A7
%define DRM_IOCTL_VERSION              0xC0406400
%define DRM_IOCTL_SET_MASTER           0x0000641E
%define DRM_IOCTL_DROP_MASTER          0x0000641F
%define DRM_IOCTL_MODE_GETRESOURCES    0xC04064A0
%define DRM_IOCTL_MODE_GETCRTC         0xC06864A1
%define DRM_IOCTL_MODE_SETCRTC         0xC06864A2
%define DRM_IOCTL_MODE_GETENCODER      0xC01464A6
%define DRM_IOCTL_MODE_GETCONNECTOR    0xC05064A7
%define DRM_IOCTL_MODE_ADDFB           0xC01C64AE
%define DRM_IOCTL_MODE_RMFB            0xC00464AF
%define DRM_IOCTL_MODE_DIRTYFB         0xC01864B7
%define DRM_IOCTL_MODE_PAGE_FLIP       0xC01864B0
%define DRM_MODE_PAGE_FLIP_EVENT       0x01
%define DRM_IOCTL_MODE_CREATE_DUMB     0xC02064B2
%define DRM_IOCTL_MODE_MAP_DUMB        0xC01064B3
%define DRM_IOCTL_MODE_CURSOR          0xC01C64A3   ; _IOWR('d',0xA3,28)
%define DRM_MODE_CURSOR_BO             0x01
%define DRM_MODE_CURSOR_MOVE           0x02
%define DRM_IOCTL_MODE_DESTROY_DUMB    0xC00464B4

%define SYS_POLL        7
%define SYS_MMAP        9
%define SYS_MUNMAP      11
%define SYS_SHMGET      29
%define SYS_SHMAT       30
%define SYS_SHMCTL      31
%define SYS_SHMDT       67
%define IPC_STAT        2
%define SHM_RDONLY      0x1000
%define SYS_NANOSLEEP   35
%define SYS_CLOCK_GETTIME 228
%define CLOCK_MONOTONIC 1
%define PROT_RW         3            ; PROT_READ | PROT_WRITE
%define MAP_SHARED      1
%define MAP_PRIVATE     2
%define MAP_ANONYMOUS   0x20

; ---- evdev / input ABI ----------------------------------------------------
; struct input_event on 64-bit:
;   __kernel_long_t tv_sec   (8)
;   __kernel_long_t tv_usec  (8)
;   __u16  type              (2)
;   __u16  code              (2)
;   __s32  value             (4)
; = 24 bytes total.
%define INPUT_EVENT_SIZE   24
%define EV_SYN             0
%define EV_KEY             1
%define EV_REL             2
%define EV_ABS             3
%define EV_MSC             4
%define EV_SW              5

; EVIOCGNAME(64): _IOC(_IOC_READ, 'E', 0x06, 64)
; (dir<<30) | (size<<16) | (type<<8) | nr = (2<<30) | (64<<16) | (0x45<<8) | 6
%define EVIOCGNAME_64      0x80404506
%define INPUT_DEV_MAX      32         ; scan /dev/input/event0..31
%define INPUT_BATCH_BYTES  768        ; 32 events × 24 bytes

%define DRM_MODE_CONNECTED      1
%define DRM_MODE_DISCONNECTED   2
%define DRM_MODE_UNKNOWNCONN    3

; drm_mode_modeinfo size — 68 bytes per mode
%define DRM_MODE_INFO_SIZE      68
%define DRM_MAX_MODES           64
%define DRM_MAX_PROPS           64
%define DRM_MAX_IDS             32

; ---- X11 protocol constants ------------------------------------------------
%define X_PROTO_MAJOR        11
%define X_PROTO_MINOR        0
%define X_VENDOR_LEN         5            ; "frame"
%define X_RELEASE_NUMBER     0            ; bump when we ship phase 1

; Pixmap format: depth 24 packed in 32-bit pixels (the standard for ARGB-
; capable visuals). The setup reply must list one for each depth the
; server advertises that's > 1.
%define X_FMT_BPP            32
%define X_SCANLINE_PAD       32
%define X_SCANLINE_UNIT      32
%define X_BITMAP_BIT_ORDER   0            ; LSB-first
%define X_IMAGE_BYTE_ORDER   0            ; LSB-first

; Screen / visual
%define X_SCREEN_W           1920
%define X_SCREEN_H           1080
%define X_SCREEN_W_MM        508          ; ~24" at 96 dpi (placeholder)
%define X_SCREEN_H_MM        286
%define X_ROOT_WINDOW        0x00000080   ; arbitrary, server-allocated

; CW* (CreateWindow / ChangeWindowAttributes) value-mask bits, in the
; order set bits are walked LSB → MSB.
%define CW_BACK_PIXMAP       0x0001
%define CW_BACK_PIXEL        0x0002
%define CW_BORDER_PIXMAP     0x0004
%define CW_BORDER_PIXEL      0x0008
%define CW_BIT_GRAVITY       0x0010
%define CW_WIN_GRAVITY       0x0020
%define CW_BACKING_STORE     0x0040
%define CW_BACKING_PLANES    0x0080
%define CW_BACKING_PIXEL     0x0100
%define CW_OVERRIDE_REDIRECT 0x0200
%define CW_SAVE_UNDER        0x0400
%define CW_EVENT_MASK        0x0800
%define CW_DONT_PROPAGATE    0x1000
%define CW_COLORMAP          0x2000
%define CW_CURSOR            0x4000

; X11 event-mask bits (subset). SubstructureRedirectMask redirects
; child MapWindow / ConfigureWindow to whichever client set it (the
; WM). SubstructureNotifyMask sends MapNotify / ConfigureNotify /
; DestroyNotify to the same subscriber.
%define EM_STRUCTURE_NOTIFY      0x00020000
%define EM_PROPERTY_CHANGE       0x00400000
%define EM_SUBSTRUCTURE_NOTIFY    0x00080000
%define EM_SUBSTRUCTURE_REDIRECT  0x00100000

; ConfigureWindow value-mask bits.
%define CFG_X                0x01
%define CFG_Y                0x02
%define CFG_WIDTH            0x04
%define CFG_HEIGHT           0x08
%define CFG_BORDER_WIDTH     0x10
%define CFG_SIBLING          0x20
%define CFG_STACK_MODE       0x40
%define X_DEFAULT_CMAP       0x00000081
%define X_ROOT_VISUAL_24     0x00000020   ; depth-24 TrueColor
%define X_ROOT_VISUAL_32     0x00000021   ; depth-32 TrueColor + alpha
%define X_MIN_KEYCODE        8
%define X_MAX_KEYCODE        255
%define X_VISUAL_TRUECOLOR   4

; Resource ID space we give to the first client. With one client this is
; safe; multi-client work later will allocate non-overlapping ranges.
%define X_RID_BASE           0x00400000

; ---- RENDER extension (phase 9) -------------------------------------------
; Major opcode we advertise for RENDER via QueryExtension. Clients then
; send requests with this as byte 0 and the RENDER minor opcode as byte 1.
%define RENDER_MAJOR         140
%define RENDER_ERROR_BASE    128
%define RENDER_VERSION_MAJOR 0
%define RENDER_VERSION_MINOR 11
; ---- XKEYBOARD (XKB) extension — gateway for Qt/GTK (xkbcommon-x11) ---------
%define XKB_MAJOR            135
%define XKB_EVENT_BASE       85
%define XKB_ERROR_BASE       137
; ---- RANDR extension — gives toolkits real screen geometry (1 crtc/output/mode)
%define RR_MAJOR             139
%define RR_EVENT_BASE        89
%define RR_ERROR_BASE        147
%define RR_CRTC_ID           0x60
%define RR_OUTPUT_ID         0x61
%define RR_MODE_ID           0x62
; ---- XInputExtension (XInput2) — required by GTK4, queried by Qt -----------
%define XI_MAJOR             131
%define XI_EVENT_BASE        91
%define XI_ERROR_BASE        151
; ---- XFIXES extension — clipboard MANAGERS (copyq) + Qt/Firefox use
; XFixesSelectSelectionInput to be told when a selection owner changes.
%define XFIXES_MAJOR         138
%define XFIXES_EVENT_BASE    93          ; XFixesSelectionNotify = base+0
%define XFIXES_ERROR_BASE    155
%define SHM_MAJOR            130         ; MIT-SHM (shared-memory image transfer)
%define SHM_EVENT_BASE       94          ; ShmCompletion = base+0
%define SHM_ERROR_BASE       156         ; BadShmSeg

%define XTEST_MAJOR          128         ; XTEST (copyq paste, xdotool)
%define SHAPE_MAJOR          129         ; SHAPE (spot's dim-with-hole overlays)
%define SHAPE_EVENT_BASE     92          ; ShapeNotify = base+0 (never sent yet)
%define SHAPE_MAX_SLOTS      8           ; shaped windows are rare (spot = 1)
%define SHAPE_MAX_RECTS      2048        ; spot: 2 bands + 2 slivers × 2R rows ≈ 562
%define SHAPE_SLOT_SIZE      (16 + SHAPE_MAX_RECTS*8)
%define SHAPE_KIND_BOUNDING  0
%define SHAPE_KIND_INPUT     2
%define X_RID_MASK           0x001FFFFF

; ============================================================================
; BSS — connection + per-client state
; ============================================================================
SECTION .bss
align 8

envp:               resq 1
listen_fd:          resq 1
client_fd:          resq 1
display_num:        resq 1
keymap_is_no:       resb 1                 ; ~/.framerc keymap=no → Norwegian
pending_vt:         resd 1                 ; Ctrl+Alt+Fn target VT for switch_vt
mouse_sens:         resd 1                 ; pointer sensitivity %, ~/.framerc (def 100)
cursor_rgb:         resd 1                 ; cursor fill colour 0xRRGGBB (def white)
cursor_transp:      resd 1                 ; cursor % transparent (def 50)
cursor_argb:        resd 1                 ; computed premultiplied interior pixel
; Cursor shapes (client-assigned per-window/grab cursors → baked sprites).
; Sprites: 0 arrow, 1 accent arrow (pressables — hand1/hand2), 2 I-beam
; (text fields — xterm), 3 crosshair (scrot -s), 4 blank (typing hides it).
%define MAX_CURSORS  128
%define CUR_ARROW    0
%define CUR_ACCENT   1
%define CUR_IBEAM    2
%define CUR_CROSS    3
%define CUR_BLANK    4
cursor_tab:         resb MAX_CURSORS * 8   ; +0 cursor xid, +4 sprite id
cursor_tab_next:    resd 1                 ; rotating evict index when full
cur_shape:          resd 1                 ; sprite currently in the BO
cur_hot_x:          resd 1                 ; hotspot of that sprite
cur_hot_y:          resd 1
cfg_cursor_accent:  resd 1                 ; ~/.framerc cursor_accent RRGGBB
ptr_grab_cursor:    resd 1                 ; GrabPointer's cursor arg (scrot)
netwm_cm_atom_srv:  resd 1                 ; _NET_WM_CM_S0 (frame = compositor)
; ~/.framerc `background = <path>`: a pre-decoded BGRX buffer at panel
; resolution (screen_w*screen_h*4). frame blits it as the compositor
; background instead of the solid COMP_BG_COLOR. No image decoder in the
; server — a helper (frame-bg) resizes any image to raw ONCE, offline.
wallpaper_ptr:      resq 1                 ; ptr into wallpaper_buf, or 0 = solid bg
wallpaper_path:     resb 256               ; the raw file path from framerc
; Selection ownership (SetSelectionOwner / GetSelectionOwner). Small table;
; the system tray needs strip to OWN _NET_SYSTEM_TRAY_S0 and apps to find it.
SEL_MAX             equ 8
sel_atoms:          resd SEL_MAX
sel_owners:         resd SEL_MAX
sel_count:          resd 1
; XFIXES SelectSelectionInput subscriptions. Each: +0 slot (-1 = empty),
; +4 selection atom, +8 window. Fires XFixesSelectionNotify to that client
; when the selection's owner changes (SetSelectionOwner). This is how copyq
; (Qt) tracks the system clipboard.
XFIXES_SUB_MAX      equ 16
xfixes_subs:        resb XFIXES_SUB_MAX * 12
xfixes_sub_evbuf:   resb 32
; MIT-SHM attached segments. Each entry (24 bytes): +0 shmseg id (u32, 0=empty),
; +4 owning client slot (u32), +8 attached address (u64), +16 segment size (u64).
; ShmPutImage reads the client's rendered image straight out of the mapped
; segment — no image bytes on the wire. Detached on ShmDetach + client death.
SHM_SEG_MAX         equ 32
shm_segs:           resb SHM_SEG_MAX * 32  ; +0 shmseg +4 slot +8 addr
                                           ; +16 size +24 readonly flag
shmid_ds_buf:       resb 128               ; shmctl(IPC_STAT) scratch (shm_segsz @ +48)

; ---- SHAPE state ------------------------------------------------------------
; Per (window, kind) rect lists. Slot: +0 xid, +4 kind, +8 count, +12 pad,
; +16 rects (x s16, y s16, w u16, h u16 each, window-local). A slot with
; count 0 is a SET empty region (input: click-through) — distinct from no
; slot at all (unshaped).
shape_slots:        resb SHAPE_MAX_SLOTS * SHAPE_SLOT_SIZE
xtest_fake_ev:      resb 24                ; synthetic input_event for FakeInput

; ---- screen auto-off (framerc blank_timeout, default 600s, 0 = never) ----
cfg_blank_ms:       resd 1                 ; idle ms before panel off
blank_state:        resb 1                 ; 1 = panel currently off
    alignb 8
last_input_mono:    resq 1                 ; CLOCK_MONOTONIC ms of last input
mono_ts:            resq 2                 ; clock_gettime scratch
blank_crtc_cmd:     resb 104               ; zeroed SETCRTC = CRTC off
cfg_blankkey_sym:   resd 1                 ; blank_key keysym (0 = none)
cfg_blankkey_mods:  resb 1                 ; blank_key required mod_state
blank_kc:           resd 1                 ; blank_key resolved X keycode
bws_clip_save:      resd 4                 ; blit_window_shaped clip save
bws_abs_x:          resd 1
bws_abs_y:          resd 1
sih_result:         resb 1                 ; shape_input_hit scratch flag
framerc_path:       resb 256               ; "$HOME/.framerc"
framerc_buf:        resb 2048              ; ~/.framerc contents
WALL_MAX            equ 1920*1200*4        ; max backing for the wallpaper (panel res)
wallpaper_buf:      resb WALL_MAX          ; the raw BGRX pixels, read from the file once
rc_remaps:          resb 16 * 28           ; staged `keycode` lines: keycode
                                           ; dword + 6 keysym dwords each
rc_remap_count:     resd 1

; ---- Phase 4 multi-client state -------------------------------------------
; clients_meta[16] — one 16-byte slot per concurrent client.
;   +0 fd (s32)          -1 = empty slot
;   +4 state (u8)        0 = SETUP, 1 = RUNNING
;   +5 pad (3)
;   +8 seq (u32)         next sequence number to assign
;   +12 buf_used (u32)   bytes valid in this client's read buffer
; Sized to fit Geir's actual session: tile + strip + 12+ glass + firefox
; + kastrup + tock + spot + nm-applet + polkit-gnome + ... often pushes
; well past 32 concurrent X clients. Each idle slot costs nothing (BSS
; demand-pages; the kernel never allocates physical RAM for a buffer
; the client never connects on). Committed cost at startup is ~2 KB
; (clients_meta is touched by init_clients).
;
; CLIENT_BUF_SIZE must hold the largest single request a client can
; send. The setup reply advertises max-request-length = 65535 4-byte
; units = 256 KB, so a PutImage (or any big request) can legitimately
; be that large. An 8 KB buffer dropped clients mid-PutImage in 4g.
; 256 KB × 128 slots = 32 MB of BSS reservation — demand-paged, so
; only touched pages cost real memory.
%define MAX_CLIENTS      128
%define CLIENT_META_SIZE 16
%define CLIENT_BUF_SIZE  262144
%define CSTATE_SETUP     0
%define CSTATE_RUNNING   1
clients_meta:       resb MAX_CLIENTS * CLIENT_META_SIZE
clients_bufs:       resb MAX_CLIENTS * CLIENT_BUF_SIZE

; pollfd_buf — listen_fd + up to MAX_CLIENTS client fds + up to
; MAX_INPUTS evdev devices. Rebuilt each poll iteration; ~1.2 KB of
; writes at full census, sub-microsecond. MAX_INPUTS is defined further
; down (16) — total = 1 + 128 + 16 = 145 entries.
pollfd_buf:         resb (MAX_CLIENTS + 1 + 16 + 3) * 8   ; +1: drm_fd (flip events)
                                                          ; +1: uevent_fd (hotplug)
                                                          ; +1: vtactive_fd (VT watch)

; Atom interning table. Atom 0 = None. Atoms 1..predef_count_max are
; X11's predefined set (PRIMARY, ATOM, STRING, WM_NAME, ...).
; Subsequent IDs allocated on demand by InternAtom. The strings live
; packed in atom_strings; per-atom offset+length stored in
; atom_off[] / atom_len[].
%define MAX_ATOMS        512
%define ATOM_STRINGS_CAP 16384
atom_count:         resd 1                   ; number of atoms allocated (1-based; entry 0 unused)
atom_strings_used:  resd 1                   ; bytes used in atom_strings
atom_off:           resd MAX_ATOMS
atom_len:           resd MAX_ATOMS
atom_strings:       resb ATOM_STRINGS_CAP

; Scratch reply buffer. 32-byte reply header + room for bodies up to a
; few KB (GetKeyboardMapping returns count × keysyms_per_keycode × 4
; bytes — at the full keycode range plus 1 keysym/keycode that's ~1 KB;
; future reply types like QueryFont return more).
reply_buf:          resb 16384
pn_buf:             resb 32                  ; PropertyNotify scratch event
xkb_getmap_present: resd 1               ; GetMap reply present mask (echoes req)

; ---- Phase 4b/4g window table ---------------------------------------------
; windows[MAX_WINDOWS] — one 48-byte record per live window. Slot 0
; pre-occupied at startup by the root window (XID = X_ROOT_WINDOW). A
; slot with xid = 0 is empty.
;
; Layout (48 bytes):
;   +0  xid (u32)           0 = empty slot
;   +4  parent (u32)
;   +8  x  (s16)
;   +10 y  (s16)
;   +12 width  (u16)
;   +14 height (u16)
;   +16 border_width (u16)
;   +18 depth  (u8)
;   +19 class  (u8)  1=InputOutput 2=InputOnly
;   +20 visual (u32)
;   +24 event_mask (u32) — SubstructureRedirect / etc. for tile's root grab
;   +28 mapped (u8)
;   +29 override_redirect (u8)
;   +30 redirect_owner (s8)  — phase 4e: slot of the WM that set
;                              SubstructureRedirectMask, or -1
;   +31 has_backing (u8)     — phase 4g: 1 once backing_ptr is mmap'd
;   +32 backing_ptr (q)      — phase 4g: per-window ARGB pixel buffer
;                              (backing_w*backing_h*4), lazily mmap'd
;   +40 backing_w (u16)      — backing buffer width (= stride, pixels)
;   +42 backing_h (u16)      — backing buffer height
;   +44 back_pixel (u32)     — CW_BACK_PIXEL; backing init colour
;   +48 stk (u32)            — z-order
;   +52 xi2_mask (u32)       — XI2 event selection bits
;   +56 border_pixel (u32)   — CW_BORDER_PIXEL; drawn by the compositor
;                              when border_width (+16) > 0 (tile's focus ring)
;   +60 cursor (u32)         — CW_CURSOR; cursor xid shown over this window
%define MAX_WINDOWS      512
%define WINDOW_REC_SIZE  64          ; was 56; +56 border_pixel, +60 cursor
windows:            resb MAX_WINDOWS * WINDOW_REC_SIZE
win_stk_next:       resd 1               ; monotonic z-order; ++ on each map/raise
rs_last_stk:        resd 1               ; recomposite: stk of last window drawn
rs_counter:         resd 1               ; DIAG: recomposite invocation count
rs_min_stk:         resd 1               ; recomposite: min stk found this pass

; ---- Phase 4g graphics-context table --------------------------------------
; gcs[MAX_GCS] — 16-byte records keyed by GC XID. Clients create GCs with
; CreateGC, reference them by XID in every drawing request.
;   +0  gcid (u32)          0 = empty slot
;   +4  foreground (u32)
;   +8  background (u32)
;   +12 pad (4)
%define MAX_GCS          256
%define GC_REC_SIZE      16
gcs:                resb MAX_GCS * GC_REC_SIZE

; ---- clip rectangles ---------------------------------------------------
; GTK partial repaints paint only the damaged rects of a buffer pixmap and
; blit its whole bounds with a clip set to the damage region. Ignoring the
; clip splashes the buffer's unpainted (zero = black) gaps over neighbours
; — the "GIMP goes black on every interaction" bug. One clip entry per GC
; (core SetClipRectangles, op 59) and per Picture (RENDER minors 5/6).
; Entry: +0 count (s32: 0 = no clip, -1 = empty clip = draw nothing,
; else n) then n rects of x1,y1,x2,y2 (s32, absolute drawable coords,
; x2/y2 exclusive, clip origin already added). Lists longer than
; CLIP_MAX_RECTS keep the first CLIP_MAX_RECTS rects (never bbox —
; bbox over-copies the paint buffer's zero gaps → black splash).
%define CLIP_MAX_RECTS   64
%define CLIP_ENTRY_SIZE  1028                ; 4 + CLIP_MAX_RECTS*16
gc_clips:           resb MAX_GCS * CLIP_ENTRY_SIZE
cur_clip:           resq 1               ; active clip entry for the op in
                                         ; flight (0 = unclipped); set by each
                                         ; consumer right before drawing
last_enter_win:     resd 1               ; window the pointer was last inside —
                                         ; drives EnterNotify/LeaveNotify. GTK
                                         ; menu items prelight + activate on
                                         ; crossings, not motion.

; ---- Phase 4h pixmap table ------------------------------------------------
; pixmaps[MAX_PIXMAPS] — offscreen drawables. Like a window's backing
; store but with no position/mapping. CopyArea and the drawing ops treat
; windows and pixmaps uniformly via drawable_get_backing.
;   +0  pid (u32)           0 = empty slot
;   +4  width (u16)
;   +6  height (u16)
;   +8  depth (u8)
;   +9  pad (7)
;   +16 backing_ptr (q)     — mmap'd ARGB buffer (w*h*4)
%define MAX_PIXMAPS      256
%define PIXMAP_REC_SIZE  24
pixmaps:            resb MAX_PIXMAPS * PIXMAP_REC_SIZE

; ---- Phase 9 RENDER Picture table -----------------------------------------
; A Picture wraps a drawable (window or pixmap) + a picture format for use
; as a RENDER source/destination. We track just the mapping; drawing
; resolves the drawable to its backing buffer.
;   +0  pid (u32)          0 = empty
;   +4  drawable (u32)
;   +8  format (u32)
;   +12 pad
%define MAX_PICTURES     256
%define PICTURE_REC_SIZE 16
pictures:           resb MAX_PICTURES * PICTURE_REC_SIZE
pic_clips:          resb MAX_PICTURES * CLIP_ENTRY_SIZE  ; see gc_clips
; Per-picture affine transform (RENDER SetPictureTransform, minor 28).
; +0 flag (0 identity/none), +4 m11 m12 m13 m21 m22 m23 (FIXED 16.16).
; The projective row is ignored (cairo emits affine only). GIMP renders
; its zoomed canvas via a transformed Composite; dropping the transform
; made the sampling miss the source entirely → black canvas.
pic_xforms:         resb MAX_PICTURES * 28
co_src_xform:       resq 1               ; active src transform for composite
; A Picture with drawable == PICTURE_SOLID is a CreateSolidFill source;
; its ARGB colour is stored in the format field.
%define PICTURE_SOLID    0xFFFFFFFF

; ---- Phase 9 RENDER glyph storage -----------------------------------------
; Glyph sets hold client-rasterised A8 coverage masks. CompositeGlyphs
; blends a solid source through each glyph's mask onto a dst Picture.
;   glyphsets[]: gsid (u32, 0=empty) + format (u32)
;   glyph_recs[]: gsid@0, glyphid@4, width@8(u16), height@10(u16),
;                 gx@12(s16), gy@14(s16), xoff@16(s16), yoff@18(s16),
;                 bitmap_off@20(u32 into glyph_pool), stride@24(u16), pad
%define MAX_GLYPHSETS    64
%define GLYPHSET_REC     8
glyphsets:          resb MAX_GLYPHSETS * GLYPHSET_REC
%define MAX_GLYPHS       8192
%define GLYPH_REC_SIZE   32
glyph_recs:         resb MAX_GLYPHS * GLYPH_REC_SIZE
glyph_count:        resd 1
%define GLYPH_POOL_SIZE  8388608      ; 8 MB A8 bitmap pool (demand-paged)
glyph_pool:         resb GLYPH_POOL_SIZE
glyph_pool_used:    resd 1
; CompositeGlyphs per-call context (constant across the glyph list).
cg_dst_ptr:         resq 1
cg_dst_stride:      resd 1
cg_dst_h:           resd 1
cg_src:             resd 1               ; 8-bit ARGB source colour
gb_bpp:             resd 1               ; current glyph bytes-per-pixel (1=A8, 4=ARGB)
; RENDER Composite (minor 8) per-call context.
co_src_ptr:         resq 1
co_src_stride:      resd 1
co_src_w:           resd 1
co_src_h:           resd 1
co_src_solid:       resd 1               ; 1 if src is a solid-fill colour
co_src_color:       resd 1
co_dst_ptr:         resq 1
co_dst_stride:      resd 1
co_dst_h:           resd 1
tz_dst_ptr:         resq 1               ; render_trapezoids: dst backing
tz_dst_stride:      resd 1
tz_dst_h:           resd 1
tz_dst_drawable:    resd 1
tz_color:           resd 1               ; resolved opaque ARGB source colour
ag_log_count:       resd 1               ; debug: limit AddGlyphs dumps

; ---- Phase 4c property table ----------------------------------------------
; properties[1024] — flat list of (window, atom) → value records. xid = 0
; marks an empty slot. Value bytes live in a separate append-only pool
; (property_values); each record references its value via (offset,
; nbytes). ChangeProperty.Replace re-appends rather than re-using the
; old slot — simpler, costs some pool space but pool is 256 KB.
;
; Layout (24 B):
;   +0  xid (u32)          0 = empty
;   +4  atom (u32)
;   +8  type (u32)
;   +12 format (u8)        8 / 16 / 32
;   +13 pad (3)
;   +16 nbytes (u32)       size of value in bytes
;   +20 value_off (u32)    offset into property_values
%define MAX_PROPERTIES        1024
%define PROPERTY_REC_SIZE     24
%define PROPERTY_VALUES_CAP   262144
properties:         resb MAX_PROPERTIES * PROPERTY_REC_SIZE
property_values:    resb PROPERTY_VALUES_CAP
property_values_used: resd 1

; ---- Phase 4d input state -------------------------------------------------
; keysym_table — flat per-X11-keycode keysym table. 6 keysyms per keycode:
; index 0/1 = level 1/2 (unshifted/shifted), 2/3 unused (group 2), 4/5 =
; level 3/4 (AltGr / AltGr+Shift). Indexed by (kc - X_MIN_KEYCODE) * 24 +
; offset. The 4-5 placement matches glass's AltGr lookup (keycode*8 + 4).
%define KEYCODE_RANGE        (X_MAX_KEYCODE - X_MIN_KEYCODE + 1)
%define KEYSYMS_PER_KC       6
keysym_table:       resb KEYCODE_RANGE * 24

; key_grabs[256] — per-grab record (16 B):
;   +0  window (u32)     0 = empty slot
;   +4  client_slot (u32)
;   +8  keycode (u8)     X11 keycode (= evdev code + 8)
;   +9  pad (1)
;   +10 modifiers (u16)
;   +12 pad (4)
%define MAX_KEY_GRABS        512            ; tile's real .tilerc registers 300+
                                            ; (each bind x8 modifier variants);
                                            ; overflow silently dropped binds
%define KEY_GRAB_SIZE        16
key_grabs:          resb MAX_KEY_GRABS * KEY_GRAB_SIZE

; Active keyboard grab — set by GrabKeyboard, cleared by
; UngrabKeyboard. -1 = no active grab.
active_kbd_slot:    resd 1
active_kbd_window:  resd 1

; ---- Phase 4d.2 evdev integration -----------------------------------------
; Up to 16 /dev/input/event* devices opened at startup. Polled
; alongside the X11 listen + client fds. Modifier state tracked in
; mod_state and reported in every KeyPress's state field.
%define MAX_INPUTS       16
input_fds:          resd MAX_INPUTS
input_fd_count:     resd 1
grab_bits:          resb 96                ; EVIOCGBIT capability scratch
mod_state:          resd 1
focus_window:       resd 1               ; SetInputFocus target (0/1 = none/PointerRoot)
keys_down:          resb 32              ; QueryKeymap bitmap: bit = X keycode,
                                         ; set on press, cleared on release
screen_w:           resd 1               ; advertised screen size; defaults to
screen_h:           resd 1               ; X_SCREEN_W/H, overwritten by the real
                                         ; DRM mode in init_compositor (--display)
cursor_x:           resd 1               ; pointer position (root coords),
cursor_y:           resd 1               ; updated by evdev REL motion
button_state:       resd 1               ; held-button mask for event 'state'
                                         ; (Button1Mask 0x100, 2 0x200, 3 0x400)
server_time_ms:     resd 1               ; monotonic ms clock from the evdev event
                                         ; timestamp; stamped into every input event
                                         ; (X time 0 = CurrentTime, which breaks GTK
                                         ; menu activation — must be a real time)
ptr_grab_win:       resd 1               ; active pointer-grab window xid (0 = none)
ptr_grab_owner:     resb 1               ; GrabPointer owner-events flag: 0 →
                                         ; report everything against the grab
                                         ; window (scrot -s filters on root)
ptr_grab_mask:      resd 1               ; the grab's event mask (SETofPOINTEREVENT)
ptr_grab_slot:      resd 1               ; client slot holding the grab — needed to
                                         ; release grabs on windows OUTSIDE the
                                         ; grabber's XID band (e.g. root) when the
                                         ; grabbing client dies
ptr_grab_xi2:       resb 1               ; grab came from XIGrabDevice → deliver
kbd_grab_xi2:       resb 1               ; XI2 events to the grabber (GTK menus)
xi2_buf:            resb 96              ; XI2 GenericEvent build buffer (84 max)
wap_best:           resq 1               ; window_at_point: winning record
wap_abs_x:          resd 1               ; ...and its absolute origin (event
wap_abs_y:          resd 1               ;    coords = cursor - this)
wapd_abs_x:         resd 1               ; window_at_point_deep: abs origin of the
wapd_abs_y:         resd 1               ; deepest window under the cursor
wapd_cur_parent:    resd 1               ; descent cursor: current parent xid
wapd_best_stk:      resd 1               ; descent cursor: best sibling z-order
abs_last_x:         resd 1               ; touchpad absolute-position anchor:
abs_last_y:         resd 1               ; last seen ABS_X/Y; cursor moves by
abs_have_x:         resd 1               ; the delta. *_have flags clear on each
abs_have_y:         resd 1               ; new finger contact (BTN_TOUCH).
finger_count:       resd 1               ; fingers down now (1 move, 2 scroll)
tap_fingers:        resd 1               ; max fingers during the current touch
tap_moved:          resd 1               ; summed |ABS delta| during the touch
clickpad_btn:       resd 1               ; button a clickpad BTN_LEFT press was
                                         ; mapped to (1 or 3) — release must
                                         ; emit the SAME button
scroll_accum:       resd 1               ; two-finger Y accumulator → notches
tap_sec:            resq 1               ; BTN_TOUCH-down time (for tap timing)
tap_usec:           resq 1
; Multitouch slot tracking (MT-B). Drives the cursor only in 2-finger-drag
; mode (button held), where the single-touch ABS_X/Y follows the wrong
; (stationary click) finger. Two slots tracked; out-of-range → dead slot 2.
mt_cur_slot:        resd 1
mt_last_x:          resd 2
mt_last_y:          resd 2
mt_have_x:          resd 2
mt_have_y:          resd 2

; ---- ConfigureWindow / ChangeWindowAttributes value-mask bits -------------
; (numeric defines used by the handlers; not in BSS)

; sockaddr_un used for both bind() and the unlink() path on shutdown.
sockaddr_buf:       resb 128
sockaddr_path:      resb 128             ; just the path string for unlink
sockaddr_pathlen:   resq 1

; X11 setup request (12 bytes + auth payload). We read into here and check
; the byte-order byte + version + auth lengths.
setup_req:          resb 4096

; Log scratch (decimal formatting etc.).
log_scratch:        resb 64
dump_path_buf:      resb 64

; Per-client read buffer for incoming requests. 64 KB matches the upper
; bound of the legacy length field (CARD16 in 4-byte units = 256 KB) for
; non-BIG-REQUESTS clients, but most actual requests are tiny.
req_buf:            resb 65536
req_pos:            resq 1               ; how many bytes are buffered

; ---- DRM probe state ------------------------------------------------------
drm_fd:             resq 1
; drm_version struct (64 bytes) + name/date/desc buffers
drm_version_buf:    resb 64
drm_name_buf:       resb 64
drm_date_buf:       resb 64
drm_desc_buf:       resb 128
; drm_mode_card_res (64 bytes) + ID arrays
drm_res_buf:        resb 64
drm_fb_ids:         resd DRM_MAX_IDS
drm_crtc_ids:       resd DRM_MAX_IDS
drm_conn_ids:       resd DRM_MAX_IDS
drm_enc_ids:        resd DRM_MAX_IDS
; drm_mode_get_connector (80 bytes) + dependent arrays
drm_conn_buf:       resb 80
drm_modes_buf:      resb (DRM_MODE_INFO_SIZE * DRM_MAX_MODES)
drm_enc_arr:        resd DRM_MAX_IDS
drm_props_arr:      resd DRM_MAX_PROPS
drm_propvals_arr:   resq DRM_MAX_PROPS
drm_card_path:      resb 32

; ---- DRM modeset state ----------------------------------------------------
drm_encoder_buf:    resb 20             ; struct drm_mode_get_encoder
drm_crtc_save:      resb 104            ; struct drm_mode_crtc (GETCRTC)
drm_crtc_set:       resb 104            ; struct drm_mode_crtc (SETCRTC)
drm_dumb_create:    resb 32             ; struct drm_mode_create_dumb
drm_dumb_map:       resb 16             ; struct drm_mode_map_dumb
; --- DRM hardware cursor (64x64 ARGB on its own plane) ---------------------
cursor_ready:       resd 1              ; 1 once the cursor BO is set on the CRTC
cursor_handle:      resd 1              ; cursor dumb-BO handle
cursor_fb_addr:     resq 1              ; mmap'd cursor pixels
drm_cursor_create:  resb 32             ; CREATE_DUMB for the cursor BO
drm_cursor_map:     resb 16             ; MAP_DUMB for the cursor BO
drm_cursor:         resb 28             ; struct drm_mode_cursor (set + move)
drm_dumb_destroy:   resb 8              ; struct drm_mode_destroy_dumb (+pad)
drm_fb_cmd:         resb 28             ; struct drm_mode_fb_cmd
drm_set_conn_id:    resd 1              ; connector ID array (just one)
drm_fb_id:          resd 1
drm_dumb_handle:    resd 1
drm_dumb_pitch:     resd 1
drm_dumb_size:      resq 1
drm_dumb_offset:    resq 1
drm_dumb_addr:      resq 1
drm_chosen_crtc:    resd 1
drm_chosen_conn:    resd 1
nanosleep_ts:       resq 2

; ---- Second output (external display) --------------------------------------
; One wide framebuffer spans both outputs side by side; each CRTC scans its
; own region via the SETCRTC x offset. screen_w/h describe the whole fb;
; panel_w/h and ext_w/h the per-output regions.
panel_w:            resd 1                 ; output-1 (eDP) mode dims
panel_h:            resd 1
ext_active:         resb 1                 ; 1 = second output is live
ext_conn:           resd 1                 ; its connector / crtc ids
ext_crtc:           resd 1
ext_x:              resd 1                 ; fb x where output 2 starts (= panel_w)
ext_w:              resd 1                 ; its mode dims
ext_h:              resd 1
mode1_save:         resb 68                ; drm_mode_modeinfo per output —
mode2_save:         resb 68                ; drm_modes_buf is scan scratch
drm_crtc_set2:      resb 104               ; SETCRTC block for output 2
drm_set_conn_id2:   resd 1
cursor_crtc:        resd 1                 ; crtc currently showing the sprite
uevent_fd:          resd 1                 ; netlink hotplug socket (-1 = none)
hotplug_pending:    resb 1                 ; uevent arrived; re-probe next cycle
rr_evwins:          resd MAX_CLIENTS       ; RRSelectInput window per client
uevent_buf:         resb 4096
nl_addr:            resb 12                ; sockaddr_nl for the uevent bind
own_vt:             resd 1                 ; frame's VT (from tty0/active)
ev_dropped:         resd 1                 ; events dropped on full sockets
vt_away:            resb 1                 ; 1 = display released, VT switched
vtactive_fd:        resd 1                 ; /sys/class/tty/tty0/active fd
vt_dev_path:        resb 16                ; "/dev/tty<own_vt>" for VT ioctls
vtact_buf:          resb 16

; drm_mode_fb_dirty_cmd (24 bytes) for kicking the panel after a
; framebuffer update. fb_id at +0, flags at +4, color at +8,
; num_clips at +12, clips_ptr at +16.
drm_dirty_cmd:      resb 24

; ---- Double-buffer + page-flip (the real fix for FBC/PSR staleness) -------
; Two dumb buffers. We render the BACK one, clflush it, then PAGE_FLIP the
; CRTC to it; the flip forces the display engine to re-scan at vblank,
; defeating framebuffer-compression / panel-self-refresh staleness that
; makes in-place CPU updates vanish. comp_addr[i]/comp_fbid[i] are the two
; buffers; comp_back is the index (0/1) currently being rendered into.
comp_addr:          resq 2                 ; mmap'd ARGB buffer per buffer
comp_fbid:          resd 2                 ; DRM framebuffer id per buffer
comp_handle:        resd 2                 ; dumb-buffer handle per buffer
comp_back:          resd 1                 ; index of the back buffer (0/1)
drm_page_flip:      resb 24                ; struct drm_mode_crtc_page_flip
drm_event_buf:      resb 64                ; drain the flip-complete event

; ---- Damage tracking (dirty rectangles) ------------------------------------
; Every visual change records a screen-space rect via damage_add; the
; compositor then repaints ONLY those rects (bg fill, window blits, clflush)
; instead of the whole 9.2 MB buffer. Because the two flip buffers alternate,
; each buffer keeps its OWN stale list: damage_add appends to both, and a
; composite of buffer b repairs+clears only dmg[b]. This also survives flip
; failures and no-swap paths without extra bookkeeping. count -1 = whole
; screen (the overflow fallback — over-REPAINTING is always safe, unlike
; clip over-approximation). Rects are x1,y1,x2,y2 (s32, exclusive).
%define DMG_MAX 32
dmg_rects0:         resd 4 * DMG_MAX
dmg_count0:         resd 1
dmg_rects1:         resd 4 * DMG_MAX
dmg_count1:         resd 1
bw_clip_x1:         resd 1               ; blit/fill clip rect = the damage
bw_clip_y1:         resd 1               ; rect currently being repainted
bw_clip_x2:         resd 1
bw_clip_y2:         resd 1
cfgw_old_rect:      resq 1               ; configure: pre-change x,y,w,h latch
dmg_lat:            resd 4               ; per-handler damage rect latch
cg_dmg:             resd 4               ; glyph-run damage bbox (x1,y1,x2,y2)
flip_pending:       resb 1               ; PAGE_FLIP in flight; don't composite
                                         ; until its completion event arrives
drm_poll_dead:      resb 1               ; drm fd hit POLLERR/POLLHUP: stop
                                         ; polling it, flips fire-and-forget
testinput_path:     resq 1               ; --testinput PATH (0 = off)
fbtest_mode:        resb 1               ; --fbtest: composite into plain
                                         ; memory, no DRM (headless testing)
comp_px_blit:       resq 1               ; PERF counters (SIGUSR1 report):
comp_px_fill:       resq 1               ; pixels blitted / bg-filled /
comp_px_flush:      resq 1               ; bytes cache-flushed since start

; ---- Phase 4f compositor state --------------------------------------------
compositor_requested: resb 1               ; set by --display argv flag
compositor_active:    resb 1               ; set to 1 after init_compositor wins
comp_dirty:           resb 1               ; a draw happened; repaint once per
                                           ; serve-loop cycle (coalesced) instead
                                           ; of a full repaint + page-flip per req
defer_bg_composite:   resb 1               ; a WM-managed toplevel was just
                                           ; removed: hold the next composite ONE
                                           ; cycle so the WM's replacement map
                                           ; lands in the same paint (no bg
                                           ; flash between tabbed apps). 16ms
                                           ; poll fallback if nothing replaces it.
dirtyfb_logged:       resb 1               ; log DIRTYFB return code only once
sig_sa_buf:           resb 32              ; kernel struct sigaction

; ---- evdev probe / watch state --------------------------------------------
input_dev_path:     resb 32
input_dev_name:     resb 256
input_event_batch:  resb INPUT_BATCH_BYTES

; ============================================================================
; RODATA — setup reply template, vendor string, log prefixes
; ============================================================================
SECTION .rodata
x11_sock_dir:       db "/tmp/.X11-unix/X", 0
str_framerc:        db "/.framerc", 0
str_dev_tty0:       db "/dev/tty0", 0
str_netwm_cm:       db "_NET_WM_CM_S0"      ; compositor-manager selection
const_100:          dd 100
vendor_str:         db "frame"

log_prefix:         db "frame: ", 0
log_listening:      db "listening on display :", 0
log_accepted:       db "client connected", 10
log_accepted_len   equ $ - log_accepted
log_setup_ok:       db "setup reply sent (", 0
log_setup_ok_2:     db " bytes)", 10
log_setup_ok_2_len equ $ - log_setup_ok_2
qext_nl:            db 10
log_render_min:     db "RENDER minor=", 0
log_rr_minor:       db "  RANDR minor=", 0
; ListExtensions STR list: length byte + name, 39 bytes total (matches the
; QueryExtension set exactly — advertising one obligates serving it).
ext_names:          db 6, "RENDER", 5, "RANDR", 9, "XKEYBOARD", 15, "XInputExtension", 6, "XFIXES", 7, "MIT-SHM", 5, "SHAPE", 5, "XTEST"
ext_names_len       equ $ - ext_names       ; 46 bytes (5 STRs), padded to 48 in reply
; Keysym names for ~/.framerc `keycode` lines: db "name",0 + dd keysym;
; terminated by a lone 0 byte. Covers the user's ~/.Xmodmap vocabulary +
; the common specials; anything else via 0xHEX or a single char.
ks_names:
    db "Escape", 0
    dd 0xFF1B
    db "F1", 0
    dd 0xFFBE
    db "F2", 0
    dd 0xFFBF
    db "F3", 0
    dd 0xFFC0
    db "F4", 0
    dd 0xFFC1
    db "F5", 0
    dd 0xFFC2
    db "F6", 0
    dd 0xFFC3
    db "F7", 0
    dd 0xFFC4
    db "F8", 0
    dd 0xFFC5
    db "F9", 0
    dd 0xFFC6
    db "F10", 0
    dd 0xFFC7
    db "F11", 0
    dd 0xFFC8
    db "F12", 0
    dd 0xFFC9
    db "Return", 0
    dd 0xFF0D
    db "Tab", 0
    dd 0xFF09
    db "BackSpace", 0
    dd 0xFF08
    db "space", 0
    dd 0x0020
    db "Delete", 0
    dd 0xFFFF
    db "Insert", 0
    dd 0xFF63
    db "Home", 0
    dd 0xFF50
    db "End", 0
    dd 0xFF57
    db "Prior", 0
    dd 0xFF55
    db "Next", 0
    dd 0xFF56
    db "Up", 0
    dd 0xFF52
    db "Down", 0
    dd 0xFF54
    db "Left", 0
    dd 0xFF51
    db "Right", 0
    dd 0xFF53
    db "Caps_Lock", 0
    dd 0xFFE5
    db "asciitilde", 0
    dd 0x007E
    db "asciicircum", 0
    dd 0x005E
    db "dead_diaeresis", 0
    dd 0xFE57
    db "dead_caron", 0
    dd 0xFE5A
    db "Pointer_Button2", 0
    dd 0xFEE9
    db "Pointer_Button3", 0
    dd 0xFEEA
    db 0

; XI1 ListInputDevices payload: 2 DeviceInfo (type Atom=None, id, nclasses=0,
; use IsXPointer/IsXKeyboard, pad) + 2 STR names + 1 pad byte = 60 bytes.
xi1_core_devs:      db 0,0,0,0, 2, 0, 0, 0
                    db 0,0,0,0, 3, 0, 1, 0
                    db 20, "Virtual core pointer"
                    db 21, "Virtual core keyboard"
                    db 0
dbg_pxfull:         db "PXFULL", 10        ; DIAG: CreatePixmap dropped — table full
dbg_cli_tag:        db "c"                 ; DIAG: client slot prefix
dbg_picfull:        db "PICFULL", 10       ; DIAG: CreatePicture dropped — table full
dbg_gcfull:         db "GCFULL", 10        ; DIAG: CreateGC dropped — table full
log_request_pre:    db "  req opcode=", 0
log_request_mid:    db " len=", 0
log_request_nl:     db 10
log_client_gone:    db "client disconnected", 10
log_client_gone_len equ $ - log_client_gone
log_bind_fail:      db "frame: bind failed (display in use?)", 10
log_bind_fail_len  equ $ - log_bind_fail
log_setup_bad:      db "frame: malformed setup request, hanging up", 10
log_setup_bad_len  equ $ - log_setup_bad

; ---- phase 4 multi-client log strings -------------------------------------
log_serve_ready:    db "serve loop ready, polling listen + clients", 10
log_serve_ready_len equ $ - log_serve_ready
log_max_clients:    db "refusing connection, all 128 client slots in use", 10
log_max_clients_len equ $ - log_max_clients
log_input_pre:      db "opened ", 0
log_input_pre_len   equ $ - log_input_pre - 1
log_input_suf:      db " input device(s)", 10
log_input_suf_len   equ $ - log_input_suf
log_blank:          db "frame: panel off (idle blank_timeout)", 10
log_blank_len       equ $ - log_blank
log_unblank:        db "frame: panel on (input)", 10
log_unblank_len     equ $ - log_unblank
log_hotplug:        db "frame: display hotplug — outputs reconfigured", 10
log_hotplug_len     equ $ - log_hotplug
log_vtback:         db "frame: VT reacquired", 10
log_vtback_len      equ $ - log_vtback
log_shm_minor:      db " SHM minor=", 0
; AllocNamedColor table: len byte, lowercase name, RGB dword. 0-len ends.
align 4
color_names:
    db 5, "black"
    dd 0x000000
    db 5, "white"
    dd 0xFFFFFF
    db 4, "gray"
    dd 0xBEBEBE
    db 4, "grey"
    dd 0xBEBEBE
    db 3, "red"
    dd 0xFF0000
    db 5, "green"
    dd 0x00FF00
    db 4, "blue"
    dd 0x0000FF
    db 6, "yellow"
    dd 0xFFFF00
    db 0
str_vtactive:       db "/sys/class/tty/tty0/active", 0
log_comp_pre:       db "compositor: mode ", 0
log_comp_pre_len    equ $ - log_comp_pre - 1
log_comp_x:         db "x"
log_comp_pitch:     db ", pitch ", 0
log_comp_pitch_len  equ $ - log_comp_pitch - 1
log_comp_size:      db ", size ", 0
log_comp_size_len   equ $ - log_comp_size - 1
log_pageflip:       db "frame: first PAGE_FLIP rc=", 0
log_pageflip_len    equ $ - log_pageflip - 1
str_render:         db "RENDER"
str_xkb:            db "XKEYBOARD"
str_randr:          db "RANDR"
str_xinput:         db "XInputExtension"
str_xfixes:         db "XFIXES"
str_shm:            db "MIT-SHM"
str_shape:          db "SHAPE"
str_xtest:          db "XTEST"
str_xi_pointer:     db "Virtual core pointer"      ; 20 bytes
str_xi_keyboard:    db "Virtual core keyboard"     ; 21 bytes
str_rel_x:          db "Rel X"
str_rel_y:          db "Rel Y"
str_monitor_default: db "default"
str_monitor_ext:     db "ext"
log_xkb_minor:      db "xkb minor=", 0
log_xi_minor:       db "xi minor=", 0

; XKB key types served by GetMap. Four canonical-ish types; every real key is
; assigned FOUR_LEVEL (index 3, 4 levels: base / Shift / AltGr(Mod5) / both) so
; one uniform width-4 sym map covers base+shift+AltGr. Each xkbKeyTypeWireDesc
; is 8 bytes (mask, realMods, vmods:2, numLevels, nMapEntries, preserve, pad)
; followed by nMapEntries × 8-byte xkbKTMapEntryWireDesc (active, mask, level,
; realMods, vmods:2, pad:2). NOT the 4-byte xkbKTSetMapEntryWireDesc — that's
; the SetMap REQUEST format. Serving it here desynced every client's type
; parse (by luck it consumed exactly these 56 bytes, so the reply "worked"),
; leaving all keys on a 1-level type whose map entry read as "level 0 needs
; Mod5" — xdotool wrapped every plain char in ISO_Level3_Shift, and copyq's
; synthetic paste keys came out at the wrong shift level in glass.
align 4
xkb_types_blob:
    db 0x00, 0x00              ; type 0 ONE_LEVEL: mask, realMods
    dw 0x0000                  ;   vmods
    db 1, 0, 0, 0              ;   numLevels=1, nMapEntries=0, preserve, pad
    db 0x01, 0x01              ; type 1 TWO_LEVEL: mask=Shift
    dw 0x0000
    db 2, 1, 0, 0              ;   numLevels=2, nMapEntries=1
    db 1, 0x01, 1, 0x01        ;     active, mask=Shift, level=1, realMods=Shift
    dw 0x0000, 0x0000          ;     vmods, pad
    db 0x03, 0x03              ; type 2 ALPHABETIC: mask=Shift|Lock
    dw 0x0000
    db 2, 2, 0, 0              ;   numLevels=2, nMapEntries=2
    db 1, 0x01, 1, 0x01        ;     Shift → level 1
    dw 0x0000, 0x0000
    db 1, 0x02, 1, 0x02        ;     Lock → level 1
    dw 0x0000, 0x0000
    db 0x81, 0x81              ; type 3 FOUR_LEVEL: mask=Shift|Mod5
    dw 0x0000
    db 4, 3, 0, 0              ;   numLevels=4, nMapEntries=3
    db 1, 0x01, 1, 0x01        ;     Shift → level 1
    dw 0x0000, 0x0000
    db 1, 0x80, 2, 0x80        ;     Mod5 (AltGr) → level 2
    dw 0x0000, 0x0000
    db 1, 0x81, 3, 0x81        ;     Shift|Mod5 → level 3
    dw 0x0000, 0x0000
xkb_types_blob_end:
XKB_TYPES_BYTES equ xkb_types_blob_end - xkb_types_blob

; Modifier map: 8 keys → real-mod mask, sorted by keycode. kc108 is Alt_R(Mod1)
; on US, AltGr(Mod5) on Norwegian — patched at emit time. 2 bytes each.
xkb_modmap_blob:
    db 37, 0x04                ; Control_L
    db 50, 0x01                ; Shift_L
    db 62, 0x01                ; Shift_R
    db 64, 0x08                ; Alt_L (Mod1)
    db 105, 0x04               ; Control_R
    db 108, 0x08               ; Alt_R/AltGr  (mods byte = blob+11)
    db 133, 0x40               ; Super_L (Mod4)
    db 134, 0x40               ; Super_R (Mod4)
XKB_MODMAP_BYTES equ $ - xkb_modmap_blob
dbg_ag_tag:         db 10, "AG: "
dbg_ag_tag_len      equ $ - dbg_ag_tag
dbg_sp:             db " "
dbg_dump_tag:       db "DUMP xid/w/h/nonbg: "
dbg_dump_tag_len    equ $ - dbg_dump_tag
dump_path:          db "/tmp/frame_win.raw", 0
dump_prefix:        db "/tmp/frame_win_", 0
dump_fb0_path:      db "/tmp/frame_fbA.raw", 0
dump_fb1_path:      db "/tmp/frame_fbB.raw", 0
dbg_fbstate:        db "FBSTATE back=", 0
dbg_evdrop:         db " evdrop=", 0
dbg_pxblit:         db " blit=", 0
dbg_pxfill:         db " fill=", 0
dbg_pxflush:        db " flush=", 0
log_fbtest:         db "frame: fbtest compositor 1920x1080 (no DRM)", 10
log_fbtest_len equ $ - log_fbtest
dbg_spX:            db " "
dump_suffix:        db ".raw", 0
log_atom_new:       db "  intern-atom new id=", 0
log_atom_new_len   equ $ - log_atom_new - 1
log_atom_known:     db "  intern-atom known id=", 0
log_atom_known_len equ $ - log_atom_known - 1
log_qext_pre:       db "  query-extension (not-present): ", 0
log_qext_pre_len   equ $ - log_qext_pre - 1

; Predefined X11 atoms (1..68 in X.h's XA_* range). Stored as a packed
; stream: 1 length byte then that many name bytes per atom, terminated
; by a length byte of 0. init_atoms walks this once at startup and
; populates atom_off[] / atom_len[] / atom_strings.
;
; Length is computed by NASM (%strlen) — manual lengths are an easy
; off-by-one trap (caught one in WM_CLIENT_MACHINE, which is 17 chars
; not 16; the resulting mis-parse poisoned every atom after it).
%macro ATM 1
    db %strlen(%1), %1
%endmacro
predef_atom_stream:
    ATM "PRIMARY"
    ATM "SECONDARY"
    ATM "ARC"
    ATM "ATOM"
    ATM "BITMAP"
    ATM "CARDINAL"
    ATM "COLORMAP"
    ATM "CURSOR"
    ATM "CUT_BUFFER0"
    ATM "CUT_BUFFER1"
    ATM "CUT_BUFFER2"
    ATM "CUT_BUFFER3"
    ATM "CUT_BUFFER4"
    ATM "CUT_BUFFER5"
    ATM "CUT_BUFFER6"
    ATM "CUT_BUFFER7"
    ATM "DRAWABLE"
    ATM "FONT"
    ATM "INTEGER"
    ATM "PIXMAP"
    ATM "POINT"
    ATM "RECTANGLE"
    ATM "RESOURCE_MANAGER"
    ATM "RGB_COLOR_MAP"
    ATM "RGB_BEST_MAP"
    ATM "RGB_BLUE_MAP"
    ATM "RGB_DEFAULT_MAP"
    ATM "RGB_GRAY_MAP"
    ATM "RGB_GREEN_MAP"
    ATM "RGB_RED_MAP"
    ATM "STRING"
    ATM "VISUALID"
    ATM "WINDOW"
    ATM "WM_COMMAND"
    ATM "WM_HINTS"
    ATM "WM_CLIENT_MACHINE"
    ATM "WM_ICON_NAME"
    ATM "WM_ICON_SIZE"
    ATM "WM_NAME"
    ATM "WM_NORMAL_HINTS"
    ATM "WM_SIZE_HINTS"
    ATM "WM_ZOOM_HINTS"
    ATM "MIN_SPACE"
    ATM "NORM_SPACE"
    ATM "MAX_SPACE"
    ATM "END_SPACE"
    ATM "SUPERSCRIPT_X"
    ATM "SUPERSCRIPT_Y"
    ATM "SUBSCRIPT_X"
    ATM "SUBSCRIPT_Y"
    ATM "UNDERLINE_POSITION"
    ATM "UNDERLINE_THICKNESS"
    ATM "STRIKEOUT_ASCENT"
    ATM "STRIKEOUT_DESCENT"
    ATM "ITALIC_ANGLE"
    ATM "X_HEIGHT"
    ATM "QUAD_WIDTH"
    ATM "WEIGHT"
    ATM "POINT_SIZE"
    ATM "RESOLUTION"
    ATM "COPYRIGHT"
    ATM "NOTICE"
    ATM "FONT_NAME"
    ATM "FAMILY_NAME"
    ATM "FULL_NAME"
    ATM "CAP_HEIGHT"
    ATM "WM_CLASS"
    ATM "WM_TRANSIENT_FOR"
    ATM "Rel X"                              ; XInput2 pointer axis labels
    ATM "Rel Y"
    ATM "default"                            ; RANDR monitor / output name
    ATM "ext"                                ; RANDR monitor 2 name
    db 0                                     ; terminator

; ---- probe-mode strings ---------------------------------------------------
probe_card_pre:     db "/dev/dri/card", 0
probe_open_fail:    db "frame: no DRM card under /dev/dri/cardN found", 10
probe_open_fail_len equ $ - probe_open_fail
probe_open_ok_pre:  db "frame: opened ", 0
probe_open_ok_len   equ $ - probe_open_ok_pre - 1
probe_version_pre:  db ", driver ", 0
probe_version_pre_len equ $ - probe_version_pre - 1
probe_version_sep:  db " v", 0
probe_version_sep_len equ $ - probe_version_sep - 1
probe_version_dot:  db "."
probe_version_nl:   db 10
probe_res_pre:      db "frame: resources: ", 0
probe_res_pre_len   equ $ - probe_res_pre - 1
probe_res_crtc:     db " CRTCs, ", 0
probe_res_crtc_len  equ $ - probe_res_crtc - 1
probe_res_conn:     db " connectors, ", 0
probe_res_conn_len  equ $ - probe_res_conn - 1
probe_res_enc:      db " encoders", 10
probe_res_enc_len   equ $ - probe_res_enc
probe_res_size:     db "frame: framebuffer range ", 0
probe_res_size_len  equ $ - probe_res_size - 1
probe_res_to:       db " to ", 0
probe_res_to_len    equ $ - probe_res_to - 1
probe_res_x:        db "x", 0
probe_conn_pre:     db "  connector ", 0
probe_conn_pre_len  equ $ - probe_conn_pre - 1
probe_conn_type:    db ": ", 0
probe_conn_type_len equ $ - probe_conn_type - 1
probe_conn_arr:     db " ", 0xE2, 0x86, 0x92, " ", 0   ; " → "
probe_conn_arr_len  equ $ - probe_conn_arr - 1
probe_conn_modes:   db ", ", 0
probe_conn_modes_len equ $ - probe_conn_modes - 1
probe_conn_mcount:  db " modes", 0
probe_conn_mcount_len equ $ - probe_conn_mcount - 1
probe_conn_pref:    db ", preferred ", 0
probe_conn_pref_len equ $ - probe_conn_pref - 1
probe_conn_at:      db " @ ", 0
probe_conn_at_len   equ $ - probe_conn_at - 1
probe_conn_hz:      db " Hz", 10
probe_conn_hz_len   equ $ - probe_conn_hz
probe_conn_nl:      db 10
probe_state_conn:  db "connected", 0
probe_state_disc:  db "disconnected", 0
probe_state_unk:   db "unknown", 0
ioctl_err:         db "frame: ioctl failed", 10
ioctl_err_len      equ $ - ioctl_err

; ---- modeset strings ------------------------------------------------------
ms_master_ok:      db "frame: SET_MASTER OK", 10
ms_master_ok_len   equ $ - ms_master_ok
ms_master_fail:    db "frame: SET_MASTER failed (need root, and X must be stopped: 'sudo systemctl stop display-manager' or kill X from a VT)", 10
ms_master_fail_len equ $ - ms_master_fail
ms_no_conn:        db "frame: no connected display found", 10
ms_no_conn_len     equ $ - ms_no_conn
ms_using_pre:      db "frame: using connector ", 0
ms_using_pre_len   equ $ - ms_using_pre - 1
ms_using_crtc:     db " on CRTC ", 0
ms_using_crtc_len  equ $ - ms_using_crtc - 1
ms_using_mode:     db ", mode ", 0
ms_using_mode_len  equ $ - ms_using_mode - 1
ms_create_pre:     db "frame: created dumb buffer, ", 0
ms_create_pre_len  equ $ - ms_create_pre - 1
ms_create_bytes:   db " bytes", 10
ms_create_bytes_len equ $ - ms_create_bytes
ms_fill_ok:        db "frame: filled with purple", 10
ms_fill_ok_len     equ $ - ms_fill_ok
ms_addfb_ok:       db "frame: added framebuffer ", 0
ms_addfb_ok_len    equ $ - ms_addfb_ok - 1
ms_setcrtc_ok:     db "frame: SETCRTC OK — displaying for 5 seconds", 10
ms_setcrtc_ok_len  equ $ - ms_setcrtc_ok
ms_restore_ok:     db "frame: restored original CRTC, cleanup done", 10
ms_restore_ok_len  equ $ - ms_restore_ok
ms_err_step:       db "frame: failed at step: ", 0
ms_err_step_len    equ $ - ms_err_step - 1
ms_err_open:       db "open", 10
ms_err_open_len    equ $ - ms_err_open
ms_err_master:     db "SET_MASTER", 10
ms_err_master_len  equ $ - ms_err_master
ms_err_getcrtc:    db "GETCRTC", 10
ms_err_getcrtc_len equ $ - ms_err_getcrtc
ms_err_dumb:       db "CREATE_DUMB", 10
ms_err_dumb_len    equ $ - ms_err_dumb
ms_err_mapdumb:    db "MAP_DUMB", 10
ms_err_mapdumb_len equ $ - ms_err_mapdumb
ms_err_mmap:       db "mmap", 10
ms_err_mmap_len    equ $ - ms_err_mmap
ms_err_addfb:      db "ADDFB", 10
ms_err_addfb_len   equ $ - ms_err_addfb
ms_err_setcrtc:    db "SETCRTC", 10
ms_err_setcrtc_len equ $ - ms_err_setcrtc

; ---- input strings --------------------------------------------------------
input_dev_pre:      db "/dev/input/event", 0
input_dev_pre_len   equ $ - input_dev_pre - 1
input_dev_header:   db "frame: input devices:", 10
input_dev_header_len equ $ - input_dev_header
input_dev_indent:   db "  event"
input_dev_indent_len equ $ - input_dev_indent
input_dev_colon:    db ": ", 0
input_dev_colon_len equ $ - input_dev_colon - 1
input_watch_pre:    db "frame: watching ", 0
input_watch_pre_len equ $ - input_watch_pre - 1
input_watch_usage:  db "usage: frame --watch-input /dev/input/eventN", 10
input_watch_usage_len equ $ - input_watch_usage
input_watch_oerr:   db "frame: open failed (need 'input' group membership, or run with sudo)", 10
input_watch_oerr_len equ $ - input_watch_oerr
input_probe_none:   db "  (none opened — run with sudo, or add yourself to the 'input' group)", 10
input_probe_none_len equ $ - input_probe_none
input_lbl_key:      db "KEY ", 0
input_lbl_key_len   equ $ - input_lbl_key - 1
input_lbl_btn:      db "BTN ", 0
input_lbl_btn_len   equ $ - input_lbl_btn - 1
input_lbl_rel:      db "REL ", 0
input_lbl_rel_len   equ $ - input_lbl_rel - 1
input_lbl_abs:      db "ABS ", 0
input_lbl_abs_len   equ $ - input_lbl_abs - 1
input_lbl_sw:       db "SW  ", 0
input_lbl_sw_len    equ $ - input_lbl_sw - 1
input_lbl_msc:      db "MSC ", 0
input_lbl_msc_len   equ $ - input_lbl_msc - 1
input_lbl_other:    db "??? ", 0
input_lbl_other_len equ $ - input_lbl_other - 1
input_act_press:    db " press", 10
input_act_press_len equ $ - input_act_press
input_act_release:  db " release", 10
input_act_release_len equ $ - input_act_release
input_act_repeat:   db " repeat", 10
input_act_repeat_len equ $ - input_act_repeat
input_value_pre:    db " value=", 0
input_value_pre_len equ $ - input_value_pre - 1

; Connector type names — indexed by drm_mode_get_connector.connector_type.
; (drm_mode.h, "DRM_MODE_CONNECTOR_*", values 0..21.)
conn_type_0:  db "Unknown", 0
conn_type_1:  db "VGA", 0
conn_type_2:  db "DVI-I", 0
conn_type_3:  db "DVI-D", 0
conn_type_4:  db "DVI-A", 0
conn_type_5:  db "Composite", 0
conn_type_6:  db "SVIDEO", 0
conn_type_7:  db "LVDS", 0
conn_type_8:  db "Component", 0
conn_type_9:  db "9PinDIN", 0
conn_type_10: db "DisplayPort", 0
conn_type_11: db "HDMI-A", 0
conn_type_12: db "HDMI-B", 0
conn_type_13: db "TV", 0
conn_type_14: db "eDP", 0
conn_type_15: db "Virtual", 0
conn_type_16: db "DSI", 0
conn_type_17: db "DPI", 0
conn_type_18: db "Writeback", 0
conn_type_19: db "SPI", 0
conn_type_20: db "USB", 0
conn_type_unknown: db "Type?", 0

align 8
conn_type_table:
    dq conn_type_0,  conn_type_1,  conn_type_2,  conn_type_3
    dq conn_type_4,  conn_type_5,  conn_type_6,  conn_type_7
    dq conn_type_8,  conn_type_9,  conn_type_10, conn_type_11
    dq conn_type_12, conn_type_13, conn_type_14, conn_type_15
    dq conn_type_16, conn_type_17, conn_type_18, conn_type_19
    dq conn_type_20
conn_type_max equ 20

; ============================================================================
; TEXT
; ============================================================================
SECTION .text
global _start

_start:
    mov rax, [rsp]                       ; argc
    lea rcx, [rsp + 8 + rax*8 + 8]       ; envp
    mov [envp], rcx

    ; Parse argv[1] for display number; default 7.
    mov qword [display_num], DEFAULT_DISPLAY
    cmp rax, 2
    jl .main
    mov rdi, [rsp + 16]
    ; "--probe" → exercise DRM enumeration and exit, leave the listening
    ; server untouched. Lets us validate the kernel interface without
    ; having to drop the running Xorg.
    cmp dword [rdi], '--pr'
    jne .check_modeset
    cmp dword [rdi + 4], 'obe'
    jne .check_modeset
    cmp byte [rdi + 7], 0
    jne .check_modeset
    call do_probe
    xor edi, edi
    mov rax, SYS_EXIT
    syscall
.check_modeset:
    cmp dword [rdi], '--mo'
    jne .check_probe_input
    cmp dword [rdi + 4], 'dese'
    jne .check_probe_input
    cmp word [rdi + 8], 't'              ; 't' + NUL
    jne .check_probe_input
    call do_modeset
    xor edi, edi
    mov rax, SYS_EXIT
    syscall
.check_probe_input:
    ; "--probe-input"
    cmp dword [rdi], '--pr'
    jne .check_display
    cmp dword [rdi + 4], 'obe-'
    jne .check_display
    cmp dword [rdi + 8], 'inpu'
    jne .check_display
    cmp word [rdi + 12], 't'             ; 't' + NUL
    jne .check_display
    call do_probe_input
    xor edi, edi
    mov rax, SYS_EXIT
    syscall
.check_display:
    ; Fall-through here when argv[1] isn't --probe-input. We'll do a
    ; second pass over all argv entries below for --display, since it
    ; can coexist with a display number.
.check_watch_input:
    ; "--watch-input PATH"
    cmp dword [rdi], '--wa'
    jne .check_num
    cmp dword [rdi + 4], 'tch-'
    jne .check_num
    cmp dword [rdi + 8], 'inpu'
    jne .check_num
    cmp word [rdi + 12], 't'
    jne .check_num
    cmp rax, 3
    jl .watch_usage
    mov rdi, [rsp + 24]                  ; argv[2] = device path
    call do_watch_input
    xor edi, edi
    mov rax, SYS_EXIT
    syscall
.watch_usage:
    mov rsi, input_watch_usage
    mov rdx, input_watch_usage_len
    call write_stderr
    mov edi, 1
    mov rax, SYS_EXIT
    syscall
.check_num:
    call atoi_or_default
    mov [display_num], rax

    ; --- Second pass over argv: pick up flags that can appear anywhere
    ;     after argv[0]. Currently only --display.
    mov rax, [rsp]                           ; argc
    mov rcx, 1
.flag_scan:
    cmp rcx, rax
    jge .main
    mov rdi, [rsp + 8 + rcx*8]
    cmp dword [rdi], '--fb'                  ; --fbtest: DRM-free compositor
    jne .flag_not_fbtest                     ; --fbtest2: same + a fake second
    cmp dword [rdi + 4], 'test'              ;   1920x1080 output (headless
    jne .flag_not_fbtest                     ;   dual-head testing)
    cmp byte [rdi + 8], 0
    je .flag_fbtest_on
    cmp word [rdi + 8], '2'                  ; '2' + NUL
    jne .flag_not_fbtest
    mov byte [ext_active], 1
.flag_fbtest_on:
    mov byte [fbtest_mode], 1
    jmp .flag_scan_next
.flag_not_fbtest:
    cmp dword [rdi], '--te'                  ; --testinput PATH: extra input fd
    jne .flag_not_testinput                  ; (FIFO) feeding synthetic evdev
    cmp dword [rdi + 4], 'stin'              ; records into the normal input
    jne .flag_not_testinput                  ; path — headless key/ptr testing
    cmp dword [rdi + 8], 'put'
    jne .flag_not_testinput
    lea rdx, [rcx + 1]
    cmp rdx, rax
    jge .flag_scan_next                      ; no path argument → ignore
    mov rdx, [rsp + 8 + rdx*8]
    mov [testinput_path], rdx
    inc rcx                                  ; consume the path argument
    jmp .flag_scan_next
.flag_not_testinput:
    cmp dword [rdi], '--di'
    jne .flag_scan_next
    cmp dword [rdi + 4], 'spla'
    jne .flag_scan_next
    cmp word [rdi + 8], 'y'
    jne .flag_scan_next
    mov byte [compositor_requested], 1
.flag_scan_next:
    inc rcx
    jmp .flag_scan

.main:
    call announce_listening
    call socket_setup
    test rax, rax
    js .die_bind
    call init_atoms
    ; Claim the compositor-manager selection: glass (and GTK) only use the
    ; ARGB visual for real transparency when _NET_WM_CM_S0 has an owner.
    ; frame IS the compositor, so it owns the selection itself (the atom is
    ; interned now; GetSelectionOwner answers root for it).
    lea rdi, [str_netwm_cm]
    mov esi, 13
    call atom_create
    mov [netwm_cm_atom_srv], eax
    call init_clients
    call init_windows
    call init_gcs
    call init_pixmaps
    call init_pictures
    call init_properties
    call install_dump_handler
    ; Ignore SIGPIPE ALWAYS (both --display and --fbtest / network-only). A
    ; client closing its connection means frame's next write to that socket
    ; raises SIGPIPE, whose DEFAULT action TERMINATES the server — on the
    ; panel that drops DRM master → black screen + frozen cursor. This was
    ; THE crash on closing a GTK dialog (frame writes a trailing event/reply
    ; to the just-closed socket; v0.0.79's XI2 crossings/motion made it near-
    ; certain). SIG_IGN → the write returns -EPIPE instead; event writes
    ; ignore it and the dead client is reaped on its next read()=0.
    lea rdi, [sig_sa_buf]
    mov qword [rdi + 0], 1                    ; sa_handler = SIG_IGN
    mov qword [rdi + 8], 0                    ; sa_flags = 0
    mov qword [rdi + 16], 0                   ; sa_restorer
    mov qword [rdi + 24], 0                   ; sa_mask
    mov rax, SYS_RT_SIGACTION
    mov edi, 13                               ; SIGPIPE
    lea rsi, [sig_sa_buf]
    xor edx, edx
    mov r10, 8
    syscall
    cmp byte [fbtest_mode], 0
    jne .main_fbtest_init
    jmp .main_fbtest_done
.main_fbtest_init:
    call init_fbtest
.main_fbtest_done:
    mov dword [cfg_blank_ms], -1             ; sentinel: blank_timeout default
    mov dword [cfg_blankkey_sym], 0xFF1B     ; blank_key default: Mod4+Escape
    mov byte [cfg_blankkey_mods], 0x40       ; (0x40 = MOD_MOD4)
    call read_framerc                        ; ~/.framerc → keymap_is_no
    cmp byte [fbtest_mode], 0                 ; fbtest: dims already set by init_fbtest,
    je .wp_not_fbtest                         ; so load the wallpaper now (--display
    call load_wallpaper                       ; loads later, after init_compositor)
.wp_not_fbtest:
    call init_keysyms
    call init_input
    ; --testinput PATH: append the FIFO to the input fd set. Opened O_RDWR
    ; so an idle FIFO never reads EOF (the server itself counts as a
    ; writer); records written to it flow through dispatch_input_event
    ; exactly like hardware evdev. Cold unless the flag was given.
    mov rdi, [testinput_path]
    test rdi, rdi
    jz .skip_testinput
    mov rax, SYS_OPEN
    mov esi, 0x802                           ; O_RDWR | O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js .skip_testinput
    mov ecx, [input_fd_count]
    cmp ecx, MAX_INPUTS
    jge .skip_testinput
    mov [input_fds + rcx*4], eax
    inc dword [input_fd_count]
.skip_testinput:
    cmp byte [compositor_requested], 0
    je .skip_compositor
    call init_compositor
    call load_wallpaper                       ; ~/.framerc background → wallpaper_ptr
.skip_compositor:
    call init_uevent_socket                   ; display-hotplug watch; sets the
    jmp serve_loop                            ; poll slot to -1 in all other modes

.die_bind:
    mov rsi, log_bind_fail
    mov rdx, log_bind_fail_len
    call write_stderr
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; ============================================================================
; announce_listening — write "frame: listening on display :N\n" to stderr.
; ============================================================================
announce_listening:
    mov rsi, log_prefix
    mov rdx, 7
    call write_stderr
    mov rsi, log_listening
    mov rdx, 22
    call write_stderr
    mov rax, [display_num]
    call format_u64
    mov rsi, log_scratch
    mov edx, eax
    call write_stderr
    lea rsi, [.nl]
    mov rdx, 1
    call write_stderr
    ret
.nl: db 10

; ============================================================================
; socket_setup — socket(AF_UNIX, SOCK_STREAM), bind to /tmp/.X11-unix/X<N>,
; listen. Returns 0 on success, -1 on failure (after writing the unlink so
; subsequent runs aren't poisoned by a stale lock).
; ============================================================================
socket_setup:
    push rbx
    ; Build the path string into sockaddr_path so we can also pass it to
    ; unlink() later. Format: "/tmp/.X11-unix/X" + display_num + NUL.
    lea rdi, [sockaddr_path]
    lea rsi, [x11_sock_dir]
.ss_cp:
    mov al, [rsi]
    test al, al
    jz .ss_cp_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .ss_cp
.ss_cp_done:
    mov rax, [display_num]
    call u64_to_ascii                    ; writes to rdi, returns new rdi
    mov byte [rdi], 0
    mov rax, rdi
    lea rcx, [sockaddr_path]
    sub rax, rcx
    mov [sockaddr_pathlen], rax

    ; Pre-unlink any stale socket file from a previous run. Ignore errors.
    mov rax, SYS_UNLINK
    lea rdi, [sockaddr_path]
    syscall

    ; socket(AF_UNIX, SOCK_STREAM, 0)
    mov rax, SYS_SOCKET
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor edx, edx
    syscall
    test rax, rax
    js .ss_fail
    mov [listen_fd], rax

    ; Build sockaddr_un { sa_family = AF_UNIX, sun_path = path }.
    lea rdi, [sockaddr_buf]
    mov word [rdi], AF_UNIX
    add rdi, 2
    lea rsi, [sockaddr_path]
    mov rcx, [sockaddr_pathlen]
.ss_path_cp:
    test rcx, rcx
    jz .ss_path_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .ss_path_cp
.ss_path_done:
    mov byte [rdi], 0
    ; bind
    mov rax, SYS_BIND
    mov rdi, [listen_fd]
    lea rsi, [sockaddr_buf]
    mov rdx, [sockaddr_pathlen]
    add rdx, 3                           ; family (2) + NUL (1)
    syscall
    test rax, rax
    js .ss_fail
    ; Make the socket world-connectable (0777), like every real X server, so
    ; clients running as a different user (e.g. tray apps as the real user
    ; while frame runs as root) can connect. /tmp/.X11-unix is already sticky.
    mov rax, 90                          ; SYS_CHMOD
    lea rdi, [sockaddr_buf + 2]          ; sun_path
    mov esi, 0o777
    syscall
    ; listen with a small backlog
    mov rax, SYS_LISTEN
    mov rdi, [listen_fd]
    mov rsi, 8
    syscall
    xor eax, eax
    pop rbx
    ret
.ss_fail:
    mov rax, -1
    pop rbx
    ret

; ============================================================================
; do_accept — accept(listen_fd). Returns new fd in rax, or -errno.
; ============================================================================
do_accept:
    mov rax, SYS_ACCEPT
    mov rdi, [listen_fd]
    xor esi, esi
    xor edx, edx
    syscall
    ret

; ============================================================================
; emit_setup_reply — rdi = target fd. Body is
; assembled in req_buf; only one screen, depths 24 and 32, one visual per
; depth, one pixmap format (depth-24-in-32-bpp).
; ============================================================================
emit_setup_reply:
    ; rdi = target fd. (Was client_fd-based when there was only one
    ; client; the multi-client serve loop passes whichever slot's fd.)
    push rbx
    push r12
    push r13
    mov r13, rdi                         ; preserve target fd across helpers
    lea rdi, [req_buf]
    mov rbx, rdi                         ; rbx = base

    ; ---- success header (8 bytes) ----
    mov byte [rdi], 1                    ; response = Success
    mov byte [rdi + 1], 0                ; unused
    mov word [rdi + 2], X_PROTO_MAJOR
    mov word [rdi + 4], X_PROTO_MINOR
    ; bytes 6-7: additional data length — patched at the end
    add rdi, 8

    ; ---- setup info (40 bytes header + vendor + formats + screen + depths) ----
    ; release-number, rid-base, rid-mask, motion-buffer-size
    ;
    ; rid-base is per-CLIENT — each client gets a 2 MB XID range of its
    ; own (X_RID_BASE + slot * 0x200000), so client N's first XID can't
    ; collide with client 0's. Without this every client allocates
    ; 0x400001 for its first window, which collides in our window table.
    mov dword [rdi + 0], X_RELEASE_NUMBER
    mov eax, esi
    shl eax, 21                              ; * 0x200000
    add eax, X_RID_BASE
    mov [rdi + 4], eax
    mov dword [rdi + 8], X_RID_MASK
    mov dword [rdi + 12], 256            ; motion buffer size
    ; vendor-length, maximum-request-length
    mov word [rdi + 16], X_VENDOR_LEN
    mov word [rdi + 18], 65535           ; max request length in 4-byte units
    ; number-of-screens, number-of-formats
    mov byte [rdi + 20], 1
    mov byte [rdi + 21], 2                   ; depth-24 + depth-32 pixmap formats
    ; image byte order, bitmap bit order
    mov byte [rdi + 22], X_IMAGE_BYTE_ORDER
    mov byte [rdi + 23], X_BITMAP_BIT_ORDER
    ; bitmap scanline-unit, bitmap scanline-pad
    mov byte [rdi + 24], X_SCANLINE_UNIT
    mov byte [rdi + 25], X_SCANLINE_PAD
    ; min keycode, max keycode
    mov byte [rdi + 26], X_MIN_KEYCODE
    mov byte [rdi + 27], X_MAX_KEYCODE
    ; pad (4 bytes)
    mov dword [rdi + 28], 0
    add rdi, 32

    ; vendor "frame" padded to 4: write 5 chars + 3 pad bytes = 8 bytes
    mov dword [rdi], 'fram'
    mov byte  [rdi + 4], 'e'
    mov byte  [rdi + 5], 0
    mov word  [rdi + 6], 0
    add rdi, 8

    ; ---- pixmap formats (8 bytes each): depth 24 and depth 32, both 32 bpp.
    ; Without the depth-32 entry xcb_image_create_native(depth=32) returns
    ; NULL and libxcb-cursor (every Qt app) SIGSEGVs at first show().
    mov byte [rdi + 0], 24               ; depth
    mov byte [rdi + 1], X_FMT_BPP        ; bits-per-pixel
    mov byte [rdi + 2], X_SCANLINE_PAD   ; scanline pad
    mov byte [rdi + 3], 0
    mov dword [rdi + 4], 0
    add rdi, 8
    mov byte [rdi + 0], 32               ; depth (ARGB)
    mov byte [rdi + 1], X_FMT_BPP
    mov byte [rdi + 2], X_SCANLINE_PAD
    mov byte [rdi + 3], 0
    mov dword [rdi + 4], 0
    add rdi, 8

    ; ---- 1 screen header (40 bytes) ----
    mov dword [rdi + 0],  X_ROOT_WINDOW
    mov dword [rdi + 4],  X_DEFAULT_CMAP
    mov dword [rdi + 8],  0x00FFFFFF     ; white pixel
    mov dword [rdi + 12], 0x00000000     ; black pixel
    mov dword [rdi + 16], 0              ; current input masks (we tell clients later)
    mov ax, [screen_w]                   ; real panel size (set by init_compositor)
    mov word  [rdi + 20], ax
    mov ax, [screen_h]
    mov word  [rdi + 22], ax
    mov word  [rdi + 24], X_SCREEN_W_MM
    mov word  [rdi + 26], X_SCREEN_H_MM
    mov word  [rdi + 28], 1              ; min installed maps
    mov word  [rdi + 30], 1              ; max installed maps
    mov dword [rdi + 32], X_ROOT_VISUAL_24
    mov byte  [rdi + 36], 0              ; backing-stores: Never
    mov byte  [rdi + 37], 0              ; save-unders: False
    mov byte  [rdi + 38], 24             ; root depth
    mov byte  [rdi + 39], 2              ; number-of-allowed-depths
    add rdi, 40

    ; depth-24 record: 8-byte header + 1 visual.
    mov byte  [rdi + 0], 24
    mov byte  [rdi + 1], 0
    mov word  [rdi + 2], 1               ; visuals
    mov dword [rdi + 4], 0
    add rdi, 8
    ; visual (24 bytes): id, class, bits-per-rgb, cmap_entries, rmask,
    ; gmask, bmask, pad.
    mov dword [rdi + 0],  X_ROOT_VISUAL_24
    mov byte  [rdi + 4],  X_VISUAL_TRUECOLOR
    mov byte  [rdi + 5],  8
    mov word  [rdi + 6],  256
    mov dword [rdi + 8],  0x00FF0000
    mov dword [rdi + 12], 0x0000FF00
    mov dword [rdi + 16], 0x000000FF
    mov dword [rdi + 20], 0
    add rdi, 24

    ; depth-32 record: 8-byte header + 1 visual (ARGB).
    mov byte  [rdi + 0], 32
    mov byte  [rdi + 1], 0
    mov word  [rdi + 2], 1
    mov dword [rdi + 4], 0
    add rdi, 8
    mov dword [rdi + 0],  X_ROOT_VISUAL_32
    mov byte  [rdi + 4],  X_VISUAL_TRUECOLOR
    mov byte  [rdi + 5],  8
    mov word  [rdi + 6],  256
    mov dword [rdi + 8],  0x00FF0000
    mov dword [rdi + 12], 0x0000FF00
    mov dword [rdi + 16], 0x000000FF
    mov dword [rdi + 20], 0
    add rdi, 24

    ; Patch additional-data-length: (rdi - base - 8) / 4 into word at base+6
    mov r12, rdi
    sub r12, rbx
    sub r12, 8                           ; bytes after the 8-byte header
    shr r12, 2                           ; convert to 4-byte units
    mov [rbx + 6], r12w

    ; Send everything
    mov rdx, rdi
    sub rdx, rbx
    push rdx
    mov rax, SYS_WRITE
    mov rdi, r13                         ; target fd from caller
    mov rsi, rbx
    syscall
    pop rdx

    ; Log success.
    mov rsi, log_prefix
    mov rdx, 7
    call write_stderr
    mov rsi, log_setup_ok
    mov rdx, 19
    call write_stderr
    mov rax, rdi                         ; SYS_WRITE returned bytes written in rax — restore
    ; (we don't actually need the precise count for the log; recompute)
    lea rax, [rbx]
    mov rax, r12
    shl rax, 2
    add rax, 8                           ; total bytes sent
    call format_u64
    mov rsi, log_scratch
    mov edx, eax
    call write_stderr
    mov rsi, log_setup_ok_2
    mov rdx, log_setup_ok_2_len
    call write_stderr

    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; log_request — rdi = opcode, rsi = length (4-byte units). Writes
; "  req opcode=N len=M\n" to stderr.
; ============================================================================
log_request:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    push rdx                                 ; slot
    lea rsi, [dbg_cli_tag]                   ; "c<slot>" client prefix
    mov edx, 1
    call write_stderr
    pop rax
    call write_u64_stderr
    mov rsi, log_request_pre
    mov rdx, 13
    call write_stderr
    mov rax, rbx
    call format_u64
    mov rsi, log_scratch
    mov edx, eax
    call write_stderr
    mov rsi, log_request_mid
    mov rdx, 5
    call write_stderr
    mov rax, r12
    call format_u64
    mov rsi, log_scratch
    mov edx, eax
    call write_stderr
    lea rsi, [log_request_nl]
    mov rdx, 1
    call write_stderr
    pop r12
    pop rbx
    ret

; ============================================================================
; format_u64 — convert rax to ASCII into log_scratch. Returns rax = length.
; ============================================================================
format_u64:
    push rbx
    push r12
    lea rbx, [log_scratch + 32]          ; write backwards from here
    mov byte [rbx], 0
    mov r12, 10
    test rax, rax
    jnz .fu_loop
    dec rbx
    mov byte [rbx], '0'
    jmp .fu_done
.fu_loop:
    xor edx, edx
    div r12
    dec rbx
    add dl, '0'
    mov [rbx], dl
    test rax, rax
    jnz .fu_loop
.fu_done:
    ; Copy from rbx to log_scratch (left-justify) for the caller.
    lea rdi, [log_scratch]
    mov rsi, rbx
.fu_cp:
    mov al, [rsi]
    test al, al
    jz .fu_cp_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .fu_cp
.fu_cp_done:
    mov rax, rdi
    lea rcx, [log_scratch]
    sub rax, rcx
    pop r12
    pop rbx
    ret

; ============================================================================
; u64_to_ascii — rax = number, rdi = destination. Writes digits in order,
; returns rdi past last digit.
; ============================================================================
u64_to_ascii:
    push rbx
    push r12
    mov r12, rdi
    call format_u64                      ; uses log_scratch as scratch
    mov rcx, rax                         ; length
    mov rsi, log_scratch
    mov rdi, r12
.uta_cp:
    test rcx, rcx
    jz .uta_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .uta_cp
.uta_done:
    pop r12
    pop rbx
    ret

; ============================================================================
; atoi_or_default — rdi = NUL-terminated string. Returns parsed integer in
; rax, or DEFAULT_DISPLAY if the string isn't a positive integer.
; ============================================================================
atoi_or_default:
    xor eax, eax
.ad_loop:
    movzx edx, byte [rdi]
    sub edx, '0'
    cmp edx, 9
    ja .ad_check
    imul eax, eax, 10
    add eax, edx
    inc rdi
    jmp .ad_loop
.ad_check:
    movzx edx, byte [rdi]
    test edx, edx
    jz .ad_done
    mov eax, DEFAULT_DISPLAY
.ad_done:
    ret

; ============================================================================
; write_stderr — rsi = buf, rdx = len. Clobbers rax, rdi.
; ============================================================================
write_stderr:
    mov rax, SYS_WRITE
    mov rdi, 2
    syscall
    ret

; ============================================================================
; write_str_stderr — rsi = NUL-terminated C-string. Writes everything up to
; the NUL.
; ============================================================================
write_str_stderr:
    push rbx
    push rsi
    mov rbx, rsi
    xor ecx, ecx
.ws_len:
    cmp byte [rbx + rcx], 0
    je .ws_emit
    inc rcx
    jmp .ws_len
.ws_emit:
    mov rdx, rcx
    pop rsi
    call write_stderr
    pop rbx
    ret

; ============================================================================
; write_u64_stderr — rax = number. Writes it as decimal.
; ============================================================================
write_u64_stderr:
    call format_u64
    mov rsi, log_scratch
    mov edx, eax
    jmp write_stderr

; ============================================================================
; do_probe — phase 2 DRM/KMS enumeration. Opens /dev/dri/cardN (first one
; that accepts), runs DRM_IOCTL_VERSION + MODE_GETRESOURCES + per-connector
; MODE_GETCONNECTOR, logs everything to stderr, closes the fd, returns.
; All ioctls are read-only — no DRM master needed, safe alongside Xorg.
; ============================================================================
do_probe:
    push rbx
    push r12
    push r13

    call drm_try_open
    test rax, rax
    js .dp_open_fail
    mov [drm_fd], rax

    call drm_probe_version
    call drm_probe_resources
    call drm_probe_connectors

    mov rax, SYS_CLOSE
    mov rdi, [drm_fd]
    syscall
    pop r13
    pop r12
    pop rbx
    ret

.dp_open_fail:
    mov rsi, probe_open_fail
    mov rdx, probe_open_fail_len
    call write_stderr
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; drm_try_open — try /dev/dri/card0..card9. Returns the first fd that opens
; cleanly in rax; -1 if none.
; ============================================================================
drm_try_open:
    push rbx
    xor ebx, ebx                         ; card index
.dt_loop:
    cmp ebx, 10
    jge .dt_miss
    ; build "/dev/dri/cardN"
    lea rdi, [drm_card_path]
    lea rsi, [probe_card_pre]
.dt_cp:
    mov al, [rsi]
    test al, al
    jz .dt_cp_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .dt_cp
.dt_cp_done:
    mov eax, ebx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov byte [rdi], 0
    ; open
    mov rax, SYS_OPEN
    lea rdi, [drm_card_path]
    mov esi, O_RDWR
    xor edx, edx
    syscall
    test rax, rax
    jns .dt_ok
    inc ebx
    jmp .dt_loop
.dt_ok:
    push rax
    mov rsi, probe_open_ok_pre
    call write_str_stderr
    mov rsi, drm_card_path
    call write_str_stderr
    pop rax
    pop rbx
    ret
.dt_miss:
    mov rax, -1
    pop rbx
    ret

; ============================================================================
; drm_probe_version — DRM_IOCTL_VERSION twice (first call learns lengths,
; second call fills the name/date/desc buffers we point it at).
; ============================================================================
drm_probe_version:
    push rbx
    ; Zero the 64-byte drm_version struct.
    lea rdi, [drm_version_buf]
    xor eax, eax
    mov ecx, 8
    rep stosq

    ; First call: only counts are filled in.
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_VERSION
    lea rdx, [drm_version_buf]
    syscall
    test rax, rax
    js .dv_err

    ; Cap name/date/desc lengths to our buffer sizes.
    mov rax, [drm_version_buf + 16]      ; name_len
    cmp rax, 63
    jbe .dv_n_ok
    mov rax, 63
.dv_n_ok:
    mov [drm_version_buf + 16], rax
    lea rax, [drm_name_buf]
    mov [drm_version_buf + 24], rax
    mov rax, [drm_version_buf + 32]      ; date_len
    cmp rax, 63
    jbe .dv_d_ok
    mov rax, 63
.dv_d_ok:
    mov [drm_version_buf + 32], rax
    lea rax, [drm_date_buf]
    mov [drm_version_buf + 40], rax
    mov rax, [drm_version_buf + 48]      ; desc_len
    cmp rax, 127
    jbe .dv_x_ok
    mov rax, 127
.dv_x_ok:
    mov [drm_version_buf + 48], rax
    lea rax, [drm_desc_buf]
    mov [drm_version_buf + 56], rax

    ; Second call: kernel fills the buffers.
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_VERSION
    lea rdx, [drm_version_buf]
    syscall
    test rax, rax
    js .dv_err

    ; Print ", driver NAME vMAJ.MIN.PATCH\n"
    mov rsi, probe_version_pre
    mov rdx, probe_version_pre_len
    call write_stderr
    mov rsi, drm_name_buf
    call write_str_stderr
    mov rsi, probe_version_sep
    mov rdx, probe_version_sep_len
    call write_stderr
    mov eax, [drm_version_buf]
    call write_u64_stderr
    lea rsi, [probe_version_dot]
    mov rdx, 1
    call write_stderr
    mov eax, [drm_version_buf + 4]
    call write_u64_stderr
    lea rsi, [probe_version_dot]
    mov rdx, 1
    call write_stderr
    mov eax, [drm_version_buf + 8]
    call write_u64_stderr
    lea rsi, [probe_version_nl]
    mov rdx, 1
    call write_stderr
    pop rbx
    ret
.dv_err:
    mov rsi, ioctl_err
    mov rdx, ioctl_err_len
    call write_stderr
    pop rbx
    ret

; ============================================================================
; drm_probe_resources — DRM_IOCTL_MODE_GETRESOURCES twice. First call gets
; the counts; we plug our ID-array pointers in; second call fills them.
; ============================================================================
drm_probe_resources:
    push rbx
    lea rdi, [drm_res_buf]
    xor eax, eax
    mov ecx, 8
    rep stosq

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETRESOURCES
    lea rdx, [drm_res_buf]
    syscall
    test rax, rax
    js .dr_err

    ; Cap counts to DRM_MAX_IDS and point arrays.
    mov eax, [drm_res_buf + 32]          ; count_fbs
    cmp eax, DRM_MAX_IDS
    jbe .dr_fb_ok
    mov eax, DRM_MAX_IDS
.dr_fb_ok:
    mov [drm_res_buf + 32], eax
    lea rax, [drm_fb_ids]
    mov [drm_res_buf + 0], rax
    mov eax, [drm_res_buf + 36]          ; count_crtcs
    cmp eax, DRM_MAX_IDS
    jbe .dr_c_ok
    mov eax, DRM_MAX_IDS
.dr_c_ok:
    mov [drm_res_buf + 36], eax
    lea rax, [drm_crtc_ids]
    mov [drm_res_buf + 8], rax
    mov eax, [drm_res_buf + 40]          ; count_connectors
    cmp eax, DRM_MAX_IDS
    jbe .dr_n_ok
    mov eax, DRM_MAX_IDS
.dr_n_ok:
    mov [drm_res_buf + 40], eax
    lea rax, [drm_conn_ids]
    mov [drm_res_buf + 16], rax
    mov eax, [drm_res_buf + 44]          ; count_encoders
    cmp eax, DRM_MAX_IDS
    jbe .dr_e_ok
    mov eax, DRM_MAX_IDS
.dr_e_ok:
    mov [drm_res_buf + 44], eax
    lea rax, [drm_enc_ids]
    mov [drm_res_buf + 24], rax

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETRESOURCES
    lea rdx, [drm_res_buf]
    syscall
    test rax, rax
    js .dr_err

    ; Print "frame: resources: N CRTCs, M connectors, K encoders"
    mov rsi, probe_res_pre
    mov rdx, probe_res_pre_len
    call write_stderr
    mov eax, [drm_res_buf + 36]
    call write_u64_stderr
    mov rsi, probe_res_crtc
    mov rdx, probe_res_crtc_len
    call write_stderr
    mov eax, [drm_res_buf + 40]
    call write_u64_stderr
    mov rsi, probe_res_conn
    mov rdx, probe_res_conn_len
    call write_stderr
    mov eax, [drm_res_buf + 44]
    call write_u64_stderr
    mov rsi, probe_res_enc
    mov rdx, probe_res_enc_len
    call write_stderr
    ; framebuffer min/max
    mov rsi, probe_res_size
    mov rdx, probe_res_size_len
    call write_stderr
    mov eax, [drm_res_buf + 48]          ; min_width
    call write_u64_stderr
    mov rsi, probe_res_x
    mov rdx, 1
    call write_stderr
    mov eax, [drm_res_buf + 56]          ; min_height
    call write_u64_stderr
    mov rsi, probe_res_to
    mov rdx, probe_res_to_len
    call write_stderr
    mov eax, [drm_res_buf + 52]          ; max_width
    call write_u64_stderr
    mov rsi, probe_res_x
    mov rdx, 1
    call write_stderr
    mov eax, [drm_res_buf + 60]          ; max_height
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    pop rbx
    ret
.dr_err:
    mov rsi, ioctl_err
    mov rdx, ioctl_err_len
    call write_stderr
    pop rbx
    ret

; ============================================================================
; drm_probe_connectors — iterate the drm_conn_ids array and call
; DRM_IOCTL_MODE_GETCONNECTOR for each, printing type, state, mode count,
; and the preferred (first) mode if connected.
; ============================================================================
drm_probe_connectors:
    push rbx
    push r12
    push r13
    mov r13d, [drm_res_buf + 40]         ; count_connectors
    xor ebx, ebx                         ; index
.dc_loop:
    cmp ebx, r13d
    jge .dc_done
    mov eax, [drm_conn_ids + rbx*4]
    mov r12d, eax                        ; connector_id

    ; Zero the 80-byte struct, then plug our ID and array pointers in.
    lea rdi, [drm_conn_buf]
    xor eax, eax
    mov ecx, 10
    rep stosq
    mov [drm_conn_buf + 32], dword DRM_MAX_MODES   ; count_modes (request)
    mov [drm_conn_buf + 36], dword DRM_MAX_PROPS   ; count_props
    mov [drm_conn_buf + 40], dword DRM_MAX_IDS     ; count_encoders
    mov [drm_conn_buf + 48], r12d                  ; connector_id
    lea rax, [drm_enc_arr]
    mov [drm_conn_buf + 0], rax                    ; encoders_ptr
    lea rax, [drm_modes_buf]
    mov [drm_conn_buf + 8], rax                    ; modes_ptr
    lea rax, [drm_props_arr]
    mov [drm_conn_buf + 16], rax                   ; props_ptr
    lea rax, [drm_propvals_arr]
    mov [drm_conn_buf + 24], rax                   ; prop_values_ptr

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETCONNECTOR
    lea rdx, [drm_conn_buf]
    syscall
    test rax, rax
    js .dc_skip

    ; "  connector ID: TYPE-N -> state, M modes[, preferred WxH @ Hz]"
    mov rsi, probe_conn_pre
    mov rdx, probe_conn_pre_len
    call write_stderr
    mov eax, r12d
    call write_u64_stderr
    mov rsi, probe_conn_type
    mov rdx, probe_conn_type_len
    call write_stderr
    ; type name
    mov eax, [drm_conn_buf + 52]                   ; connector_type
    cmp eax, conn_type_max
    jbe .dc_type_ok
    lea rsi, [conn_type_unknown]
    jmp .dc_type_emit
.dc_type_ok:
    lea rdi, [conn_type_table]
    mov rsi, [rdi + rax*8]
.dc_type_emit:
    call write_str_stderr
    lea rsi, [.dc_dash]
    mov rdx, 1
    call write_stderr
    mov eax, [drm_conn_buf + 56]                   ; connector_type_id
    call write_u64_stderr
    mov rsi, probe_conn_arr
    mov rdx, probe_conn_arr_len
    call write_stderr
    ; state
    mov eax, [drm_conn_buf + 60]
    cmp eax, DRM_MODE_CONNECTED
    je .dc_state_conn
    cmp eax, DRM_MODE_DISCONNECTED
    je .dc_state_disc
    lea rsi, [probe_state_unk]
    jmp .dc_state_done
.dc_state_conn:
    lea rsi, [probe_state_conn]
    jmp .dc_state_done
.dc_state_disc:
    lea rsi, [probe_state_disc]
.dc_state_done:
    call write_str_stderr
    ; ", N modes"
    mov rsi, probe_conn_modes
    mov rdx, probe_conn_modes_len
    call write_stderr
    mov eax, [drm_conn_buf + 32]
    call write_u64_stderr
    mov rsi, probe_conn_mcount
    mov rdx, probe_conn_mcount_len
    call write_stderr
    ; if connected and at least 1 mode -> print mode 0 dims + refresh
    mov eax, [drm_conn_buf + 60]
    cmp eax, DRM_MODE_CONNECTED
    jne .dc_endl
    mov eax, [drm_conn_buf + 32]
    test eax, eax
    jz .dc_endl
    mov rsi, probe_conn_pref
    mov rdx, probe_conn_pref_len
    call write_stderr
    ; mode 0: hdisplay at +4, vdisplay at +14, vrefresh at +24
    movzx eax, word [drm_modes_buf + 4]
    call write_u64_stderr
    mov rsi, probe_res_x
    mov rdx, 1
    call write_stderr
    movzx eax, word [drm_modes_buf + 14]
    call write_u64_stderr
    mov rsi, probe_conn_at
    mov rdx, probe_conn_at_len
    call write_stderr
    mov eax, [drm_modes_buf + 24]
    call write_u64_stderr
    mov rsi, probe_conn_hz
    mov rdx, probe_conn_hz_len
    call write_stderr
    jmp .dc_skip
.dc_endl:
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
.dc_skip:
    inc ebx
    jmp .dc_loop
.dc_done:
    pop r13
    pop r12
    pop rbx
    ret
.dc_dash: db "-"

; ============================================================================
; do_modeset — phase 2b. Takes DRM master, finds the first connected
; connector, creates a dumb buffer at the connector's preferred mode size,
; fills it solid purple, SETCRTC's it, sleeps 5s, restores the original CRTC
; state, and frees everything. Requires root (CAP_SYS_ADMIN) and that no
; other client holds DRM master — run from a VT after stopping X.
; ============================================================================
do_modeset:
    push rbx
    push r12
    push r13
    push r14
    push r15

    call drm_try_open
    test rax, rax
    js .ms_e_open
    mov [drm_fd], rax
    ; drm_try_open leaves its log line open so probe mode can extend it
    ; with ", driver foo vX.Y.Z". Modeset mode wants a clean newline.
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr

    ; SET_MASTER. Fails if Xorg or another DRM master is still active,
    ; or if we lack CAP_SYS_ADMIN.
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_SET_MASTER
    xor edx, edx
    syscall
    test rax, rax
    js .ms_e_master
    mov rsi, ms_master_ok
    mov rdx, ms_master_ok_len
    call write_stderr

    ; Resources + connectors (reuses the probe helpers; they print along
    ; the way, which is what we want — situational awareness).
    call drm_probe_version
    call drm_probe_resources

    ; Find first connected connector (silent, sets r12 = connector_id,
    ; leaves drm_conn_buf populated and mode-0 at drm_modes_buf[0..68]).
    call modeset_find_connector
    test eax, eax
    jz .ms_e_no_conn
    mov [drm_chosen_conn], r12d

    ; GETENCODER for connector's encoder_id (drm_conn_buf+44).
    lea rdi, [drm_encoder_buf]
    xor eax, eax
    mov ecx, 5
    rep stosd
    mov eax, [drm_conn_buf + 44]
    mov [drm_encoder_buf], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETENCODER
    lea rdx, [drm_encoder_buf]
    syscall
    test rax, rax
    js .ms_e_getcrtc

    ; Choose a CRTC. Prefer the encoder's current crtc_id; fall back to
    ; the first bit set in possible_crtcs.
    mov eax, [drm_encoder_buf + 8]
    test eax, eax
    jnz .ms_have_crtc
    mov ecx, [drm_encoder_buf + 12]
    bsf rdx, rcx
    mov eax, [drm_crtc_ids + rdx*4]
.ms_have_crtc:
    mov r13d, eax
    mov [drm_chosen_crtc], eax

    ; Announce choice.
    mov rsi, ms_using_pre
    mov rdx, ms_using_pre_len
    call write_stderr
    mov eax, [drm_chosen_conn]
    call write_u64_stderr
    mov rsi, ms_using_crtc
    mov rdx, ms_using_crtc_len
    call write_stderr
    mov eax, [drm_chosen_crtc]
    call write_u64_stderr
    mov rsi, ms_using_mode
    mov rdx, ms_using_mode_len
    call write_stderr
    movzx eax, word [drm_modes_buf + 4]
    call write_u64_stderr
    mov rsi, probe_res_x
    mov rdx, 1
    call write_stderr
    movzx eax, word [drm_modes_buf + 14]
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr

    ; GETCRTC to save current state for restore on cleanup.
    lea rdi, [drm_crtc_save]
    xor eax, eax
    mov ecx, 13
    rep stosq
    mov [drm_crtc_save + 12], r13d
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETCRTC
    lea rdx, [drm_crtc_save]
    syscall
    test rax, rax
    js .ms_e_getcrtc

    ; CREATE_DUMB: width × height @ 32 bpp.
    lea rdi, [drm_dumb_create]
    xor eax, eax
    mov ecx, 4
    rep stosq
    movzx eax, word [drm_modes_buf + 4]      ; hdisplay → width
    mov [drm_dumb_create + 4], eax
    movzx eax, word [drm_modes_buf + 14]     ; vdisplay → height
    mov [drm_dumb_create + 0], eax
    mov dword [drm_dumb_create + 8], 32      ; bpp
    mov dword [drm_dumb_create + 12], 0      ; flags
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CREATE_DUMB
    lea rdx, [drm_dumb_create]
    syscall
    test rax, rax
    js .ms_e_dumb
    mov eax, [drm_dumb_create + 16]
    mov [drm_dumb_handle], eax
    mov eax, [drm_dumb_create + 20]
    mov [drm_dumb_pitch], eax
    mov rax, [drm_dumb_create + 24]
    mov [drm_dumb_size], rax

    mov rsi, ms_create_pre
    mov rdx, ms_create_pre_len
    call write_stderr
    mov rax, [drm_dumb_size]
    call write_u64_stderr
    mov rsi, ms_create_bytes
    mov rdx, ms_create_bytes_len
    call write_stderr

    ; MAP_DUMB: get the mmap offset to use for the dumb buffer.
    lea rdi, [drm_dumb_map]
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov eax, [drm_dumb_handle]
    mov [drm_dumb_map], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_MAP_DUMB
    lea rdx, [drm_dumb_map]
    syscall
    test rax, rax
    js .ms_e_mapdumb
    mov rax, [drm_dumb_map + 8]
    mov [drm_dumb_offset], rax

    ; mmap(NULL, size, PROT_RW, MAP_SHARED, fd, offset)
    mov rax, SYS_MMAP
    xor edi, edi
    mov rsi, [drm_dumb_size]
    mov edx, PROT_RW
    mov r10d, MAP_SHARED
    mov r8, [drm_fd]
    mov r9, [drm_dumb_offset]
    syscall
    cmp rax, -4096
    ja .ms_e_mmap
    mov [drm_dumb_addr], rax

    ; Fill: solid purple in XRGB8888. Little-endian memory bytes B,G,R,X.
    ; 0xFFAA00FF: A=FF (ignored), R=AA, G=00, B=FF → magenta-ish.
    mov rdi, [drm_dumb_addr]
    mov rcx, [drm_dumb_size]
    shr rcx, 2
    mov eax, 0xFFAA00FF
    rep stosd

    mov rsi, ms_fill_ok
    mov rdx, ms_fill_ok_len
    call write_stderr

    ; ADDFB.
    lea rdi, [drm_fb_cmd]
    xor eax, eax
    mov ecx, 7
    rep stosd
    mov eax, [drm_dumb_create + 4]           ; width
    mov [drm_fb_cmd + 4], eax
    mov eax, [drm_dumb_create + 0]           ; height
    mov [drm_fb_cmd + 8], eax
    mov eax, [drm_dumb_pitch]
    mov [drm_fb_cmd + 12], eax
    mov dword [drm_fb_cmd + 16], 32          ; bpp
    mov dword [drm_fb_cmd + 20], 24          ; depth
    mov eax, [drm_dumb_handle]
    mov [drm_fb_cmd + 24], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_ADDFB
    lea rdx, [drm_fb_cmd]
    syscall
    test rax, rax
    js .ms_e_addfb
    mov eax, [drm_fb_cmd]
    mov [drm_fb_id], eax

    mov rsi, ms_addfb_ok
    mov rdx, ms_addfb_ok_len
    call write_stderr
    mov eax, [drm_fb_id]
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr

    ; SETCRTC: point r13's CRTC at our new fb, with the preferred mode,
    ; connected to drm_chosen_conn.
    mov eax, [drm_chosen_conn]
    mov [drm_set_conn_id], eax
    lea rdi, [drm_crtc_set]
    xor eax, eax
    mov ecx, 13
    rep stosq
    lea rax, [drm_set_conn_id]
    mov [drm_crtc_set + 0], rax              ; set_connectors_ptr
    mov dword [drm_crtc_set + 8], 1          ; count_connectors
    mov [drm_crtc_set + 12], r13d            ; crtc_id
    mov eax, [drm_fb_id]
    mov [drm_crtc_set + 16], eax             ; fb_id
    mov dword [drm_crtc_set + 32], 1         ; mode_valid
    ; Copy 68-byte modeinfo (mode 0 = preferred) into struct+36.
    lea rsi, [drm_modes_buf]
    lea rdi, [drm_crtc_set + 36]
    mov ecx, 17                              ; 68/4
    rep movsd
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_set]
    syscall
    test rax, rax
    js .ms_e_setcrtc

    mov rsi, ms_setcrtc_ok
    mov rdx, ms_setcrtc_ok_len
    call write_stderr

    ; Sleep 5 seconds.
    lea rdi, [nanosleep_ts]
    mov qword [rdi], 5
    mov qword [rdi + 8], 0
    mov rax, SYS_NANOSLEEP
    xor esi, esi
    syscall

    ; Restore the original CRTC. drm_crtc_save came back from GETCRTC with
    ; the original mode + fb_id; replaying it via SETCRTC puts things back
    ; the way they were. set_connectors_ptr in the save struct is 0,
    ; which DRM treats as "use the CRTC's previously-bound connectors".
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_save]
    syscall

    ; Cleanup: RMFB, munmap, DESTROY_DUMB, DROP_MASTER, close.
    mov eax, [drm_fb_id]
    mov [drm_dumb_destroy], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_RMFB
    lea rdx, [drm_dumb_destroy]
    syscall

    mov rax, SYS_MUNMAP
    mov rdi, [drm_dumb_addr]
    mov rsi, [drm_dumb_size]
    syscall

    mov eax, [drm_dumb_handle]
    mov [drm_dumb_destroy], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_DESTROY_DUMB
    lea rdx, [drm_dumb_destroy]
    syscall

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_DROP_MASTER
    xor edx, edx
    syscall

    mov rax, SYS_CLOSE
    mov rdi, [drm_fd]
    syscall

    mov rsi, ms_restore_ok
    mov rdx, ms_restore_ok_len
    call write_stderr
    jmp .ms_done

.ms_e_open:
    mov rsi, probe_open_fail
    mov rdx, probe_open_fail_len
    call write_stderr
    jmp .ms_done
.ms_e_master:
    mov rsi, ms_master_fail
    mov rdx, ms_master_fail_len
    call write_stderr
    mov rax, SYS_CLOSE
    mov rdi, [drm_fd]
    syscall
    jmp .ms_done
.ms_e_no_conn:
    mov rsi, ms_no_conn
    mov rdx, ms_no_conn_len
    call write_stderr
    jmp .ms_close_master
.ms_e_getcrtc:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
    mov rsi, ms_err_getcrtc
    mov rdx, ms_err_getcrtc_len
    call write_stderr
    jmp .ms_close_master
.ms_e_dumb:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
    mov rsi, ms_err_dumb
    mov rdx, ms_err_dumb_len
    call write_stderr
    jmp .ms_close_master
.ms_e_mapdumb:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
    mov rsi, ms_err_mapdumb
    mov rdx, ms_err_mapdumb_len
    call write_stderr
    jmp .ms_close_master
.ms_e_mmap:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
    mov rsi, ms_err_mmap
    mov rdx, ms_err_mmap_len
    call write_stderr
    jmp .ms_close_master
.ms_e_addfb:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
    mov rsi, ms_err_addfb
    mov rdx, ms_err_addfb_len
    call write_stderr
    jmp .ms_close_master
.ms_e_setcrtc:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
    mov rsi, ms_err_setcrtc
    mov rdx, ms_err_setcrtc_len
    call write_stderr
    jmp .ms_close_master
.ms_close_master:
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_DROP_MASTER
    xor edx, edx
    syscall
    mov rax, SYS_CLOSE
    mov rdi, [drm_fd]
    syscall
.ms_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; modeset_find_connector — silent variant of drm_probe_connectors. Loops the
; ID array, GETCONNECTOR each one, stops at the first connected with
; count_modes > 0. Returns rax=1 (found) or rax=0 (none), and on found:
; r12d = connector_id, drm_conn_buf populated, drm_modes_buf[0..68] = mode 0.
; ============================================================================
modeset_find_connector:
    push rbx
    push r13
    mov r13d, [drm_res_buf + 40]              ; count_connectors
    xor ebx, ebx
.mf_loop:
    cmp ebx, r13d
    jge .mf_none
    mov eax, [drm_conn_ids + rbx*4]
    mov r12d, eax

    ; Zero + plug in our arrays + connector_id (same shape as the
    ; probe path's per-connector call).
    lea rdi, [drm_conn_buf]
    xor eax, eax
    mov ecx, 10
    rep stosq
    mov [drm_conn_buf + 32], dword DRM_MAX_MODES
    mov [drm_conn_buf + 36], dword DRM_MAX_PROPS
    mov [drm_conn_buf + 40], dword DRM_MAX_IDS
    mov [drm_conn_buf + 48], r12d
    lea rax, [drm_enc_arr]
    mov [drm_conn_buf + 0], rax
    lea rax, [drm_modes_buf]
    mov [drm_conn_buf + 8], rax
    lea rax, [drm_props_arr]
    mov [drm_conn_buf + 16], rax
    lea rax, [drm_propvals_arr]
    mov [drm_conn_buf + 24], rax

    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETCONNECTOR
    lea rdx, [drm_conn_buf]
    syscall
    test rax, rax
    js .mf_skip

    mov eax, [drm_conn_buf + 60]              ; connection state
    cmp eax, DRM_MODE_CONNECTED
    jne .mf_skip
    mov eax, [drm_conn_buf + 32]              ; count_modes
    test eax, eax
    jz .mf_skip

    mov eax, 1
    pop r13
    pop rbx
    ret
.mf_skip:
    inc ebx
    jmp .mf_loop
.mf_none:
    xor eax, eax
    pop r13
    pop rbx
    ret

; ============================================================================
; do_probe_input — phase 3a. Scan /dev/input/event0..31, call EVIOCGNAME
; on each that opens, print "  event N: NAME". No privileges beyond reading
; the device files (which on this system requires 'input' group; the user
; can also be in 'video' to inherit that).
; ============================================================================
do_probe_input:
    push rbx
    push r12
    mov rsi, input_dev_header
    mov rdx, input_dev_header_len
    call write_stderr

    xor ebx, ebx
    xor r12d, r12d                       ; success counter
.pi_loop:
    cmp ebx, INPUT_DEV_MAX
    jge .pi_done

    ; Build path "/dev/input/eventN".
    lea rdi, [input_dev_path]
    lea rsi, [input_dev_pre]
.pi_cp:
    mov al, [rsi]
    test al, al
    jz .pi_cp_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .pi_cp
.pi_cp_done:
    mov eax, ebx
    call u64_to_ascii
    mov byte [rdi], 0

    ; open O_RDONLY
    mov rax, SYS_OPEN
    lea rdi, [input_dev_path]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .pi_next
    push rax

    ; ioctl EVIOCGNAME(64) — returns bytes written including NUL.
    mov rdi, rax
    mov esi, EVIOCGNAME_64
    lea rdx, [input_dev_name]
    mov rax, SYS_IOCTL
    syscall
    pop rdi                              ; recover fd
    push rdi
    test rax, rax
    js .pi_close_skip

    ; "  event N: NAME\n"
    mov rsi, input_dev_indent
    mov rdx, input_dev_indent_len
    call write_stderr
    mov eax, ebx
    call write_u64_stderr
    mov rsi, input_dev_colon
    mov rdx, input_dev_colon_len
    call write_stderr
    lea rsi, [input_dev_name]
    call write_str_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    inc r12d

.pi_close_skip:
    pop rdi
    mov rax, SYS_CLOSE
    syscall
.pi_next:
    inc ebx
    jmp .pi_loop
.pi_done:
    test r12d, r12d
    jnz .pi_have_devs
    mov rsi, input_probe_none
    mov rdx, input_probe_none_len
    call write_stderr
.pi_have_devs:
    pop r12
    pop rbx
    ret

; ============================================================================
; do_watch_input(rdi = NUL-terminated device path) — phase 3b. Opens the
; device, prints "frame: watching NAME", then loops on read(): each batch
; of input_event records is decoded and printed. Runs until read returns 0
; (EOF — device unplugged) or the user kills us.
;
; Per-event output drops EV_SYN packets (just framing) and uses a compact
; one-line decode:
;   KEY 30 press     (EV_KEY with code < 0x100 → keyboard key)
;   BTN 272 press    (EV_KEY with code ≥ 0x100 → mouse / pad button)
;   REL 0 value=-3   (EV_REL — relative axis; mostly mouse motion)
;   ABS 0 value=512  (EV_ABS — absolute axis; touchpad coords)
;   SW  0 value=1    (EV_SW  — switch; lid open/close etc.)
;
; Keycodes match /usr/include/linux/input-event-codes.h. Phase 4 layers the
; evdev→XKB→keysym translation table on top so X clients see real keysyms.
; ============================================================================
do_watch_input:
    push rbx
    push r12
    push r13
    mov rbx, rdi                         ; save path

    mov rax, SYS_OPEN
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .wi_open_fail
    mov r12, rax

    ; Get the device name for the "watching" announcement.
    mov rdi, r12
    mov esi, EVIOCGNAME_64
    lea rdx, [input_dev_name]
    mov rax, SYS_IOCTL
    syscall

    mov rsi, input_watch_pre
    mov rdx, input_watch_pre_len
    call write_stderr
    lea rsi, [input_dev_name]
    call write_str_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr

.wi_loop:
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [input_event_batch]
    mov rdx, INPUT_BATCH_BYTES
    syscall
    test rax, rax
    jle .wi_done

    mov r13, rax                         ; total bytes
    xor rbx, rbx
.wi_event:
    cmp rbx, r13
    jge .wi_loop
    lea rdi, [input_event_batch]
    add rdi, rbx
    call print_input_event
    add rbx, INPUT_EVENT_SIZE
    jmp .wi_event

.wi_done:
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    pop r13
    pop r12
    pop rbx
    ret

.wi_open_fail:
    mov rsi, input_watch_oerr
    mov rdx, input_watch_oerr_len
    call write_stderr
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; print_input_event(rdi = pointer to a 24-byte input_event)
; Layout: tv_sec(8) tv_usec(8) type(2) code(2) value(4). Drops SYN events
; (type 0) silently — they're just packet boundaries, not user actions.
; ============================================================================
print_input_event:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    movzx r12d, word [rbx + 16]          ; type
    movzx r13d, word [rbx + 18]          ; code
    ; value is signed int32 — sign-extend.
    movsxd r14, dword [rbx + 20]

    test r12d, r12d
    jz .pe_done                           ; SYN → ignore

    ; Pick a label based on type.
    cmp r12d, EV_KEY
    je .pe_key
    cmp r12d, EV_REL
    je .pe_rel
    cmp r12d, EV_ABS
    je .pe_abs
    cmp r12d, EV_SW
    je .pe_sw
    cmp r12d, EV_MSC
    je .pe_msc
    ; ??? — print generic with type=N
    mov rsi, input_lbl_other
    mov rdx, input_lbl_other_len
    call write_stderr
    mov eax, r12d
    call write_u64_stderr
    mov rsi, input_value_pre
    mov rdx, input_value_pre_len
    call write_stderr
    mov rax, r14
    call write_i64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    jmp .pe_done

.pe_key:
    ; BTN_* codes start at 0x100; below that is keyboard.
    cmp r13d, 0x100
    jae .pe_btn
    mov rsi, input_lbl_key
    mov rdx, input_lbl_key_len
    call write_stderr
    jmp .pe_keylike
.pe_btn:
    mov rsi, input_lbl_btn
    mov rdx, input_lbl_btn_len
    call write_stderr
.pe_keylike:
    mov eax, r13d
    call write_u64_stderr
    ; action label based on value: 1 = press, 0 = release, 2 = repeat.
    cmp r14d, 1
    je .pe_press
    cmp r14d, 0
    je .pe_release
    cmp r14d, 2
    je .pe_repeat
    mov rsi, input_value_pre
    mov rdx, input_value_pre_len
    call write_stderr
    mov rax, r14
    call write_i64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    jmp .pe_done
.pe_press:
    mov rsi, input_act_press
    mov rdx, input_act_press_len
    call write_stderr
    jmp .pe_done
.pe_release:
    mov rsi, input_act_release
    mov rdx, input_act_release_len
    call write_stderr
    jmp .pe_done
.pe_repeat:
    mov rsi, input_act_repeat
    mov rdx, input_act_repeat_len
    call write_stderr
    jmp .pe_done

.pe_rel:
    mov rsi, input_lbl_rel
    mov rdx, input_lbl_rel_len
    call write_stderr
    jmp .pe_axis_emit
.pe_abs:
    mov rsi, input_lbl_abs
    mov rdx, input_lbl_abs_len
    call write_stderr
    jmp .pe_axis_emit
.pe_sw:
    mov rsi, input_lbl_sw
    mov rdx, input_lbl_sw_len
    call write_stderr
    jmp .pe_axis_emit
.pe_msc:
    mov rsi, input_lbl_msc
    mov rdx, input_lbl_msc_len
    call write_stderr
.pe_axis_emit:
    mov eax, r13d
    call write_u64_stderr
    mov rsi, input_value_pre
    mov rdx, input_value_pre_len
    call write_stderr
    mov rax, r14
    call write_i64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr

.pe_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; write_i64_stderr — rax = signed integer. Emits a leading '-' if negative.
; ============================================================================
write_i64_stderr:
    test rax, rax
    jns .wi_pos
    push rax
    lea rsi, [.wi_minus]
    mov rdx, 1
    call write_stderr
    pop rax
    neg rax
.wi_pos:
    jmp write_u64_stderr
.wi_minus: db "-"

; ============================================================================
; ============================================================================
; PHASE 4a — multi-client serve loop, dispatch table, atom interning.
; ============================================================================
; The single-client accept-then-drop model is replaced by a poll()-driven
; serve loop with up to MAX_CLIENTS concurrent connections. Each client has:
;   - a 16-byte metadata slot (fd, state, seq, buf_used)
;   - an 8 KB per-client read buffer (handles partial requests)
;
; Phase 4a implements just enough of the wire protocol that a real client
; (xdpyinfo, eventually tile/glass) can get past the setup-reply and into
; its first round of "what atoms / extensions do you have" probing:
;
;   InternAtom       (opcode  16) — real implementation with a 68-entry
;                                   predefined table + dynamic allocation
;   QueryExtension   (opcode  98) — always "not present" (no extensions
;                                   shipped yet)
;
; Every other opcode is logged ("req opcode=N len=M") and silently dropped
; — same behaviour as phase 1, just per-client now. Subsequent phases
; (4b window tree, 4c properties, 4d input, 4e SubstructureRedirect, 4f
; compositor) fill in real implementations one opcode at a time.
; ============================================================================

; ----------------------------------------------------------------------------
; init_clients — mark every slot empty (fd = -1).
; ----------------------------------------------------------------------------
init_clients:
    push rbx
    xor ebx, ebx
.ic_loop:
    cmp ebx, MAX_CLIENTS
    jge .ic_done
    mov rax, rbx
    imul rax, CLIENT_META_SIZE
    mov dword [clients_meta + rax], -1
    inc ebx
    jmp .ic_loop
.ic_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; client_alloc — accept a new client. rdi = listen_fd's accept() result.
; Finds the first empty slot, stores fd, initialises state. Returns slot
; index in eax, or -1 if every slot is in use (caller closes the fd).
; ----------------------------------------------------------------------------
client_alloc:
    push rbx
    push r12
    mov r12d, edi                            ; new fd
    xor ebx, ebx
.ca_loop:
    cmp ebx, MAX_CLIENTS
    jge .ca_full
    mov rax, rbx
    imul rax, CLIENT_META_SIZE
    cmp dword [clients_meta + rax], -1
    je .ca_take
    inc ebx
    jmp .ca_loop
.ca_take:
    ; slot at [clients_meta + rax]
    mov [clients_meta + rax + 0], r12d       ; fd
    mov byte [clients_meta + rax + 4], CSTATE_SETUP
    mov dword [clients_meta + rax + 8], 0    ; seq (incremented on first reply)
    mov dword [clients_meta + rax + 12], 0   ; buf_used
    mov eax, ebx
    pop r12
    pop rbx
    ret
.ca_full:
    mov eax, -1
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; client_close — close the fd, mark slot empty. edi = slot index.
; ----------------------------------------------------------------------------
client_close:
    push rbx
    mov ebx, edi
    mov rax, rbx
    imul rax, CLIENT_META_SIZE
    mov edi, [clients_meta + rax]
    push rax
    mov rax, SYS_CLOSE
    syscall
    pop rax
    mov dword [clients_meta + rax], -1
    mov edi, ebx
    call client_cleanup_resources
    mov rsi, log_client_gone
    mov rdx, log_client_gone_len
    call write_stderr
    pop rbx
    ret

; ----------------------------------------------------------------------------
; client_cleanup_resources — edi = slot of a disconnected client. X11
; semantics: a client's resources die with its connection. Destroys every
; resource whose XID falls in the client's ID band (X_RID_BASE + slot<<21,
; 2M wide): windows (WM gets UnmapNotify so tile drops the ghost tab, the
; screen region is exposed + damaged, backings munmap'd), pixmaps (munmap),
; GCs + pictures (with their clip entries), selection ownerships, key
; grabs, the pointer grab, focus, and any redirect claims the client held
; (a crashed WM must release root so a restarted one can re-claim it).
; Without this every client exit leaked its whole backing memory and left
; tile managing dead windows.
; ----------------------------------------------------------------------------
client_cleanup_resources:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                            ; slot
    mov dword [rr_evwins + r12*4], 0         ; drop its RandR notify sub
    mov r13d, edi
    shl r13d, 21
    add r13d, X_RID_BASE                     ; band base
    mov r14d, r13d
    add r14d, 0x200000                       ; band end (exclusive)

    ; Pointer grab held by the dying client → release. Checked by grabber
    ; slot, not window band: a grab on root (drag/DND pattern) lies outside
    ; every client band and would otherwise wedge input forever.
    cmp dword [ptr_grab_win], 0
    je .ccr_grab_ok
    cmp [ptr_grab_slot], r12d
    jne .ccr_grab_ok
    mov dword [ptr_grab_win], 0
    mov dword [ptr_grab_cursor], 0
    mov byte [ptr_grab_xi2], 0               ; stale XI2 routing wedges menus
.ccr_grab_ok:
    ; Keyboard grab held by the dying client → release (a crashed rofi
    ; must not wedge the keyboard).
    cmp [active_kbd_slot], r12d
    jne .ccr_kbd_ok
    mov dword [active_kbd_slot], -1
    mov dword [active_kbd_window], 0
    mov byte [kbd_grab_xi2], 0
.ccr_kbd_ok:
    ; Focus on a dying window → revert to PointerRoot.
    mov eax, [focus_window]
    cmp eax, r13d
    jb .ccr_focus_ok
    cmp eax, r14d
    jae .ccr_focus_ok
    mov dword [focus_window], 1
.ccr_focus_ok:

    ; Windows.
    xor ebx, ebx
.ccr_win:
    cmp ebx, MAX_WINDOWS
    jge .ccr_win_done
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea r15, [windows + rax]
    mov eax, [r15]
    cmp eax, r13d
    jb .ccr_win_next
    cmp eax, r14d
    jae .ccr_win_next
    ; Live in-band window. If mapped: damage + expose + tell the WM.
    cmp byte [r15 + 28], 0
    je .ccr_win_unmapped
    mov byte [r15 + 28], 0
    mov byte [comp_dirty], 1
    mov byte [defer_bg_composite], 1         ; app closed → hold one cycle so the
                                             ; WM's next-tab map paints in the
                                             ; same frame (no wallpaper flash)
    mov rdi, r15
    call damage_add_window
    mov rdi, r15
    call expose_under_window
    mov edi, [r15 + 4]                       ; parent
    call window_lookup
    test rax, rax
    jz .ccr_win_destroy
    test dword [rax + 24], EM_SUBSTRUCTURE_NOTIFY
    jz .ccr_win_destroy
    ; Subscriber slot: for a ROOT child it's the redirect owner (tile —
    ; root has no owning client). For any other parent it's the parent's
    ; OWNER (XID band): strip selects SubstructureNotify on its bar and
    ; must hear about dying tray icons, or their slots leak as gaps —
    ; the old code read redirect_owner (-1 on a bar) and never notified.
    cmp dword [rax], X_ROOT_WINDOW
    jne .ccr_win_owner
    movsx edi, byte [rax + 30]               ; root → redirect owner (the WM)
    cmp edi, 0
    jl .ccr_win_destroy
    jmp .ccr_win_have_slot
.ccr_win_owner:
    mov edi, [rax]
    sub edi, X_RID_BASE
    shr edi, 21                              ; parent's owner slot
    cmp edi, MAX_CLIENTS
    jae .ccr_win_destroy
.ccr_win_have_slot:
    cmp edi, r12d                            ; the dead client itself
    je .ccr_win_destroy
    mov esi, [rax]                           ; event window = parent
    mov edx, [r15]                           ; window
    push rax
    push rdi
    call send_unmap_notify
    pop rdi
    pop rax
    ; DestroyNotify too: a WM that unmaps windows itself (tile hides
    ; whole workspaces) cannot treat UnmapNotify as client-gone — it
    ; untracks on DestroyNotify only. Without this, a killed client
    ; left a ghost slot in tile's workspace forever.
    mov esi, [rax]
    mov edx, [r15]
    call send_destroy_notify
    jmp .ccr_win_destroy

.ccr_win_unmapped:
    ; Unmapped in-band window (killed while WS-hidden: the WM unmapped
    ; it, but still tracks it): no unmap/damage needed, but the WM must
    ; still hear DestroyNotify or the client ghosts in its tables.
    mov edi, [r15 + 4]                       ; parent
    call window_lookup
    test rax, rax
    jz .ccr_win_destroy
    test dword [rax + 24], EM_SUBSTRUCTURE_NOTIFY
    jz .ccr_win_destroy
    cmp dword [rax], X_ROOT_WINDOW
    jne .ccr_win_uowner
    movsx edi, byte [rax + 30]               ; root → redirect owner (the WM)
    cmp edi, 0
    jl .ccr_win_destroy
    jmp .ccr_win_uhave
.ccr_win_uowner:
    mov edi, [rax]
    sub edi, X_RID_BASE
    shr edi, 21                              ; parent's owner slot
    cmp edi, MAX_CLIENTS
    jae .ccr_win_destroy
.ccr_win_uhave:
    cmp edi, r12d                            ; the dead client itself
    je .ccr_win_destroy
    mov esi, [rax]                           ; event window = parent
    mov edx, [r15]                           ; window
    call send_destroy_notify
.ccr_win_destroy:
    mov edi, [r15]
    call window_destroy                      ; munmaps backing, recurses children
.ccr_win_next:
    inc ebx
    jmp .ccr_win
.ccr_win_done:

    ; Pixmaps.
    xor ebx, ebx
.ccr_px:
    cmp ebx, MAX_PIXMAPS
    jge .ccr_px_done
    mov rax, rbx
    imul rax, PIXMAP_REC_SIZE
    lea r15, [pixmaps + rax]
    mov eax, [r15]
    cmp eax, r13d
    jb .ccr_px_next
    cmp eax, r14d
    jae .ccr_px_next
    mov rdi, [r15 + 16]
    test rdi, rdi
    jz .ccr_px_clear
    movzx esi, word [r15 + 4]
    movzx ecx, word [r15 + 6]
    imul esi, ecx
    shl esi, 2
    mov rax, SYS_MUNMAP
    syscall
.ccr_px_clear:
    mov dword [r15], 0
    mov qword [r15 + 16], 0
.ccr_px_next:
    inc ebx
    jmp .ccr_px
.ccr_px_done:

    ; GCs (zero the xid AND the clip entry so a reused slot starts clean).
    xor ebx, ebx
.ccr_gc:
    cmp ebx, MAX_GCS
    jge .ccr_gc_done
    mov rax, rbx
    imul rax, GC_REC_SIZE
    lea r15, [gcs + rax]
    mov eax, [r15]
    cmp eax, r13d
    jb .ccr_gc_next
    cmp eax, r14d
    jae .ccr_gc_next
    mov dword [r15], 0
    mov rax, rbx
    imul rax, CLIP_ENTRY_SIZE
    mov dword [gc_clips + rax], 0
.ccr_gc_next:
    inc ebx
    jmp .ccr_gc
.ccr_gc_done:

    ; Pictures (same clip-entry hygiene).
    xor ebx, ebx
.ccr_pic:
    cmp ebx, MAX_PICTURES
    jge .ccr_pic_done
    mov rax, rbx
    imul rax, PICTURE_REC_SIZE
    lea r15, [pictures + rax]
    mov eax, [r15]
    cmp eax, r13d
    jb .ccr_pic_next
    cmp eax, r14d
    jae .ccr_pic_next
    mov dword [r15], 0
    mov rax, rbx
    imul rax, CLIP_ENTRY_SIZE
    mov dword [pic_clips + rax], 0
.ccr_pic_next:
    inc ebx
    jmp .ccr_pic
.ccr_pic_done:

    ; Selection ownerships → None (the atom stays interned).
    xor ebx, ebx
.ccr_sel:
    cmp ebx, [sel_count]
    jge .ccr_sel_done
    mov eax, [sel_owners + rbx*4]
    cmp eax, r13d
    jb .ccr_sel_next
    cmp eax, r14d
    jae .ccr_sel_next
    mov dword [sel_owners + rbx*4], 0
.ccr_sel_next:
    inc ebx
    jmp .ccr_sel
.ccr_sel_done:

    ; XFIXES selection-notify subscriptions held by this client.
    lea eax, [r12d + 1]                       ; stored value = slot+1
    xor ebx, ebx
.ccr_xf:
    cmp ebx, XFIXES_SUB_MAX
    jge .ccr_xf_done
    mov ecx, ebx
    imul ecx, ecx, 12
    cmp [xfixes_subs + rcx], eax
    jne .ccr_xf_next
    mov dword [xfixes_subs + rcx], 0
.ccr_xf_next:
    inc ebx
    jmp .ccr_xf
.ccr_xf_done:

    ; MIT-SHM segments this client attached → shmdt + free the table entry.
    xor ebx, ebx
.ccr_shm:
    cmp ebx, SHM_SEG_MAX
    jge .ccr_shm_done
    imul ecx, ebx, 32
    cmp dword [shm_segs + rcx], 0            ; occupied?
    je .ccr_shm_next
    cmp [shm_segs + rcx + 4], r12d           ; owned by the dying client?
    jne .ccr_shm_next
    push rcx
    mov rdi, [shm_segs + rcx + 8]
    mov eax, SYS_SHMDT
    syscall
    pop rcx
    mov dword [shm_segs + rcx], 0
.ccr_shm_next:
    inc ebx
    jmp .ccr_shm
.ccr_shm_done:

    ; Key grabs registered by this client.
    xor ebx, ebx
.ccr_kg:
    cmp ebx, MAX_KEY_GRABS
    jge .ccr_kg_done
    mov rax, rbx
    shl rax, 4                               ; KEY_GRAB_SIZE = 16
    cmp dword [key_grabs + rax], 0
    je .ccr_kg_next
    cmp [key_grabs + rax + 4], r12d          ; client_slot
    jne .ccr_kg_next
    mov dword [key_grabs + rax], 0
.ccr_kg_next:
    inc ebx
    jmp .ccr_kg
.ccr_kg_done:

    ; Redirect claims (WM death): release so a restarted WM can re-claim.
    xor ebx, ebx
.ccr_rd:
    cmp ebx, MAX_WINDOWS
    jge .ccr_rd_done
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea r15, [windows + rax]
    cmp dword [r15], 0
    je .ccr_rd_next
    movsx eax, byte [r15 + 30]
    cmp eax, r12d
    jne .ccr_rd_next
    mov byte [r15 + 30], -1
.ccr_rd_next:
    inc ebx
    jmp .ccr_rd
.ccr_rd_done:
    call sync_pointer_window                 ; dead client's windows are gone —
    pop r15                                  ; re-crossing under the pointer
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Helpers: client_meta_addr(eax = slot) → rax = &clients_meta[slot]
;          client_buf_addr (eax = slot) → rax = &clients_bufs[slot * BUF_SIZE]
; Both leave the input register intact.
; ----------------------------------------------------------------------------
client_meta_addr:
    mov rcx, rax
    imul rcx, CLIENT_META_SIZE
    lea rax, [clients_meta + rcx]
    ret
client_buf_addr:
    mov rcx, rax
    imul rcx, CLIENT_BUF_SIZE
    lea rax, [clients_bufs + rcx]
    ret

; ----------------------------------------------------------------------------
; init_atoms — walk predef_atom_stream, populating atom_off[] / atom_len[]
; / atom_strings. Predefined atoms get IDs 1..68; atom_count is left
; pointing at the next free ID (69). Atom 0 = None and is never used.
; ----------------------------------------------------------------------------
init_atoms:
    push rbx
    push r12
    push r13
    push r14
    mov dword [atom_count], 1                ; reserve atom 0 = None
    mov dword [atom_strings_used], 0
    lea rbx, [predef_atom_stream]
.ia_loop:
    movzx eax, byte [rbx]
    test eax, eax
    jz .ia_done
    mov r12d, eax                            ; name length
    inc rbx                                  ; skip length byte

    ; Allocate atom id = atom_count, then ++.
    mov r13d, [atom_count]
    inc dword [atom_count]
    ; Record offset + length.
    mov r14d, [atom_strings_used]
    mov [atom_off + r13*4], r14d
    mov [atom_len + r13*4], r12d
    ; Copy r12 bytes from rbx to atom_strings + r14d.
    lea rdi, [atom_strings + r14]
    mov rsi, rbx
    mov ecx, r12d
    rep movsb
    add [atom_strings_used], r12d
    add rbx, r12                             ; advance past name
    jmp .ia_loop
.ia_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; atom_lookup — find an atom by name. rdi = name ptr, esi = name length.
; Returns atom id in eax, or 0 if not found. Linear scan over atom_count;
; for ~68 entries this is well under a microsecond.
; ----------------------------------------------------------------------------
atom_lookup:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                             ; needle ptr
    mov r13d, esi                            ; needle length
    mov ebx, 1                               ; skip atom 0
.al_loop:
    cmp ebx, [atom_count]
    jge .al_miss
    cmp [atom_len + rbx*4], r13d
    jne .al_next
    mov eax, [atom_off + rbx*4]
    lea r14, [atom_strings + rax]
    mov r15, r12
    mov ecx, r13d
.al_cmp:
    test ecx, ecx
    jz .al_hit
    mov al, [r14]
    cmp al, [r15]
    jne .al_next
    inc r14
    inc r15
    dec ecx
    jmp .al_cmp
.al_hit:
    mov eax, ebx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.al_next:
    inc ebx
    jmp .al_loop
.al_miss:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; atom_create — register a new atom. rdi = name ptr, esi = name length.
; Returns the new id in eax, or 0 on table exhaustion (table is sized
; for typical full sessions; an exhausted table just refuses further
; allocations rather than overflowing).
; ----------------------------------------------------------------------------
atom_create:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov r13d, [atom_count]
    cmp r13d, MAX_ATOMS
    jge .ac_full
    mov eax, [atom_strings_used]
    add eax, r12d
    cmp eax, ATOM_STRINGS_CAP
    jg .ac_full
    ; Stash offset + length, copy name.
    mov eax, [atom_strings_used]
    mov [atom_off + r13*4], eax
    mov [atom_len + r13*4], r12d
    lea rdi, [atom_strings + rax]
    mov rsi, rbx
    mov ecx, r12d
    rep movsb
    add [atom_strings_used], r12d
    inc dword [atom_count]
    mov eax, r13d
    pop r13
    pop r12
    pop rbx
    ret
.ac_full:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; serve_loop — main multi-client event loop. Builds a pollfd array each
; iteration (listen_fd + up to 16 client fds), polls with infinite
; timeout, then accepts new connections / dispatches per-client reads.
; ============================================================================
serve_loop:
    mov rsi, log_prefix
    mov rdx, 7
    call write_stderr
    mov rsi, log_serve_ready
    mov rdx, log_serve_ready_len
    call write_stderr
.sl_iter:
    ; --- Build pollfd_buf. Always begins with listen_fd. Then each
    ; live client slot gets a pollfd; empty slots are represented by
    ; fd=-1 (poll ignores those, returning revents=0).
    mov eax, [listen_fd]
    mov [pollfd_buf], eax
    mov word [pollfd_buf + 4], 1             ; POLLIN
    mov word [pollfd_buf + 6], 0
    xor ecx, ecx                             ; client slot index
.sl_build:
    cmp ecx, MAX_CLIENTS
    jge .sl_build_inputs
    mov rax, rcx
    imul rax, CLIENT_META_SIZE
    mov edx, [clients_meta + rax]            ; fd (or -1)
    mov rax, rcx
    inc rax                                  ; pollfd index = client_slot + 1
    shl rax, 3                               ; * 8 (pollfd size)
    mov [pollfd_buf + rax], edx
    mov word [pollfd_buf + rax + 4], 1       ; POLLIN
    mov word [pollfd_buf + rax + 6], 0
    inc ecx
    jmp .sl_build
.sl_build_inputs:
    ; --- Now append input device pollfds at indices
    ;     (MAX_CLIENTS + 1) .. (MAX_CLIENTS + 1 + MAX_INPUTS - 1).
    xor ecx, ecx
.sl_build_in_loop:
    cmp ecx, MAX_INPUTS
    jge .sl_build_drm
    mov edx, [input_fds + rcx*4]             ; fd (or -1)
    mov eax, MAX_CLIENTS + 1
    add eax, ecx
    shl eax, 3
    mov [pollfd_buf + rax], edx
    mov word [pollfd_buf + rax + 4], 1       ; POLLIN
    mov word [pollfd_buf + rax + 6], 0
    inc ecx
    jmp .sl_build_in_loop
.sl_build_drm:
    ; --- Last slot: the DRM fd, so page-flip completion events wake the
    ; loop instead of a blocking read stalling the whole server a vblank.
    mov edx, -1
    cmp byte [compositor_active], 0
    je .sl_drm_slot
    cmp byte [fbtest_mode], 0
    jne .sl_drm_slot
    cmp byte [drm_poll_dead], 0              ; errored fd: stop polling it
    jne .sl_drm_slot
    mov edx, [drm_fd]
.sl_drm_slot:
    mov eax, MAX_CLIENTS + 1 + MAX_INPUTS
    shl eax, 3
    mov [pollfd_buf + rax], edx
    mov word [pollfd_buf + rax + 4], 1       ; POLLIN
    mov word [pollfd_buf + rax + 6], 0
    ; --- Next slot: the netlink uevent socket (display hotplug).
    ; -1 when unavailable — poll ignores negative fds, zero idle cost.
    mov edx, [uevent_fd]
    mov eax, MAX_CLIENTS + 1 + MAX_INPUTS + 1
    shl eax, 3
    mov [pollfd_buf + rax], edx
    mov word [pollfd_buf + rax + 4], 1       ; POLLIN
    mov word [pollfd_buf + rax + 6], 0
    ; --- Very last slot: the VT-active sysfs attr. POLLPRI fires on any
    ; VT switch; that's how frame re-acquires the display when its VT
    ; comes back (Ctrl+Alt+Fn away and back no longer kills the session).
    mov edx, [vtactive_fd]
    mov eax, MAX_CLIENTS + 1 + MAX_INPUTS + 2
    shl eax, 3
    mov [pollfd_buf + rax], edx
    mov word [pollfd_buf + rax + 4], 2       ; POLLPRI
    mov word [pollfd_buf + rax + 6], 0
.sl_poll:
    mov rax, SYS_POLL
    lea rdi, [pollfd_buf]
    mov esi, MAX_CLIENTS + 1 + MAX_INPUTS + 3
    mov edx, -1                              ; infinite timeout when idle (no
    cmp byte [flip_pending], 0               ; wakeups → battery). But while a
    jne .sl_poll_flip                        ; PAGE_FLIP is in flight, cap at
    cmp byte [comp_dirty], 0                 ; 100ms; and after a one-cycle bg
    je .sl_chk_blank                         ; defer (comp_dirty held, no flip),
    mov edx, 16                              ; wake in 16ms so the fallback
    jmp .sl_poll_go                          ; bg-repaint still happens if the WM
.sl_poll_flip:                               ; never maps a replacement.
    mov edx, 100                             ; a DRM completion event that never
    jmp .sl_poll_go                          ; arrives would otherwise wedge
.sl_chk_blank:                               ; flip_pending forever = black screen.
    ; Fully idle. Screen auto-off: wake exactly once, at the blank deadline.
    ; Once blanked (or disabled/fbtest) the timeout stays infinite — zero
    ; idle wakeups either way.
    cmp byte [compositor_active], 0
    je .sl_poll_go
    cmp byte [fbtest_mode], 0                ; no panel to power off — and
    jne .sl_poll_go                          ; last_input_mono is never armed
    cmp byte [vt_away], 0                    ; console owns the display
    jne .sl_poll_go
    cmp byte [blank_state], 0
    jne .sl_poll_go
    mov eax, [cfg_blank_ms]
    test eax, eax
    jz .sl_poll_go
    push rax
    call now_mono_ms
    pop rcx                                  ; cfg ms
    mov rdx, [last_input_mono]
    add rdx, rcx                             ; deadline
    sub rdx, rax                             ; remaining
    jg  .sl_blank_wait
    call comp_blank                          ; deadline passed → panel off
    mov edx, -1
    jmp .sl_poll_go
.sl_blank_wait:
    mov rax, 0x7FFFFFFF                      ; cap to poll's int range
    cmp rdx, rax
    cmova rdx, rax
    mov edx, edx                             ; timeout = ms until blank
.sl_poll_go:
    ; re-load the poll registers — the blank-deadline path clobbers them
    mov rax, SYS_POLL
    lea rdi, [pollfd_buf]
    mov esi, MAX_CLIENTS + 1 + MAX_INPUTS + 3
    syscall                                  ; (timeout in edx)
    test rax, rax
    jz .sl_poll_timeout
    js .sl_iter                              ; -EINTR or similar — re-poll
    jmp .sl_poll_done
.sl_poll_timeout:
    cmp byte [flip_pending], 0               ; flip was pending → lost-flip path:
    je .sl_poll_done                         ; unstick + re-poll. Else this was the
    mov byte [flip_pending], 0               ; 16ms bg-defer fallback → fall to the
    jmp .sl_iter                             ; composite check and paint it.
.sl_poll_done:

    ; --- Listen fd ready: accept all pending connections.
    movzx eax, word [pollfd_buf + 6]
    test eax, eax
    jz .sl_clients
    call do_accept
    test rax, rax
    js .sl_clients                           ; transient error — skip
    mov edi, eax
    push rdi
    call client_alloc
    pop rdi
    cmp eax, -1
    jne .sl_announce_ok
    ; All slots full — refuse and close immediately.
    push rdi
    mov rsi, log_max_clients
    mov rdx, log_max_clients_len
    call write_stderr
    pop rdi
    mov rax, SYS_CLOSE
    syscall
    jmp .sl_clients
.sl_announce_ok:
    mov rsi, log_accepted
    mov rdx, log_accepted_len
    call write_stderr

.sl_clients:
    ; --- Walk client slots and process anyone whose revents has POLLIN.
    xor ecx, ecx
.sl_walk:
    cmp ecx, MAX_CLIENTS
    jge .sl_walk_inputs
    push rcx
    mov rax, rcx
    inc rax
    shl rax, 3
    movzx edx, word [pollfd_buf + rax + 6]   ; revents
    pop rcx
    test edx, edx
    jz .sl_walk_next
    mov rax, rcx
    imul rax, CLIENT_META_SIZE
    cmp dword [clients_meta + rax], -1
    je .sl_walk_next                         ; slot was closed mid-iter
    push rcx
    mov edi, ecx
    call client_process
    pop rcx
.sl_walk_next:
    inc ecx
    jmp .sl_walk
.sl_walk_inputs:
    ; --- Walk input pollfds and process anyone who has POLLIN.
    xor ecx, ecx
.sl_iw:
    cmp ecx, MAX_INPUTS
    jge .sl_flush
    mov eax, MAX_CLIENTS + 1
    add eax, ecx
    shl eax, 3
    movzx edx, word [pollfd_buf + rax + 6]
    test edx, edx
    jz .sl_iw_next
    mov edi, [input_fds + rcx*4]
    cmp edi, 0
    js .sl_iw_next
    push rcx
    call process_input
    pop rcx
.sl_iw_next:
    inc ecx
    jmp .sl_iw

.sl_flush:
    ; --- VT watch: POLLPRI on tty0/active = a VT switch happened. Re-read
    ; the attr (rearms the poll) and re-acquire the display if it's ours.
    mov eax, MAX_CLIENTS + 1 + MAX_INPUTS + 2
    shl eax, 3
    movzx eax, word [pollfd_buf + rax + 6]   ; revents
    test eax, 0x0A                           ; POLLPRI|POLLERR (sysfs style)
    jz .sl_no_vtev
    call vt_read_active                      ; eax = active VT (also rearms)
    cmp byte [vt_away], 0
    je .sl_no_vtev
    cmp eax, [own_vt]
    jne .sl_no_vtev
    call vt_reacquire
.sl_no_vtev:

    ; --- Display hotplug: drain the uevent socket; any DRM change event
    ; schedules a reconfigure (run below once no flip is in flight).
    mov eax, MAX_CLIENTS + 1 + MAX_INPUTS + 1
    shl eax, 3
    movzx eax, word [pollfd_buf + rax + 6]   ; revents
    test eax, 1                              ; POLLIN
    jz .sl_no_uevent
.sl_uevent_drain:
    mov rax, SYS_READ
    mov edi, [uevent_fd]
    lea rsi, [uevent_buf]
    mov rdx, 4096
    syscall
    test rax, rax
    jle .sl_no_uevent                        ; EAGAIN → drained
    ; scan the datagram for "drm" (change@ ... /drm/cardN, HOTPLUG=1)
    lea rdi, [uevent_buf]
    lea rcx, [rax - 3]
.sl_uev_scan:
    test rcx, rcx
    jle .sl_uevent_drain
    cmp word [rdi], 'dr'
    jne .sl_uev_next
    cmp byte [rdi + 2], 'm'
    je .sl_uev_hit
.sl_uev_next:
    inc rdi
    dec rcx
    jmp .sl_uev_scan
.sl_uev_hit:
    mov byte [hotplug_pending], 1
    jmp .sl_uevent_drain
.sl_no_uevent:
    cmp byte [hotplug_pending], 0
    je .sl_no_hotplug
    cmp byte [flip_pending], 0               ; wait until in-flight flips land
    jne .sl_no_hotplug
    cmp byte [vt_away], 0                    ; deferred until the VT is ours
    jne .sl_no_hotplug                       ; again (flag survives)
    mov byte [hotplug_pending], 0
    call compositor_reconfigure
.sl_no_hotplug:

    ; Flip completion: the DRM fd's POLLIN means the pending page flip
    ; landed at vblank — drain the event and clear the gate. POLLERR/POLLHUP
    ; (GPU reset, device loss) must ALSO be consumed or poll returns
    ; immediately forever (busy-spin) with flip_pending wedged: drain, clear
    ; the gate, and stop polling the fd (flips become fire-and-forget).
    mov eax, MAX_CLIENTS + 1 + MAX_INPUTS
    shl eax, 3
    movzx eax, word [pollfd_buf + rax + 6]   ; revents
    test eax, 0x19                            ; POLLIN|POLLERR|POLLHUP
    jz .sl_composite
    test eax, 0x18                            ; error states → fd is dead
    jz .sl_drm_read
    mov byte [drm_poll_dead], 1
.sl_drm_read:
    mov rax, SYS_READ
    mov rdi, [drm_fd]
    lea rsi, [drm_event_buf]
    mov rdx, 64
    syscall
    ; Walk the events: each FLIP_COMPLETE (type 2) retires one in-flight
    ; flip. With two outputs the two completions can arrive in one read or
    ; two wakeups — flip_pending is a count, not a flag.
    test rax, rax
    jle .sl_composite
    xor ecx, ecx
.sl_drm_ev:
    lea rdx, [rax - 8]
    cmp rcx, rdx                             ; need type+length header
    jg .sl_composite
    mov edx, [drm_event_buf + rcx + 4]       ; event length
    cmp edx, 8
    jl .sl_composite                         ; malformed → stop
    cmp dword [drm_event_buf + rcx], 2       ; DRM_EVENT_FLIP_COMPLETE
    jne .sl_drm_ev_next
    cmp byte [flip_pending], 0
    je .sl_drm_ev_next
    dec byte [flip_pending]
.sl_drm_ev_next:
    add ecx, edx
    cmp rcx, rax
    jl .sl_drm_ev
.sl_composite:
    ; Coalesced, flip-paced repaint: at most ONE damage repaint + async
    ; page-flip per poll cycle, and none while a flip is still in flight
    ; (its completion event re-runs this check). Drawing handlers set
    ; comp_dirty + damage rects rather than repainting per request.
    cmp byte [comp_dirty], 0
    je .sl_iter
    cmp byte [vt_away], 0                    ; switched away: the console owns
    je .sl_vt_here                           ; the display — swallow the dirt,
    mov byte [comp_dirty], 0                 ; reacquire repaints everything
    jmp .sl_iter
.sl_vt_here:
    cmp byte [blank_state], 0                ; panel dark: swallow the dirt —
    je .sl_blank_ok                          ; compositing (and flipping on a
    mov byte [comp_dirty], 0                 ; disabled CRTC) is pure waste, and
    jmp .sl_iter                             ; a held comp_dirty means 16ms
.sl_blank_ok:                                ; wakeups forever. Unblank forces a
    cmp byte [flip_pending], 0               ; full repaint anyway.
    jne .sl_iter
    cmp byte [defer_bg_composite], 0         ; a toplevel was just removed?
    je .sl_do_composite
    mov byte [defer_bg_composite], 0         ; consume the one-cycle grace: leave
    jmp .sl_iter                             ; comp_dirty set, composite next time
.sl_do_composite:                            ; (poll now uses a 16ms fallback)
    mov byte [comp_dirty], 0
    call recomposite_screen
    jmp .sl_iter

; ============================================================================
; client_process — read everything available on this client and drain
; the per-client buffer. edi = slot index. On read 0/error → close slot.
; ============================================================================
client_process:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi                             ; slot

    ; meta_ptr in r12, fd in r13d
    mov eax, ebx
    call client_meta_addr
    mov r12, rax
    mov r13d, [r12]
    mov r14d, [r12 + 12]                     ; buf_used

    ; If buffer is full, drop client (request too big / malformed).
    cmp r14d, CLIENT_BUF_SIZE
    jge .cp_close

    ; Read into buf + buf_used.
    mov eax, ebx
    call client_buf_addr
    add rax, r14
    mov rax, SYS_READ
    push rax                                  ; placeholder for syscall arg juggling
    mov edi, r13d
    mov eax, ebx
    call client_buf_addr
    lea rsi, [rax + r14]
    pop rax
    mov rax, SYS_READ
    mov edi, r13d
    mov edx, CLIENT_BUF_SIZE
    sub edx, r14d                             ; space left
    syscall
    test rax, rax
    jle .cp_close                             ; 0=EOF, <0=error
    add r14d, eax
    mov [r12 + 12], r14d

.cp_drain:
    ; --- State machine.
    movzx eax, byte [r12 + 4]
    cmp eax, CSTATE_SETUP
    je .cp_setup
    ; RUNNING.
    cmp r14d, 4
    jl .cp_done                              ; need at least the 4-byte header
    mov eax, ebx
    call client_buf_addr
    movzx edx, word [rax + 2]                ; length in 4-byte units
    shl edx, 2
    test edx, edx
    jnz .cp_have_len
    mov edx, 4                               ; defensive (length 0 shouldn't happen)
.cp_have_len:
    cmp r14d, edx
    jl .cp_done                              ; need more bytes for this request
    push rdx
    mov edi, ebx
    mov esi, edx
    call dispatch_request
    pop rdx
    ; Shift remaining buffer down by edx.
    mov eax, ebx
    call client_buf_addr
    sub r14d, edx
    mov rsi, rax
    add rsi, rdx
    mov rdi, rax
    mov ecx, r14d
    rep movsb
    mov [r12 + 12], r14d
    jmp .cp_drain

.cp_setup:
    ; Setup-request handling. Need at least 12 bytes, plus auth tail.
    cmp r14d, 12
    jl .cp_done
    mov eax, ebx
    call client_buf_addr
    cmp byte [rax], 'l'
    jne .cp_setup_bad
    mov dx, [rax + 2]
    cmp dx, X_PROTO_MAJOR
    jne .cp_setup_bad
    movzx edx, word [rax + 6]                ; auth name length
    add edx, 3
    and edx, ~3
    movzx ecx, word [rax + 8]                ; auth data length
    add ecx, 3
    and ecx, ~3
    add edx, ecx
    add edx, 12                              ; total setup-request size
    cmp r14d, edx
    jl .cp_done                              ; need more bytes for auth tail
    push rdx
    mov edi, r13d                            ; fd
    mov esi, ebx                             ; client slot — for per-client rid_base
    call emit_setup_reply
    pop rdx
    mov byte [r12 + 4], CSTATE_RUNNING
    ; Shift buffer past the consumed setup bytes.
    mov eax, ebx
    call client_buf_addr
    sub r14d, edx
    mov rsi, rax
    add rsi, rdx
    mov rdi, rax
    mov ecx, r14d
    rep movsb
    mov [r12 + 12], r14d
    jmp .cp_drain

.cp_setup_bad:
    mov rsi, log_setup_bad
    mov rdx, log_setup_bad_len
    call write_stderr
    jmp .cp_close

.cp_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.cp_close:
    mov edi, ebx
    call client_close
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; dispatch_request — edi = slot, esi = request size in bytes. The request
; lives at client_buf_addr(slot)[0..esi-1].
;
; Increments the per-client sequence number for every request (whether or
; not it gets a reply; replies need the matching sequence so the client
; can tie reply to request).
; ============================================================================
dispatch_request:
    push rbx
    push r12
    push r13
    mov ebx, edi                             ; slot
    mov r13d, esi                            ; request size

    ; Bump sequence.
    mov eax, ebx
    call client_meta_addr
    inc dword [rax + 8]

    mov eax, ebx
    call client_buf_addr
    mov r12, rax                             ; request ptr

    movzx eax, byte [r12]                    ; opcode
    movzx edx, word [r12 + 2]                ; length (4-byte units)

    ; Requests are NOT logged per-request any more — log_request costs ~7
    ; write() syscalls, which at GIMP-scale traffic (thousands of draw
    ; requests per second) burned real CPU and battery. Only UNHANDLED
    ; opcodes are logged now (at the dispatch fall-through).
    cmp eax, 1
    je .dr_create_window
    cmp eax, 2
    je .dr_change_window_attributes
    cmp eax, 3
    je .dr_get_window_attributes
    cmp eax, 25
    je .dr_send_event
    cmp eax, 22
    je .dr_set_selection_owner
    cmp eax, 23
    je .dr_get_selection_owner
    cmp eax, 24
    je .dr_convert_selection
    cmp eax, 47
    je .dr_query_font
    cmp eax, 4
    je .dr_destroy_window
    cmp eax, 7
    je .dr_reparent_window
    cmp eax, 8
    je .dr_map_window
    cmp eax, 10
    je .dr_unmap_window
    cmp eax, 12
    je .dr_configure_window
    cmp eax, 53
    je .dr_create_pixmap
    cmp eax, 54
    je .dr_free_pixmap
    cmp eax, 56
    je .dr_change_gc
    cmp eax, 59
    je .dr_set_clip_rectangles
    cmp eax, 60
    je .dr_free_gc
    cmp eax, 61
    je .dr_clear_area
    cmp eax, 62
    je .dr_copy_area
    cmp eax, 67
    je .dr_poly_rectangle
    cmp eax, 70
    je .dr_poly_fill_rectangle
    cmp eax, 72
    je .dr_put_image
    cmp eax, 73
    je .dr_get_image
    cmp eax, 83
    je .dr_list_installed_colormaps
    cmp eax, 26
    je .dr_grab_pointer
    cmp eax, 27
    je .dr_ungrab_pointer
    cmp eax, 31
    je .dr_grab_keyboard
    cmp eax, 32
    je .dr_ungrab_keyboard
    cmp eax, 33
    je .dr_grab_key
    cmp eax, 34
    je .dr_ungrab_key
    cmp eax, 14
    je .dr_get_geometry
    cmp eax, 15
    je .dr_query_tree
    cmp eax, 16
    je .dr_intern_atom
    cmp eax, 17
    je .dr_get_atom_name
    cmp eax, 18
    je .dr_change_property
    cmp eax, 19
    je .dr_delete_property
    cmp eax, 20
    je .dr_get_property
    cmp eax, 21
    je .dr_list_properties
    cmp eax, 42
    je .dr_set_input_focus
    cmp eax, 43
    je .dr_get_input_focus
    cmp eax, 44
    je .dr_query_keymap
    cmp eax, 41
    je .dr_warp_pointer
    cmp eax, 84                              ; AllocColor / AllocNamedColor —
    je .dr_alloc_color                       ; reply-carrying; scrot -s blocks
    cmp eax, 85                              ; on 'gray' for its rubber band
    je .dr_alloc_named_color
    cmp eax, 38
    je .dr_query_pointer
    cmp eax, 40
    je .dr_translate_coords
    cmp eax, 55
    je .dr_create_gc
    cmp eax, 97
    je .dr_query_best_size
    cmp eax, 98
    je .dr_query_extension
    cmp eax, 99
    je .dr_list_extensions
    cmp eax, 100
    je .dr_change_keyboard_mapping
    cmp eax, 101
    je .dr_get_keyboard_mapping
    cmp eax, 118
    je .dr_set_modifier_mapping
    cmp eax, 103
    je .dr_get_keyboard_control
    cmp eax, 106
    je .dr_get_pointer_control
    cmp eax, 108
    je .dr_get_screen_saver
    cmp eax, 110
    je .dr_list_hosts
    cmp eax, 117
    je .dr_get_pointer_mapping
    cmp eax, 119
    je .dr_get_modifier_mapping
    cmp eax, RENDER_MAJOR
    je .dr_render
    cmp eax, XKB_MAJOR
    je .dr_xkb
    cmp eax, RR_MAJOR
    je .dr_randr
    cmp eax, XI_MAJOR
    je .dr_xinput
    cmp eax, XFIXES_MAJOR
    je .dr_xfixes
    cmp eax, SHM_MAJOR
    je .dr_shm
    cmp eax, SHAPE_MAJOR
    je .dr_shape
    cmp eax, XTEST_MAJOR
    je .dr_xtest
    ; Void no-ops — requests with no reply that frame can safely accept and
    ; ignore. Silences the log noise and, for toolkits that follow them with
    ; a blocking round-trip, keeps the stream healthy. 36/37 Grab/UngrabServer
    ; (single-threaded server — always "grabbed"), 45/46 Open/CloseFont (core
    ; fonts unused; QueryFont replies fixed metrics regardless), 78..82
    ; colormap ops (TrueColor only — colormaps are decorative), 95 FreeCursor.
    lea ecx, [rax - 36]
    cmp ecx, 1
    jbe .dr_done
    lea ecx, [rax - 45]
    cmp ecx, 1
    jbe .dr_done
    lea ecx, [rax - 78]
    cmp ecx, 4
    jbe .dr_done
    cmp eax, 95
    je .dr_done
    cmp eax, 94                              ; CreateGlyphCursor
    jne .dr_not_gcur
    mov rsi, r12
    call handle_create_glyph_cursor
    jmp .dr_done
.dr_not_gcur:
    cmp eax, 93                              ; CreatePixmapCursor
    jne .dr_not_pcur
    mov rsi, r12
    call handle_create_pixmap_cursor
    jmp .dr_done
.dr_not_pcur:
    ; Unhandled — log it (the only requests still logged; each one is a
    ; protocol gap worth knowing about).
    push rax
    movzx edx, word [r12 + 2]
    mov rdi, rax
    mov rsi, rdx
    mov edx, ebx
    call log_request
    pop rax
    jmp .dr_done

.dr_render:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_render
    jmp .dr_done

.dr_xkb:
    mov edi, ebx
    mov rsi, r12
    call handle_xkb
    jmp .dr_done

.dr_query_pointer:
    mov edi, ebx
    mov rsi, r12
    call handle_query_pointer
    jmp .dr_done

.dr_translate_coords:
    mov edi, ebx
    mov rsi, r12
    call handle_translate_coordinates
    jmp .dr_done

.dr_randr:
    mov edi, ebx
    mov rsi, r12
    call handle_randr
    jmp .dr_done

.dr_xfixes:
    mov edi, ebx
    mov rsi, r12
    call handle_xfixes
    jmp .dr_done

.dr_shm:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_shm
    jmp .dr_done

.dr_shape:
    mov edi, ebx
    mov rsi, r12
    call handle_shape
    jmp .dr_done

.dr_xtest:
    mov edi, ebx
    mov rsi, r12
    call handle_xtest
    jmp .dr_done

.dr_xinput:
    mov edi, ebx
    mov rsi, r12
    call handle_xinput
    jmp .dr_done

.dr_intern_atom:
    mov edi, ebx
    call handle_intern_atom
    jmp .dr_done

.dr_get_property:
    mov edi, ebx
    mov rsi, r12
    call handle_get_property
    jmp .dr_done

.dr_change_property:
    mov edi, ebx
    mov rsi, r12
    call handle_change_property
    jmp .dr_done

.dr_get_atom_name:
    mov edi, ebx
    mov rsi, r12
    call handle_get_atom_name
    jmp .dr_done

.dr_delete_property:
    mov edi, ebx
    mov rsi, r12
    call handle_delete_property
    jmp .dr_done

.dr_list_properties:
    mov edi, ebx
    mov rsi, r12
    call handle_list_properties
    jmp .dr_done

.dr_create_gc:
    mov edi, ebx
    mov rsi, r12
    call handle_create_gc
    jmp .dr_done

.dr_change_gc:
    mov edi, ebx
    mov rsi, r12
    call handle_change_gc
    jmp .dr_done

.dr_free_gc:
    mov rsi, r12
    call handle_free_gc
    jmp .dr_done

.dr_set_clip_rectangles:
    mov rsi, r12
    mov edx, r13d
    call handle_set_clip_rectangles
    jmp .dr_done

.dr_poly_fill_rectangle:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_poly_fill_rectangle
    jmp .dr_done

.dr_put_image:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_put_image
    jmp .dr_done

.dr_create_pixmap:
    mov rsi, r12
    call handle_create_pixmap
    jmp .dr_done

.dr_free_pixmap:
    mov rsi, r12
    call handle_free_pixmap
    jmp .dr_done

.dr_clear_area:
    mov rsi, r12
    call handle_clear_area
    jmp .dr_done

.dr_copy_area:
    mov rsi, r12
    call handle_copy_area
    jmp .dr_done

.dr_poly_rectangle:
    mov rsi, r12
    mov edx, r13d
    call handle_poly_rectangle
    jmp .dr_done

.dr_query_extension:
    mov edi, ebx
    mov rsi, r12
    call handle_query_extension
    jmp .dr_done

.dr_get_geometry:
    mov edi, ebx
    mov rsi, r12
    call handle_get_geometry
    jmp .dr_done

.dr_query_tree:
    mov edi, ebx
    call handle_query_tree
    jmp .dr_done

.dr_set_input_focus:
    mov rsi, r12
    call handle_set_input_focus
    jmp .dr_done

.dr_get_input_focus:
    mov edi, ebx
    call handle_get_input_focus
    jmp .dr_done
.dr_query_keymap:
    mov edi, ebx
    call handle_query_keymap
    jmp .dr_done
.dr_warp_pointer:
    mov rsi, r12
    call handle_warp_pointer
    jmp .dr_done
.dr_alloc_color:
    mov edi, ebx
    mov rsi, r12
    call handle_alloc_color
    jmp .dr_done
.dr_alloc_named_color:
    mov edi, ebx
    mov rsi, r12
    call handle_alloc_named_color
    jmp .dr_done

.dr_list_extensions:
    mov edi, ebx
    call handle_list_extensions
    jmp .dr_done

.dr_convert_selection:
    mov edi, ebx
    mov rsi, r12
    call handle_convert_selection
    jmp .dr_done

.dr_get_image:
    mov edi, ebx
    mov rsi, r12
    call handle_get_image
    jmp .dr_done

.dr_list_installed_colormaps:
    mov edi, ebx
    call handle_list_installed_colormaps
    jmp .dr_done

.dr_get_keyboard_mapping:
    mov edi, ebx
    mov rsi, r12                             ; request ptr
    call handle_get_keyboard_mapping
    jmp .dr_done

.dr_change_keyboard_mapping:
    mov rsi, r12
    call handle_change_keyboard_mapping
    jmp .dr_done

.dr_set_modifier_mapping:
    mov edi, ebx
    call handle_set_modifier_mapping
    jmp .dr_done

.dr_get_window_attributes:
    mov edi, ebx
    mov rsi, r12
    call handle_get_window_attributes
    jmp .dr_done

.dr_grab_pointer:
    mov edi, ebx
    mov rsi, r12
    call handle_grab_pointer
    jmp .dr_done

.dr_ungrab_pointer:
    mov dword [ptr_grab_win], 0              ; release the pointer grab
    mov dword [ptr_grab_cursor], 0
    call cursor_sync                         ; back to the window's cursor
    jmp .dr_done

.dr_grab_keyboard:
    mov edi, ebx
    mov rsi, r12
    call handle_grab_keyboard
    jmp .dr_done

.dr_ungrab_keyboard:
    mov dword [active_kbd_slot], -1
    mov dword [active_kbd_window], 0
    jmp .dr_done

.dr_grab_key:
    mov edi, ebx
    mov rsi, r12
    call handle_grab_key
    jmp .dr_done

.dr_ungrab_key:
    mov rsi, r12
    call handle_ungrab_key
    jmp .dr_done

.dr_send_event:
    mov rsi, r12
    call handle_send_event
    jmp .dr_done

.dr_set_selection_owner:
    mov edi, ebx
    mov rsi, r12
    call handle_set_selection_owner
    jmp .dr_done

.dr_get_selection_owner:
    mov edi, ebx
    mov rsi, r12
    call handle_get_selection_owner
    jmp .dr_done

.dr_query_font:
    mov edi, ebx
    call handle_query_font
    jmp .dr_done

.dr_create_window:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_create_window
    jmp .dr_done

.dr_change_window_attributes:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_change_window_attributes
    jmp .dr_done

.dr_destroy_window:
    mov edi, ebx
    mov rsi, r12
    call handle_destroy_window
    jmp .dr_done

.dr_reparent_window:
    mov edi, ebx
    mov rsi, r12
    call handle_reparent_window
    jmp .dr_done

.dr_map_window:
    mov edi, ebx
    mov rsi, r12
    call handle_map_window
    jmp .dr_done

.dr_unmap_window:
    mov edi, ebx
    mov rsi, r12
    call handle_unmap_window
    jmp .dr_done

.dr_configure_window:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_configure_window
    jmp .dr_done

.dr_query_best_size:
    mov edi, ebx
    mov rsi, r12
    call handle_query_best_size
    jmp .dr_done

.dr_get_keyboard_control:
    mov edi, ebx
    call handle_get_keyboard_control
    jmp .dr_done

.dr_get_pointer_control:
    mov edi, ebx
    call handle_get_pointer_control
    jmp .dr_done

.dr_get_screen_saver:
    mov edi, ebx
    call handle_get_screen_saver
    jmp .dr_done

.dr_list_hosts:
    mov edi, ebx
    call handle_list_hosts
    jmp .dr_done

.dr_get_pointer_mapping:
    mov edi, ebx
    call handle_get_pointer_mapping
    jmp .dr_done

.dr_get_modifier_mapping:
    mov edi, ebx
    call handle_get_modifier_mapping
    jmp .dr_done

.dr_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_intern_atom — edi = slot. The request body sits at the start of
; the client's buffer:
;   +0 opcode (16)        +1 only-if-exists (BOOL)
;   +2 length (4u)        +4 n (CARD16 = name length)
;   +6 pad (2)            +8 name (n bytes, padded to 4)
;
; Reply (32 bytes):
;   +0 1 (Reply)          +1 0
;   +2 sequence (u16)     +4 reply length (4u, = 0)
;   +8 atom (u32)         +12..31 pad
; ============================================================================
handle_intern_atom:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax                             ; meta ptr
    mov eax, ebx
    call client_buf_addr
    mov r13, rax                             ; request ptr
    movzx r14d, word [r13 + 4]               ; n
    lea r15, [r13 + 8]                       ; name ptr
    movzx ecx, byte [r13 + 1]                ; only-if-exists

    ; Look up first.
    push rcx
    mov rdi, r15
    mov esi, r14d
    call atom_lookup
    pop rcx
    test eax, eax
    jnz .ha_have                             ; existing atom
    ; Not found. If only-if-exists, return 0; else create.
    test cl, cl
    jnz .ha_emit
    mov rdi, r15
    mov esi, r14d
    call atom_create
.ha_have:
.ha_emit:
    push rax
    ; Build reply.
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]                       ; seq (already incremented)
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0                   ; reply length
    pop rax
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; Write 32 bytes.
    mov edi, [r12]                           ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_query_extension — edi = slot. Always replies "not present" since
; no extensions have shipped yet.
;
; Reply (32 bytes):
;   +0 1 (Reply)          +1 0
;   +2 seq (u16)          +4 reply length 0
;   +8 present (BOOL = 0) +9 major-opcode (0)
;   +10 first-event (0)   +11 first-error (0)
;   +12..31 pad
; ============================================================================
; edi = slot, rsi = req ptr.
;   +4 name-length (CARD16)   +8 name (string, padded to 4)
; We recognise "RENDER" and report it present with major opcode
; RENDER_MAJOR; everything else reports absent (present=0).
; ============================================================================
; handle_xfixes — edi = slot, rsi = req. XFIXES extension. Implements the
; clipboard-manager path: QueryVersion (0) + SelectSelectionInput (2). All
; other minors (regions, save-set, cursor) are void no-ops. GetCursorImage
; (4) has a reply, but no clipboard flow uses it; add if something blocks.
; ============================================================================
; ----------------------------------------------------------------------------
; handle_shm — MIT-SHM. edi = slot, rsi = req ptr, edx = req byte length.
;   minor 0 ShmQueryVersion  1 ShmAttach  2 ShmDetach  3 ShmPutImage
; Attach shmat()s the client's SysV segment read-only; PutImage blits the
; client's rendered image straight out of it (no image bytes on the wire).
; ----------------------------------------------------------------------------
handle_shm:
    movzx eax, byte [rsi + 1]                ; minor
    test eax, eax
    jz .shm_query_version
    cmp eax, 1
    je .shm_attach
    cmp eax, 2
    je .shm_detach
    cmp eax, 3
    je .shm_put_image
    cmp eax, 4
    je .shm_get_image
    ; unknown minor: log it — a silently dropped reply-carrying request
    ; wedges the client forever (ShmGetImage cost a debugging session)
    push rax
    mov rsi, log_shm_minor
    mov edx, 11
    call write_stderr
    pop rax
    call write_u64_stderr
    mov rsi, qext_nl
    mov edx, 1
    call write_stderr
    ret

.shm_get_image:
    jmp handle_shm_get_image                 ; edi=slot, rsi=req still set

.shm_query_version:
    mov esi, 32
    call xkb_reply_zero                      ; edi=slot; rdi=buf r15d=fd r8d=total
    mov byte [rdi + 1], 0                    ; sharedPixmaps = False (PutImage only)
    mov word [rdi + 8], 1                    ; majorVersion = 1
    mov word [rdi + 10], 1                   ; minorVersion = 1 → classic SysV attach
    mov byte [rdi + 16], 2                   ; pixmapFormat = ZPixmap
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.shm_attach:
    ; +4 shmseg id   +8 SysV shmid   +12 readOnly
    push rbx
    push r12
    push r13
    push r14
    mov r12d, [rsi + 4]                      ; shmseg id
    mov r14d, edi                            ; client slot
    mov r13d, [rsi + 8]                      ; SysV shmid
    movzx ebx, byte [rsi + 12]               ; readOnly flag from the client
    mov eax, SYS_SHMAT                       ; readOnly=0 → attach READ-WRITE:
    mov edi, r13d                            ; ShmGetImage fills the segment
    xor esi, esi
    xor edx, edx
    test ebx, ebx
    jz .shm_att_mode
    mov edx, SHM_RDONLY
.shm_att_mode:
    push rbx
    syscall
    pop rbx
    test rax, rax
    jns .shm_att_ok
    ; RW attach refused (segment perms) → retry read-only; PutImage
    ; still works, GetImage into it will refuse.
    test ebx, ebx
    jnz .shm_attach_done                     ; was already RO → give up
    mov ebx, 1
    mov eax, SYS_SHMAT
    mov edi, r13d
    xor esi, esi
    mov edx, SHM_RDONLY
    push rbx
    syscall
    pop rbx
    test rax, rax
    js .shm_attach_done
.shm_att_ok:
    push rbx                                 ; ro flag
    mov rbx, rax                             ; attached address
    mov eax, SYS_SHMCTL                      ; size = shm_segsz (IPC_STAT @ +48)
    mov edi, r13d
    mov esi, IPC_STAT
    lea rdx, [shmid_ds_buf]
    syscall
    test rax, rax
    js .shm_attach_detach                    ; can't size it → safest to detach
    mov r13, [shmid_ds_buf + 48]             ; shm_segsz
    xor ecx, ecx
.shm_att_find:
    cmp ecx, SHM_SEG_MAX
    jge .shm_attach_detach                   ; table full → detach, drop
    imul eax, ecx, 32
    mov edx, [shm_segs + rax]                ; shmseg (0 = empty)
    test edx, edx
    jz .shm_att_store
    cmp edx, r12d                            ; reuse a same-id entry
    je .shm_att_store
    inc ecx
    jmp .shm_att_find
.shm_att_store:
    mov [shm_segs + rax + 0], r12d           ; shmseg id
    mov [shm_segs + rax + 4], r14d           ; owning client slot
    mov [shm_segs + rax + 8], rbx            ; attached address
    mov [shm_segs + rax + 16], r13           ; segment size
    pop rcx                                  ; ro flag
    mov [shm_segs + rax + 24], cl
    jmp .shm_attach_ret
.shm_attach_detach:
    mov eax, SYS_SHMDT
    mov rdi, rbx
    syscall
    pop rcx                                  ; discard the pushed ro flag
    jmp .shm_attach_ret
.shm_attach_done:
.shm_attach_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.shm_detach:
    ; +4 shmseg id — shmdt() and free the table entry.
    mov r9d, [rsi + 4]
    xor ecx, ecx
.shm_det_find:
    cmp ecx, SHM_SEG_MAX
    jge .shm_detach_done
    imul eax, ecx, 32
    cmp [shm_segs + rax], r9d
    je .shm_det_hit
    inc ecx
    jmp .shm_det_find
.shm_det_hit:
    push rax
    mov rdi, [shm_segs + rax + 8]
    mov eax, SYS_SHMDT
    syscall
    pop rax
    mov dword [shm_segs + rax], 0
.shm_detach_done:
    ret

.shm_put_image:
    jmp handle_shm_put_image                  ; edi=slot, rsi=req still set

; ----------------------------------------------------------------------------
; handle_shm_get_image — edi = slot, rsi = req. ShmGetImage (minor 4):
;   +4 drawable  +8 x s16  +10 y s16  +12 w u16  +14 h u16  +16 planemask
;   +20 format (2 = ZPixmap)  +24 shmseg  +28 offset
; Copies the rect into the client's attached segment (tight w*4 rows at
; offset) and replies {depth, visual, size}. scrot/imlib2 grab the whole
; screen this way — an unanswered ShmGetImage hangs them forever.
; ----------------------------------------------------------------------------
handle_shm_get_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 40
    mov ebx, edi                             ; slot
    mov r12, rsi                             ; req
    mov eax, ebx
    call client_meta_addr
    mov [rsp], rax                           ; meta (fd +0, seq +8)
    cmp byte [r12 + 20], 2                   ; ZPixmap only
    jne .sgi_err
    ; --- source pixels (mirror handle_get_image) ---
    mov edi, [r12 + 4]
    cmp edi, X_ROOT_WINDOW
    jne .sgi_drawable
    cmp byte [comp_dirty], 0                 ; fold pending damage first, or
    je .sgi_root_fresh                       ; the grab misses fresh drawing
    cmp byte [flip_pending], 0
    jne .sgi_root_fresh
    mov byte [comp_dirty], 0
    call recomposite_screen
.sgi_root_fresh:
    mov eax, [comp_back]
    xor eax, 1
    mov r13, [comp_addr + rax*8]             ; FRONT buffer
    test r13, r13
    jz .sgi_err
    mov eax, [screen_w]
    mov [rsp + 8], eax                       ; src width (px)
    mov eax, [screen_h]
    mov [rsp + 12], eax                      ; src height
    mov eax, [drm_dumb_pitch]
    mov [rsp + 24], eax                      ; src pitch (bytes)
    jmp .sgi_have_src
.sgi_drawable:
    call drawable_get_backing
    test rax, rax
    jz .sgi_err
    mov r13, rax
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    shl edx, 2
    mov [rsp + 24], edx
.sgi_have_src:
    movsx r14d, word [r12 + 8]               ; x
    movsx r15d, word [r12 + 10]              ; y
    movzx ebp, word [r12 + 12]               ; w
    movzx eax, word [r12 + 14]               ; h
    mov [rsp + 16], eax
    test ebp, ebp
    jz .sgi_err
    test eax, eax
    jz .sgi_err
    test r14d, r14d
    js .sgi_err
    test r15d, r15d
    js .sgi_err
    mov eax, r14d
    add eax, ebp
    cmp eax, [rsp + 8]                       ; x+w <= src width
    jg .sgi_err
    mov eax, r15d
    add eax, [rsp + 16]
    cmp eax, [rsp + 12]                      ; y+h <= src height
    jg .sgi_err
    ; --- destination segment: find entry (need addr + size + ro flag) ---
    mov r9d, [r12 + 24]                      ; shmseg id
    xor ecx, ecx
.sgi_seg_find:
    cmp ecx, SHM_SEG_MAX
    jge .sgi_err
    imul eax, ecx, 32
    cmp [shm_segs + rax], r9d
    je .sgi_seg_hit
    inc ecx
    jmp .sgi_seg_find
.sgi_seg_hit:
    cmp byte [shm_segs + rax + 24], 0        ; attached read-only → can't fill
    jne .sgi_err
    mov r10, [shm_segs + rax + 8]            ; segment address
    mov r11, [shm_segs + rax + 16]           ; segment size
    mov ecx, [r12 + 28]                      ; offset
    add r10, rcx                             ; dst = addr + offset
    sub r11, rcx                             ; remaining bytes
    jb .sgi_err
    ; bytes needed = w*4 * h
    mov eax, ebp
    shl eax, 2                               ; dst stride (tight)
    mov [rsp + 28], eax
    mov edx, [rsp + 16]                      ; h (zero-extended)
    imul rax, rdx                            ; bytes needed = stride * h
    cmp rax, r11
    ja .sgi_err
    ; --- copy rows: src = r13 + y*pitch + x*4 ---
    mov eax, r15d
    imul eax, dword [rsp + 24]
    add r13, rax
    mov eax, r14d
    shl eax, 2
    add r13, rax
    mov edx, [rsp + 16]                      ; rows left
.sgi_row:
    test edx, edx
    jz .sgi_done_copy
    push rdx
    mov rsi, r13
    mov rdi, r10
    mov ecx, ebp                             ; w pixels
    rep movsd
    pop rdx
    mov eax, [rsp + 24]
    add r13, rax                             ; next src row
    mov eax, [rsp + 28]
    add r10, rax                             ; next dst row (tight)
    dec edx
    jmp .sgi_row
.sgi_done_copy:
    ; --- reply: depth @1, visual @8, size @12 ---
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 24                   ; depth
    mov rax, [rsp]
    mov ecx, [rax + 8]
    mov [rdi + 2], cx                        ; seq
    mov dword [rdi + 8], X_ROOT_VISUAL_24    ; visual
    mov eax, [rsp + 28]
    imul eax, dword [rsp + 16]
    mov [rdi + 12], eax                      ; size (bytes written)
    mov rax, [rsp]
    mov edi, [rax]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
    jmp .sgi_out
.sgi_err:
    ; BadMatch error so the client unblocks instead of hanging.
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 0                    ; Error
    mov byte [rdi + 1], 8                    ; BadMatch
    mov rax, [rsp]
    mov ecx, [rax + 8]
    mov [rdi + 2], cx                        ; seq
    mov rax, [rsp]
    mov edi, [rax]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
.sgi_out:
    add rsp, 40
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; shm_seg_lookup — edi = shmseg id. Returns rax = attached address (0 if not
; found), rdx = segment size. Clobbers rcx.
shm_seg_lookup:
    xor ecx, ecx
.ssl_find:
    cmp ecx, SHM_SEG_MAX
    jge .ssl_none
    imul eax, ecx, 32
    cmp [shm_segs + rax], edi
    je .ssl_hit
    inc ecx
    jmp .ssl_find
.ssl_hit:
    mov rdx, [shm_segs + rax + 16]
    mov rax, [shm_segs + rax + 8]
    ret
.ssl_none:
    xor eax, eax
    xor edx, edx
    ret

handle_xfixes:
    movzx eax, byte [rsi + 1]                ; XFIXES minor
    test eax, eax
    jz .xf_query_version
    cmp eax, 2
    je .xf_select_input
    ret                                      ; void: regions / save-set / etc.

.xf_query_version:
    ; XFixesQueryVersion (0): reply major=5 minor=0. Clients accept >= 1.
    mov esi, 32
    call xkb_reply_zero                       ; edi=slot; rdi=buf r15d=fd r8d=total
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 5                    ; major_version
    mov dword [rdi + 12], 0                   ; minor_version
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.xf_select_input:
    ; XFixesSelectSelectionInput (2): +4 window, +8 selection, +12 event-mask.
    ; Record (slot, selection, window). mask == 0 removes the subscription.
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi                             ; slot
    mov r13d, [rsi + 8]                       ; selection atom
    mov r14d, [rsi + 4]                       ; window
    mov r15d, [rsi + 12]                      ; event-mask
    xor ecx, ecx                             ; index
    mov r12d, -1                             ; first empty seen
.xfsi_find:
    cmp ecx, XFIXES_SUB_MAX
    jge .xfsi_place
    mov eax, ecx
    imul eax, eax, 12
    mov edx, [xfixes_subs + rax]             ; stored slot+1 (0 = empty)
    test edx, edx
    jz .xfsi_empty
    dec edx
    cmp edx, ebx
    jne .xfsi_next
    cmp [xfixes_subs + rax + 4], r13d        ; same selection?
    jne .xfsi_next
    mov r12d, ecx                            ; update existing entry
    jmp .xfsi_store
.xfsi_empty:
    cmp r12d, -1
    jne .xfsi_next
    mov r12d, ecx                            ; remember first empty
.xfsi_next:
    inc ecx
    jmp .xfsi_find
.xfsi_place:
    cmp r12d, -1
    je .xfsi_done                            ; table full → drop
.xfsi_store:
    mov eax, r12d
    imul eax, eax, 12
    test r15d, r15d
    jz .xfsi_clear                           ; mask 0 → deselect
    lea edx, [ebx + 1]
    mov [xfixes_subs + rax], edx             ; slot+1
    mov [xfixes_subs + rax + 4], r13d        ; selection
    mov [xfixes_subs + rax + 8], r14d        ; window
    jmp .xfsi_done
.xfsi_clear:
    mov dword [xfixes_subs + rax], 0
.xfsi_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; xfixes_emit_selection_notify — ecx = selection atom, edx = new owner window.
; Sends XFixesSelectionNotify (subtype 0 = SetSelectionOwner) to every client
; subscribed to that selection. This is what lets copyq notice the clipboard
; changed and grab the new content into its history.
; ----------------------------------------------------------------------------
xfixes_emit_selection_notify:
    push rbx
    push r12
    push r13
    push r14
    mov r13d, ecx                            ; selection
    mov r14d, edx                            ; owner
    xor ebx, ebx
.xen_loop:
    cmp ebx, XFIXES_SUB_MAX
    jge .xen_done
    mov eax, ebx
    imul eax, eax, 12
    mov r12d, [xfixes_subs + rax]            ; slot+1
    test r12d, r12d
    jz .xen_next
    cmp [xfixes_subs + rax + 4], r13d        ; this selection?
    jne .xen_next
    dec r12d                                 ; subscriber slot
    mov ecx, [xfixes_subs + rax + 8]         ; subscriber window
    lea rdi, [xfixes_sub_evbuf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi], XFIXES_EVENT_BASE        ; type = XFixesSelectionNotify
    mov byte [rdi + 1], 0                    ; subtype = SetSelectionOwner
    mov [rdi + 4], ecx                       ; window
    mov [rdi + 8], r14d                      ; owner
    mov [rdi + 12], r13d                     ; selection
    mov eax, [server_time_ms]
    mov [rdi + 16], eax                      ; timestamp
    mov [rdi + 20], eax                      ; selection_timestamp
    mov edi, r12d                            ; slot
    lea rsi, [xfixes_sub_evbuf]
    call send_event_to_slot
.xen_next:
    inc ebx
    jmp .xen_loop
.xen_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

handle_query_extension:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r13, rsi                             ; req ptr
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1                    ; reply
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]                       ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0                   ; reply length 0
    mov dword [rdi + 8], 0                   ; present(0)=absent + pad
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; Recognised extensions: RENDER (len 6), XKEYBOARD (len 9). Else → absent.
    movzx eax, word [r13 + 4]                ; name-length
    cmp eax, 6
    jne .qe_try_xkb
    lea rsi, [r13 + 8]
    lea rdi, [str_render]
    mov ecx, 6
.qe_cmp_r:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_try_xfixes                       ; not RENDER — try XFIXES (also len 6)
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_r
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], RENDER_MAJOR         ; major-opcode
    mov byte [rdi + 10], 0                   ; first-event
    mov byte [rdi + 11], RENDER_ERROR_BASE   ; first-error
    jmp .qe_send
.qe_try_xfixes:
    lea rsi, [r13 + 8]
    lea rdi, [str_xfixes]
    mov ecx, 6
.qe_cmp_xf:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_send
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_xf
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], XFIXES_MAJOR
    mov byte [rdi + 10], XFIXES_EVENT_BASE
    mov byte [rdi + 11], XFIXES_ERROR_BASE
    jmp .qe_send
.qe_try_xkb:
    cmp eax, 9
    jne .qe_try_randr
    lea rsi, [r13 + 8]
    lea rdi, [str_xkb]
    mov ecx, 9
.qe_cmp_x:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_send
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_x
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], XKB_MAJOR
    mov byte [rdi + 10], XKB_EVENT_BASE
    mov byte [rdi + 11], XKB_ERROR_BASE
    jmp .qe_send
.qe_try_randr:
    cmp eax, 5
    jne .qe_try_xinput
    lea rsi, [r13 + 8]
    lea rdi, [str_randr]
    mov ecx, 5
.qe_cmp_rr:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_try_shape                        ; len 5 but not RANDR → try SHAPE
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_rr
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], RR_MAJOR
    mov byte [rdi + 10], RR_EVENT_BASE
    mov byte [rdi + 11], RR_ERROR_BASE
    jmp .qe_send
.qe_try_xinput:
    cmp eax, 15
    jne .qe_try_shm
    lea rsi, [r13 + 8]
    lea rdi, [str_xinput]
    mov ecx, 15
.qe_cmp_xi:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_send
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_xi
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], XI_MAJOR
    mov byte [rdi + 10], XI_EVENT_BASE
    mov byte [rdi + 11], XI_ERROR_BASE
    jmp .qe_send
.qe_try_shm:
    cmp eax, 7
    jne .qe_try_shape
    lea rsi, [r13 + 8]
    lea rdi, [str_shm]
    mov ecx, 7
.qe_cmp_shm:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_send
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_shm
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], SHM_MAJOR
    mov byte [rdi + 10], SHM_EVENT_BASE
    mov byte [rdi + 11], SHM_ERROR_BASE
    jmp .qe_send

.qe_try_shape:
    cmp eax, 5
    jne .qe_send
    lea rsi, [r13 + 8]
    lea rdi, [str_shape]
    mov ecx, 5
.qe_cmp_shape:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_try_xtest                        ; len 5 but not SHAPE → try XTEST
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_shape
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], SHAPE_MAJOR
    mov byte [rdi + 10], SHAPE_EVENT_BASE
    mov byte [rdi + 11], 0                   ; SHAPE defines no errors
    jmp .qe_send

.qe_try_xtest:
    lea rsi, [r13 + 8]
    lea rdi, [str_xtest]
    mov ecx, 5
.qe_cmp_xtest:
    mov dl, [rsi]
    cmp dl, [rdi]
    jne .qe_send
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp_xtest
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], XTEST_MAJOR
    mov byte [rdi + 10], 0                   ; XTest has no events
    mov byte [rdi + 11], 0                   ; ...and no errors

.qe_send:
    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; XTEST extension — synthetic input injection (copyq's paste-into-terminal,
; xdotool). Minors: 0 GetVersion, 1 CompareCursor (trivial true), 2 FakeInput
; (the one that matters), 3 GrabControl (void no-op). FakeInput synthesises a
; 24-byte input_event and feeds dispatch_input_event — the exact pipeline
; real evdev and --testinput use, so grabs/focus/modifiers all behave
; identically. The request's time field (delay) is treated as 0/now.
; ============================================================================
handle_xtest:
    movzx eax, byte [rsi + 1]
    test eax, eax
    jz .xt_get_version
    cmp eax, 1
    je .xt_compare_cursor
    cmp eax, 2
    je .xt_fake_input
    ret                                      ; 3 GrabControl (void) + unknown

.xt_get_version:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 2                    ; majorVersion = 2
    mov word [rdi + 8], 2                    ; minorVersion = 2
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.xt_compare_cursor:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 1                    ; same = True
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.xt_fake_input:
    ; Embedded core-event layout: type@+4 detail@+5 time@+8 root@+12
    ; rootX s16 @+24  rootY s16 @+26.
    push rbx
    push r12
    push r13
    mov r12, rsi
    ; Stamp the synthetic event with the current server time so
    ; server_time_ms doesn't jump backwards (dispatch derives it from the
    ; record's tv fields).
    lea rbx, [xtest_fake_ev]
    mov eax, [server_time_ms]
    xor edx, edx
    mov ecx, 1000
    div ecx                                  ; eax = sec, edx = ms
    mov [rbx], rax                           ; tv_sec (upper bits 0)
    imul edx, 1000
    mov [rbx + 8], rdx                       ; tv_usec (upper bits 0)
    movzx eax, byte [r12 + 4]                ; fake event type
    movzx r13d, byte [r12 + 5]               ; detail
    cmp eax, 2
    je .xt_key_press
    cmp eax, 3
    je .xt_key_release
    cmp eax, 4
    je .xt_btn_press
    cmp eax, 5
    je .xt_btn_release
    cmp eax, 6
    je .xt_motion
    jmp .xt_out

.xt_key_press:
    mov ecx, 1
    jmp .xt_key
.xt_key_release:
    xor ecx, ecx
.xt_key:
    ; X keycode = evdev code + 8
    sub r13d, 8
    js  .xt_out
    mov word [rbx + 16], EV_KEY
    mov [rbx + 18], r13w
    mov [rbx + 20], ecx
    lea rdi, [rbx]
    call dispatch_input_event
    jmp .xt_out

.xt_btn_press:
    mov ecx, 1
    jmp .xt_btn
.xt_btn_release:
    xor ecx, ecx
.xt_btn:
    ; buttons 4-7 are wheel steps: one EV_REL on press, nothing on release
    cmp r13d, 4
    jb  .xt_btn_real
    cmp r13d, 7
    ja  .xt_btn_real
    test ecx, ecx
    jz  .xt_out                              ; wheel release = no-op
    mov word [rbx + 16], EV_REL
    mov word [rbx + 18], 8                   ; REL_WHEEL
    mov edx, 1
    cmp r13d, 4
    je  .xt_wheel_set
    mov edx, -1
.xt_wheel_set:
    mov [rbx + 20], edx
    lea rdi, [rbx]
    call dispatch_input_event
    jmp .xt_out
.xt_btn_real:
    ; 1=BTN_LEFT 2=BTN_MIDDLE 3=BTN_RIGHT 8=BTN_SIDE 9=BTN_EXTRA
    mov edx, 0x110                           ; BTN_LEFT
    cmp r13d, 2
    jne .xt_b3q
    mov edx, 0x112                           ; BTN_MIDDLE
.xt_b3q:
    cmp r13d, 3
    jne .xt_b8q
    mov edx, 0x111                           ; BTN_RIGHT
.xt_b8q:
    cmp r13d, 8
    jne .xt_b9q
    mov edx, 0x113                           ; BTN_SIDE
.xt_b9q:
    cmp r13d, 9
    jne .xt_bset
    mov edx, 0x114                           ; BTN_EXTRA
.xt_bset:
    mov word [rbx + 16], EV_KEY
    mov [rbx + 18], dx
    mov [rbx + 20], ecx
    lea rdi, [rbx]
    call dispatch_input_event
    jmp .xt_out

.xt_motion:
    ; detail 0 = absolute (rootX/rootY are targets), 1 = relative deltas.
    movsx eax, word [r12 + 24]               ; rootX
    movsx edx, word [r12 + 26]               ; rootY
    cmp r13d, 0
    jne .xt_mot_rel
    sub eax, [cursor_x]
    sub edx, [cursor_y]
.xt_mot_rel:
    push rdx
    test eax, eax
    jz  .xt_mot_y
    mov word [rbx + 16], EV_REL
    mov word [rbx + 18], 0                   ; REL_X
    mov [rbx + 20], eax
    lea rdi, [rbx]
    call dispatch_input_event
.xt_mot_y:
    pop rdx
    test edx, edx
    jz  .xt_out
    mov word [rbx + 16], EV_REL
    mov word [rbx + 18], 1                   ; REL_Y
    mov [rbx + 20], edx
    lea rdi, [rbx]
    call dispatch_input_event
.xt_out:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; SHAPE extension — minors: 0 QueryVersion, 1 Rectangles (the one spot uses),
; 5 QueryExtents, 6 SelectInput (no-op), 7 InputSelected, 8 GetRectangles.
; Mask/Combine/Offset (2/3/4) are void and ignored. Regions are stored as
; window-local rect lists in shape_slots; the compositor honours bounding
; regions in blit_window_shaped, the pickers honour input regions via
; shape_input_hit (empty input region = click-through — spot's overlay).
; ============================================================================
handle_shape:
    movzx eax, byte [rsi + 1]
    test eax, eax
    jz .shp_query_version
    cmp eax, 1
    je .shp_rectangles
    cmp eax, 5
    je .shp_query_extents
    cmp eax, 6
    je .shp_done                             ; SelectInput — void, no events yet
    cmp eax, 7
    je .shp_input_selected
    cmp eax, 8
    je .shp_get_rectangles
.shp_done:
    ret

.shp_query_version:
    mov esi, 32
    call xkb_reply_zero                      ; rdi=buf r15d=fd r8d=total
    mov byte [rdi + 1], 0
    mov word [rdi + 8], 1                    ; majorVersion
    mov word [rdi + 10], 1                   ; minorVersion
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.shp_rectangles:
    ; +4 op  +5 kind  +6 ordering  +8 window  +12 xOff s16  +14 yOff s16
    ; +16.. rects (8 bytes each). Length = 4 + 2n words. op treated as Set
    ; (spot re-sends the full list each move).
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi                             ; req
    movzx ebx, byte [rsi + 5]                ; kind
    cmp ebx, 1
    je .shp_r_out                            ; clip region — nothing to clip
    mov r13d, [rsi + 8]                      ; window xid
    movzx ecx, word [rsi + 2]                ; request length (words)
    sub ecx, 4
    shr ecx, 1                               ; rect count
    cmp ecx, SHAPE_MAX_RECTS
    jbe .shp_r_cap
    mov ecx, SHAPE_MAX_RECTS
.shp_r_cap:
    mov r14d, ecx
    mov edi, r13d
    mov esi, ebx
    call shape_slot_get
    test rax, rax
    jz .shp_r_out                            ; table full → ignore
    mov [rax + 8], r14d                      ; count (0 = SET empty region)
    ; Copy rects, applying the request's xOff/yOff to each.
    lea rdi, [rax + 16]
    lea rsi, [r12 + 16]
    movsx r8d, word [r12 + 12]               ; xOff
    movsx r9d, word [r12 + 14]               ; yOff
    mov ecx, r14d
.shp_r_copy:
    test ecx, ecx
    jz .shp_r_copied
    movsx edx, word [rsi]
    add edx, r8d
    mov [rdi], dx                            ; x + xOff
    movsx edx, word [rsi + 2]
    add edx, r9d
    mov [rdi + 2], dx                        ; y + yOff
    mov edx, [rsi + 4]
    mov [rdi + 4], edx                       ; w,h
    add rsi, 8
    add rdi, 8
    dec ecx
    jmp .shp_r_copy
.shp_r_copied:
    ; Damage the whole window — a shrinking shape exposes what's beneath.
    mov edi, r13d
    call window_lookup
    test rax, rax
    jz .shp_r_out
    mov rdi, rax
    movzx ecx, word [rax + 12]               ; w
    movzx r8d, word [rax + 14]               ; h
    xor eax, eax
    xor edx, edx
    call damage_add_local
    mov byte [comp_dirty], 1
.shp_r_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.shp_query_extents:
    push rbx
    push r12
    push r13
    push r14
    mov r14d, edi                            ; client slot
    mov r12d, [rsi + 4]                      ; window xid
    mov edi, r12d
    call window_lookup
    mov r13, rax                             ; window rec (0 ok)
    mov edi, r12d
    xor esi, esi                             ; kind bounding
    call shape_slot_find
    mov rbx, rax                             ; bounding slot (0 ok)
    mov edi, r14d
    mov esi, 32
    call xkb_reply_zero
    xor eax, eax
    test rbx, rbx
    setnz al
    mov [rdi + 1], al                        ; boundingShaped
    mov byte [rdi + 8], 0                    ; clipShaped = False
    test r13, r13
    jz .shp_qe_send
    ; extents = full window rect, window-local (x/y stay 0)
    movzx eax, word [r13 + 12]               ; w
    mov [rdi + 16], ax
    mov [rdi + 24], ax
    movzx eax, word [r13 + 14]               ; h
    mov [rdi + 18], ax
    mov [rdi + 26], ax
.shp_qe_send:
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.shp_input_selected:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0                    ; enabled = False
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.shp_get_rectangles:
    ; Reports the full window rect as one rectangle. Nobody in the app set
    ; reads back the stored list (spot never calls this); answering at all
    ; is what matters — a reply-less request would hang the client.
    push rbx
    push r13
    mov r13d, edi                            ; client slot
    mov edi, [rsi + 4]
    call window_lookup
    mov rbx, rax                             ; window rec (0 ok)
    mov edi, r13d
    mov esi, 40                              ; 32 header + 1 rect
    call xkb_reply_zero                      ; sets length = 2 words
    mov byte [rdi + 1], 0                    ; ordering = UnSorted
    mov dword [rdi + 8], 1                   ; nrects = 1
    test rbx, rbx
    jz .shp_gr_send
    movzx eax, word [rbx + 12]
    mov [rdi + 36], ax                       ; w (x/y stay 0)
    movzx eax, word [rbx + 14]
    mov [rdi + 38], ax                       ; h
.shp_gr_send:
    mov edi, r15d
    lea rsi, [reply_buf]
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    pop r13
    pop rbx
    ret

; ----------------------------------------------------------------------------
; shape_slot_find — edi = xid, esi = kind. rax = slot ptr or 0. Preserves all
; other registers (including edi/esi).
; ----------------------------------------------------------------------------
shape_slot_find:
    push rbx
    xor ebx, ebx
.ssf_loop:
    cmp ebx, SHAPE_MAX_SLOTS
    jge .ssf_miss
    mov rax, rbx
    imul rax, SHAPE_SLOT_SIZE
    lea rax, [shape_slots + rax]
    cmp [rax], edi
    jne .ssf_next
    cmp [rax + 4], esi
    jne .ssf_next
    pop rbx
    ret
.ssf_next:
    inc ebx
    jmp .ssf_loop
.ssf_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; shape_slot_get — edi = xid, esi = kind. Find or allocate. rax = ptr or 0.
; ----------------------------------------------------------------------------
shape_slot_get:
    push rbx
    call shape_slot_find
    test rax, rax
    jnz .ssg_out
    xor ebx, ebx
.ssg_scan:
    cmp ebx, SHAPE_MAX_SLOTS
    jge .ssg_full
    mov rax, rbx
    imul rax, SHAPE_SLOT_SIZE
    lea rax, [shape_slots + rax]
    cmp dword [rax], 0
    je .ssg_take
    inc ebx
    jmp .ssg_scan
.ssg_take:
    mov [rax], edi
    mov [rax + 4], esi
    mov dword [rax + 8], 0
    jmp .ssg_out
.ssg_full:
    xor eax, eax
.ssg_out:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; shape_free_window — edi = xid. Frees all shape slots for the window.
; Preserves all registers.
; ----------------------------------------------------------------------------
shape_free_window:
    push rax
    push rbx
    xor ebx, ebx
.sfw_loop:
    cmp ebx, SHAPE_MAX_SLOTS
    jge .sfw_done
    mov rax, rbx
    imul rax, SHAPE_SLOT_SIZE
    lea rax, [shape_slots + rax]
    cmp [rax], edi
    jne .sfw_next
    mov dword [rax], 0
.sfw_next:
    inc ebx
    jmp .sfw_loop
.sfw_done:
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; shape_input_hit — edi = xid, esi = point x, edx = point y (window-local).
; Returns ZF=1 → window takes the input, ZF=0 → click-through (skip window).
; Preserves ALL registers; only flags change.
; ----------------------------------------------------------------------------
shape_input_hit:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov ebx, esi                             ; px
    mov ecx, edx                             ; py
    mov esi, SHAPE_KIND_INPUT
    call shape_slot_find
    test rax, rax
    jz .sih_hit                              ; no input shape → normal delivery
    mov edx, [rax + 8]                       ; count
    test edx, edx
    jz .sih_miss                             ; SET empty → click-through
    xor esi, esi
.sih_loop:
    cmp esi, edx
    jge .sih_miss
    lea rdi, [rsi*8]
    lea rdi, [rax + rdi + 16]
    movsx r8d, word [rdi]                    ; rx
    cmp ebx, r8d
    jl .sih_next
    movzx r8d, word [rdi + 4]                ; rw
    add r8w, word [rdi]
    movsx r8d, r8w
    cmp ebx, r8d
    jge .sih_next
    movsx r8d, word [rdi + 2]                ; ry
    cmp ecx, r8d
    jl .sih_next
    movzx r8d, word [rdi + 6]                ; rh
    add r8w, word [rdi + 2]
    movsx r8d, r8w
    cmp ecx, r8d
    jge .sih_next
    jmp .sih_hit
.sih_next:
    inc esi
    jmp .sih_loop
.sih_hit:
    mov byte [sih_result], 1
    jmp .sih_out
.sih_miss:
    mov byte [sih_result], 0
.sih_out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    cmp byte [sih_result], 1                 ; ZF=1 → deliver
    ret

; ============================================================================
; handle_xkb — edi = slot, rsi = req. XKB extension, built incrementally.
; minor 0 (XkbUseExtension) is answered (supported, version 1.0). Any other
; minor opcode is logged so the oracle reveals what to implement next.
; ============================================================================
handle_xkb:
    movzx eax, byte [rsi + 1]                ; XKB minor opcode
    test eax, eax                            ; 0 = XkbUseExtension
    jz .xkb_use_ext
    cmp eax, 24                              ; 24 = XkbGetDeviceInfo
    je .xkb_get_device_info
    cmp eax, 8                               ; 8  = XkbGetMap
    je .xkb_get_map
    cmp eax, 6                               ; 6  = XkbGetControls
    je .xkb_get_controls
    cmp eax, 10                              ; 10 = XkbGetCompatMap
    je .xkb_get_compat_map
    cmp eax, 13                              ; 13 = XkbGetIndicatorMap
    je .xkb_get_indicator_map
    cmp eax, 17                              ; 17 = XkbGetNames
    je .xkb_get_names
    cmp eax, 1                               ; 1  = XkbSelectEvents (void, no reply)
    je .xkb_select_events
    cmp eax, 21                              ; 21 = XkbPerClientFlags (GTK blocks on it)
    je .xkb_per_client_flags
    cmp eax, 4                               ; 4  = XkbGetState (GIMP uses it)
    je .xkb_get_state
    ; --- DIAG (temporary): log unhandled XKB minor opcode ---
    push rax
    mov rsi, log_xkb_minor
    mov edx, 10
    call write_stderr
    pop rax
    call write_u64_stderr
    mov rsi, qext_nl
    mov edx, 1
    call write_stderr
    ret

.xkb_select_events:
    ret                                       ; XkbSelectEvents is void — no reply

.xkb_get_state:                               ; idle state: no mods, group 0, no buttons
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 3                      ; deviceID = core keyboard
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.xkb_per_client_flags:
    ; GTK calls XkbSetDetectableAutoRepeat → PerClientFlags and BLOCKS on the
    ; reply. Echo: supported = all per-client flags, value = the bits it set.
    mov r9, [rsi + 8]                         ; change (lo32) | value (hi32)
    push r9
    mov esi, 32
    call xkb_reply_zero                       ; rdi=reply, r15d=fd, r8d=total
    pop r9
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 0x1F                  ; supported (5 per-client flags)
    mov eax, r9d                               ; change mask
    shr r9, 32                                 ; r9d = requested value
    and r9d, eax                               ; value within the change mask
    mov [rdi + 12], r9d                        ; value
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.xkb_get_device_info:
    ; Minimal reply: hand back the core-keyboard device ID (3). xkbcommon's
    ; get_core_keyboard_device_id only reads reply.deviceID. wanted=0 from the
    ; client → no name/buttons/LEDs, so the reply is just its 36-byte header.
    push rbx
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr                    ; rax = client meta
    mov r8d, [rax + 8]                        ; seq
    mov r9d, [rax]                            ; fd
    lea rdi, [reply_buf]
    xor ecx, ecx
    mov [rdi + 0], rcx
    mov [rdi + 8], rcx
    mov [rdi + 16], rcx
    mov [rdi + 24], rcx
    mov [rdi + 32], rcx
    mov byte [rdi + 0], 1                     ; reply
    mov byte [rdi + 1], 3                     ; deviceID = 3 (core keyboard)
    mov [rdi + 2], r8w                        ; seq
    mov dword [rdi + 4], 1                    ; length = 1 (36 bytes total)
    mov edi, r9d                              ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 36
    syscall
    pop rbx
    ret

.xkb_get_map:
    ; Serialize frame's keyboard into an XKB GetMap reply: 40-byte header, then
    ; key types (static blob), then a per-keycode symbol map for 8..255, then
    ; the modifier map. present = KeyTypes|KeySyms|ModifierMap (0x07); actions/
    ; behaviors/vmods/vmodmap omitted. Each real key → 1 group, width 4,
    ; FOUR_LEVEL type, syms [base, shift, AltGr, AltGr+Shift] from keysym_table.
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi                             ; slot
    ; Echo the request's `full` mask as the reply's present, OR'd with the
    ; sections we always write (types|syms|modmap). xkbcommon rejects the map
    ; unless present contains every component it requested; the extras it asks
    ; for (actions/explicit/vmods/vmodmap) are legitimately empty (count 0).
    movzx eax, word [rsi + 6]                ; req full mask
    or  eax, 0x17                            ; types|syms|modmap + KeyActions(0x10):
    mov [xkb_getmap_present], eax            ; the action section is ALWAYS written,
                                             ; so present MUST declare it or libX11's
                                             ; _XkbReadGetMapReply reads modmap at the
                                             ; wrong offset and SIGSEGVs (GIMP crash).

    ; --- key types (copy the 56-byte static blob) ---
    lea rdi, [reply_buf + 40]                ; data follows the 40-byte header
    lea rsi, [xkb_types_blob]
    mov ecx, XKB_TYPES_BYTES
    rep movsb

    ; --- per-keycode symbol maps (KEYCODE_RANGE keys) ---
    xor r10d, r10d                           ; totalSyms
    xor r14d, r14d                           ; keycode index 0..RANGE-1
    lea r9, [keysym_table]
.gm_sym_loop:
    mov eax, [r9 + 0]                        ; base   (level 0)
    mov ecx, [r9 + 4]                        ; shift  (level 1)
    mov edx, [r9 + 16]                       ; AltGr  (level 2)
    mov ebp, [r9 + 20]                       ; AltGr+Shift (level 3)
    ; Type by key shape, like real Xorg: AltGr levels → FOUR_LEVEL;
    ; distinct base/shift → TWO_LEVEL; single sym (modifier keys — often
    ; duplicated across both columns) → ONE_LEVEL. A blanket FOUR_LEVEL
    ; sent lookups on held-modifier state (e.g. Mod5 while typing AltGr
    ; combos) to an empty level: the key read NoSymbol.
    mov r11d, edx
    or  r11d, ebp
    jnz .gm_sym_four
    test ecx, ecx
    jz  .gm_sym_one
    cmp ecx, eax
    jne .gm_sym_two
.gm_sym_one:
    test eax, eax
    jz  .gm_sym_empty
    mov dword [rdi + 0], 0                    ; ktIndex = ONE_LEVEL
    mov byte  [rdi + 4], 1                    ; groupInfo: 1 group
    mov byte  [rdi + 5], 1                    ; width
    mov word  [rdi + 6], 1                    ; nSyms
    mov [rdi + 8], eax
    add rdi, 12
    inc r10d
    jmp .gm_sym_next
.gm_sym_two:
    mov dword [rdi + 0], 1                    ; ktIndex = TWO_LEVEL
    mov byte  [rdi + 4], 1
    mov byte  [rdi + 5], 2                    ; width
    mov word  [rdi + 6], 2                    ; nSyms
    mov [rdi + 8], eax
    mov [rdi + 12], ecx
    add rdi, 16
    add r10d, 2
    jmp .gm_sym_next
.gm_sym_four:
    mov dword [rdi + 0], 3                    ; ktIndex = {3,0,0,0} (FOUR_LEVEL)
    mov byte  [rdi + 4], 1                    ; groupInfo: 1 group
    mov byte  [rdi + 5], 4                    ; width
    mov word  [rdi + 6], 4                    ; nSyms
    mov [rdi + 8], eax
    mov [rdi + 12], ecx
    mov [rdi + 16], edx
    mov [rdi + 20], ebp
    add rdi, 24
    add r10d, 4
    jmp .gm_sym_next
.gm_sym_empty:
    mov dword [rdi + 0], 0                    ; ktIndex 0
    mov dword [rdi + 4], 0                    ; groupInfo 0, width 0, nSyms 0
    add rdi, 8
.gm_sym_next:
    add r9, 24
    inc r14d
    cmp r14d, KEYCODE_RANGE
    jb  .gm_sym_loop

    ; --- key actions: per-key counts, all zero (no actions) ---
    ; Advertised present, so xkbcommon needs firstKeyAction == min_key_code and
    ; one count byte per key in [min,max]. totalActs = 0 → no action structs.
    mov ecx, KEYCODE_RANGE
    xor eax, eax
    rep stosb                                ; KEYCODE_RANGE zero count bytes

    ; --- modifier map (copy 16-byte blob, patch kc108 for Norwegian) ---
    lea rsi, [xkb_modmap_blob]
    mov ecx, XKB_MODMAP_BYTES
    rep movsb
    cmp byte [keymap_is_no], 0
    je  .gm_modmap_done
    mov byte [rdi - 5], 0x80                  ; kc108 mods → Mod5 (AltGr)
.gm_modmap_done:
    mov r12, rdi                             ; end-of-data ptr

    ; --- header (40 bytes) ---
    mov eax, ebx
    call client_meta_addr                    ; rax = meta
    mov r13d, [rax + 8]                       ; seq
    mov r15d, [rax]                           ; fd
    lea rdi, [reply_buf]
    xor ecx, ecx
    mov [rdi + 0], rcx
    mov [rdi + 8], rcx
    mov [rdi + 16], rcx
    mov [rdi + 24], rcx
    mov [rdi + 32], rcx
    mov byte [rdi + 0], 1                     ; reply
    mov byte [rdi + 1], 3                     ; deviceID
    mov [rdi + 2], r13w                       ; seq
    mov rax, r12
    lea rcx, [reply_buf]
    sub rax, rcx                              ; total reply bytes
    mov r8d, eax                              ; (saved for write)
    sub eax, 32
    shr eax, 2
    mov [rdi + 4], eax                        ; length = (total-32)/4
    mov byte [rdi + 10], X_MIN_KEYCODE        ; minKeyCode
    mov byte [rdi + 11], X_MAX_KEYCODE        ; maxKeyCode
    mov eax, [xkb_getmap_present]            ; present (req full | types|syms|modmap)
    mov [rdi + 12], ax
    mov byte [rdi + 15], 4                    ; nTypes
    mov byte [rdi + 16], 4                    ; totalTypes
    mov byte [rdi + 17], X_MIN_KEYCODE        ; firstKeySym
    mov word [rdi + 18], r10w                 ; totalSyms
    mov byte [rdi + 20], KEYCODE_RANGE        ; nKeySyms
    mov byte [rdi + 21], X_MIN_KEYCODE        ; firstKeyAction
    mov byte [rdi + 24], KEYCODE_RANGE        ; nKeyActions (totalActs stays 0)
    mov byte [rdi + 31], 37                   ; firstModMapKey
    mov byte [rdi + 32], 8                    ; nModMapKeys
    mov byte [rdi + 33], 8                    ; totalModMapKeys
    mov edi, r15d                             ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, r8d
    syscall
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

    ; The remaining keymap replies xkbcommon needs are minimal-but-valid: it
    ; reads all five before validating, and the real keyboard data is already
    ; in GetMap. These are mostly-zero fixed replies via xkb_reply_zero.
.xkb_get_controls:
    mov esi, 92                              ; fixed size incl. perKeyRepeat[32]
    call xkb_reply_zero
    mov byte [rdi + 9], 1                    ; numGroups = 1
    jmp .xkb_reply_write
.xkb_get_compat_map:
    mov esi, 32                              ; groups=0, nSI=0 → no body
    call xkb_reply_zero
    jmp .xkb_reply_write
.xkb_get_indicator_map:
    mov esi, 32                              ; which=0, nIndicators=0 → no body
    call xkb_reply_zero
    jmp .xkb_reply_write
.xkb_get_names:
    ; GetNames reply for which=0x1FF5 (what xkbcommon requests). All name atoms
    ; are None(0) — xkbcommon skips GetAtomName for None, so components/types/
    ; levels are unnamed but valid. Key names are REAL + unique ("K008".."K255")
    ; since xkbcommon uses them as key identifiers. Body order (per XKB spec):
    ; keycodes, symbols, types, compat, typeNames(4), KTLevelNames(counts+9),
    ; [indicators/vmods/groups empty], keyNames(248), [aliases empty].
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi                             ; slot
    lea rdi, [reply_buf + 32]                ; body after 32-byte header
    ; keycodes+symbols+types+compat (4) + typeNames (4) = 8 None atoms
    xor eax, eax
    mov ecx, 8
    rep stosd
    ; KTLevelNames: name 0 levels per type (counts all 0, nKTLevels=0). Avoids
    ; the num_levels>=wire check entirely; levels are simply unnamed (optional).
    mov dword [rdi + 0], 0                    ; n_levels_per_type[4] = {0,0,0,0}
    add rdi, 4
    ; (indicatorNames / virtualModNames / groupNames all empty → 0 bytes)
    ; keyNames: one XkbKeyNameRec ("Knnn") per keycode 8..255
    mov r14d, X_MIN_KEYCODE
    mov r12d, KEYCODE_RANGE
.gn_keyname:
    mov byte [rdi], 'K'
    mov eax, r14d
    xor edx, edx
    mov ecx, 100
    div ecx                                  ; al = hundreds
    add al, '0'
    mov [rdi + 1], al
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx                                  ; al = tens, dl = units
    add al, '0'
    mov [rdi + 2], al
    add dl, '0'
    mov [rdi + 3], dl
    add rdi, 4
    inc r14d
    dec r12d
    jnz .gn_keyname
    ; (keyAliases empty)
    mov r12, rdi                             ; end-of-data ptr
    ; --- header (32 bytes) ---
    mov eax, ebx
    call client_meta_addr
    mov r13d, [rax + 8]                       ; seq
    mov r15d, [rax]                           ; fd
    lea rdi, [reply_buf]
    xor ecx, ecx
    mov [rdi + 0], rcx
    mov [rdi + 8], rcx
    mov [rdi + 16], rcx
    mov [rdi + 24], rcx
    mov byte [rdi + 0], 1                     ; reply
    mov byte [rdi + 1], 3                     ; deviceID
    mov [rdi + 2], r13w                       ; seq
    mov rax, r12
    lea rcx, [reply_buf]
    sub rax, rcx                              ; total bytes
    mov r8d, eax
    sub eax, 32
    shr eax, 2
    mov [rdi + 4], eax                        ; length
    mov dword [rdi + 8], 0x1FF5               ; which
    mov byte [rdi + 12], X_MIN_KEYCODE        ; minKeyCode
    mov byte [rdi + 13], X_MAX_KEYCODE        ; maxKeyCode
    mov byte [rdi + 14], 4                    ; nTypes
    mov byte [rdi + 18], X_MIN_KEYCODE        ; firstKey
    mov byte [rdi + 19], KEYCODE_RANGE        ; nKeys
    ; nKTLevels = 0 (no level names) — header already zeroed
    mov edi, r15d                             ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, r8d
    syscall
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.xkb_reply_write:
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

.xkb_use_ext:
    push rbx
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1                    ; reply
    mov byte [rdi + 1], 1                    ; supported = True
    mov ecx, [rax + 8]
    mov [rdi + 2], cx                        ; seq
    mov dword [rdi + 4], 0                   ; reply length 0
    mov word [rdi + 8], 1                    ; serverMajor = 1
    mov word [rdi + 10], 0                   ; serverMinor = 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, [rax]                           ; fd
    push rax
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall
    pop rax
    pop rbx
    ret

; xkb_reply_zero — edi=slot, esi=total bytes. Zeroes reply_buf and writes the
; common reply header (type=1, deviceID=3, seq, length=(total-32)/4). Returns
; rdi=reply_buf, r15d=fd, r8d=total for the caller to patch fields + write.
; (Non-local label: kept outside handle_xkb's local-label scope on purpose.)
xkb_reply_zero:
    push rbx
    mov ebx, edi
    mov r8d, esi
    mov eax, ebx
    call client_meta_addr
    mov r15d, [rax]                          ; fd
    mov r9d, [rax + 8]                        ; seq
    lea rdi, [reply_buf]
    mov ecx, r8d
    add ecx, 7
    shr ecx, 3                               ; qwords to clear
    xor eax, eax
    push rdi
    rep stosq
    pop rdi
    mov byte [rdi + 0], 1                     ; reply
    mov byte [rdi + 1], 3                     ; deviceID
    mov [rdi + 2], r9w                        ; seq
    mov eax, r8d
    sub eax, 32
    shr eax, 2
    mov [rdi + 4], eax                        ; length
    pop rbx
    ret

; ============================================================================
; handle_query_pointer — edi = slot, rsi = req. Reports the cursor position and
; button/modifier state. GTK and Qt issue this during seat setup and BLOCK on
; the reply; an unanswered QueryPointer stalls the client forever before it
; ever maps a window (the cause of "GTK maps nothing on frame").
; ============================================================================
handle_query_pointer:
    mov esi, 32
    call xkb_reply_zero                       ; rdi=reply, r15d=fd, r8d=total
    mov byte [rdi + 1], 1                      ; sameScreen = True
    mov dword [rdi + 8], X_ROOT_WINDOW         ; root
    mov dword [rdi + 12], 0                    ; child = None (no mapped window yet)
    mov eax, [cursor_x]
    mov [rdi + 16], ax                         ; rootX
    mov [rdi + 20], ax                         ; winX (queried window is the root)
    mov eax, [cursor_y]
    mov [rdi + 18], ax                         ; rootY
    mov [rdi + 22], ax                         ; winY
    ; mask (+24) = 0: no buttons / modifiers held
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

; ============================================================================
; window_abs_xy — edi = window xid. Returns r10d = absolute x, r11d = absolute
; y (signed), summing the x/y of every ancestor up to (not incl.) the root.
; ============================================================================
window_abs_xy:
    push rbx
    push r12
    push r13
    xor r12d, r12d                            ; abs x
    xor r13d, r13d                            ; abs y
.wax_loop:
    test edi, edi
    jz .wax_done
    call window_lookup
    test rax, rax
    jz .wax_done
    cmp dword [rax], X_ROOT_WINDOW
    je .wax_done
    movsx ecx, word [rax + 8]
    add r12d, ecx
    movsx ecx, word [rax + 10]
    add r13d, ecx
    mov edi, [rax + 4]                        ; parent xid
    jmp .wax_loop
.wax_done:
    mov r10d, r12d
    mov r11d, r13d
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_translate_coordinates — edi = slot, rsi = req. GTK calls this during
; show (gdk_window_get_origin) and BLOCKS on the reply; without it GTK never
; maps its toplevel, so tile never manages the window (it stays invisible).
; req: +4 src-window  +8 dst-window  +12 src-x (INT16)  +14 src-y (INT16)
; ============================================================================
handle_translate_coordinates:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi                              ; slot
    mov r14, rsi                              ; req
    mov edi, [r14 + 4]                        ; src window
    call window_abs_xy                        ; r10d = abs x, r11d = abs y
    movsx eax, word [r14 + 12]
    add r10d, eax                             ; absolute point x
    movsx eax, word [r14 + 14]
    add r11d, eax                             ; absolute point y
    mov r12d, r10d                            ; save point
    mov r13d, r11d
    mov edi, [r14 + 8]                        ; dst window
    call window_abs_xy
    sub r12d, r10d                            ; dst-x = point - dst.abs
    sub r13d, r11d                            ; dst-y
    mov edi, ebx
    mov esi, 32
    push r12
    push r13
    call xkb_reply_zero                       ; rdi=reply, r15d=fd, r8d=total
    pop r13
    pop r12
    mov byte [rdi + 1], 1                     ; sameScreen = True
    mov dword [rdi + 8], 0                    ; child = None
    mov [rdi + 12], r12w                      ; dst-x
    mov [rdi + 14], r13w                      ; dst-y
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_randr — edi = slot, rsi = req. RANDR: frame models its panel as one
; CRTC + one output + one mode, so toolkits see a real screen (not "fake").
; Reuses xkb_reply_zero for the common header (then overwrites byte[1]).
; ============================================================================
handle_randr:
    movzx eax, byte [rsi + 1]                ; RANDR minor opcode
    cmp eax, 0                               ; QueryVersion
    je .rr_query_version
    cmp eax, 8                               ; GetScreenResources
    je .rr_get_resources
    cmp eax, 25                              ; GetScreenResourcesCurrent
    je .rr_get_resources
    cmp eax, 9                               ; GetOutputInfo
    je .rr_get_output_info
    cmp eax, 20                              ; GetCrtcInfo
    je .rr_get_crtc_info
    cmp eax, 6                               ; GetScreenSizeRange
    je .rr_get_size_range
    cmp eax, 31                              ; GetOutputPrimary
    je .rr_get_output_primary
    cmp eax, 42                              ; GetMonitors — strip calls this DIRECTLY
    je .rr_get_monitors                      ; (ignores the advertised version), so it
                                             ; MUST be answered or strip hangs. Qt won't
                                             ; call it: we advertise 1.4 (< 1.5).
    cmp eax, 15                              ; GetOutputProperty — Qt reads EDID and
    je .rr_get_output_property               ; BLOCKS on the reply (3x per screen)
    cmp eax, 4                               ; RRSelectInput: void, no reply —
    je .rr_select_input                      ; but record the notify window
    cmp eax, 32                              ; GetProviders (RandR 1.4) — Firefox
    je .rr_get_providers                     ; probes GPU providers; empty is fine
    cmp eax, 28                              ; GetPanning — xrandr 1.5 asks per
    je .rr_get_panning                       ; crtc and blocks; zeros = disabled
    cmp eax, 27                              ; GetCrtcTransform — ditto; reply
    je .rr_get_crtc_transform                ; identity matrices, no filters
    cmp eax, 22                              ; GetCrtcGammaSize / GetCrtcGamma —
    je .rr_gamma_zero                        ; size 0 = no gamma ramp; xrandr
    cmp eax, 23                              ; blocks on both
    je .rr_gamma_zero
    cmp eax, 5                               ; GetScreenInfo (RandR 1.0) —
    je .rr_get_screen_info                   ; xrandr --listmonitors blocks on it
    ; Unhandled RANDR minor — log it (each is a potential client hang).
    push rax
    mov rsi, log_rr_minor
    mov edx, 14                              ; string only, not its NUL
    call write_stderr
    pop rax
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov edx, 1
    call write_stderr
.rr_void:
    ret

.rr_select_input:
    ; Record where RRScreenChangeNotify goes on hotplug (mask bit 0).
    mov eax, [rsi + 4]                       ; window
    movzx ecx, word [rsi + 8]                ; enable mask
    test ecx, 1                              ; ScreenChangeNotifyMask
    jnz .rr_si_set
    xor eax, eax
.rr_si_set:
    mov [rr_evwins + rdi*4], eax             ; rdi = client slot
    ret

.rr_get_output_property:
    ; Property-absent reply: type None, 0 items — Qt accepts and moves on.
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0                    ; format 0
    mov dword [rdi + 8], 0                   ; type None
    mov dword [rdi + 12], 0                  ; bytesAfter
    mov dword [rdi + 16], 0                  ; nItems
    jmp .rr_write

.rr_query_version:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 1                    ; majorVersion = 1
    mov dword [rdi + 12], 5                   ; minorVersion = 5 (GetMonitors)
    jmp .rr_write

.rr_get_size_range:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov word [rdi + 8], 320                   ; minWidth
    mov word [rdi + 10], 200                  ; minHeight
    mov word [rdi + 12], 0x4000               ; maxWidth
    mov word [rdi + 14], 0x4000               ; maxHeight
    jmp .rr_write

.rr_get_output_primary:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], RR_OUTPUT_ID         ; output
    jmp .rr_write

.rr_get_screen_info:
    ; xRRGetScreenInfoReply: one size (the whole fb), Rotate_0, 60 Hz.
    mov esi, 44                              ; 32 hdr + 8 size + 4 rate info
    call xkb_reply_zero
    mov byte [rdi + 1], 1                    ; setOfRotations = Rotate_0
    mov dword [rdi + 8], X_ROOT_WINDOW       ; root
    mov dword [rdi + 12], 1                  ; timestamp
    mov dword [rdi + 16], 1                  ; configTimestamp
    mov word [rdi + 20], 1                   ; nSizes
    mov word [rdi + 22], 0                   ; sizeID
    mov word [rdi + 24], 1                   ; rotation = Rotate_0
    mov word [rdi + 26], 60                  ; rate
    mov word [rdi + 28], 2                   ; nrateEnts (count + one rate)
    mov eax, [screen_w]
    mov [rdi + 32], ax                       ; size: widthInPixels
    mov eax, [screen_h]
    mov [rdi + 34], ax                       ; heightInPixels
    mov word [rdi + 36], X_SCREEN_W_MM       ; mmWidth
    mov word [rdi + 38], X_SCREEN_H_MM       ; mmHeight
    mov word [rdi + 40], 1                   ; nRates for size 0
    mov word [rdi + 42], 60                  ; the rate
    jmp .rr_write

.rr_gamma_zero:
    mov esi, 32                              ; size@8 stays 0, no ramp data
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    jmp .rr_write

.rr_get_crtc_transform:
    ; xRRGetCrtcTransformReply: 96 bytes. Both transforms = identity
    ; (fixed-point 1.0 on the diagonal), no filters.
    mov esi, 96
    call xkb_reply_zero
    mov byte [rdi + 1], 0                    ; status
    mov dword [rdi + 8],  0x10000            ; pendingTransform m11
    mov dword [rdi + 24], 0x10000            ; m22
    mov dword [rdi + 40], 0x10000            ; m33
    mov byte  [rdi + 44], 0                  ; hasTransforms = False
    mov dword [rdi + 48], 0x10000            ; currentTransform m11
    mov dword [rdi + 64], 0x10000            ; m22
    mov dword [rdi + 80], 0x10000            ; m33
    jmp .rr_write

.rr_get_panning:
    mov esi, 36                              ; xRRGetPanningReply (length = 1)
    call xkb_reply_zero
    mov byte [rdi + 1], 0                    ; status = Success
    mov dword [rdi + 8], 1                   ; timestamp
    jmp .rr_write

.rr_get_providers:
    ; RRGetProviders reply: +8 timestamp, +12 nProviders (u16 = 0). frame has
    ; no GPU-offload providers, so an empty list is correct. Firefox's
    ; glxtest queries this; it soft-fails to software rendering either way.
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 1                    ; timestamp
    mov word [rdi + 12], 0                    ; nProviders
    jmp .rr_write

.rr_get_resources:
    cmp byte [ext_active], 0
    jne .rr_res_dual
    mov esi, 80                              ; 32 header + 48 body (1 crtc/out/mode)
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 1                    ; timestamp
    mov dword [rdi + 12], 1                   ; configTimestamp
    mov word [rdi + 16], 1                    ; nCrtcs
    mov word [rdi + 18], 1                    ; nOutputs
    mov word [rdi + 20], 1                    ; nModes
    mov word [rdi + 22], 7                    ; nbytesNames ("default")
    mov dword [rdi + 32], RR_CRTC_ID          ; crtcs[0]
    mov dword [rdi + 36], RR_OUTPUT_ID        ; outputs[0]
    mov dword [rdi + 40], RR_MODE_ID          ; modeInfo.id
    mov eax, [panel_w]
    mov [rdi + 44], ax                        ; modeInfo.width
    mov eax, [panel_h]
    mov [rdi + 46], ax                        ; modeInfo.height
    mov dword [rdi + 48], 148500000           ; dotClock
    mov word [rdi + 56], 2200                 ; hTotal  (refresh ≈ 60)
    mov word [rdi + 64], 1125                 ; vTotal
    mov word [rdi + 66], 7                    ; modeInfo.nameLength
    mov dword [rdi + 72], 'defa'              ; names block: "default"
    mov word [rdi + 76], 'ul'
    mov byte [rdi + 78], 't'
    jmp .rr_write
.rr_res_dual:
    ; 32 hdr + crtcs 2×4 + outputs 2×4 + modes 2×32 + names 7+3 → 122, pad 124
    mov esi, 124
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 1                    ; timestamp
    mov dword [rdi + 12], 1                   ; configTimestamp
    mov word [rdi + 16], 2                    ; nCrtcs
    mov word [rdi + 18], 2                    ; nOutputs
    mov word [rdi + 20], 2                    ; nModes
    mov word [rdi + 22], 10                   ; nbytesNames
    mov dword [rdi + 32], RR_CRTC_ID          ; crtcs
    mov dword [rdi + 36], RR_CRTC_ID + 1
    mov dword [rdi + 40], RR_OUTPUT_ID        ; outputs
    mov dword [rdi + 44], RR_OUTPUT_ID + 1
    mov dword [rdi + 48], RR_MODE_ID          ; mode 1 @48..79
    mov eax, [panel_w]
    mov [rdi + 52], ax
    mov eax, [panel_h]
    mov [rdi + 54], ax
    mov dword [rdi + 56], 148500000
    mov word [rdi + 64], 2200
    mov word [rdi + 72], 1125
    mov word [rdi + 74], 7                    ; nameLength "default"
    mov dword [rdi + 80], RR_MODE_ID + 1      ; mode 2 @80..111
    mov eax, [ext_w]
    mov [rdi + 84], ax
    mov eax, [ext_h]
    mov [rdi + 86], ax
    mov dword [rdi + 88], 148500000
    mov word [rdi + 96], 2200
    mov word [rdi + 104], 1125
    mov word [rdi + 106], 3                   ; nameLength "ext"
    mov dword [rdi + 112], 'defa'             ; names: "default" + "ext"
    mov word [rdi + 116], 'ul'
    mov byte [rdi + 118], 't'
    mov word [rdi + 119], 'ex'
    mov byte [rdi + 121], 't'
    jmp .rr_write

.rr_get_output_info:
    mov eax, [rsi + 4]                       ; requested output id
    cmp eax, RR_OUTPUT_ID + 1
    jne .rr_oi_one
    cmp byte [ext_active], 0
    je .rr_oi_one
    ; output 2 (external)
    mov esi, 48                              ; 36 header + 8 body + "ext" pad
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 1                    ; timestamp
    mov dword [rdi + 12], RR_CRTC_ID + 1      ; crtc
    mov word [rdi + 26], 1                    ; nCrtcs (mm unknown = 0)
    mov word [rdi + 28], 1                    ; nModes
    mov word [rdi + 30], 1                    ; nPreferred
    mov word [rdi + 34], 3                    ; nameLength
    mov dword [rdi + 36], RR_CRTC_ID + 1      ; crtcs[0]
    mov dword [rdi + 40], RR_MODE_ID + 1      ; modes[0]
    mov word [rdi + 44], 'ex'                 ; name "ext"
    mov byte [rdi + 46], 't'
    jmp .rr_write
.rr_oi_one:
    mov esi, 52                              ; 36 header + 16 body
    call xkb_reply_zero
    mov byte [rdi + 1], 0                     ; status = Success
    mov dword [rdi + 8], 1                    ; timestamp
    mov dword [rdi + 12], RR_CRTC_ID          ; crtc
    mov dword [rdi + 16], X_SCREEN_W_MM       ; mmWidth
    mov dword [rdi + 20], X_SCREEN_H_MM       ; mmHeight
    mov word [rdi + 26], 1                    ; nCrtcs (connection=Connected at +24)
    mov word [rdi + 28], 1                    ; nModes
    mov word [rdi + 30], 1                    ; nPreferred
    mov word [rdi + 34], 7                    ; nameLength
    mov dword [rdi + 36], RR_CRTC_ID          ; crtcs[0]
    mov dword [rdi + 40], RR_MODE_ID          ; modes[0]
    mov dword [rdi + 44], 'defa'              ; name "default"
    mov word [rdi + 48], 'ul'
    mov byte [rdi + 50], 't'
    jmp .rr_write

.rr_get_crtc_info:
    mov eax, [rsi + 4]                       ; requested crtc id
    cmp eax, RR_CRTC_ID + 1
    jne .rr_ci_one
    cmp byte [ext_active], 0
    je .rr_ci_one
    mov esi, 40                              ; crtc 2: external's fb slice
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], 1                    ; timestamp
    mov eax, [ext_x]
    mov [rdi + 12], ax                        ; x
    mov eax, [ext_w]
    mov [rdi + 16], ax                        ; width  (y at +14 stays 0)
    mov eax, [ext_h]
    mov [rdi + 18], ax                        ; height
    mov dword [rdi + 20], RR_MODE_ID + 1      ; mode
    mov word [rdi + 24], 1                    ; rotation
    mov word [rdi + 26], 1                    ; rotations
    mov word [rdi + 28], 1                    ; nOutput
    mov word [rdi + 30], 1                    ; nPossibleOutput
    mov dword [rdi + 32], RR_OUTPUT_ID + 1
    mov dword [rdi + 36], RR_OUTPUT_ID + 1
    jmp .rr_write
.rr_ci_one:
    mov esi, 40                              ; 32 header + 8 body
    call xkb_reply_zero
    mov byte [rdi + 1], 0                     ; status
    mov dword [rdi + 8], 1                    ; timestamp (x=0,y=0 at +12,+14)
    mov eax, [panel_w]
    mov [rdi + 16], ax                        ; width
    mov eax, [panel_h]
    mov [rdi + 18], ax                        ; height
    mov dword [rdi + 20], RR_MODE_ID          ; mode
    mov word [rdi + 24], 1                    ; rotation = Rotate_0
    mov word [rdi + 26], 1                    ; rotations
    mov word [rdi + 28], 1                    ; nOutput
    mov word [rdi + 30], 1                    ; nPossibleOutput
    mov dword [rdi + 32], RR_OUTPUT_ID        ; outputs[0]
    mov dword [rdi + 36], RR_OUTPUT_ID        ; possibleOutputs[0]
    jmp .rr_write

.rr_get_monitors:
    ; xRRGetMonitorsReply: 32-byte header + MONITORINFO (24) + 1 output (4)
    ; per monitor. Monitor 1 = the panel at fb (0,0); monitor 2 = the
    ; external at fb (ext_x, 0). tile pins WS10 to monitor 2 from this.
    mov esi, 60
    cmp byte [ext_active], 0
    je .rr_gm_sized
    mov esi, 88
.rr_gm_sized:
    call xkb_reply_zero
    mov byte  [rdi + 1], 0
    mov dword [rdi + 8],  1                   ; timestamp
    movzx eax, byte [ext_active]
    inc eax
    mov [rdi + 12], eax                       ; nmonitors
    mov [rdi + 16], eax                       ; noutputs (total)
    ; resolve the monitor-name atom ("default"); save rdi/r8/r15 across the call
    push rdi
    push r8
    push r15
    lea rdi, [str_monitor_default]
    mov esi, 7
    call atom_lookup
    pop r15
    pop r8
    pop rdi
    mov [rdi + 32], eax                       ; MONITORINFO.name (atom)
    mov byte [rdi + 36], 1                    ; primary  = True
    mov byte [rdi + 37], 1                    ; automatic = True
    mov word [rdi + 38], 1                    ; noutput  = 1
    ; x, y at +40/+42 stay 0
    mov eax, [panel_w]
    mov [rdi + 44], ax                        ; width  (pixels)
    mov eax, [panel_h]
    mov [rdi + 46], ax                        ; height (pixels)
    mov dword [rdi + 48], X_SCREEN_W_MM       ; widthInMillimeters
    mov dword [rdi + 52], X_SCREEN_H_MM       ; heightInMillimeters
    mov dword [rdi + 56], RR_OUTPUT_ID        ; outputs[0]
    cmp byte [ext_active], 0
    je .rr_write
    ; monitor 2 @60..87
    push rdi
    push r8
    push r15
    lea rdi, [str_monitor_ext]
    mov esi, 3
    call atom_lookup
    pop r15
    pop r8
    pop rdi
    mov [rdi + 60], eax                       ; name atom "ext"
    mov byte [rdi + 64], 0                    ; primary = False
    mov byte [rdi + 65], 1                    ; automatic
    mov word [rdi + 66], 1                    ; noutput
    mov eax, [ext_x]
    mov [rdi + 68], ax                        ; x  (y at +70 stays 0)
    mov eax, [ext_w]
    mov [rdi + 72], ax                        ; width
    mov eax, [ext_h]
    mov [rdi + 74], ax                        ; height
    ; mm at +76/+80 stay 0 (unknown)
    mov dword [rdi + 84], RR_OUTPUT_ID + 1    ; outputs[0]
    jmp .rr_write

.rr_write:
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

; ----------------------------------------------------------------------------
; rr_emit_screen_change — RRScreenChangeNotify to every client that did
; RRSelectInput (rr_evwins). Hotplug calls this after reconfiguring; tile
; rediscovers outputs and retiles on receipt.
; ----------------------------------------------------------------------------
rr_emit_screen_change:
    push rbx
    push r12
    xor ebx, ebx
.esc_loop:
    cmp ebx, MAX_CLIENTS
    jge .esc_done
    mov r12d, [rr_evwins + rbx*4]
    test r12d, r12d
    jz .esc_next
    mov eax, ebx
    call client_meta_addr
    cmp dword [rax], -1                      ; fd live?
    je .esc_next
    lea rdi, [pn_buf]
    xor eax, eax
    mov [rdi + 0], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], RR_EVENT_BASE        ; ScreenChangeNotify
    mov byte [rdi + 1], 1                    ; rotation = Rotate_0
    mov eax, [server_time_ms]
    mov [rdi + 4], eax                       ; timestamp
    mov [rdi + 8], eax                       ; configTimestamp
    mov dword [rdi + 12], X_ROOT_WINDOW      ; root
    mov [rdi + 16], r12d                     ; the subscribing window
    mov eax, [screen_w]
    mov [rdi + 24], ax                       ; widthInPixels
    mov eax, [screen_h]
    mov [rdi + 26], ax                       ; heightInPixels
    mov word [rdi + 28], X_SCREEN_W_MM       ; widthInMM
    mov word [rdi + 30], X_SCREEN_H_MM       ; heightInMM
    mov edi, ebx
    lea rsi, [pn_buf]
    call send_event_to_slot
.esc_next:
    inc ebx
    jmp .esc_loop
.esc_done:
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_xinput — edi = slot, rsi = req. XInput2 (required by GTK4). Built
; incrementally: XIQueryVersion answered; other minors logged.
; ============================================================================
handle_xinput:
    movzx eax, byte [rsi + 1]                ; XI minor opcode
    cmp eax, 1                               ; X_GetExtensionVersion (XI1 probe)
    je .xi_get_ext_version
    cmp eax, 2                               ; XI1 ListInputDevices
    je .xi_list_devices
    cmp eax, 47                              ; XIQueryVersion (XI2)
    je .xi_query_version
    cmp eax, 48                              ; XIQueryDevice
    je .xi_query_device
    cmp eax, 46                              ; XISelectEvents
    je .xi_select_events
    cmp eax, 51                              ; XIGrabDevice (GTK menus)
    je .xi_grab_device
    cmp eax, 52                              ; XIUngrabDevice
    je .xi_ungrab_device
    cmp eax, 49                              ; XISetFocus (void-ish, no reply)
    je .xi_noop
    cmp eax, 50                              ; XIGetFocus
    je .xi_get_focus
    cmp eax, 53                              ; XIAllowEvents (no reply)
    je .xi_noop
    cmp eax, 56                              ; XIListProperties → empty
    je .xi_empty_reply
    cmp eax, 59                              ; XIGetProperty → empty (type=None)
    je .xi_empty_reply
    cmp eax, 45                              ; XIGetClientPointer (GTK4 blocks on it)
    je .xi_get_client_pointer
    cmp eax, 40                              ; XIQueryPointer (GIMP blocks on it)
    je .xi_query_pointer
    ; --- DIAG (temp): log unhandled XI minor opcode ---
    push rax
    mov rsi, log_xi_minor
    mov edx, 9
    call write_stderr
    pop rax
    call write_u64_stderr
    mov rsi, qext_nl
    mov edx, 1
    call write_stderr
    ret

.xi_get_ext_version:
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov word [rdi + 8], 2                     ; major_version = 2
    mov word [rdi + 10], 0                    ; minor_version = 0
    mov byte [rdi + 12], 1                    ; present = True
    jmp .xi_write

.xi_select_events:
    ; XISelectEvents (46, void): +4 window, +8 num_masks u16, then per entry
    ; deviceid(2) mask_len(2) mask words. frame keeps ONE XI mask per window
    ; (union over devices/calls) in record +52; evtypes 0..31 fit word 0.
    ; This is how GTK/GDK subscribe to input — delivery checks it first.
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rsi
    mov edi, [rbx + 4]
    call window_lookup
    test rax, rax
    jz .xise_done
    mov r13, rax
    ; Request end from the length field — the walk MUST NOT trust num_masks /
    ; mask_len past this (a malformed request could otherwise march rsi off
    ; the client buffer → SIGSEGV, or OR the next request's bytes into +52).
    movzx r14d, word [rbx + 2]
    lea r14, [rbx + r14*4]                    ; reqend
    ; Replace semantics: this request's union REPLACES the window's XI2 mask
    ; (so mask_len=0 deselects; X11 is replace-per-window, not accumulate).
    mov dword [r13 + 52], 0
    movzx r12d, word [rbx + 8]               ; num_masks
    lea rsi, [rbx + 12]
.xise_entry:
    test r12d, r12d
    jz .xise_done
    lea rax, [rsi + 4]
    cmp rax, r14                              ; header word in bounds?
    ja .xise_done
    movzx ecx, word [rsi + 2]                ; mask_len (words)
    test ecx, ecx
    jz .xise_next
    lea rax, [rsi + 4 + rcx*4]
    cmp rax, r14                              ; mask body in bounds?
    ja .xise_done
    mov eax, [rsi + 4]                       ; mask word 0
    or [r13 + 52], eax
.xise_next:
    lea rsi, [rsi + 4 + rcx*4]
    dec r12d
    jmp .xise_entry
.xise_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.xi_grab_device:
    ; XIGrabDevice (51): +4 window, +8 time, +12 cursor, +16 deviceid u16,
    ; +18 mode, +19 paired-mode, +20 owner-events, +22 mask_len. Maps onto
    ; the core grab state; the xi2 flag makes grab deliveries GenericEvents.
    ; deviceid 2 / 1 (AllMaster) / 0 (All) grabs the pointer; 3 the keyboard.
    push rbx
    push r12
    mov ebx, edi
    mov r12, rsi
    movzx eax, word [r12 + 16]               ; deviceid
    cmp eax, 3
    je .xgd_kbd
    mov ecx, [r12 + 4]
    mov [ptr_grab_win], ecx
    mov [ptr_grab_slot], ebx
    mov dword [ptr_grab_mask], 0xFFFF        ; grab wants everything
    mov byte [ptr_grab_xi2], 1
    mov byte [ptr_grab_owner], 1             ; XI2 grabs keep the deep pick
                                             ; (GTK menu-item selection)
    mov eax, [r12 + 12]                      ; XIGrabDevice cursor field
    mov [ptr_grab_cursor], eax
    call cursor_sync
    movzx eax, word [r12 + 16]               ; re-derive deviceid (clobbered)
    cmp eax, 2
    jbe .xgd_maybe_both                      ; 0/1 = all devices → kbd too
    jmp .xgd_reply
.xgd_maybe_both:
    cmp eax, 2
    je .xgd_reply                            ; exactly the pointer → done
.xgd_kbd:
    mov ecx, [r12 + 4]
    mov [active_kbd_window], ecx
    mov [active_kbd_slot], ebx
    mov byte [kbd_grab_xi2], 1
.xgd_reply:
    mov edi, ebx
    pop r12                                  ; balance BEFORE the shared tail —
    pop rbx                                  ; .xi_write rets directly
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0                    ; status = Success (deviceID slot
    jmp .xi_write                            ; doubles as status here)

.xi_ungrab_device:
    ; XIUngrabDevice (52, void): header(4) + time@4 + deviceid u16 @8 + pad@10.
    ; deviceid is at +8, NOT +12 (that read the next batched request's opcode
    ; and cleared the wrong grab). Only release a grab this client actually
    ; holds — a stray ungrab must not free another client's (or a core) grab.
    movzx eax, word [rsi + 8]
    cmp eax, 3
    je .xud_kbd
    cmp [ptr_grab_slot], edi                 ; we own the pointer grab?
    jne .xud_chk_kbd
    mov dword [ptr_grab_win], 0
    mov dword [ptr_grab_cursor], 0
    mov byte [ptr_grab_xi2], 0
    push rax
    push rdi
    call cursor_sync
    pop rdi
    pop rax
.xud_chk_kbd:
    cmp eax, 2
    jae .xud_done                            ; 2 = pointer only
.xud_kbd:
    cmp [active_kbd_slot], edi               ; we own the keyboard grab?
    jne .xud_done
    mov dword [active_kbd_slot], -1
    mov dword [active_kbd_window], 0
    mov byte [kbd_grab_xi2], 0
.xud_done:
    ret

.xi_get_focus:
    ; XIGetFocus (50): reply the core focus window.
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov eax, [focus_window]
    cmp eax, 1
    jbe .xgf_none
    mov [rdi + 8], eax
    jmp .xi_write
.xgf_none:
    mov dword [rdi + 8], 0
    jmp .xi_write

.xi_list_devices:
    ; GTK2 calls XListInputDevices in gdk_input_init and BLOCKS on the reply
    ; (fortitray's invisible hang). The reply must carry the TWO core devices:
    ; ndevices=0 + length=0 CHECK-crashes Chromium (its parser has a fixed
    ; 1-byte pad + align-4 after the lists, so it demands length >= 1), while
    ; ndevices=0 + length=1 aborts libXi (it skips the payload read when
    ; ndevices==0, and xcb asserts on the 4 leftover bytes). With ndevices=2
    ; both walk the same 60-byte payload: 2 DeviceInfo (no classes) + 2 STR
    ; names + pad. GTK2 skips core devices, so behavior is unchanged there.
    mov esi, 92                               ; 32 + 60 → length = 15
    call xkb_reply_zero
    mov byte [rdi + 1], 2                     ; xi_reply_type = ListInputDevices
    mov byte [rdi + 8], 2                     ; ndevices
    push rsi
    lea rsi, [xi1_core_devs]
    lea rdi, [reply_buf + 32]
    mov ecx, 60
    rep movsb
    pop rsi
    jmp .xi_write

.xi_get_client_pointer:                       ; reply: a client pointer IS set
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    mov byte [rdi + 8], 1                     ; set = True
    mov word [rdi + 10], 2                    ; deviceid = master pointer (2)
    jmp .xi_write

.xi_query_pointer:                            ; XI2 form of QueryPointer (56-byte reply)
    push rbx
    push r13
    push r14
    mov ebx, edi                              ; slot
    mov edi, [rsi + 4]                        ; queried window
    call window_abs_xy                        ; r10d=abs x, r11d=abs y
    mov r13d, [cursor_x]
    sub r13d, r10d                            ; win_x (pixels)
    mov r14d, [cursor_y]
    sub r14d, r11d                            ; win_y (pixels)
    mov edi, ebx
    mov esi, 56
    push r13
    push r14
    call xkb_reply_zero                       ; rdi=reply, r15d=fd, r8d=total
    pop r14
    pop r13
    mov byte [rdi + 1], 0
    mov dword [rdi + 8], X_ROOT_WINDOW         ; root
    mov dword [rdi + 12], 0                    ; child = None
    mov eax, [cursor_x]
    shl eax, 16
    mov [rdi + 16], eax                        ; root_x (FP1616)
    mov eax, [cursor_y]
    shl eax, 16
    mov [rdi + 20], eax                        ; root_y
    mov eax, r13d
    shl eax, 16
    mov [rdi + 24], eax                        ; win_x
    mov eax, r14d
    shl eax, 16
    mov [rdi + 28], eax                        ; win_y
    mov word [rdi + 32], 1                     ; same_screen = True
    mov word [rdi + 34], 0                     ; buttons_len = 0
    ; mods (+36..52) + group (+52..56) left zero
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    pop r14
    pop r13
    pop rbx
    ret

.xi_query_version:
    movzx r13d, word [rsi + 6]                ; client minor (req +4 major, +6 minor)
    mov esi, 32                               ; — read BEFORE this clobbers rsi
    call xkb_reply_zero                       ; rdi=reply_buf, r15d=fd, r8d=total
    mov byte [rdi + 1], 0                     ; RepType (override XKB deviceID)
    mov word [rdi + 8], 2                     ; major_version = 2
    mov word [rdi + 10], 2                    ; minor: min(client, 2) per spec
    cmp r13d, 2
    jae .xqv_minor                            ; client >= 2.2 → cap at 2
    mov [rdi + 10], r13w                       ; else echo the client's minor
.xqv_minor:
    jmp .xi_write

.xi_noop:                                     ; void requests (XISelectEvents)
    ret

.xi_empty_reply:                              ; ListProperties=0 / GetProperty=None
    mov esi, 32
    call xkb_reply_zero
    mov byte [rdi + 1], 0
    ; all-zero body = 0 properties / type None, 0 items
    ; fall through

.xi_write:
    lea rsi, [reply_buf]
    mov edi, r15d
    mov edx, r8d
    mov eax, SYS_WRITE
    syscall
    ret

; XIQueryDevice — enumerate two master devices so GTK4/Qt see input. Master
; pointer (id 2): button class (7 buttons) + 2 valuator classes (x,y absolute).
; Master keyboard (id 3): key class listing keycodes 8..255. Layout offsets are
; fixed; total 1228 bytes. r12 holds the reply base.
.xi_query_device:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    ; Resolve the pointer axis-label atoms (GTK ignores axes with a None label).
    lea rdi, [str_rel_x]
    mov esi, 5
    call atom_lookup
    mov r13d, eax                             ; "Rel X" atom
    lea rdi, [str_rel_y]
    mov esi, 5
    call atom_lookup
    mov r14d, eax                             ; "Rel Y" atom
    mov edi, ebx
    mov esi, 1228
    call xkb_reply_zero                       ; zeroes, header (type/seq/length=299)
    mov r12, rdi                              ; reply base
    mov byte [r12 + 1], 0                     ; RepType
    mov word [r12 + 8], 2                     ; num_devices

    ; --- Device 1: master pointer (id 2) at +32 ---
    mov word [r12 + 32], 2                    ; deviceid
    mov word [r12 + 34], 1                    ; use = MasterPointer
    mov word [r12 + 36], 3                    ; attachment = keyboard
    mov word [r12 + 38], 3                    ; num_classes
    mov word [r12 + 40], 20                   ; name_len
    mov byte [r12 + 42], 1                    ; enabled
    lea rdi, [r12 + 44]                        ; name
    lea rsi, [str_xi_pointer]
    mov ecx, 20
    rep movsb
    ; ButtonClass at +64 (8 hdr + 4 state + 28 labels = 40, length 10)
    mov word [r12 + 64], 1                    ; type = ButtonClass
    mov word [r12 + 66], 10                   ; length
    mov word [r12 + 68], 2                    ; sourceid
    mov word [r12 + 70], 7                    ; num_buttons
    ; ValuatorClass x at +104 — "Rel X", relative (min/max/value/mode all 0)
    mov word [r12 + 104], 2                   ; type = ValuatorClass
    mov word [r12 + 106], 11                  ; length
    mov word [r12 + 108], 2                   ; sourceid
    mov word [r12 + 110], 0                   ; number = 0 (x)
    mov [r12 + 112], r13d                     ; label = "Rel X" atom
    ; ValuatorClass y at +148 — "Rel Y"
    mov word [r12 + 148], 2                   ; type
    mov word [r12 + 150], 11                  ; length
    mov word [r12 + 152], 2                   ; sourceid
    mov word [r12 + 154], 1                   ; number = 1 (y)
    mov [r12 + 156], r14d                     ; label = "Rel Y" atom

    ; --- Device 2: master keyboard (id 3) at +192 ---
    mov word [r12 + 192], 3                   ; deviceid
    mov word [r12 + 194], 2                   ; use = MasterKeyboard
    mov word [r12 + 196], 2                   ; attachment = pointer
    mov word [r12 + 198], 1                   ; num_classes
    mov word [r12 + 200], 21                  ; name_len
    mov byte [r12 + 202], 1                   ; enabled
    lea rdi, [r12 + 204]                       ; name
    lea rsi, [str_xi_keyboard]
    mov ecx, 21
    rep movsb
    ; KeyClass at +228 (8 hdr + 248*4 keycodes = 1000, length 250)
    mov word [r12 + 228], 0                   ; type = KeyClass
    mov word [r12 + 230], 250                 ; length
    mov word [r12 + 232], 3                   ; sourceid
    mov word [r12 + 234], KEYCODE_RANGE       ; num_keycodes = 248
    lea rdi, [r12 + 236]
    mov eax, X_MIN_KEYCODE
.xiqd_kc:
    mov [rdi], eax                            ; keycode
    add rdi, 4
    inc eax
    cmp eax, X_MAX_KEYCODE + 1                ; 256 → writes 8..255 (248 keys)
    jb .xiqd_kc

    mov edi, r15d                             ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, r8d
    syscall
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_property — edi = slot, rsi = request ptr. Looks up the
; (window, property) pair in the property table; returns the full value
; (long-offset / long-length ignored for now — every GetProperty either
; "succeeds with the entire stored value" or "doesn't exist"). Common
; case for WM/client property reads.
;
; Request:
;   +0 opcode (20)        +1 delete (BOOL)
;   +2 length             +4 window
;   +8 property (atom)    +12 type
;   +16 long-offset       +20 long-length
;
; Reply (32 + nbytes + pad):
;   +0 1                  +1 format
;   +2 seq                +4 reply length = ceil(nbytes / 4)
;   +8 type               +12 bytes-after (0)
;   +16 length-of-value (in format-units)
;   +20..31 pad
;   +32..32+n value
;   +32+n.. pad to 4-byte boundary
; ============================================================================
handle_get_property:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r14, rsi                             ; req ptr
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    mov edi, [r14 + 4]                       ; window
    mov esi, [r14 + 8]                       ; property atom
    call property_find
    test rax, rax
    jz .gp_none
    mov r13, rax                             ; record ptr

    ; ---- found: emit value reply ----
    movzx r9d, byte [r13 + 12]               ; format (8/16/32)
    mov r8d, [r13 + 16]                      ; nbytes
    mov ecx, r8d
    add ecx, 3
    shr ecx, 2                               ; reply length in 4u
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov [rdi + 1], r9b                       ; format
    mov edx, [r12 + 8]
    mov [rdi + 2], dx                        ; seq
    mov [rdi + 4], ecx
    mov eax, [r13 + 8]
    mov [rdi + 8], eax                       ; type
    mov dword [rdi + 12], 0                  ; bytes-after = 0
    ; length in format-units
    mov eax, r8d
    cmp r9d, 16
    je .gp_units16
    cmp r9d, 32
    je .gp_units32
    jmp .gp_units_set
.gp_units16:
    shr eax, 1
    jmp .gp_units_set
.gp_units32:
    shr eax, 2
.gp_units_set:
    mov [rdi + 16], eax
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; Copy the value into reply_buf + 32.
    mov eax, [r13 + 20]                      ; value offset in pool
    lea rsi, [property_values + rax]
    lea rdi, [reply_buf + 32]
    mov ecx, r8d                             ; nbytes
    rep movsb

    ; Pad to 4-byte boundary.
    mov ecx, r8d
    add ecx, 3
    and ecx, ~3
    mov r10d, ecx                            ; padded body bytes
    sub ecx, r8d
    xor eax, eax
    rep stosb

    ; Write header + padded body.
    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, r10d
    add edx, 32
    syscall

    ; Delete-on-read?
    cmp byte [r14 + 1], 0
    je .gp_done
    mov edi, [r13]                           ; window (grab before zeroing)
    mov esi, [r13 + 4]                       ; atom
    mov dword [r13], 0                       ; xid = 0 → empty
    mov edx, 1                               ; state = Deleted — same notify
    call send_property_notify                ; DeleteProperty sends
    jmp .gp_done

.gp_none:
    ; Not found — 32-byte "doesn't exist" reply.
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; format = 0
    mov edx, [r12 + 8]
    mov [rdi + 2], dx
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0                   ; type = None
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

.gp_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_geometry — edi = slot, rsi = request ptr. Real per-window
; geometry from the window table. Falls back to root for unknown XIDs.
;
; Request: +4 drawable (WINDOW)
;
; Reply (32 bytes):
;   +0 1 (Reply)          +1 depth (CARD8)
;   +2 seq                +4 reply length (= 0)
;   +8 root (WINDOW)      +12 x (INT16)
;   +14 y (INT16)         +16 width (CARD16)
;   +18 height (CARD16)   +20 border-width (CARD16)
;   +22..31 pad
; ============================================================================
handle_get_geometry:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r13, rsi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    mov edi, [r13 + 4]                       ; drawable xid
    call window_lookup
    test rax, rax
    jnz .gg_have
    ; Unknown XID — pretend it's the root. Real X servers would send a
    ; Drawable error; phase 4b stays permissive so partial clients work.
    xor eax, eax
    mov edi, X_ROOT_WINDOW
    call window_lookup
.gg_have:
    mov r13, rax                             ; window record ptr

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    movzx eax, byte [r13 + 18]
    mov [rdi + 1], al                        ; depth
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], X_ROOT_WINDOW
    mov ax, [r13 + 8]
    mov [rdi + 12], ax                       ; x
    mov ax, [r13 + 10]
    mov [rdi + 14], ax                       ; y
    mov ax, [r13 + 12]
    mov [rdi + 16], ax                       ; width
    mov ax, [r13 + 14]
    mov [rdi + 18], ax                       ; height
    mov ax, [r13 + 16]
    mov [rdi + 20], ax                       ; border
    mov word [rdi + 22], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_query_tree — edi = slot. Walks the window table for the request's
; window: returns parent + all windows whose parent matches.
;
; Request: +4 window (WINDOW)
;
; Reply (32 + 4N bytes where N = num children):
;   +0 1                  +1 0
;   +2 seq                +4 reply length N
;   +8 root               +12 parent
;   +16 num-children u16  +18 pad
;   +20..31 pad           +32..32+4N children
; ============================================================================
handle_query_tree:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    mov eax, ebx
    call client_buf_addr
    mov r13, rax                             ; request ptr
    mov edi, [r13 + 4]                       ; window xid
    call window_lookup
    test rax, rax
    jnz .qt_have
    ; Unknown — treat as root (forgive bad XIDs in phase 4b).
    xor eax, eax
    mov edi, X_ROOT_WINDOW
    call window_lookup
.qt_have:
    mov r13, rax                             ; window record
    mov r14d, [r13]                          ; target xid

    ; Build children list at reply_buf + 32, count in r15.
    lea rdi, [reply_buf + 32]
    xor r15d, r15d
    xor ecx, ecx
.qt_walk:
    cmp ecx, MAX_WINDOWS
    jge .qt_emit
    mov rax, rcx
    imul rax, WINDOW_REC_SIZE
    lea rdx, [windows + rax]
    mov eax, [rdx]                           ; xid
    test eax, eax
    jz .qt_walk_next
    cmp eax, r14d
    je .qt_walk_next                         ; don't list self
    mov esi, [rdx + 4]                       ; parent
    cmp esi, r14d
    jne .qt_walk_next
    mov [rdi], eax                           ; emit child xid
    add rdi, 4
    inc r15d
.qt_walk_next:
    inc ecx
    jmp .qt_walk
.qt_emit:
    ; Header.
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov [rdi + 4], r15d                      ; reply length in 4u (= N)
    mov dword [rdi + 8], X_ROOT_WINDOW
    mov eax, [r13 + 4]                       ; parent
    mov [rdi + 12], eax
    mov [rdi + 16], r15w                     ; num-children
    mov word [rdi + 18], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, r15
    shl rdx, 2
    add rdx, 32
    syscall

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_input_focus — edi = slot. Replies with the real focus_window
; (see handle_set_input_focus); PointerRoot (1) when nothing was focused.
; copyq/xdotool resolve their paste/type target from this reply.
;
; Reply (32 bytes):
;   +0 1                  +1 revert-to (PointerRoot=1)
;   +2 seq                +4 reply length 0
;   +8 focus (window XID, or 1 = PointerRoot)
;   +12..31 pad
; ============================================================================
; ============================================================================
; handle_list_extensions — edi = slot. Always replies "zero extensions".
; Pairs with QueryExtension to cover the two ways clients enumerate.
;
; Reply (32 bytes for empty list):
;   +0 1                  +1 nExtensions (CARD8 = 0)
;   +2 seq                +4 reply length 0
;   +8..31 pad
; ============================================================================
handle_list_extensions:
    ; Names the four extensions QueryExtension actually serves. Qt's xcb
    ; platform plugin enumerates via ListExtensions (not QueryExtension),
    ; so the old empty reply made Qt believe frame had NO extensions.
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 8                    ; nExtensions
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 17                  ; 68 bytes of names (66 + 2 pad)
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    ; STR list: length byte + name, ext_names_len bytes, then pad to 48.
    lea rsi, [ext_names]
    lea rdi, [reply_buf + 32]
    mov ecx, ext_names_len
    rep movsb
    mov word [rdi], 0                        ; pad the tail

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 100                             ; 32 header + 68 names
    syscall

    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_get_image — edi = slot, rsi = req. GetImage (opcode 73).
;   +1 format (2 = ZPixmap; XY formats unsupported)
;   +4 drawable   +8 x s16   +10 y s16   +12 w u16   +14 h u16   +16 planemask
; Reply: 32-byte header (depth 24, visual root-24, length = w*h words) then
; w*h*4 bytes of pixels row-copied from the drawable's BGRA backing. Client
; fds are blocking, so the row writes drain fully; a short-write loop guards
; the tail anyway. Out-of-bounds / XY format / no backing → Match error
; (XGetImage returns NULL instead of hanging).
; GIMP's color picker and screenshot paths block on this reply.
; ----------------------------------------------------------------------------
handle_get_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 40
    mov ebx, edi                             ; slot
    mov r12, rsi                             ; req
    mov eax, ebx
    call client_meta_addr
    mov [rsp], rax                           ; meta (fd +0, seq +8)
    cmp byte [r12 + 1], 2                    ; ZPixmap only
    jne .gi_err
    mov edi, [r12 + 4]
    cmp edi, X_ROOT_WINDOW
    jne .gi_drawable
    ; Root = the composited screen. Serve pixels from the FRONT buffer
    ; (GIMP's screen color picker + screenshot tools read root). The DRM
    ; dumb-buffer pitch may be padded beyond w*4, hence byte pitch below.
    ; Compositor inactive (network-only mode) → no pixels → Match error.
    ; Pending damage must be composited FIRST or the read returns pixels
    ; from before the client's own just-flushed drawing. Skip if a flip
    ; is in flight (can't touch the buffers) — best-effort then.
    cmp byte [comp_dirty], 0
    je .gi_root_fresh
    cmp byte [flip_pending], 0
    jne .gi_root_fresh
    mov byte [comp_dirty], 0
    call recomposite_screen
.gi_root_fresh:
    mov eax, [comp_back]
    xor eax, 1
    mov r13, [comp_addr + rax*8]
    test r13, r13
    jz .gi_err
    mov eax, [screen_w]
    mov [rsp + 8], eax                       ; width (px) for bounds
    mov eax, [screen_h]
    mov [rsp + 12], eax                      ; height
    mov eax, [drm_dumb_pitch]
    mov [rsp + 24], eax                      ; row pitch (bytes)
    jmp .gi_have_src
.gi_drawable:
    call drawable_get_backing
    test rax, rax
    jz .gi_err
    mov r13, rax                             ; backing ptr
    mov [rsp + 8], edx                       ; width (px)
    mov [rsp + 12], ecx                      ; backing height
    shl edx, 2
    mov [rsp + 24], edx                      ; row pitch (bytes) = w*4
.gi_have_src:
    movsx r14d, word [r12 + 8]               ; x
    movsx r15d, word [r12 + 10]              ; y
    movzx ebp, word [r12 + 12]               ; w
    movzx eax, word [r12 + 14]               ; h
    mov [rsp + 16], eax
    test ebp, ebp
    jz .gi_err
    test eax, eax
    jz .gi_err
    test r14d, r14d
    js .gi_err
    test r15d, r15d
    js .gi_err
    mov eax, r14d
    add eax, ebp
    cmp eax, [rsp + 8]                       ; x+w <= width
    jg .gi_err
    mov eax, r15d
    add eax, [rsp + 16]
    cmp eax, [rsp + 12]                      ; y+h <= height
    jg .gi_err
    ; Header.
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 24                   ; depth
    mov rax, [rsp]
    mov ecx, [rax + 8]
    mov [rdi + 2], cx                        ; seq
    mov eax, ebp
    imul eax, dword [rsp + 16]               ; w*h → reply length in words
    mov [rdi + 4], eax
    mov dword [rdi + 8], X_ROOT_VISUAL_24
    mov rax, [rsp]
    mov edi, [rax]                           ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
    ; Rows.
    mov dword [rsp + 20], 0                  ; row counter
.gi_row:
    mov eax, [rsp + 20]
    cmp eax, [rsp + 16]
    jge .gi_done
    add eax, r15d                            ; src row = y + i
    imul eax, dword [rsp + 24]               ; * pitch (bytes)
    mov ecx, r14d
    shl ecx, 2
    add eax, ecx                             ; + x*4
    lea rsi, [r13 + rax]
    mov edx, ebp
    shl edx, 2                               ; row bytes
.gi_wr:
    mov rax, [rsp]
    mov edi, [rax]
    mov rax, SYS_WRITE
    syscall
    cmp rax, -4                              ; EINTR (e.g. the SIGUSR1 dump
    je .gi_wr                                ; handler) → retry, or the reply
                                             ; truncates and the stream desyncs
    test rax, rax
    jle .gi_done                             ; client gone → abandon
    add rsi, rax
    sub edx, eax
    jnz .gi_wr
    inc dword [rsp + 20]
    jmp .gi_row
.gi_err:
    ; Match error (code 8): byte0=0, +4 bad resource, +10 major opcode.
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 1], 8                    ; Match
    mov rax, [rsp]
    mov ecx, [rax + 8]
    mov [rdi + 2], cx                        ; seq
    mov ecx, [r12 + 4]
    mov [rdi + 4], ecx                       ; bad drawable
    mov byte [rdi + 10], 73                  ; major
    mov edi, [rax]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
.gi_done:
    add rsp, 40
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_list_installed_colormaps — edi = slot. Opcode 83. TrueColor-only
; server: exactly one colormap, always installed. Reply n=1 + the default
; colormap id. Qt queries this during screen setup.
; ----------------------------------------------------------------------------
handle_list_installed_colormaps:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 1
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 1                   ; 1 word of cmap ids
    mov word [rdi + 8], 1                    ; n = 1
    mov dword [rdi + 32], X_DEFAULT_CMAP

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 36
    syscall

    pop r12
    pop rbx
    ret

; handle_alloc_color — edi = slot, rsi = req. AllocColor (84): TrueColor →
; pixel is just the 8-bit-truncated RGB; nothing to allocate.
;   req: cmap@4, red@8 (u16), green@10, blue@12
;   reply: red/green/blue@8,10,12 (echo), pixel@16
handle_alloc_color:
    push rbx
    push r12
    mov ebx, edi
    mov r12, rsi
    mov eax, ebx
    call client_meta_addr
    push rax
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 1
    pop rax
    mov ecx, [rax + 8]
    mov [rdi + 2], cx                        ; seq
    push rax
    movzx ecx, word [r12 + 8]                ; red
    mov [rdi + 8], cx
    movzx edx, word [r12 + 10]               ; green
    mov [rdi + 10], dx
    movzx esi, word [r12 + 12]               ; blue
    mov [rdi + 12], si
    shr ecx, 8
    shl ecx, 16
    mov eax, edx
    shr eax, 8
    shl eax, 8
    or ecx, eax
    shr esi, 8
    or ecx, esi
    mov [rdi + 16], ecx                      ; pixel = RRGGBB
    pop rax
    mov edi, [rax]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
    pop r12
    pop rbx
    ret

; handle_alloc_named_color — edi = slot, rsi = req. AllocNamedColor (85):
;   req: cmap@4, nameLen@8 (u16), name@12
;   reply: pixel@8, exactR/G/B@12,14,16, visualR/G/B@18,20,22
; Small name table (X11 rgb.txt values); unknown names resolve to white —
; a wrong colour beats a hung client (scrot -s asks for "gray").
handle_alloc_named_color:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    movzx ecx, word [r12 + 8]                ; name length
    lea rsi, [r12 + 12]                      ; name bytes
    lea rdi, [color_names]
    xor r13d, r13d                           ; default: white (table entry 0 fallback)
    mov r13d, 0xFFFFFF
.anc_scan:
    movzx eax, byte [rdi]                    ; table entry name length (0 = end)
    test eax, eax
    jz .anc_have
    cmp eax, ecx
    jne .anc_skip
    push rcx
    push rsi
    push rdi
    inc rdi
.anc_cmp:
    mov dl, [rsi]
    or dl, 0x20                              ; case-insensitive (names are ascii)
    cmp dl, [rdi]
    jne .anc_miss
    inc rsi
    inc rdi
    dec ecx
    jnz .anc_cmp
    pop rdi
    pop rsi
    pop rcx
    movzx eax, byte [rdi]
    lea rdi, [rdi + rax + 1]
    mov r13d, [rdi]                          ; the RGB dword after the name
    jmp .anc_have
.anc_miss:
    pop rdi
    pop rsi
    pop rcx
.anc_skip:
    movzx eax, byte [rdi]
    lea rdi, [rdi + rax + 1 + 4]             ; skip name + rgb dword
    jmp .anc_scan
.anc_have:
    mov eax, ebx
    call client_meta_addr
    push rax
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 1
    pop rax
    mov ecx, [rax + 8]
    mov [rdi + 2], cx
    push rax
    mov [rdi + 8], r13d                      ; pixel
    ; 16-bit channel values = 8-bit << 8 (echoed as both exact and visual)
    mov ecx, r13d
    shr ecx, 16
    and ecx, 0xFF
    mov ch, cl                               ; r*0x101 ≈ r<<8|r
    mov [rdi + 12], cx                       ; exactRed
    mov [rdi + 18], cx                       ; visualRed
    mov ecx, r13d
    shr ecx, 8
    and ecx, 0xFF
    mov ch, cl
    mov [rdi + 14], cx                       ; exactGreen
    mov [rdi + 20], cx                       ; visualGreen
    mov ecx, r13d
    and ecx, 0xFF
    mov ch, cl
    mov [rdi + 16], cx                       ; exactBlue
    mov [rdi + 22], cx                       ; visualBlue
    pop rax
    mov edi, [rax]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
    pop r13
    pop r12
    pop rbx
    ret

; handle_query_keymap — edi = slot. Reply: 8-byte header + the 32-byte
; keys_down bitmap (bit = X keycode, maintained by dispatch_input_event).
handle_query_keymap:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 2                   ; length = 2 (40 bytes total)
    lea rsi, [keys_down]
    mov rax, [rsi]
    mov [rdi + 8], rax
    mov rax, [rsi + 8]
    mov [rdi + 16], rax
    mov rax, [rsi + 16]
    mov [rdi + 24], rax
    mov rax, [rsi + 24]
    mov [rdi + 32], rax
    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 40
    syscall
    pop r12
    pop rbx
    ret

; handle_warp_pointer — rsi = req. WarpPointer (41), void. dst window None →
; relative move by (dst-x, dst-y); else absolute to the dst window's origin
; + offset. xdotool's mousemove is XWarpPointer — dropping this made every
; synthetic absolute pointer move a silent no-op. Moves the sprite and
; delivers MotionNotify like real motion (src-window confinement ignored).
handle_warp_pointer:
    push rbx
    mov eax, [rsi + 8]                       ; dst window
    movsx ecx, word [rsi + 20]               ; dst-x
    movsx edx, word [rsi + 22]               ; dst-y
    test eax, eax
    jz .hwp_relative
    push rcx
    push rdx
    mov edi, eax
    call window_abs_xy                       ; r10d/r11d = dst absolute origin
    pop rdx
    pop rcx
    add ecx, r10d
    add edx, r11d
    jmp .hwp_apply
.hwp_relative:
    add ecx, [cursor_x]
    add edx, [cursor_y]
.hwp_apply:
    test ecx, ecx
    jns .hwp_x_lo
    xor ecx, ecx
.hwp_x_lo:
    mov eax, [screen_w]
    dec eax
    cmp ecx, eax
    cmovg ecx, eax
    test edx, edx
    jns .hwp_y_lo
    xor edx, edx
.hwp_y_lo:
    mov eax, [screen_h]
    dec eax
    cmp edx, eax
    cmovg edx, eax
    mov [cursor_x], ecx
    mov [cursor_y], edx
    call cursor_move_hw
    call deliver_pointer_motion
    pop rbx
    ret

handle_get_input_focus:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 1                    ; revert-to = PointerRoot
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov eax, [focus_window]                  ; the REAL focus — copyq targets
    mov [rdi + 8], eax                       ; its paste at this window; the
    mov dword [rdi + 12], 0                  ; old PointerRoot stub broke it
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_keyboard_mapping — edi = slot, rsi = request ptr. The request
; specifies first-keycode + count; we reply with `count` keycodes' worth
; of keysyms, 1 keysym per keycode (all NoSymbol for now). Real
; layout-driven keysyms land in phase 4d (input) + phase 11 (XKB).
;
; Request:
;   +0 opcode (101)       +1 0
;   +2 length (4u)        +4 first-keycode (u8)
;   +5 count (u8)         +6 pad (2)
;
; Reply (32 + count*4 bytes; keysyms-per-keycode = 1):
;   +0 1                  +1 keysyms-per-keycode (= 1)
;   +2 seq                +4 reply length (= count, since one CARD32 each)
;   +8..31 pad
;   +32..32+count*4 keysyms (all 0 = NoSymbol)
; ============================================================================
handle_get_keyboard_mapping:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r13, rsi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    movzx r14d, byte [r13 + 4]               ; first-keycode
    movzx ecx, byte [r13 + 5]                ; count

    ; Header.
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], KEYSYMS_PER_KC       ; keysyms-per-keycode = 6
    mov edx, [r12 + 8]
    mov [rdi + 2], dx
    imul edx, ecx, KEYSYMS_PER_KC            ; reply length = count × 6 (4u each)
    mov [rdi + 4], edx
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; Body: count × 2 keysyms from keysym_table.
    ; For each requested keycode k (first..first+count-1):
    ;   reply[+0] = keysym_table[(k - X_MIN_KEYCODE) * 8 + 0]
    ;   reply[+4] = keysym_table[(k - X_MIN_KEYCODE) * 8 + 4]
    test ecx, ecx
    jz .gkm_write
    push rcx
    add rdi, 32
    mov esi, r14d
    sub esi, X_MIN_KEYCODE                   ; table index in keycode units
    imul esi, esi, 24                        ; bytes (24 per keycode)
    lea r9, [keysym_table + rsi]             ; source ptr
.gkm_emit:
    mov eax, [r9 + 0]
    mov [rdi + 0], eax
    mov eax, [r9 + 4]
    mov [rdi + 4], eax
    mov eax, [r9 + 8]
    mov [rdi + 8], eax
    mov eax, [r9 + 12]
    mov [rdi + 12], eax
    mov eax, [r9 + 16]
    mov [rdi + 16], eax
    mov eax, [r9 + 20]
    mov [rdi + 20], eax
    add r9, 24
    add rdi, 24
    dec ecx
    jnz .gkm_emit
    pop rcx
.gkm_write:
    imul edx, ecx, 24                        ; body bytes = count × 24
    add edx, 32                              ; total reply bytes
    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    syscall

    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; reply_canned32(rdi = meta_ptr) — write a 32-byte reply that's already
; been laid out in reply_buf (bytes 0,1 plus seq, with everything else
; zeroed by caller as needed). Used by the cheap stub handlers below.
; Doesn't touch reply_buf, just the seq slot at +2.
; ============================================================================
emit_canned_reply32:
    push rax
    push rsi
    push rdx
    mov ecx, [rdi + 8]                       ; seq
    lea rsi, [reply_buf]
    mov [rsi + 2], cx
    mov edi, [rdi]                           ; fd
    mov rax, SYS_WRITE
    mov rdx, 32
    syscall
    pop rdx
    pop rsi
    pop rax
    ret

; ============================================================================
; handle_get_window_attributes — edi = slot, rsi = request ptr. Real
; per-window attrs from the table.
;
; Request: +4 window (WINDOW)
;
; Reply (44 bytes, length 3 in 4u):
;   +0 1                  +1 backing-store
;   +2 seq                +4 reply length 3
;   +8 visual (u32)
;   +12 class (u16)       +14 bit-gravity (u8)
;   +15 win-gravity (u8)
;   +16 backing-planes (u32)
;   +20 backing-pixel (u32)
;   +24 save-under (u8)
;   +25 map-is-installed (u8)
;   +26 map-state (u8)
;   +27 override-redirect (u8)
;   +28 colormap (u32)
;   +32 all-event-masks (u32)
;   +36 your-event-mask (u32)
;   +40 do-not-propagate-mask (u16)
;   +42 pad (2)
; ============================================================================
handle_get_window_attributes:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r13, rsi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    mov edi, [r13 + 4]
    call window_lookup
    test rax, rax
    jnz .gwa_have
    xor eax, eax
    mov edi, X_ROOT_WINDOW
    call window_lookup
.gwa_have:
    mov r13, rax                             ; window record

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; backing-store = NotUseful
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 3
    mov eax, [r13 + 20]
    mov [rdi + 8], eax                       ; visual
    movzx eax, byte [r13 + 19]
    mov [rdi + 12], ax                       ; class (u16, comes from u8 field)
    mov byte [rdi + 14], 0
    mov byte [rdi + 15], 1
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov byte [rdi + 24], 0
    mov byte [rdi + 25], 1
    movzx eax, byte [r13 + 28]
    test eax, eax
    jz .gwa_not_viewable
    mov byte [rdi + 26], 2                   ; Viewable
    jmp .gwa_view_done
.gwa_not_viewable:
    mov byte [rdi + 26], 0                   ; Unmapped
.gwa_view_done:
    movzx eax, byte [r13 + 29]
    mov [rdi + 27], al                       ; override-redirect
    mov dword [rdi + 28], X_DEFAULT_CMAP
    mov dword [rdi + 32], 0
    mov eax, [r13 + 24]
    mov [rdi + 36], eax                      ; your-event-mask
    mov word [rdi + 40], 0
    mov word [rdi + 42], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 44
    syscall

    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_query_best_size — edi = slot, rsi = request ptr. Echoes the
; client's requested width/height as the "best" size. Acceptable for
; cursor/tile/stipple queries until real backing-store logic exists.
; ============================================================================
handle_query_best_size:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r13, rsi                             ; request ptr
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    movzx edx, word [r13 + 8]                ; requested width
    movzx ecx, word [r13 + 10]               ; requested height

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov eax, [r12 + 8]
    mov [rdi + 2], ax
    mov dword [rdi + 4], 0
    mov [rdi + 8], dx                        ; width
    mov [rdi + 10], cx                       ; height
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_keyboard_control — edi = slot. Defaults: bells off,
; auto-repeat off, no LEDs.
;
; Reply (52 bytes; 5 = (52-32)/4):
;   +0 1                  +1 global-auto-repeat (Off=0)
;   +2 seq                +4 reply length 5
;   +8 led-mask (CARD32)
;   +12 key-click-percent (CARD8)
;   +13 bell-percent (CARD8)
;   +14 bell-pitch (CARD16)
;   +16 bell-duration (CARD16)
;   +18 pad (2)
;   +20 auto-repeats (32 bytes = 256 bits, one per keycode 0..255)
;   +52
; ============================================================================
handle_get_keyboard_control:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; global-auto-repeat Off
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 5
    mov dword [rdi + 8], 0                   ; led-mask
    mov byte [rdi + 12], 0                   ; key-click %
    mov byte [rdi + 13], 0                   ; bell %
    mov word [rdi + 14], 400                 ; bell pitch (Hz)
    mov word [rdi + 16], 100                 ; bell duration (ms)
    mov word [rdi + 18], 0
    ; Auto-repeats: 32 bytes of zero (auto-repeat disabled on every key).
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov dword [rdi + 32], 0
    mov dword [rdi + 36], 0
    mov dword [rdi + 40], 0
    mov dword [rdi + 44], 0
    mov dword [rdi + 48], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 52
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_pointer_control — edi = slot. Defaults: linear acceleration.
;
; Reply (32 bytes):
;   +0 1                  +1 0
;   +2 seq                +4 reply length 0
;   +8 accel-numerator (u16)
;   +10 accel-denominator (u16)
;   +12 threshold (u16)
;   +14..31 pad
; ============================================================================
handle_get_pointer_control:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov word [rdi + 8], 1                    ; accel num
    mov word [rdi + 10], 1                   ; accel denom
    mov word [rdi + 12], 4                   ; threshold
    mov word [rdi + 14], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_screen_saver — edi = slot. Screensaver disabled.
;
; Reply (32 bytes):
;   +0 1                  +1 0
;   +2 seq                +4 reply length 0
;   +8 timeout (u16)      +10 interval (u16)
;   +12 prefer-blanking (Yes=1, No=0, Default=2)
;   +13 allow-exposures
;   +14..31 pad
; ============================================================================
handle_get_screen_saver:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov word [rdi + 8], 0                    ; timeout 0 = disabled
    mov word [rdi + 10], 0
    mov byte [rdi + 12], 0                   ; prefer-blanking
    mov byte [rdi + 13], 0                   ; allow-exposures
    mov word [rdi + 14], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_list_hosts — edi = slot. Access control list always empty,
; access control disabled.
;
; Reply (32 bytes for empty list):
;   +0 1                  +1 mode (0 = disabled)
;   +2 seq                +4 reply length 0
;   +8 nHosts (u16)       +10 pad
;   +12..31 pad
; ============================================================================
handle_list_hosts:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; mode = disabled
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov word [rdi + 8], 0                    ; nHosts
    mov word [rdi + 10], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_pointer_mapping — edi = slot. Identity mapping for 3
; buttons (1=1, 2=2, 3=3). Padded to 4 bytes so reply length = 1.
;
; Reply (36 bytes):
;   +0 1                  +1 nMap (CARD8 = 3)
;   +2 seq                +4 reply length (CARD32 = 1, ceil(3/4))
;   +8..31 pad            +32 map (3 bytes: 1,2,3) + 1 pad
; ============================================================================
handle_get_pointer_mapping:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 3                    ; nMap
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 1                   ; reply length
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov byte [rdi + 32], 1
    mov byte [rdi + 33], 2
    mov byte [rdi + 34], 3
    mov byte [rdi + 35], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 36
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_modifier_mapping — edi = slot. Empty modifier map (no keys
; map to any modifier). 8 modifier classes × keycodes-per-modifier (we
; pick 2) = 16 bytes of body.
;
; Reply (32 + 16 = 48 bytes):
;   +0 1                  +1 keycodes-per-modifier (CARD8 = 2)
;   +2 seq                +4 reply length (= 4)
;   +8..31 pad            +32..47 modifier→keycode (16 bytes, all 0)
; ============================================================================
handle_get_modifier_mapping:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 2                    ; keycodes-per-modifier
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 4                   ; reply length
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    ; Body: 8 modifier rows × 2 keycodes (reply_buf +32..+47). Zero, then fill.
    mov dword [rdi + 32], 0
    mov dword [rdi + 36], 0
    mov dword [rdi + 40], 0
    mov dword [rdi + 44], 0
    mov byte [rdi + 32], 50                   ; Shift   = Shift_L
    mov byte [rdi + 33], 62                   ; Shift   = Shift_R
    mov byte [rdi + 36], 37                   ; Control = Control_L
    mov byte [rdi + 37], 105                  ; Control = Control_R
    mov byte [rdi + 38], 64                   ; Mod1    = Alt_L
    mov byte [rdi + 44], 133                  ; Mod4    = Super_L
    mov byte [rdi + 45], 134                  ; Mod4    = Super_R
    cmp byte [keymap_is_no], 0                ; right Alt (kc 108):
    jne .gmm_no
    mov byte [rdi + 39], 108                  ;   US → Mod1 (Alt_R)
    jmp .gmm_send
.gmm_no:
    mov byte [rdi + 46], 108                  ;   NO → Mod5 (AltGr)
.gmm_send:

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 48
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4b — window table + 7 window-management opcodes.
; ============================================================================
; The window record is 32 bytes (see windows: in BSS). Slot 0 is reserved
; for the root window at startup. Lookup is linear scan over MAX_WINDOWS
; (512) — sub-µs for the typical desktop's ~100 windows.
;
; Opcodes added in this phase:
;
;   CreateWindow            (1)  allocate + parse CW value-list (we
;                                care about CW_OVERRIDE_REDIRECT and
;                                CW_EVENT_MASK; other values consumed
;                                from the list but ignored for now)
;   ChangeWindowAttributes  (2)  same CW value-list parse; updates an
;                                existing window. Tile sets the root
;                                window's event_mask here to grab
;                                SubstructureRedirect.
;   DestroyWindow           (4)  remove from table; cascading destroy
;                                of children (whose parent xid matches)
;   MapWindow               (8)  mark mapped=1
;   UnmapWindow            (10)  mark mapped=0
;   ConfigureWindow        (12)  update geometry / stacking from
;                                CFG_* value-list
;
; Plus upgraded GetGeometry / GetWindowAttributes / QueryTree to use
; real per-window state (see those handlers above).
; ============================================================================

; ----------------------------------------------------------------------------
; init_windows — zero the table, then register the root window at slot 0.
; ----------------------------------------------------------------------------
init_windows:
    push rbx
    ; Zero the whole table (all slots empty).
    lea rdi, [windows]
    xor eax, eax
    mov ecx, MAX_WINDOWS * WINDOW_REC_SIZE
    rep stosb
    ; Slot 0 = root.
    lea rbx, [windows]
    mov dword [rbx + 0],  X_ROOT_WINDOW
    mov dword [rbx + 4],  0                  ; root's parent = None
    mov word  [rbx + 8],  0                  ; x
    mov word  [rbx + 10], 0                  ; y
    ; Default the runtime screen size; init_compositor overwrites it (and
    ; this root width/height) with the real DRM mode when --display engages.
    mov dword [screen_w], X_SCREEN_W
    mov dword [screen_h], X_SCREEN_H
    mov ax, [screen_w]
    mov word  [rbx + 12], ax
    mov ax, [screen_h]
    mov word  [rbx + 14], ax
    ; Centre the pointer (re-centred on the real size in init_compositor).
    mov eax, X_SCREEN_W
    shr eax, 1
    mov [cursor_x], eax
    mov eax, X_SCREEN_H
    shr eax, 1
    mov [cursor_y], eax
    mov word  [rbx + 16], 0                  ; border-width
    mov byte  [rbx + 18], 24                 ; depth
    mov byte  [rbx + 19], 1                  ; class = InputOutput
    mov dword [rbx + 20], X_ROOT_VISUAL_24
    mov dword [rbx + 24], 0                  ; event_mask (tile will set this)
    mov byte  [rbx + 28], 1                  ; mapped = true
    mov byte  [rbx + 29], 0                  ; override-redirect
    mov byte  [rbx + 30], -1                 ; no redirect owner yet
    mov byte  [rbx + 31], 0
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_lookup — edi = xid. Returns ptr to record in rax, or 0 if not
; found.
; ----------------------------------------------------------------------------
window_lookup:
    push rbx
    test edi, edi                            ; xid 0 = None — never a window, and
    jz .wl_miss                              ; would falsely match an empty slot
    xor ebx, ebx
.wl_loop:
    cmp ebx, MAX_WINDOWS
    jge .wl_miss
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea rax, [windows + rax]
    cmp [rax], edi
    je .wl_hit
    inc ebx
    jmp .wl_loop
.wl_hit:
    pop rbx
    ret
.wl_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_alloc — find first empty slot, mark with xid. edi = xid.
; Returns slot ptr in rax, or 0 if table is full.
; ----------------------------------------------------------------------------
window_alloc:
    push rbx
    xor ebx, ebx
.wa_loop:
    cmp ebx, MAX_WINDOWS
    jge .wa_full
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea rax, [windows + rax]
    cmp dword [rax], 0
    je .wa_take
    inc ebx
    jmp .wa_loop
.wa_take:
    mov [rax], edi
    pop rbx
    ret
.wa_full:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_destroy — edi = xid. Removes the window plus every child whose
; parent xid matches (cascading). Skips the root (xid = X_ROOT_WINDOW)
; defensively so a misbehaving client can't blank our state.
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; window_props_clear — edi = window xid. Zeroes every property record
; belonging to the window. Value-pool bytes are NOT reclaimed (append-only
; pool by design), but the 1024 records must be, or table churn from app
; restarts exhausts them and ChangeProperty silently no-ops forever after.
; ----------------------------------------------------------------------------
window_props_clear:
    push rbx
    xor ebx, ebx
.wpc_loop:
    cmp ebx, MAX_PROPERTIES
    jge .wpc_done
    mov rax, rbx
    imul rax, PROPERTY_REC_SIZE
    cmp [properties + rax], edi
    jne .wpc_next
    mov dword [properties + rax], 0
.wpc_next:
    inc ebx
    jmp .wpc_loop
.wpc_done:
    pop rbx
    ret

window_destroy:
    push rbx
    push r12
    push r13
    cmp edi, X_ROOT_WINDOW
    je .wd_done
    call shape_free_window                   ; drop any SHAPE regions (preserves regs)
    mov r12d, edi                            ; xid being destroyed
    xor ebx, ebx
.wd_walk:
    cmp ebx, MAX_WINDOWS
    jge .wd_done
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea r13, [windows + rax]
    mov eax, [r13]
    test eax, eax
    jz .wd_walk_next
    cmp eax, r12d
    je .wd_kill                              ; the window itself
    mov edx, [r13 + 4]
    cmp edx, r12d
    je .wd_recurse                           ; a child — recurse
    jmp .wd_walk_next
.wd_kill:
    cmp byte [r13 + 28], 0                   ; on screen? damage its rect
    je .wd_kill_free
    mov rdi, r13
    call damage_add_window
    mov byte [comp_dirty], 1                 ; cascade-killed mapped children
                                             ; must trigger a composite too
.wd_kill_free:
    ; Free the backing buffer if one was mmap'd.
    cmp byte [r13 + 31], 0
    je .wd_kill_clear
    push rbx
    mov rax, SYS_MUNMAP
    mov rdi, [r13 + 32]                      ; backing_ptr
    movzx esi, word [r13 + 40]               ; backing_w
    movzx ecx, word [r13 + 42]               ; backing_h
    imul esi, ecx
    shl esi, 2                               ; bytes = w*h*4
    syscall
    pop rbx
.wd_kill_clear:
    mov edi, [r13]                           ; free its property records too:
    call window_props_clear                  ; Xlib XID reuse is deterministic,
                                             ; so stale records would resurrect
                                             ; on the next client/window using
                                             ; this xid (and the 1024-slot
                                             ; table would exhaust under churn)
    mov dword [r13], 0                       ; mark empty
    mov byte [r13 + 31], 0                   ; has_backing = 0
    mov qword [r13 + 32], 0
    mov dword [r13 + 40], 0                  ; backing_w/h = 0
    mov dword [r13 + 52], 0                  ; XI2 mask (recycled slots!)
    jmp .wd_walk_next
.wd_recurse:
    push rbx
    mov edi, eax                             ; child xid
    call window_destroy
    pop rbx
    ; After recursion, this slot may now be empty (or contain a
    ; different window if the table got re-packed — we don't re-pack,
    ; so it's the same slot, now zeroed by the recursive call's kill).
.wd_walk_next:
    inc ebx
    jmp .wd_walk
.wd_done:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; apply_cw_values — common parser for CreateWindow + ChangeWindowAttributes
; value-lists. r13 = window record ptr, ecx = value-mask, rdx = ptr to the
; CARD32 value-list. Walks the mask LSB→MSB; for each set bit, consumes
; one CARD32 and (for the two attrs we track) updates the record.
; ----------------------------------------------------------------------------
apply_cw_values:
    push rbx
    push r12
    push r14
    mov ebx, ecx                             ; remaining mask
    mov r12, rdx                             ; value list cursor
    xor r14d, r14d                           ; bit index
.av_loop:
    test ebx, ebx
    jz .av_done
    bt ebx, 0
    jnc .av_skip_bit
    ; Bit r14 is set. Get the corresponding CARD32 and dispatch.
    mov eax, [r12]
    test r14d, r14d                          ; CW_BACK_PIXMAP bit pos (0)
    jz .av_back_pixmap
    cmp r14d, 1                              ; CW_BACK_PIXEL bit pos
    je .av_back_pixel
    cmp r14d, 3                              ; CW_BORDER_PIXEL bit pos
    je .av_border_pixel
    cmp r14d, 9                              ; CW_OVERRIDE_REDIRECT bit pos
    je .av_override
    cmp r14d, 11                             ; CW_EVENT_MASK bit pos
    je .av_event_mask
    cmp r14d, 14                             ; CW_CURSOR bit pos
    je .av_cursor
    jmp .av_advance
.av_back_pixmap:
    ; Background pixmap: materialise it straight into the window backing
    ; (spot's dim-cover overlay is a back-pixmap-only window — it never
    ; draws). None (0) / ParentRelative (1) keep the back_pixel behaviour.
    cmp eax, 1
    jbe .av_advance
    mov rdi, r13
    mov esi, eax
    call window_apply_back_pixmap            ; preserves rbx/r12/r13/r14
    jmp .av_advance
.av_back_pixel:
    mov [r13 + 44], eax                      ; back_pixel
    jmp .av_advance
.av_border_pixel:
    mov [r13 + 56], eax                      ; border_pixel (tile's focus ring
    mov rdi, r13                             ; recolours it per focus change)
    call border_damage                       ; preserves rbx/r12/r13/r14
    jmp .av_advance
.av_override:
    mov [r13 + 29], al                       ; u8 boolean
    jmp .av_advance
.av_event_mask:
    mov [r13 + 24], eax
    jmp .av_advance
.av_cursor:
    mov [r13 + 60], eax                      ; cursor xid (None = 0 clears)
    call cursor_sync                         ; window may be under the pointer
.av_advance:
    add r12, 4
.av_skip_bit:
    shr ebx, 1
    inc r14d
    jmp .av_loop
.av_done:
    pop r14
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_create_window — edi = slot, rsi = req ptr, edx = req size in bytes.
;
; Request:
;   +0 opcode (1)         +1 depth (CARD8)
;   +2 length             +4 wid (WINDOW)
;   +8 parent (WINDOW)    +12 x (INT16)
;   +14 y (INT16)         +16 width (CARD16)
;   +18 height (CARD16)   +20 border-width (CARD16)
;   +22 class (CARD16)    +24 visual (VISUALID)
;   +28 value-mask        +32 value-list
;
; No reply (the wid is supplied by the client).
; ============================================================================
handle_create_window:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12, rsi                             ; req ptr
    mov r14, rdx

    mov edi, [r12 + 4]                       ; wid
    test edi, edi
    jz .cw_done                              ; 0 is invalid
    call window_alloc
    test rax, rax
    jz .cw_done                              ; table full — silently drop
    mov r13, rax                             ; record ptr

    ; Initialise the record.
    movzx eax, byte [r12 + 1]
    test al, al                              ; depth = CopyFromParent (0)?
    jnz .cw_depth_set
    mov al, 24                               ; inherit the root depth
.cw_depth_set:
    mov [r13 + 18], al                       ; depth
    mov eax, [r12 + 8]
    mov [r13 + 4], eax                       ; parent
    mov ax, [r12 + 12]
    mov [r13 + 8], ax                        ; x
    mov ax, [r12 + 14]
    mov [r13 + 10], ax                       ; y
    mov ax, [r12 + 16]
    mov [r13 + 12], ax                       ; width
    mov ax, [r12 + 18]
    mov [r13 + 14], ax                       ; height
    mov ax, [r12 + 20]
    mov [r13 + 16], ax                       ; border
    mov ax, [r12 + 22]
    mov [r13 + 19], al                       ; class
    mov eax, [r12 + 24]
    test eax, eax                            ; visual = CopyFromParent (0)?
    jnz .cw_visual_set
    mov eax, X_ROOT_VISUAL_24                ; inherit the root visual (0x20)
.cw_visual_set:
    mov [r13 + 20], eax                      ; visual
    mov dword [r13 + 24], 0                  ; event_mask (default 0)
    mov byte  [r13 + 28], 0                  ; mapped (false)
    mov byte  [r13 + 29], 0                  ; override-redirect (false)
    mov byte  [r13 + 30], -1                 ; redirect_owner (none)
    mov dword [r13 + 52], 0                  ; XI2 event mask (none)
    mov byte  [r13 + 31], 0                  ; has_backing (false)
    mov qword [r13 + 32], 0                  ; backing_ptr
    mov dword [r13 + 40], 0                  ; backing_cap
    mov dword [r13 + 44], 0                  ; back_pixel (default black)
    mov dword [r13 + 56], 0                  ; border_pixel (default black)
    mov dword [r13 + 60], 0                  ; cursor (None)

    ; Walk CW value-mask.
    mov ecx, [r12 + 28]
    test ecx, ecx
    jz .cw_done
    lea rdx, [r12 + 32]
    call apply_cw_values
    ; If the event mask includes SubstructureRedirect, claim ownership.
    mov eax, [r13 + 24]
    test eax, EM_SUBSTRUCTURE_REDIRECT
    jz .cw_done
    mov [r13 + 30], bl                       ; redirect_owner = current slot
.cw_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_change_window_attributes — edi = slot, rsi = req ptr,
; edx = req size. Updates the named window's CW attrs.
;
; Request:
;   +0 opcode (2)         +1 0
;   +2 length             +4 window
;   +8 value-mask         +12 value-list
;
; No reply.
; ============================================================================
handle_change_window_attributes:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov edi, [r12 + 4]
    call window_lookup
    test rax, rax
    jz .cwa_done
    mov r13, rax
    mov ecx, [r12 + 8]
    test ecx, ecx
    jz .cwa_done
    ; frame keeps ONE event_mask per window, but X masks are per-client. If a
    ; NON-owner (e.g. the WM selecting PropertyChange on a client's window)
    ; changes attributes, OR its selection into the existing mask instead of
    ; overwriting — else it wipes the owner's ButtonPress/Motion bits and input
    ; to that window dies. Owner slot is encoded in the xid's high bits (bogus
    ; for root → treated as non-owner, so root's mask accumulates, which is
    ; what we want for SubstructureRedirect/Notify selectors).
    mov eax, [r13]                           ; window xid
    sub eax, X_RID_BASE
    shr eax, 21                              ; owner slot
    cmp eax, ebx                             ; requester slot
    je .cwa_owner
    mov eax, [r13 + 24]                       ; existing mask
    push rax
    lea rdx, [r12 + 12]
    call apply_cw_values                      ; [r13+24] = requester's new mask
    mov r8d, [r13 + 24]                       ; r8d = THIS request's selection
    pop rax
    or [r13 + 24], eax                        ; combined mask for delivery
    jmp .cwa_redirect
.cwa_owner:
    lea rdx, [r12 + 12]
    call apply_cw_values
    mov r8d, [r13 + 24]                       ; owner's new (full) mask
.cwa_redirect:
    ; SubstructureRedirect ownership keys on what THIS request selected (r8d),
    ; not the combined mask — else every later CWA would re-claim redirect.
    ; EXCLUSIVE, like real X: if another client owns it, reply BadAccess and
    ; leave the claim alone. Chromium/GTK probe for a running WM by selecting
    ; SubstructureRedirect on root and expecting BadAccess; without it the
    ; prober silently STOLE MapRequest routing from tile — every window
    ; mapped after a FortiClient/Electron launch went to the prober and
    ; never showed (the panel's dead Mod4+Return).
    ; A request that does NOT carry CW_EVENT_MASK cannot change the claim:
    ; without this gate r8d holds the COMBINED mask (with the WM's redirect
    ; bit), so an innocent cursor/background CWA on root by any GTK client
    ; got a spurious BadAccess — GTK2 treats X errors as fatal (dead
    ; fortitray on the panel).
    test dword [r12 + 8], 0x800              ; CW_EVENT_MASK in value-mask?
    jz .cwa_done
    test r8d, EM_SUBSTRUCTURE_REDIRECT
    jz .cwa_clear_redirect
    movsx eax, byte [r13 + 30]
    cmp eax, 0
    jl .cwa_claim                            ; unowned → claim
    ; Owned (by us or another): leave the claim untouched. The spec says
    ; BadAccess for a second claimant, but GTK2's default error handling is
    ; FATAL — fortitray does an untrapped XSelectInput(root, ...Redirect...)
    ; when no EWMH _NET_SUPPORTING_WM_CHECK is present, and the error killed
    ; it on the panel. Silently ignoring keeps the WM's MapRequest routing
    ; intact (the actual v0.0.75 bug) AND keeps error-fatal clients alive.
    jmp .cwa_done
.cwa_claim:
    mov [r13 + 30], bl                       ; this client claims the redirect
    jmp .cwa_done
.cwa_clear_redirect:
    ; Only the CURRENT owner may relinquish SubstructureRedirect. Another
    ; client changing its own event selection on a shared window (e.g. strip's
    ; system-tray setup selecting on root) must NOT revoke the WM's redirect.
    movsx eax, byte [r13 + 30]
    cmp eax, ebx
    jne .cwa_done
    mov byte [r13 + 30], -1
.cwa_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_destroy_window — edi = slot, rsi = req ptr. Removes the named
; window and all its descendants (cascading via window_destroy).
;
; Request: +4 window
;
; No reply.
; ============================================================================
handle_destroy_window:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov edi, [rsi + 4]
    mov r12d, edi                            ; save xid
    call window_lookup
    test rax, rax
    jz .hd_clear
    mov r13, rax                             ; window record
    mov ecx, [r13]                           ; if it held the grab, drop it
    cmp ecx, [ptr_grab_win]
    jne .hd_nograb
    mov dword [ptr_grab_win], 0
    mov dword [ptr_grab_cursor], 0
    mov byte [ptr_grab_xi2], 0
.hd_nograb:
    ; A dying window holding the KEYBOARD grab wedged all key input (GTK
    ; menus grab pointer AND keyboard; only the pointer was released).
    mov ecx, [r13]
    cmp ecx, [active_kbd_window]
    jne .hd_nokbd
    mov dword [active_kbd_slot], -1
    mov dword [active_kbd_window], 0
    mov byte [kbd_grab_xi2], 0
.hd_nokbd:
    ; If the window is still MAPPED, send its own UnmapNotify first — Xorg
    ; unmaps before destroy, and GTK's map/unmap freeze/thaw needs the pair.
    cmp byte [r13 + 28], 0
    je .hd_noumap
    mov eax, [r13 + 24]
    test eax, EM_STRUCTURE_NOTIFY
    jz .hd_noumap
    mov eax, [r13]                           ; xid -> owner slot
    cmp eax, X_RID_BASE
    jb .hd_noumap
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .hd_noumap
    mov edi, eax
    mov esi, [r13]
    mov edx, [r13]
    call send_unmap_notify
.hd_noumap:
    mov rdi, r13                             ; Expose the region it was covering
    call expose_under_window
    ; DestroyNotify to the window's own StructureNotify selector (owner)...
    mov eax, [r13 + 24]
    test eax, EM_STRUCTURE_NOTIFY
    jz .hd_nodn
    mov eax, [r13]
    cmp eax, X_RID_BASE
    jb .hd_nodn
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .hd_nodn
    mov edi, eax
    mov esi, [r13]                           ; event window = the window
    mov edx, [r13]
    call send_destroy_notify
.hd_nodn:
    ; ...and to the parent's SubstructureNotify subscriber (root → the WM's
    ; redirect owner; other parents → the parent's owner client).
    mov edi, [r13 + 4]                       ; parent xid
    call window_lookup
    test rax, rax
    jz .hd_clear
    test dword [rax + 24], EM_SUBSTRUCTURE_NOTIFY
    jz .hd_clear
    cmp dword [rax], X_ROOT_WINDOW
    jne .hd_dn_owner
    movsx edi, byte [rax + 30]               ; redirect owner (the WM)
    cmp edi, 0
    jl .hd_clear
    jmp .hd_dn_send
.hd_dn_owner:
    mov edi, [rax]
    sub edi, X_RID_BASE
    shr edi, 21
    cmp edi, MAX_CLIENTS
    jae .hd_clear
.hd_dn_send:
    cmp edi, ebx                             ; requester destroyed its own child
    je .hd_clear                             ; under itself: skip the echo
    mov esi, [rax]                           ; event window = parent
    mov edx, [r13]                           ; window
    call send_destroy_notify
.hd_clear:
    mov edi, r12d
    call window_destroy
    mov byte [comp_dirty], 1
    call sync_pointer_window
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_map_window — edi = slot, rsi = req ptr.
;
; SubstructureRedirect intercept: if the window's parent has a redirect
; owner that's a DIFFERENT client than the requester, we don't map; we
; send a MapRequest event to the owner instead. The owner (the WM) then
; sees the request and decides what to do.
;
; Otherwise we map directly, and if the parent has SubstructureNotify on
; the same client (the WM), send MapNotify so the WM knows it landed.
;
; Request: +4 window
; No reply.
; ============================================================================
handle_map_window:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi                              ; requester slot
    mov edi, [rsi + 4]                        ; window xid
    push rsi
    call window_lookup
    pop rsi
    test rax, rax
    jnz .mw_have
    mov edi, ebx
    mov esi, [rsi + 4]
    mov edx, 8
    call send_bad_window
    jmp .mw_done
.mw_have:
    mov r12, rax                              ; window record
    ; X11: MapWindow on an already-mapped window has NO effect — no MapRequest,
    ; no MapNotify. Skipping this let GTK re-map generate a duplicate MapNotify;
    ; GDK thaws the toplevel on each MapNotify but froze it only once, so the
    ; second thaw aborts with 'freeze_count > 0' (the GIMP-on-frame crash).
    cmp byte [r12 + 28], 0
    jne .mw_done
    mov edi, [r12 + 4]                        ; parent xid
    call window_lookup
    test rax, rax
    jz .mw_just_map
    mov r13, rax                              ; parent record
    ; Override-redirect windows bypass SubstructureRedirect entirely —
    ; the server maps them directly and NEVER sends the WM a MapRequest
    ; (X11 semantics). strip's status bar is such a window; redirecting it
    ; to tile wedged tile's map-handling. Still falls through to .mw_just_map
    ; which sends MapNotify (carrying override-redirect=1) to SubNotify subs.
    cmp byte [r12 + 29], 0                     ; window override-redirect?
    jne .mw_just_map
    movsx r14d, byte [r13 + 30]               ; redirect_owner
    cmp r14d, 0
    jl .mw_just_map
    cmp r14d, ebx
    je .mw_just_map                            ; requester IS the WM → map
    ; Redirect: send MapRequest to the WM.
    mov edi, r14d                              ; owner slot
    mov esi, [r13]                             ; parent xid
    mov edx, [r12]                             ; window xid
    call send_map_request
    jmp .mw_done
.mw_just_map:
    mov byte [r12 + 28], 1
    ; A freshly mapped window must show its BACKGROUND immediately (X
    ; semantics) — backless windows let the wallpaper shine through until
    ; the client's first draw (bg flash on every glass launch).
    cmp byte [r12 + 19], 2                     ; InputOnly: nothing to paint
    je .mw_no_backing
    mov rdi, r12
    call window_ensure_backing                 ; no-op if already backed
.mw_no_backing:
    mov byte [comp_dirty], 1
    mov rdi, r12
    call damage_add_window
    inc dword [win_stk_next]                   ; mapping raises to top of z-order
    mov eax, [win_stk_next]
    mov [r12 + 48], eax
    ; If the window selected StructureNotify on ITSELF, send its own client
    ; MapNotify + ConfigureNotify (clients like glass wait for the latter
    ; before forking their shell / learning their geometry). Owner client
    ; slot is encoded in the xid: (xid - X_RID_BASE) >> 21.
    mov eax, [r12 + 24]
    test eax, EM_STRUCTURE_NOTIFY
    jz .mw_check_sub
    mov eax, [r12]                             ; window xid
    cmp eax, X_RID_BASE
    jb .mw_check_sub
    sub eax, X_RID_BASE
    shr eax, 21                                 ; owner slot
    cmp eax, MAX_CLIENTS
    jae .mw_check_sub
    mov r14d, eax                               ; owner slot
    mov edi, r14d
    mov esi, [r12]                              ; event window = the window
    mov edx, [r12]                              ; window = itself
    call send_map_notify
    mov edi, r14d
    mov rsi, r12                                ; window record
    call send_configure_notify
.mw_check_sub:
    ; Newly viewable + ExposureMask selected → the window's owner gets a
    ; full-window Expose (X semantics: paint now). scrot -s re-maps its
    ; shaped overlay and BLOCKS waiting for exactly this event.
    test dword [r12 + 24], 0x8000               ; ExposureMask
    jz .mw_no_expose
    mov eax, [r12]
    cmp eax, X_RID_BASE
    jb .mw_no_expose
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .mw_no_expose
    mov edi, eax                                ; owner slot
    mov esi, [r12]                              ; window
    xor edx, edx                                ; x
    xor ecx, ecx                                ; y
    movzx r8d, word [r12 + 12]                  ; width
    movzx r9d, word [r12 + 14]                  ; height
    call send_expose
.mw_no_expose:
    ; Parent's SubstructureNotify subscriber: root → the WM's redirect
    ; owner; other parents → the parent's owner client (a bar owner must
    ; see children map).
    test r13, r13
    jz .mw_done
    mov eax, [r13 + 24]
    test eax, EM_SUBSTRUCTURE_NOTIFY
    jz .mw_done
    cmp dword [r13], X_ROOT_WINDOW
    jne .mw_sub_owner
    movsx r14d, byte [r13 + 30]
    cmp r14d, 0
    jl .mw_done
    jmp .mw_sub_send
.mw_sub_owner:
    mov r14d, [r13]
    sub r14d, X_RID_BASE
    shr r14d, 21
    cmp r14d, MAX_CLIENTS
    jae .mw_done
.mw_sub_send:
    cmp r14d, ebx                              ; skip echo to the requester
    je .mw_done
    mov edi, r14d
    mov esi, [r13]                             ; parent xid (the event window)
    mov edx, [r12]                             ; child xid
    call send_map_notify
.mw_done:
    call sync_pointer_window
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_unmap_window — symmetric to handle_map_window. (UnmapWindow is
; NOT redirected — substructure redirect applies only to MapWindow,
; ConfigureWindow, CirculateWindow.) Sends UnmapNotify to substructure
; notify subscribers.
; ============================================================================
handle_unmap_window:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov edi, [rsi + 4]
    call window_lookup
    test rax, rax
    jz .uw_done
    mov r12, rax
    mov byte [r12 + 28], 0
    mov byte [comp_dirty], 1
    mov rdi, r12
    call damage_add_window
    mov eax, [r12]                            ; if this window held the grab, drop it
    cmp eax, [ptr_grab_win]
    jne .uw_nograb
    mov dword [ptr_grab_win], 0
    mov dword [ptr_grab_cursor], 0
    mov byte [ptr_grab_xi2], 0
.uw_nograb:
    mov eax, [r12]                            ; keyboard grab too (GTK menus
    cmp eax, [active_kbd_window]              ; grab both; a badly-closed menu
    jne .uw_nokbd                             ; must not wedge key input)
    mov dword [active_kbd_slot], -1
    mov dword [active_kbd_window], 0
    mov byte [kbd_grab_xi2], 0
.uw_nokbd:
    ; Send the window its OWN UnmapNotify (StructureNotify) — mirrors the
    ; MapNotify in handle_map_window. Without it GTK's map/unmap freeze/thaw
    ; underflows (Gdk-CRITICAL thaw assertion -> GIMP aborts on menu use).
    mov eax, [r12 + 24]
    test eax, EM_STRUCTURE_NOTIFY
    jz .uw_no_self
    mov eax, [r12]                            ; window xid -> owner slot
    cmp eax, X_RID_BASE
    jb .uw_no_self
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .uw_no_self
    mov edi, eax
    mov esi, [r12]                            ; event window = the window
    mov edx, [r12]                            ; window = itself
    call send_unmap_notify
.uw_no_self:
    mov rdi, r12                              ; Expose the region it was covering
    call expose_under_window
    mov edi, [r12 + 4]
    call window_lookup
    test rax, rax
    jz .uw_done
    mov r13, rax
    mov eax, [r13 + 24]
    test eax, EM_SUBSTRUCTURE_NOTIFY
    jz .uw_done
    ; Subscriber: root → the WM's redirect owner; any other parent → the
    ; parent's OWNER client (strip must hear a tray icon's unmap — GTK's
    ; SNI switch unmaps its XEmbed icon; redirect_owner is -1 on a bar).
    cmp dword [r13], X_ROOT_WINDOW
    jne .uw_sub_owner
    movsx r14d, byte [r13 + 30]
    cmp r14d, 0
    jl .uw_done
    jmp .uw_sub_send
.uw_sub_owner:
    mov r14d, [r13]
    sub r14d, X_RID_BASE
    shr r14d, 21
    cmp r14d, MAX_CLIENTS
    jae .uw_done
.uw_sub_send:
    cmp r14d, ebx                             ; skip echo to the requester
    je .uw_done
    mov edi, r14d
    mov esi, [r13]
    mov edx, [r12]
    call send_unmap_notify
.uw_done:
    call sync_pointer_window
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_configure_window — edi = slot, rsi = req ptr, edx = req size.
; Updates the window's geometry / border / (stacking ignored).
;
; Request:
;   +0 opcode (12)        +1 0
;   +2 length             +4 window
;   +8 value-mask (u16)   +10 pad (2)
;   +12 value-list (CARD32×N)
;
; CFG bit → field:
;   CFG_X (bit 0)            → x  (INT16 in low half of CARD32)
;   CFG_Y (bit 1)            → y  (INT16)
;   CFG_WIDTH (bit 2)        → width (CARD16)
;   CFG_HEIGHT (bit 3)       → height (CARD16)
;   CFG_BORDER_WIDTH (bit 4) → border (CARD16)
;   CFG_SIBLING (bit 5)      → ignored (no stacking yet)
;   CFG_STACK_MODE (bit 6)   → ignored
;
; No reply.
; ============================================================================
handle_configure_window:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov r12, rsi
    mov edi, [r12 + 4]
    call window_lookup
    test rax, rax
    jnz .cfgw_have
    mov edi, ebx                             ; window gone → BadWindow
    mov esi, [r12 + 4]
    mov edx, 12
    call send_bad_window
    jmp .cfgw_done
.cfgw_have:
    mov r13, rax                             ; record ptr

    ; Override-redirect windows (menus, tooltips, DND, combo popups) bypass
    ; SubstructureRedirect — like map, their ConfigureWindow must be applied
    ; directly, never sent to the WM. Without this a menu popup and its item
    ; windows never get positioned or sized: they stay at GTK's 1x1/-1,-1
    ; creation geometry, so the menu renders wrong and no click can land on an
    ; item (handle_map_window already does this check; handle_configure_window
    ; was missing it).
    cmp byte [r13 + 29], 0
    jne .cfgw_apply
    ; SubstructureRedirect check on parent.
    push rax
    mov edi, [r13 + 4]                       ; parent xid
    call window_lookup
    mov r15, rax                             ; parent record (may be 0)
    pop rax
    test r15, r15
    jz .cfgw_apply
    movsx eax, byte [r15 + 30]
    cmp eax, 0
    jl .cfgw_apply
    cmp eax, ebx
    je .cfgw_apply                           ; requester IS the WM → apply
    ; Redirect: send ConfigureRequest to the WM.
    mov edi, eax                              ; owner slot
    mov rsi, r12                              ; req ptr (has all the fields)
    mov edx, [r13]                            ; window xid
    mov ecx, [r15]                            ; parent xid
    call send_configure_request
    jmp .cfgw_done

.cfgw_apply:
    mov rax, [r13 + 8]                        ; latch pre-change x,y,w,h
    mov [cfgw_old_rect], rax
    movzx ecx, word [r12 + 8]                ; value-mask
    lea r14, [r12 + 12]                      ; cursor in value-list
.cfgw_loop:
    test ecx, CFG_X
    jz .cfgw_y
    mov eax, [r14]
    mov [r13 + 8], ax                        ; x (s16)
    add r14, 4
.cfgw_y:
    test ecx, CFG_Y
    jz .cfgw_w
    mov eax, [r14]
    mov [r13 + 10], ax
    add r14, 4
.cfgw_w:
    test ecx, CFG_WIDTH
    jz .cfgw_h
    mov eax, [r14]
    mov [r13 + 12], ax
    add r14, 4
.cfgw_h:
    test ecx, CFG_HEIGHT
    jz .cfgw_b
    mov eax, [r14]
    mov [r13 + 14], ax
    add r14, 4
.cfgw_b:
    test ecx, CFG_BORDER_WIDTH
    jz .cfgw_skip_stacking
    mov eax, [r14]
    mov [r13 + 16], ax
    add r14, 4
.cfgw_skip_stacking:
    ; Sibling/StackMode words are consumed only to keep the cursor honest;
    ; phase 4b doesn't model stacking.
    test ecx, CFG_SIBLING
    jz .cfgw_no_sib
    add r14, 4
.cfgw_no_sib:
    test ecx, CFG_STACK_MODE
    jz .cfgw_apply_done
    mov eax, [r14]                            ; stack-mode value (al = mode)
    add r14, 4
    test al, al                               ; Above (0) → raise to top of z-order
    jnz .cfgw_apply_done
    inc dword [win_stk_next]
    mov eax, [win_stk_next]
    mov [r13 + 48], eax
    mov byte [comp_dirty], 1
    mov rdi, r13                              ; raise reveals the whole window
    call damage_add_window
.cfgw_apply_done:
    ; If the window resized and has a backing at the old size, REPLACE it
    ; with a fresh back_pixel-filled one and copy the old content's
    ; overlap in. Dropping the backing outright (old behaviour) let the
    ; WALLPAPER shine through every re-tiled window until its client
    ; repainted — a background flash on each new-window launch.
    cmp byte [r13 + 31], 0
    je .cfgw_recomp
    movzx eax, word [r13 + 40]               ; backing_w
    cmp ax, [r13 + 12]                        ; width
    jne .cfgw_resize_backing
    movzx eax, word [r13 + 42]               ; backing_h
    cmp ax, [r13 + 14]                        ; height
    je .cfgw_recomp
.cfgw_resize_backing:
    push qword [r13 + 32]                     ; old ptr
    movzx eax, word [r13 + 40]
    push rax                                  ; old w
    movzx eax, word [r13 + 42]
    push rax                                  ; old h
    mov byte [r13 + 31], 0                    ; force a fresh allocation
    mov qword [r13 + 32], 0
    mov rdi, r13
    call window_ensure_backing                ; new size, back_pixel-filled
    test rax, rax
    jz .cfgw_rz_free                          ; alloc failed → just drop old
    mov edx, [rsp + 8]                        ; copy cols = min(old w, new w)
    movzx eax, word [r13 + 40]
    cmp edx, eax
    cmovg edx, eax
    mov ecx, [rsp]                            ; copy rows = min(old h, new h)
    movzx eax, word [r13 + 42]
    cmp ecx, eax
    cmovg ecx, eax
    test edx, edx
    jz .cfgw_rz_free
    mov r14, [rsp + 16]                       ; old base
    mov r15d, [rsp + 8]                       ; old stride (px)
    xor ebx, ebx                              ; row
.cfgw_rz_row:
    cmp ebx, ecx
    jge .cfgw_rz_free
    mov eax, ebx
    imul eax, r15d
    lea rsi, [r14 + rax*4]                    ; old row
    movzx eax, word [r13 + 40]
    imul eax, ebx
    mov rdi, [r13 + 32]
    lea rdi, [rdi + rax*4]                    ; new row
    push rcx
    mov ecx, edx
    rep movsd
    pop rcx
    inc ebx
    jmp .cfgw_rz_row
.cfgw_rz_free:
    mov rax, SYS_MUNMAP
    mov rdi, [rsp + 16]                       ; old ptr
    mov esi, [rsp + 8]
    imul esi, [rsp]                           ; old w * old h
    shl esi, 2
    syscall
    add rsp, 24
.cfgw_recomp:
    mov byte [comp_dirty], 1
    mov edi, [r13 + 4]                        ; parent's abs origin (old x/y are
    call window_abs_xy                        ; parent-local) → r10d/r11d
    mov rax, [cfgw_old_rect]                  ; damage the OLD rect
    movsx r9d, ax                             ; x
    add r9d, r10d
    shr rax, 16
    movsx edx, ax                             ; y
    add edx, r11d
    shr rax, 16
    movzx ecx, ax                             ; w
    shr rax, 16
    movzx r8d, ax                             ; h
    mov eax, r9d                              ; x
    movzx esi, word [r13 + 16]                ; include the border ring
    sub eax, esi
    sub edx, esi
    lea ecx, [rcx + rsi*2]
    lea r8d, [r8 + rsi*2]
    call damage_add
    mov rdi, r13                              ; ...and the NEW rect
    call damage_add_window
    ; Tell the window's own client its new geometry (StructureNotify). A real
    ; server sends ConfigureNotify on every reconfigure — including the ones a
    ; WM drives. GTK freezes its toplevel when it requests a resize and thaws
    ; on this notify; without it the window stays frozen (renders black) and
    ; GTK's freeze count drifts into the 'freeze_count > 0' abort. Unsolicited
    ; notifies are safe: GTK only thaws while its request count is nonzero.
    ; Owner slot is encoded in the xid: (xid - X_RID_BASE) >> 21 (as at map).
    mov eax, [r13 + 24]
    test eax, EM_STRUCTURE_NOTIFY
    jz .cfgw_done
    mov eax, [r13]
    cmp eax, X_RID_BASE
    jb .cfgw_done
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .cfgw_done
    mov edi, eax
    mov rsi, r13
    call send_configure_notify
.cfgw_done:
    call sync_pointer_window
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4c — property storage.
; ============================================================================
; Per-window properties keyed by (xid, atom). Records held in a flat
; 1024-slot table; value bytes appended to a 256 KB pool. The pool is
; append-only: ChangeProperty.Replace allocates new pool space and
; leaks the old. A full session of tile + glass + firefox usually
; settles below 100 KB of property storage; if a long-running session
; ever fills the pool, ChangeProperty silently drops new sets (real
; X servers would generate BadAlloc; we'll add error events later).
; ============================================================================

; ----------------------------------------------------------------------------
; init_properties — zero the table + reset pool watermark.
; ----------------------------------------------------------------------------
init_properties:
    push rbx
    lea rdi, [properties]
    xor eax, eax
    mov ecx, MAX_PROPERTIES * PROPERTY_REC_SIZE
    rep stosb
    mov dword [property_values_used], 0
    pop rbx
    ret

; ----------------------------------------------------------------------------
; property_find — edi = window, esi = atom. Returns ptr to record or 0.
; ----------------------------------------------------------------------------
property_find:
    push rbx
    xor ebx, ebx
.pf_loop:
    cmp ebx, MAX_PROPERTIES
    jge .pf_miss
    mov rax, rbx
    imul rax, PROPERTY_REC_SIZE
    lea rax, [properties + rax]
    cmp [rax], edi
    jne .pf_next
    cmp [rax + 4], esi
    je .pf_hit
.pf_next:
    inc ebx
    jmp .pf_loop
.pf_hit:
    pop rbx
    ret
.pf_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; property_alloc — edi = window, esi = atom. Either returns the existing
; record (so callers can update in place) or finds an empty slot, marks
; it with (window, atom), and returns it. 0 if table is full.
; ----------------------------------------------------------------------------
property_alloc:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov edi, r12d
    mov esi, r13d
    call property_find
    test rax, rax
    jnz .pa_done
    xor ebx, ebx
.pa_loop:
    cmp ebx, MAX_PROPERTIES
    jge .pa_full
    mov rax, rbx
    imul rax, PROPERTY_REC_SIZE
    lea rax, [properties + rax]
    cmp dword [rax], 0
    je .pa_take
    inc ebx
    jmp .pa_loop
.pa_take:
    mov [rax], r12d
    mov [rax + 4], r13d
.pa_done:
    pop r13
    pop r12
    pop rbx
    ret
.pa_full:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; property_value_alloc — edi = nbytes. Allocates from the value pool;
; returns offset in eax (>=0), or -1 if out of space.
; ----------------------------------------------------------------------------
property_value_alloc:
    mov eax, [property_values_used]
    mov ecx, eax
    add ecx, edi
    cmp ecx, PROPERTY_VALUES_CAP
    ja .pva_full
    mov [property_values_used], ecx
    ret
.pva_full:
    mov eax, -1
    ret

; ============================================================================
; handle_change_property — edi = slot, rsi = request ptr.
;
; Request:
;   +0 opcode (18)        +1 mode (0=Replace 1=Prepend 2=Append)
;   +2 length             +4 window
;   +8 property (atom)    +12 type (atom)
;   +16 format (8/16/32)  +17 pad (3)
;   +20 length-of-data (in format-units)
;   +24 data
;
; nbytes = length-of-data * (format / 8).
;
; No reply.
; ============================================================================
handle_change_property:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov r12, rsi                             ; req ptr

    ; nbytes = data_units × format/8
    movzx eax, byte [r12 + 16]               ; format
    mov ecx, [r12 + 20]                      ; data units
    cmp eax, 16
    je .cp_n16
    cmp eax, 32
    je .cp_n32
    ; format 8 → 1 byte/unit
    jmp .cp_n_set
.cp_n16:
    shl ecx, 1
    jmp .cp_n_set
.cp_n32:
    shl ecx, 2
.cp_n_set:
    mov r13d, ecx                            ; nbytes for new data

    ; Allocate / fetch record.
    mov edi, [r12 + 4]                       ; window
    mov esi, [r12 + 8]                       ; atom
    call property_alloc
    test rax, rax
    jz .cp_done
    mov r14, rax                             ; record ptr

    movzx eax, byte [r12 + 1]                ; mode
    test eax, eax
    je .cp_replace
    ; Prepend (1) or Append (2): combined length = old + new.
    mov edx, [r14 + 16]                      ; old nbytes
    mov edi, edx
    add edi, r13d                            ; total
    push rax                                  ; mode
    call property_value_alloc
    pop rcx                                   ; mode
    cmp eax, -1
    je .cp_done
    mov r15d, eax                            ; new value offset
    ; Compose at property_values + r15.
    lea rdi, [property_values + r15]
    cmp ecx, 1
    je .cp_prepend
    ; Append: old then new
    mov esi, [r14 + 20]                      ; old offset
    lea rsi, [property_values + rsi]
    mov ecx, [r14 + 16]                      ; old nbytes
    rep movsb
    lea rsi, [r12 + 24]                      ; new data ptr
    mov ecx, r13d
    rep movsb
    jmp .cp_finalise_combined
.cp_prepend:
    lea rsi, [r12 + 24]                      ; new data first
    mov ecx, r13d
    rep movsb
    mov esi, [r14 + 20]
    lea rsi, [property_values + rsi]
    mov ecx, [r14 + 16]
    rep movsb
.cp_finalise_combined:
    mov ecx, [r14 + 16]
    add ecx, r13d
    mov [r14 + 16], ecx                      ; nbytes
    mov [r14 + 20], r15d                     ; value_off
    mov ecx, [r12 + 12]
    mov [r14 + 8], ecx                       ; type
    movzx ecx, byte [r12 + 16]
    mov [r14 + 12], cl                       ; format
    jmp .cp_notify

.cp_replace:
    ; Allocate pool space and copy the new data.
    mov edi, r13d
    call property_value_alloc
    cmp eax, -1
    je .cp_done
    mov r15d, eax                            ; offset
    lea rdi, [property_values + r15]
    lea rsi, [r12 + 24]
    mov ecx, r13d
    rep movsb
    mov [r14 + 16], r13d                     ; nbytes
    mov [r14 + 20], r15d                     ; value_off
    mov ecx, [r12 + 12]
    mov [r14 + 8], ecx                       ; type
    movzx ecx, byte [r12 + 16]
    mov [r14 + 12], cl                       ; format

.cp_notify:
    mov edi, [r12 + 4]                       ; window
    mov esi, [r12 + 8]                       ; atom
    xor edx, edx                             ; state = 0 (NewValue)
    call send_property_notify

.cp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_delete_property — edi = slot, rsi = request ptr.
;
; Request: +4 window, +8 property
;
; No reply.
; ============================================================================
handle_delete_property:
    push rbx
    push r12
    mov edi, [rsi + 4]                       ; window
    mov r12d, edi
    mov ebx, [rsi + 8]                       ; atom
    mov esi, ebx
    call property_find
    test rax, rax
    jz .dp_done
    mov dword [rax], 0                       ; mark empty
    mov edi, r12d
    mov esi, ebx
    mov edx, 1                               ; state = 1 (Deleted)
    call send_property_notify
.dp_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_property_notify — edi = window xid, esi = atom, edx = state (0/1).
; PropertyNotify (28): +4 window, +8 atom, +12 time, +16 state.
; Emits to the window's owner client if PropertyChangeMask is in the
; window's (combined) event mask. Root properties broadcast to every
; live client (frame keeps one mask per window; root has many
; listeners, e.g. strip watching tile's EWMH properties).
; ----------------------------------------------------------------------------
send_property_notify:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi                            ; window
    mov r13d, esi                            ; atom
    mov r14d, edx                            ; state
    call window_lookup
    test rax, rax
    jz .spn_done
    test dword [rax + 24], EM_PROPERTY_CHANGE
    jz .spn_done
    ; Fresh timestamp, not the last-input one: Qt and GTK learn "server
    ; time" from THIS event's time field (their zero-length-property
    ; dance), then Qt refuses to serve selections it acquired at time 0 —
    ; a stale/zero stamp here is why copyq owned CLIPBOARD but answered
    ; every ConvertSelection with a property=None refusal.
    call now_real_ms
    mov [server_time_ms], eax
    lea rdi, [pn_buf]
    mov dword [rdi], 28                      ; code 28, rest of dword 0
    mov [rdi + 4], r12d                      ; window
    mov [rdi + 8], r13d                      ; atom
    mov eax, [server_time_ms]
    mov [rdi + 12], eax                      ; time
    mov [rdi + 16], r14d                     ; state (+3 pad bytes)
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    cmp r12d, X_ROOT_WINDOW
    je .spn_root
    cmp r12d, X_RID_BASE
    jb .spn_done
    mov eax, r12d
    sub eax, X_RID_BASE
    shr eax, 21                              ; owner slot
    cmp eax, MAX_CLIENTS
    jae .spn_done
    mov ebx, eax
    call client_meta_addr                    ; eax = slot
    cmp dword [rax], -1                      ; fd live?
    je .spn_done
    mov edi, ebx
    lea rsi, [pn_buf]
    call send_event_to_slot
    jmp .spn_done
.spn_root:
    xor ebx, ebx
.spn_root_loop:
    cmp ebx, MAX_CLIENTS
    jge .spn_done
    mov eax, ebx
    call client_meta_addr
    cmp dword [rax], -1
    je .spn_root_next
    cmp byte [rax + 4], CSTATE_RUNNING       ; never write events into a
    jne .spn_root_next                       ; handshake still in progress
    mov edi, ebx
    lea rsi, [pn_buf]
    call send_event_to_slot
.spn_root_next:
    inc ebx
    jmp .spn_root_loop
.spn_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_get_atom_name — edi = slot, rsi = request ptr. Reverse-lookup
; from atom ID to name string. Returns the name string from the table
; we built in init_atoms (predefined atoms 1..68) plus any IDs added
; later by InternAtom.
;
; Request: +4 atom (CARD32)
;
; Reply (32 + name-bytes + pad):
;   +0 1                  +1 0
;   +2 seq                +4 reply length = ceil(name_len / 4)
;   +8 name length u16    +10 pad (22)
;   +32..32+n name        +32+n.. pad to 4
; ============================================================================
handle_get_atom_name:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r14, rsi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    mov r13d, [r14 + 4]                      ; atom id
    ; Bounds check.
    cmp r13d, [atom_count]
    jae .gan_zero
    test r13d, r13d
    jz .gan_zero
    mov ecx, [atom_off + r13*4]              ; string offset
    mov edx, [atom_len + r13*4]              ; string length

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov eax, [r12 + 8]
    mov [rdi + 2], ax
    mov eax, edx
    add eax, 3
    shr eax, 2
    mov [rdi + 4], eax                       ; reply length
    mov [rdi + 8], dx                        ; name length
    mov word [rdi + 10], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; Copy name into reply_buf + 32.
    lea rsi, [atom_strings + rcx]
    lea rdi, [reply_buf + 32]
    mov ecx, edx
    rep movsb

    ; Pad to 4.
    mov ecx, edx
    add ecx, 3
    and ecx, ~3
    mov r9d, ecx                             ; total body bytes (padded)
    sub ecx, edx
    xor eax, eax
    rep stosb

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, r9d
    add edx, 32
    syscall
    jmp .gan_done

.gan_zero:
    ; Unknown atom id — return empty name. (Real X servers would emit
    ; a BadAtom error; we permit-and-empty for now.)
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov eax, [r12 + 8]
    mov [rdi + 2], ax
    mov dword [rdi + 4], 0
    mov word [rdi + 8], 0                    ; name length 0
    mov word [rdi + 10], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

.gan_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_list_properties — edi = slot, rsi = request ptr.
;
; Request: +4 window
;
; Reply (32 + 4N bytes):
;   +0 1                  +1 0
;   +2 seq                +4 reply length N
;   +8 nAtoms u16         +10 pad (22)
;   +32..32+4N atoms
; ============================================================================
handle_list_properties:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov r14, rsi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    mov r13d, [r14 + 4]                      ; window xid
    xor r15d, r15d                           ; count
    lea rdi, [reply_buf + 32]
    xor ecx, ecx
.lp_walk:
    cmp ecx, MAX_PROPERTIES
    jge .lp_emit
    mov rax, rcx
    imul rax, PROPERTY_REC_SIZE
    lea rdx, [properties + rax]
    mov eax, [rdx]
    test eax, eax
    jz .lp_walk_next
    cmp eax, r13d
    jne .lp_walk_next
    mov eax, [rdx + 4]
    mov [rdi], eax
    add rdi, 4
    inc r15d
.lp_walk_next:
    inc ecx
    jmp .lp_walk
.lp_emit:
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov [rdi + 4], r15d                      ; reply length
    mov [rdi + 8], r15w                      ; nAtoms
    mov word [rdi + 10], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, r15
    shl rdx, 2
    add rdx, 32
    syscall

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4d.1 — input API surface (grab tables + real keysym table).
; ============================================================================
; This phase ships the X-side API a WM uses to set up its input model:
; GrabKey records a key/modifier combination as routed-to-this-client;
; GrabKeyboard claims exclusive keyboard access; GetKeyboardMapping
; returns real US-layout keysyms instead of NoSymbol stubs. Phase 4d.2
; (next commit) wires the kernel evdev fds into the serve loop so
; physical key presses actually become KeyPress events.
; ============================================================================

; ----------------------------------------------------------------------------
; KS — set keysym_table[X11_KC] level 1/2 (unshifted + shifted).
; KSA — set level 3/4 (AltGr + AltGr+Shift), at indices 4/5.
; ----------------------------------------------------------------------------
%macro KS 3
    mov dword [keysym_table + (%1 - X_MIN_KEYCODE) * 24 + 0], %2
    mov dword [keysym_table + (%1 - X_MIN_KEYCODE) * 24 + 4], %3
%endmacro
%macro KSA 3
    mov dword [keysym_table + (%1 - X_MIN_KEYCODE) * 24 + 16], %2
    mov dword [keysym_table + (%1 - X_MIN_KEYCODE) * 24 + 20], %3
%endmacro

; SCALE_SENS — scale the cursor delta in eax by mouse_sens%: eax = eax*sens/100.
; Clobbers edx (and eax). mouse_sens defaults to 100 (= no change).
%macro SCALE_SENS 0
    imul eax, [mouse_sens]
    cdq
    idiv dword [const_100]
%endmacro

; X11 keysym values (subset of keysymdef.h we use).
%define XK_BackSpace    0xFF08
%define XK_Tab          0xFF09
%define XK_Return       0xFF0D
%define XK_Escape       0xFF1B
%define XK_space        0x0020
%define XK_F1           0xFFBE
%define XK_F2           0xFFBF
%define XK_F3           0xFFC0
%define XK_F4           0xFFC1
%define XK_F5           0xFFC2
%define XK_F6           0xFFC3
%define XK_F7           0xFFC4
%define XK_F8           0xFFC5
%define XK_F9           0xFFC6
%define XK_F10          0xFFC7
%define XK_F11          0xFFC8
%define XK_F12          0xFFC9
%define XK_Caps_Lock    0xFFE5
%define XK_Shift_L      0xFFE1
%define XK_Shift_R      0xFFE2
%define XK_Control_L    0xFFE3
%define XK_Control_R    0xFFE4
%define XK_Alt_L        0xFFE9
%define XK_Alt_R        0xFFEA
%define XK_Super_L      0xFFEB
%define XK_Super_R      0xFFEC
%define XK_Left         0xFF51
%define XK_Up           0xFF52
%define XK_Right        0xFF53
%define XK_Down         0xFF54
%define XK_Prior        0xFF55              ; Page_Up
%define XK_Next         0xFF56              ; Page_Down
%define XK_Home         0xFF50
%define XK_End          0xFF57
%define XK_Insert       0xFF63
%define XK_Delete       0xFFFF
%define XK_Print        0xFF61
%define XF86_AudioMute          0x1008FF12
%define XF86_AudioLowerVolume   0x1008FF11
%define XF86_AudioRaiseVolume   0x1008FF13
%define XF86_MonBrightnessDown  0x1008FF03
%define XF86_MonBrightnessUp    0x1008FF02

; ----------------------------------------------------------------------------
; read_framerc — read ~/.framerc and set keymap_is_no from a `keymap = no`
; line. No file / no key → keymap_is_no stays 0 (US default). Called once at
; startup, before init_keysyms. Line-based key=value, the CHasm rc convention.
; ----------------------------------------------------------------------------
read_framerc:
    push rbx
    mov dword [mouse_sens], 100               ; defaults before parsing
    mov dword [cursor_rgb], 0xFFFFFF
    mov dword [cursor_transp], 50
    mov dword [cfg_cursor_accent], 0xFF00C800 ; pressable-item arrow fill (green)
    ; --- locate HOME in envp ---
    mov rsi, [envp]
    test rsi, rsi
    jz .rf_done
.rf_env:
    mov rdi, [rsi]
    test rdi, rdi
    jz .rf_done                              ; end of envp, no HOME
    cmp dword [rdi], 'HOME'
    jne .rf_env_next
    cmp byte [rdi + 4], '='
    je .rf_home
.rf_env_next:
    add rsi, 8
    jmp .rf_env
.rf_home:
    add rdi, 5                               ; → HOME value
    lea rbx, [framerc_path]
.rf_cp:
    mov al, [rdi]
    test al, al
    jz .rf_cp_done
    mov [rbx], al
    inc rdi
    inc rbx
    jmp .rf_cp
.rf_cp_done:
    lea rsi, [str_framerc]                    ; append "/.framerc\0"
.rf_app:
    mov al, [rsi]
    mov [rbx], al
    test al, al
    jz .rf_open
    inc rsi
    inc rbx
    jmp .rf_app
.rf_open:
    mov rax, SYS_OPEN
    lea rdi, [framerc_path]
    xor esi, esi                             ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .rf_done                              ; no ~/.framerc → US default
    mov rbx, rax                             ; fd
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [framerc_buf]
    mov edx, 2047
    syscall
    push rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    pop rax
    test rax, rax
    jle .rf_done
    lea rsi, [framerc_buf]
    mov byte [rsi + rax], 0                   ; NUL-terminate
    call parse_framerc
.rf_done:
    call compute_cursor_argb                  ; fold colour+transparency → pixel
    pop rbx
    ret

; compute_cursor_argb — build the premultiplied ARGB interior pixel from
; cursor_rgb (0xRRGGBB) and cursor_transp (% transparent). Premultiplied
; because the DRM cursor plane blends that way. alpha = 100-transp percent;
; each channel is scaled by that alpha. Default white/50% → 0x80808080.
compute_cursor_argb:
    push rbx
    mov eax, 100
    sub eax, [cursor_transp]                  ; alpha % = 100 - transp
    jns .cca_lo
    xor eax, eax
.cca_lo:
    cmp eax, 100
    jbe .cca_hi
    mov eax, 100
.cca_hi:
    mov ebx, eax                              ; ebx = alpha % (0..100)
    mov eax, ebx                              ; alpha byte = a%*255/100
    imul eax, 255
    xor edx, edx
    div dword [const_100]
    shl eax, 24
    mov ecx, eax                              ; ecx = pixel accumulator
    mov eax, [cursor_rgb]                     ; R' = R*a%/100
    shr eax, 16
    and eax, 0xFF
    imul eax, ebx
    xor edx, edx
    div dword [const_100]
    shl eax, 16
    or ecx, eax
    mov eax, [cursor_rgb]                     ; G'
    shr eax, 8
    and eax, 0xFF
    imul eax, ebx
    xor edx, edx
    div dword [const_100]
    shl eax, 8
    or ecx, eax
    mov eax, [cursor_rgb]                     ; B'
    and eax, 0xFF
    imul eax, ebx
    xor edx, edx
    div dword [const_100]
    or ecx, eax
    mov [cursor_argb], ecx
    pop rbx
    ret

; parse_framerc — scan framerc_buf for a `keymap` line; if its value is "no",
; set keymap_is_no. First match wins; anything else leaves the US default.
parse_framerc:
    lea rsi, [framerc_buf]
.pf_line:
    mov al, [rsi]
    test al, al
    jz .pf_ret
.pf_skip_ws:
    mov al, [rsi]
    cmp al, ' '
    je .pf_ws_adv
    cmp al, 9
    je .pf_ws_adv
    jmp .pf_key
.pf_ws_adv:
    inc rsi
    jmp .pf_skip_ws
.pf_key:
    ; keymap = no ?
    mov eax, [rsi]
    cmp eax, 'keym'
    jne .pf_chk_keycode
    mov ax, [rsi + 4]
    cmp ax, 'ap'
    jne .pf_chk_keycode
    call pf_to_value
    cmp byte [rsi], 'n'
    jne .pf_next_line
    cmp byte [rsi + 1], 'o'
    jne .pf_next_line
    mov byte [keymap_is_no], 1
    jmp .pf_next_line
.pf_chk_keycode:
    ; keycode N = SYM [SYM ...]   (xmodmap-mirror syntax, max 16 lines,
    ; max 6 syms; names, single chars, or 0xHEX)
    mov eax, [rsi]
    cmp eax, 'keyc'
    jne .pf_chk_sens
    push rbx
    push r12
    push r13
    call pf_to_value                          ; skip "keycode" + ws → digits
    call pf_parse_dec                         ; eax = X keycode
    cmp eax, X_MIN_KEYCODE
    jb .pf_kc_bad
    cmp eax, 255
    ja .pf_kc_bad
    mov ecx, [rc_remap_count]
    cmp ecx, 16
    jge .pf_kc_bad
    imul edx, ecx, 28
    lea rbx, [rc_remaps + rdx]                ; staging entry
    mov [rbx], eax
    xor eax, eax
    mov [rbx + 4], eax
    mov [rbx + 8], eax
    mov [rbx + 12], eax
    mov [rbx + 16], eax
    mov [rbx + 20], eax
    mov [rbx + 24], eax
    call pf_to_value                          ; skip ws + '=' → first token
    xor r12d, r12d                            ; sym column
.pf_kc_tok:
    cmp r12d, 6
    jge .pf_kc_commit
.pf_kc_tok_ws:
    mov al, [rsi]
    cmp al, ' '
    je .pf_kc_tok_adv
    cmp al, 9
    je .pf_kc_tok_adv
    jmp .pf_kc_tok_start
.pf_kc_tok_adv:
    inc rsi
    jmp .pf_kc_tok_ws
.pf_kc_tok_start:
    test al, al
    jz .pf_kc_commit
    cmp al, 10
    je .pf_kc_commit
    cmp al, '#'
    je .pf_kc_commit
    mov r13, rsi                              ; token start
.pf_kc_tok_end:
    mov al, [rsi]
    test al, al
    jz .pf_kc_resolve
    cmp al, 10
    je .pf_kc_resolve
    cmp al, ' '
    je .pf_kc_resolve
    cmp al, 9
    je .pf_kc_resolve
    inc rsi
    jmp .pf_kc_tok_end
.pf_kc_resolve:
    mov rcx, rsi
    sub rcx, r13                              ; token length
    push rsi
    mov rsi, r13
    call pf_resolve_keysym                    ; eax = keysym (0 unknown)
    pop rsi
    mov [rbx + 4 + r12*4], eax
    inc r12d
    jmp .pf_kc_tok
.pf_kc_commit:
    inc dword [rc_remap_count]
.pf_kc_bad:
    pop r13
    pop r12
    pop rbx
    jmp .pf_next_line

.pf_chk_sens:
    ; sensitivity = N ?
    mov eax, [rsi]
    cmp eax, 'sens'
    jne .pf_chk_cursor
    mov ax, [rsi + 4]
    cmp ax, 'it'
    jne .pf_chk_cursor
    call pf_to_value
    call pf_parse_dec
    test eax, eax
    jz .pf_next_line                          ; ignore 0 — would freeze the pointer
    mov [mouse_sens], eax
    jmp .pf_next_line
.pf_chk_cursor:
    ; cursor_color = RRGGBB / cursor_transparency = N / cursor_accent = RRGGBB
    mov eax, [rsi]
    cmp eax, 'curs'
    jne .pf_chk_blank
    mov al, [rsi + 7]                          ; cursor_[c]olor / [t]ransp / [a]ccent
    cmp al, 'c'
    je .pf_cur_color
    cmp al, 'a'
    je .pf_cur_accent
    cmp al, 't'
    jne .pf_next_line
    call pf_to_value
    call pf_parse_dec
    mov [cursor_transp], eax
    jmp .pf_next_line
.pf_cur_color:
    call pf_to_value
    call pf_parse_hex
    mov [cursor_rgb], eax
    jmp .pf_next_line
.pf_cur_accent:
    call pf_to_value
    call pf_parse_hex
    or  eax, 0xFF000000                        ; opaque (premult = itself)
    mov [cfg_cursor_accent], eax
    jmp .pf_next_line
.pf_chk_blank:
    ; blank_timeout = N (seconds of idle before the panel powers off;
    ; 0 disables, default 600), or
    ; blank_key = [Mod+...]SYM (hotkey that blanks the panel NOW;
    ; default Mod4+Escape, `none` disables)
    mov eax, [rsi]
    cmp eax, 'blan'
    jne .pf_chk_bg
    cmp byte [rsi + 6], 'k'                   ; blank_[t]imeout / blank_[k]ey
    je .pf_blank_key
    call pf_to_value
    call pf_parse_dec
    imul eax, eax, 1000                       ; s → ms (0 stays 0 = never)
    mov [cfg_blank_ms], eax
    jmp .pf_next_line
.pf_blank_key:
    call pf_to_value                          ; rsi → "Mod4+F12" / "none"
    mov dword [cfg_blankkey_sym], 0           ; nothing until a sym resolves
    mov byte [cfg_blankkey_mods], 0           ; (so `none` fully disables)
.pf_bk_tok:
    ; token = [rsi, rsi+rcx); ends at '+' (modifier) or ws/EOL (keysym)
    xor ecx, ecx
.pf_bk_len:
    mov al, [rsi + rcx]
    cmp al, '+'
    je .pf_bk_end
    cmp al, ' '
    jbe .pf_bk_end                            ; space, tab, CR, LF, NUL
    inc ecx
    jmp .pf_bk_len
.pf_bk_end:
    test ecx, ecx
    jz .pf_next_line                          ; empty token (trailing '+')
    cmp al, '+'
    jne .pf_bk_sym                            ; last token = the keysym
    ; modifier token: Shift / Ctrl|Control / Alt|Mod1 / Super|Mod4 / Mod5
    mov edx, [rsi]                            ; ≥4 bytes readable ('+' follows)
    cmp ecx, 4
    jne .pf_bk_m5
    cmp edx, 'Mod4'
    je .pf_bk_mod4
    cmp edx, 'Mod1'
    je .pf_bk_mod1
    cmp edx, 'Mod5'
    je .pf_bk_mod5
    cmp edx, 'Ctrl'
    je .pf_bk_ctrl
    jmp .pf_bk_next                           ; unknown modifier: ignore
.pf_bk_m5:
    cmp ecx, 5
    jne .pf_bk_m3
    cmp edx, 'Shif'
    je .pf_bk_shift
    cmp edx, 'Supe'
    je .pf_bk_mod4
    jmp .pf_bk_next
.pf_bk_m3:
    cmp ecx, 3
    jne .pf_bk_m7
    cmp word [rsi], 'Al'
    jne .pf_bk_next
    cmp byte [rsi + 2], 't'
    je .pf_bk_mod1
    jmp .pf_bk_next
.pf_bk_m7:
    cmp ecx, 7
    jne .pf_bk_next
    cmp edx, 'Cont'
    je .pf_bk_ctrl
    jmp .pf_bk_next
.pf_bk_mod4:
    or byte [cfg_blankkey_mods], 0x40         ; MOD_MOD4
    jmp .pf_bk_next
.pf_bk_mod1:
    or byte [cfg_blankkey_mods], 0x08         ; MOD_MOD1
    jmp .pf_bk_next
.pf_bk_mod5:
    or byte [cfg_blankkey_mods], 0x80         ; MOD_MOD5
    jmp .pf_bk_next
.pf_bk_ctrl:
    or byte [cfg_blankkey_mods], 0x04         ; MOD_CONTROL
    jmp .pf_bk_next
.pf_bk_shift:
    or byte [cfg_blankkey_mods], 0x01         ; MOD_SHIFT
.pf_bk_next:
    lea rsi, [rsi + rcx + 1]                  ; past the '+'
    jmp .pf_bk_tok
.pf_bk_sym:
    call pf_resolve_keysym                    ; (rsi,rcx) → eax, 0 if unknown
    mov [cfg_blankkey_sym], eax               ; "none" resolves to 0 = off
    jmp .pf_next_line

.pf_chk_bg:
    ; background = <path to raw BGRX file>
    mov eax, [rsi]
    cmp eax, 'back'
    jne .pf_next_line
    mov eax, [rsi + 4]
    cmp eax, 'grou'
    jne .pf_next_line
    call pf_to_value                          ; rsi → value (path) start
    lea rdi, [wallpaper_path]
    xor ecx, ecx
.pf_bg_copy:
    mov al, [rsi]
    test al, al
    jz .pf_bg_end
    cmp al, 10                                ; newline ends the value
    je .pf_bg_end
    cmp al, 13
    je .pf_bg_end
    mov [rdi + rcx], al
    inc rsi
    inc ecx
    cmp ecx, 255
    jb .pf_bg_copy
.pf_bg_end:
    ; strip trailing spaces/tabs off the path
.pf_bg_trim:
    test ecx, ecx
    jz .pf_bg_term
    mov al, [rdi + rcx - 1]
    cmp al, ' '
    je .pf_bg_dec
    cmp al, 9
    jne .pf_bg_term
.pf_bg_dec:
    dec ecx
    jmp .pf_bg_trim
.pf_bg_term:
    mov byte [rdi + rcx], 0
    jmp .pf_next_line
.pf_next_line:
    mov al, [rsi]
    test al, al
    jz .pf_ret
    inc rsi
    cmp al, 10
    jne .pf_next_line
    jmp .pf_line
.pf_ret:
    ret

; pf_to_value — rsi at a key; skip the key's letters and '_', then ws / '=',
; leaving rsi on the value's first character.
pf_to_value:
.ptv_key:
    mov al, [rsi]
    cmp al, '_'
    je .ptv_key_adv
    cmp al, 'a'
    jb .ptv_sep
    cmp al, 'z'
    ja .ptv_sep
.ptv_key_adv:
    inc rsi
    jmp .ptv_key
.ptv_sep:
    mov al, [rsi]
    cmp al, ' '
    je .ptv_adv
    cmp al, 9
    je .ptv_adv
    cmp al, '='
    je .ptv_adv
    ret
.ptv_adv:
    inc rsi
    jmp .ptv_sep

; pf_resolve_keysym — rsi = token start, rcx = length. Returns eax = keysym,
; 0 if unrecognized. Accepts: a name from ks_names, a single Latin-1 char
; (keysym == codepoint), or 0xHEX.
pf_resolve_keysym:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rcx
    cmp rcx, 1
    jne .prk_hex
    movzx eax, byte [rsi]                    ; single char → Latin-1 keysym
    jmp .prk_ret
.prk_hex:
    cmp rcx, 2
    jbe .prk_names
    cmp word [rsi], '0x'
    jne .prk_names
    add rsi, 2
    call pf_parse_hex
    jmp .prk_ret
.prk_names:
    lea rbx, [ks_names]
.prk_scan:
    cmp byte [rbx], 0                        ; table end
    je .prk_miss
    ; strlen of table name
    xor ecx, ecx
.prk_len:
    cmp byte [rbx + rcx], 0
    je .prk_cmp
    inc ecx
    jmp .prk_len
.prk_cmp:
    cmp rcx, r13
    jne .prk_skip
    ; compare bytes
    xor edx, edx
.prk_cmpb:
    cmp edx, ecx
    je .prk_hit
    mov al, [rbx + rdx]
    cmp al, [r12 + rdx]
    jne .prk_skip
    inc edx
    jmp .prk_cmpb
.prk_hit:
    mov eax, [rbx + rcx + 1]                 ; keysym after NUL
    jmp .prk_ret
.prk_skip:
    lea rbx, [rbx + rcx + 5]                 ; name + NUL + dd
    jmp .prk_scan
.prk_miss:
    xor eax, eax
.prk_ret:
    pop r13
    pop r12
    pop rbx
    ret

; pf_parse_dec — rsi at first digit; eax = decimal value, rsi advanced past it.
pf_parse_dec:
    xor eax, eax
.ppd_loop:
    movzx ecx, byte [rsi]
    cmp cl, '0'
    jb .ppd_done
    cmp cl, '9'
    ja .ppd_done
    imul eax, eax, 10
    sub ecx, '0'
    add eax, ecx
    inc rsi
    jmp .ppd_loop
.ppd_done:
    ret

; pf_parse_hex — rsi at first hex digit; eax = value, rsi advanced. Accepts
; 0-9 a-f A-F (e.g. cursor_color = ff8800).
pf_parse_hex:
    xor eax, eax
.pph_loop:
    movzx ecx, byte [rsi]
    cmp cl, '0'
    jb .pph_done
    cmp cl, '9'
    jbe .pph_dig
    or cl, 0x20                               ; fold to lowercase
    cmp cl, 'a'
    jb .pph_done
    cmp cl, 'f'
    ja .pph_done
    sub ecx, 'a' - 10
    jmp .pph_acc
.pph_dig:
    sub ecx, '0'
.pph_acc:
    shl eax, 4
    or eax, ecx
    inc rsi
    jmp .pph_loop
.pph_done:
    ret

; handle_change_keyboard_mapping — rsi = req. ChangeKeyboardMapping (100,
; void). xmodmap's workhorse: Geir's ~/.Xmodmap remaps physical Esc→F12
; (rofi) and CapsLock→Escape. Writes the request's keysyms into
; keysym_table (m per keycode, table holds 6 — extra columns zeroed), then
; broadcasts MappingNotify so clients re-read the map.
;   +1 keycode-count n   +4 first-keycode   +5 keysyms-per-keycode m
;   +8 n*m CARD32 keysyms
; ----------------------------------------------------------------------------
handle_change_keyboard_mapping:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi
    movzx r12d, byte [rbx + 1]               ; n keycodes
    movzx r13d, byte [rbx + 4]               ; first keycode
    movzx r14d, byte [rbx + 5]               ; m syms per keycode
    test r12d, r12d
    jz .ckm_done
    test r14d, r14d
    jz .ckm_done
    cmp r13d, X_MIN_KEYCODE
    jb .ckm_done
    lea eax, [r13 + r12]
    cmp eax, 256
    ja .ckm_done
    lea r15, [rbx + 8]                       ; keysym cursor
    xor ecx, ecx                             ; keycode index
.ckm_kc:
    cmp ecx, r12d
    jge .ckm_notify
    lea eax, [r13 + rcx]
    sub eax, X_MIN_KEYCODE
    imul eax, eax, 24
    lea rdi, [keysym_table + rax]
    xor edx, edx
.ckm_col:
    cmp edx, 6
    jge .ckm_next
    xor eax, eax                             ; columns past m → NoSymbol
    cmp edx, r14d
    jge .ckm_store
    mov eax, [r15 + rdx*4]
.ckm_store:
    mov [rdi + rdx*4], eax
    inc edx
    jmp .ckm_col
.ckm_next:
    lea r15, [r15 + r14*4]
    inc ecx
    jmp .ckm_kc
.ckm_notify:
    mov edi, 1                               ; request = Keyboard
    mov esi, r13d
    mov edx, r12d
    call send_mapping_notify
.ckm_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_set_modifier_mapping — edi = slot. SetModifierMapping (118).
; xmodmap's `clear Lock` sends this and BLOCKS on the reply. frame's
; modifier tracking is evdev-hardcoded (Ctrl/Shift/Alt/Mod4 by scan code),
; so the map itself is accepted and ignored; reply Success + notify.
; ----------------------------------------------------------------------------
handle_set_modifier_mapping:
    push rbx
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    push rax
    lea rdi, [reply_buf]
    xor ecx, ecx
    mov [rdi], rcx
    mov [rdi + 8], rcx
    mov [rdi + 16], rcx
    mov [rdi + 24], rcx
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; status = Success
    pop rax
    mov ecx, [rax + 8]
    mov [rdi + 2], cx
    mov edi, [rax]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
    xor edi, edi                             ; request = Modifier
    xor esi, esi
    xor edx, edx
    call send_mapping_notify
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_mapping_notify — edi = request (0 Modifier / 1 Keyboard / 2 Pointer),
; esi = first keycode, edx = count. MappingNotify (34) is delivered to ALL
; fully-connected clients regardless of event masks (X11 core semantics).
; ----------------------------------------------------------------------------
send_mapping_notify:
    push rbx
    push r12
    lea rax, [pn_buf]
    xor ecx, ecx
    mov [rax], rcx
    mov [rax + 8], rcx
    mov [rax + 16], rcx
    mov [rax + 24], rcx
    mov byte [rax + 0], 34
    mov [rax + 4], dil                       ; request
    mov [rax + 5], sil                       ; first keycode
    mov [rax + 6], dl                        ; count
    xor ebx, ebx
.smn_loop:
    cmp ebx, MAX_CLIENTS
    jge .smn_done
    mov eax, ebx
    call client_meta_addr
    cmp dword [rax], -1
    je .smn_next
    cmp byte [rax + 4], CSTATE_RUNNING
    jne .smn_next
    mov edi, ebx
    lea rsi, [pn_buf]
    call send_event_to_slot
.smn_next:
    inc ebx
    jmp .smn_loop
.smn_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; init_keysyms — populate keysym_table. Keys shared across layouts are set
; unconditionally; the number row + punctuation branch on keymap_is_no
; (US default, or Norwegian when ~/.framerc has keymap=no).
; ----------------------------------------------------------------------------
init_keysyms:
    lea rdi, [keysym_table]
    xor eax, eax
    mov ecx, KEYCODE_RANGE * 6
    rep stosd

    ; X11 keycode = evdev keycode + 8.
    ; --- Keys identical in every layout: letters, modifiers, whitespace,
    ;     function + navigation keys.
    KS 9,  XK_Escape, XK_Escape
    KS 22, XK_BackSpace, XK_BackSpace
    KS 23, XK_Tab, XK_Tab
    KS 24, 'q', 'Q'
    KS 25, 'w', 'W'
    KS 26, 'e', 'E'
    KS 27, 'r', 'R'
    KS 28, 't', 'T'
    KS 29, 'y', 'Y'
    KS 30, 'u', 'U'
    KS 31, 'i', 'I'
    KS 32, 'o', 'O'
    KS 33, 'p', 'P'
    KS 36, XK_Return, XK_Return
    KS 37, XK_Control_L, XK_Control_L
    KS 38, 'a', 'A'
    KS 39, 's', 'S'
    KS 40, 'd', 'D'
    KS 41, 'f', 'F'
    KS 42, 'g', 'G'
    KS 43, 'h', 'H'
    KS 44, 'j', 'J'
    KS 45, 'k', 'K'
    KS 46, 'l', 'L'
    KS 50, XK_Shift_L, XK_Shift_L
    KS 52, 'z', 'Z'
    KS 53, 'x', 'X'
    KS 54, 'c', 'C'
    KS 55, 'v', 'V'
    KS 56, 'b', 'B'
    KS 57, 'n', 'N'
    KS 58, 'm', 'M'
    KS 62, XK_Shift_R, XK_Shift_R
    KS 64, XK_Alt_L, XK_Alt_L
    KS 65, XK_space, XK_space
    KS 66, XK_Caps_Lock, XK_Caps_Lock
    KS 67, XK_F1, XK_F1
    KS 68, XK_F2, XK_F2
    KS 69, XK_F3, XK_F3
    KS 70, XK_F4, XK_F4
    KS 71, XK_F5, XK_F5
    KS 72, XK_F6, XK_F6
    KS 73, XK_F7, XK_F7
    KS 74, XK_F8, XK_F8
    KS 75, XK_F9, XK_F9
    KS 76, XK_F10, XK_F10
    KS 95, XK_F11, XK_F11
    KS 96, XK_F12, XK_F12
    KS 105, XK_Control_R, XK_Control_R
    KS 108, XK_Alt_R, XK_Alt_R
    KS 111, XK_Up, XK_Up
    KS 113, XK_Left, XK_Left
    KS 114, XK_Right, XK_Right
    KS 116, XK_Down, XK_Down
    KS 133, XK_Super_L, XK_Super_L
    KS 134, XK_Super_R, XK_Super_R
    ; Navigation cluster + Print — tile binds Mod4+Shift+Page_Up/Down;
    ; missing syms meant tile could not resolve those binds on frame.
    KS 107, XK_Print, XK_Print
    KS 110, XK_Home, XK_Home
    KS 112, XK_Prior, XK_Prior
    KS 115, XK_End, XK_End
    KS 117, XK_Next, XK_Next
    KS 118, XK_Insert, XK_Insert
    KS 119, XK_Delete, XK_Delete
    ; XF86 media keys (laptop function row) — tile's volume/brightness
    ; binds resolve against these via GetKeyboardMapping.
    KS 121, XF86_AudioMute, XF86_AudioMute
    KS 122, XF86_AudioLowerVolume, XF86_AudioLowerVolume
    KS 123, XF86_AudioRaiseVolume, XF86_AudioRaiseVolume
    KS 232, XF86_MonBrightnessDown, XF86_MonBrightnessDown
    KS 233, XF86_MonBrightnessUp, XF86_MonBrightnessUp

    ; --- Number row + punctuation: layout-dependent.
    cmp byte [keymap_is_no], 0
    jne .iks_no
    ; US (default)
    KS 10, '1', '!'
    KS 11, '2', '@'
    KS 12, '3', '#'
    KS 13, '4', '$'
    KS 14, '5', '%'
    KS 15, '6', '^'
    KS 16, '7', '&'
    KS 17, '8', '*'
    KS 18, '9', '('
    KS 19, '0', ')'
    KS 20, '-', '_'
    KS 21, '=', '+'
    KS 34, '[', '{'
    KS 35, ']', '}'
    KS 47, ';', ':'
    KS 48, "'", '"'
    KS 49, '`', '~'
    KS 51, '\', '|'
    KS 59, ',', '<'
    KS 60, '.', '>'
    KS 61, '/', '?'
    jmp .iks_remaps
.iks_no:
    ; Norwegian (ISO). Latin-1 keysyms equal their codepoints.
    KS 10, '1', '!'
    KS 11, '2', '"'
    KS 12, '3', '#'
    KS 13, '4', 0xA4              ; 4 / currency ¤
    KS 14, '5', '%'
    KS 15, '6', '&'
    KS 16, '7', '/'
    KS 17, '8', '('
    KS 18, '9', ')'
    KS 19, '0', '='
    KS 20, '+', '?'
    KS 21, '\', '`'              ; backslash / grave
    KS 34, 0xE5, 0xC5            ; å / Å
    KS 35, 0xA8, '^'            ; diaeresis / circumflex
    KS 47, 0xF8, 0xD8            ; ø / Ø
    KS 48, 0xE6, 0xC6            ; æ / Æ
    KS 49, '|', 0xA7            ; bar / section §
    KS 51, 0x27, '*'            ; apostrophe / asterisk
    KS 59, ',', ';'
    KS 60, '.', ':'
    KS 61, '-', '_'
    KS 94, '<', '>'            ; ISO key left of Z
    ; AltGr (level 3): the programming characters.
    KS 108, 0xFE03, 0xFE03      ; right Alt = ISO_Level3_Shift (was Alt_R)
    KSA 11, '@', 0              ; AltGr+2
    KSA 12, 0xA3, 0            ; AltGr+3 = £
    KSA 13, '$', 0             ; AltGr+4
    KSA 16, '{', 0             ; AltGr+7
    KSA 17, '[', 0             ; AltGr+8
    KSA 18, ']', 0             ; AltGr+9
    KSA 19, '}', 0             ; AltGr+0
    KSA 20, '\', 0             ; AltGr++  = backslash
    KSA 26, 0x20AC, 0          ; AltGr+e  = €
    KSA 35, '~', 0             ; AltGr+¨  = tilde
.iks_remaps:
    ; Apply ~/.framerc `keycode N = SYM [SYM...]` remaps (staged by
    ; parse_framerc, which runs before this table is built). Native
    ; equivalent of the user's ~/.Xmodmap — e.g. keycode 9 = F12 puts
    ; rofi on the physical Esc key. Each line replaces the keycode's
    ; whole 6-column row (unlisted levels become NoSymbol), matching
    ; xmodmap semantics.
    xor ecx, ecx
.iksr_loop:
    cmp ecx, [rc_remap_count]
    jge .iksr_done
    imul eax, ecx, 28
    lea rsi, [rc_remaps + rax]
    mov eax, [rsi]                           ; keycode
    sub eax, X_MIN_KEYCODE
    imul eax, eax, 24
    lea rdi, [keysym_table + rax]
    mov eax, [rsi + 4]
    mov [rdi + 0], eax
    mov eax, [rsi + 8]
    mov [rdi + 4], eax
    mov eax, [rsi + 12]
    mov [rdi + 8], eax
    mov eax, [rsi + 16]
    mov [rdi + 12], eax
    mov eax, [rsi + 20]
    mov [rdi + 16], eax
    mov eax, [rsi + 24]
    mov [rdi + 20], eax
    inc ecx
    jmp .iksr_loop
.iksr_done:
    ; Resolve blank_key's keysym to an X keycode (level-0 scan, AFTER the
    ; remaps so e.g. F12-on-physical-Esc resolves to keycode 9). No match
    ; (or `none`) leaves blank_kc = 0 = hotkey off.
    mov dword [blank_kc], 0
    mov eax, [cfg_blankkey_sym]
    test eax, eax
    jz .iks_bk_done
    xor ecx, ecx
.iks_bk_scan:
    cmp ecx, KEYCODE_RANGE
    jge .iks_bk_done
    imul edx, ecx, 24
    cmp [keysym_table + rdx], eax
    je .iks_bk_hit
    inc ecx
    jmp .iks_bk_scan
.iks_bk_hit:
    lea edx, [ecx + X_MIN_KEYCODE]
    mov [blank_kc], edx
.iks_bk_done:
    ret

; ----------------------------------------------------------------------------
; maybe_grab_input — edi = fd. EVIOCGRAB the device iff it's a keyboard
; (has KEY_SPACE) or a pointer (EV_REL/EV_ABS). Grabbing stops the kernel
; from ALSO routing its events to the foreground VT (keystrokes were
; leaking into TTY shells). Power button + lid switch are NOT grabbed, so
; the lid still suspends (battery). Kernel releases the grab on fd close.
; ----------------------------------------------------------------------------
maybe_grab_input:
    push rbx
    mov ebx, edi                             ; save fd
    ; EVIOCGBIT(0, 4): supported event-type bitmap → byte 0.
    mov dword [grab_bits], 0
    mov eax, SYS_IOCTL
    mov edi, ebx
    mov esi, 0x80044520                      ; EVIOCGBIT(0,4)
    lea rdx, [grab_bits]
    syscall
    mov al, [grab_bits]
    test al, 0x0C                             ; EV_REL(2) | EV_ABS(3) → pointer
    jnz .mg_grab
    test al, 0x02                             ; EV_KEY(1)?
    jz .mg_done
    ; EVIOCGBIT(EV_KEY, 96): key bitmap; KEY_SPACE(57) marks a real keyboard
    ; (power/lid have EV_KEY but only KEY_POWER / switches).
    lea rdi, [grab_bits]
    xor eax, eax
    mov ecx, 12
    rep stosq
    mov eax, SYS_IOCTL
    mov edi, ebx
    mov esi, 0x80604521                      ; EVIOCGBIT(EV_KEY,96)
    lea rdx, [grab_bits]
    syscall
    test byte [grab_bits + 7], 0x02           ; KEY_SPACE = 57 = byte 7 bit 1
    jz .mg_done
.mg_grab:
    mov eax, SYS_IOCTL
    mov edi, ebx
    mov esi, 0x40044590                      ; EVIOCGRAB
    mov edx, 1
    syscall
.mg_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; init_input — phase 4d.2: zero grab tables, then walk
; /dev/input/event0..31 and keep every fd that opens. Pre-fills the
; first MAX_INPUTS slots with -1.
;
; Best-effort. When run as a regular user without input-group access,
; every open fails with EACCES and input_fd_count stays at 0; input
; just doesn't fire. Run as root from a VT (where the DRM modeset
; path is anyway) for the real behaviour.
; ----------------------------------------------------------------------------
init_input:
    push rbx
    push r12
    push r13
    ; Zero key-grab table + state.
    lea rdi, [key_grabs]
    xor eax, eax
    mov ecx, MAX_KEY_GRABS * KEY_GRAB_SIZE
    rep stosb
    mov dword [active_kbd_slot], -1
    mov dword [active_kbd_window], 0
    mov dword [mod_state], 0
    ; Pre-fill input_fds with -1.
    lea rdi, [input_fds]
    mov eax, -1
    mov ecx, MAX_INPUTS
    rep stosd
    mov dword [input_fd_count], 0

    ; Walk event0..event31; stash openable fds.
    xor ebx, ebx
.ii_loop:
    cmp ebx, INPUT_DEV_MAX
    jge .ii_done
    cmp dword [input_fd_count], MAX_INPUTS
    jge .ii_done
    ; Build "/dev/input/eventN" in input_dev_path.
    lea rdi, [input_dev_path]
    lea rsi, [input_dev_pre]
.ii_cp:
    mov al, [rsi]
    test al, al
    jz .ii_cp_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .ii_cp
.ii_cp_done:
    mov eax, ebx
    call u64_to_ascii
    mov byte [rdi], 0
    ; open O_RDONLY | O_NONBLOCK = 0 | 0x800
    mov rax, SYS_OPEN
    lea rdi, [input_dev_path]
    mov esi, 0x800                            ; O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js .ii_next
    ; Store the fd.
    mov r13d, [input_fd_count]
    mov [input_fds + r13*4], eax
    inc dword [input_fd_count]
    mov edi, eax                             ; fd → grab if keyboard/pointer
    call maybe_grab_input
.ii_next:
    inc ebx
    jmp .ii_loop
.ii_done:
    ; Log how many we got.
    mov rsi, log_prefix
    mov rdx, 7
    call write_stderr
    mov rsi, log_input_pre
    mov rdx, log_input_pre_len
    call write_stderr
    mov eax, [input_fd_count]
    call write_u64_stderr
    mov rsi, log_input_suf
    mov rdx, log_input_suf_len
    call write_stderr
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_grab_key — edi = slot, rsi = req ptr.
;
; Request:
;   +0 opcode (33)        +1 owner-events (BOOL)
;   +2 length             +4 grab-window
;   +8 modifiers (CARD16) +10 key (CARD8 = keycode)
;   +11 pointer-mode (u8) +12 keyboard-mode (u8)
;
; Allocates a grab slot. No reply.
; ============================================================================
handle_grab_key:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12, rsi

    mov r13d, [r12 + 4]
    movzx r14d, word [r12 + 8]
    movzx eax, byte [r12 + 10]

    xor ecx, ecx
.gk_loop:
    cmp ecx, MAX_KEY_GRABS
    jge .gk_done
    mov rdx, rcx
    imul rdx, KEY_GRAB_SIZE
    lea rdx, [key_grabs + rdx]
    cmp dword [rdx], 0
    je .gk_take
    inc ecx
    jmp .gk_loop
.gk_take:
    mov [rdx + 0], r13d
    mov [rdx + 4], ebx
    mov [rdx + 8], al
    mov byte [rdx + 9], 0
    mov [rdx + 10], r14w
.gk_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_ungrab_key — rsi = req ptr. Clears matching grab(s). No reply.
; ============================================================================
handle_ungrab_key:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12d, [rbx + 4]
    movzx r13d, byte [rbx + 1]
    movzx eax, word [rbx + 8]
    mov esi, eax
    xor ecx, ecx
.uk_loop:
    cmp ecx, MAX_KEY_GRABS
    jge .uk_done
    mov rdx, rcx
    imul rdx, KEY_GRAB_SIZE
    lea rdx, [key_grabs + rdx]
    cmp dword [rdx], r12d
    jne .uk_next
    movzx eax, byte [rdx + 8]
    cmp eax, r13d
    jne .uk_next
    movzx eax, word [rdx + 10]
    cmp eax, esi
    jne .uk_next
    mov dword [rdx], 0
.uk_next:
    inc ecx
    jmp .uk_loop
.uk_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; handle_grab_keyboard — edi = slot, rsi = req ptr. Records grab,
; replies Success.
; ============================================================================
handle_grab_keyboard:
    push rbx
    push r12
    mov ebx, edi
    mov eax, [rsi + 4]
    mov [active_kbd_window], eax
    mov [active_kbd_slot], ebx
    mov byte [kbd_grab_xi2], 0               ; core grab → core events
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; handle_grab_pointer — edi = slot. Phase 4d.1 stub: replies Success.
; ============================================================================
handle_grab_pointer:
    mov eax, [rsi + 4]                        ; grab-window → activate the grab
    mov [ptr_grab_win], eax
    movzx eax, word [rsi + 8]                 ; event-mask (SETofPOINTEREVENT)
    mov [ptr_grab_mask], eax
    mov [ptr_grab_slot], edi                  ; who holds it (death cleanup)
    mov byte [ptr_grab_xi2], 0                ; core grab → core events
    movzx eax, byte [rsi + 1]                 ; owner-events (X: False → all
    mov [ptr_grab_owner], al                  ; events report the grab window)
    mov eax, [rsi + 16]                       ; grab cursor (scrot's crosshair)
    mov [ptr_grab_cursor], eax
    push rbx
    push r12
    mov ebx, edi
    call cursor_sync
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall

    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4d.2 — evdev → KeyPress event delivery.
; ============================================================================

; Modifier-bit defines matching X11's "state" field in KeyPress events.
%define MOD_SHIFT       0x01
%define MOD_LOCK        0x02
%define MOD_CONTROL     0x04
%define MOD_MOD1        0x08
%define MOD_MOD4        0x40
%define MOD_MOD5        0x80                 ; AltGr / ISO_Level3_Shift

; ----------------------------------------------------------------------------
; process_input — edi = fd. Reads up to INPUT_BATCH_BYTES worth of
; input_event records and dispatches each.
; ----------------------------------------------------------------------------
process_input:
    push rbx
    push r12
    push r13
    mov r12d, edi                            ; fd
    ; read()
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [input_event_batch]
    mov rdx, INPUT_BATCH_BYTES
    syscall
    test rax, rax
    jle .pi_done                             ; 0=EOF, <0=error/EAGAIN
    mov r13, rax                             ; total bytes
    ; Screen auto-off bookkeeping: stamp the idle clock once per batch (one
    ; clock_gettime per wake, not per event) and wake the panel if dark.
    push rax
    call now_mono_ms
    mov [last_input_mono], rax
    cmp byte [blank_state], 1
    jne .pi_awake
    ; Dark: wake only on a key/button PRESS or pointer motion. A bare key
    ; RELEASE stays dark — else letting go of the blank_key combo (or of
    ; the key whose hold outlived the timeout) would instantly re-light.
    xor ecx, ecx
.pi_wake_scan:
    cmp rcx, r13
    jge .pi_awake
    movzx eax, word [input_event_batch + rcx + 16]   ; type
    cmp eax, EV_REL
    je .pi_wake
    cmp eax, EV_ABS
    je .pi_wake
    cmp eax, EV_KEY
    jne .pi_wake_next
    cmp dword [input_event_batch + rcx + 20], 1      ; press only
    je .pi_wake
.pi_wake_next:
    add rcx, INPUT_EVENT_SIZE
    jmp .pi_wake_scan
.pi_wake:
    call comp_unblank
.pi_awake:
    pop rax
    xor ebx, ebx
.pi_event:
    cmp rbx, r13
    jge .pi_done
    lea rdi, [input_event_batch + rbx]
    call dispatch_input_event
    add rbx, INPUT_EVENT_SIZE
    jmp .pi_event
.pi_done:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; dispatch_input_event — rdi = pointer to 24-byte input_event. We only
; care about EV_KEY events: update modifier state if it's a modifier
; key, then check key_grabs[] for a matching grab.
; ----------------------------------------------------------------------------
dispatch_input_event:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    cmp byte [vt_away], 0                    ; switched away: these keystrokes
    jne .die_done                            ; belong to the console, not X
    ; Derive the X server time (ms) from this event's own kernel timestamp —
    ; input_event = { tv_sec@0 (8), tv_usec@8 (8), type@16, code@18, value@20 }.
    ; No extra syscall: the timestamp is already in the record. Low 32 bits
    ; only (X time is CARD32 and wraps ~49 days, which is allowed).
    mov rax, [rbx]                           ; tv_sec
    imul rax, rax, 1000
    push rax
    mov rax, [rbx + 8]                        ; tv_usec
    xor edx, edx
    mov ecx, 1000
    div rcx                                   ; rax = tv_usec / 1000
    pop rcx                                    ; tv_sec * 1000
    add rax, rcx
    mov [server_time_ms], eax
    movzx eax, word [rbx + 16]               ; type
    cmp eax, EV_REL
    je .die_rel                              ; mouse motion / wheel
    cmp eax, EV_ABS
    je .die_abs                              ; touchpad absolute motion
    cmp eax, EV_KEY
    jne .die_done

    movzx r12d, word [rbx + 18]              ; code (evdev keycode / BTN_*)
    mov r13d, [rbx + 20]                     ; value (0=rel,1=press,2=repeat)

    ; Mouse buttons (code >= 0x100) are pointer events, not keyboard.
    cmp r12d, 0x100
    jae .die_button

    ; If modifier key: adjust mod_state. (Key repeats don't toggle.)
    cmp r12d, 29
    je .die_ctrl
    cmp r12d, 97
    je .die_ctrl
    cmp r12d, 42
    je .die_shift
    cmp r12d, 54
    je .die_shift
    cmp r12d, 56
    je .die_alt
    cmp r12d, 100
    je .die_alt
    cmp r12d, 125
    je .die_mod4
    cmp r12d, 126
    je .die_mod4
    jmp .die_check_grab

.die_ctrl:
    mov al, MOD_CONTROL
    jmp .die_apply_mod
.die_shift:
    mov al, MOD_SHIFT
    jmp .die_apply_mod
.die_alt:
    mov al, MOD_MOD1
    cmp r12d, 100                             ; right Alt = AltGr in Norwegian
    jne .die_apply_mod
    cmp byte [keymap_is_no], 0
    je .die_apply_mod
    mov al, MOD_MOD5                          ; → Mod5 (state bit 7); glass level 3
    jmp .die_apply_mod
.die_mod4:
    mov al, MOD_MOD4
.die_apply_mod:
    test r13d, r13d
    jz .die_mod_release
    cmp r13d, 1
    jne .die_check_grab                       ; ignore repeat for mod
    movzx ecx, byte [mod_state]
    or ecx, eax
    mov [mod_state], ecx
    jmp .die_check_grab
.die_mod_release:
    movzx ecx, byte [mod_state]
    not eax
    and ecx, eax
    mov [mod_state], ecx

.die_check_grab:
    ; Ctrl+Alt+Backspace → zap (clean exit). Ctrl+Alt+F1..F12 → switch to
    ; that VT. frame grabs the keyboard (EVIOCGRAB), so the kernel can't do
    ; the VT switch itself — we detect the combo and call VT_ACTIVATE, exactly
    ; like a real X server. Both are press-only and require Ctrl + left-Alt.
    cmp r13d, 1
    jne .die_nozap
    movzx eax, byte [mod_state]
    and eax, MOD_CONTROL | MOD_MOD1
    cmp eax, MOD_CONTROL | MOD_MOD1
    jne .die_nozap
    cmp r12d, 14                             ; Backspace → zap
    jne .die_chk_vt
    call compositor_shutdown
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
.die_chk_vt:
    cmp r12d, 59                             ; F1..F10 = evdev 59..68 → VT 1..10
    jb .die_nozap
    cmp r12d, 68
    ja .die_chk_f11
    lea edi, [r12d - 58]
    call switch_vt                           ; returns: display released, the
    jmp .die_done                            ; serve loop keeps running
.die_chk_f11:
    cmp r12d, 87                             ; F11 → VT 11
    jne .die_chk_f12
    mov edi, 11
    call switch_vt
    jmp .die_done
.die_chk_f12:
    cmp r12d, 88                             ; F12 → VT 12
    jne .die_nozap
    mov edi, 12
    call switch_vt
    jmp .die_done
.die_nozap:
    ; x11_keycode = evdev_code + 8 (kept in r12d from here on).
    add r12d, 8

    ; QueryKeymap bitmap: bit = X keycode. copyq (and anything else that
    ; waits for modifiers to be released before faking keys) polls this.
    cmp r13d, 2
    je .die_kd_done                          ; repeat: state unchanged
    test r13d, r13d
    jz .die_kd_up
    bts dword [keys_down], r12d
    jmp .die_kd_done
.die_kd_up:
    btr dword [keys_down], r12d
.die_kd_done:

    ; framerc blank_key: exact modifier match on the resolved keycode →
    ; panel off NOW. Server-level like the zap/VT combos: the combo never
    ; reaches clients (press blanks; its repeats + release are swallowed).
    mov eax, [blank_kc]
    test eax, eax
    jz .die_no_blankkey
    cmp eax, r12d
    jne .die_no_blankkey
    movzx eax, byte [mod_state]
    cmp al, [cfg_blankkey_mods]
    jne .die_no_blankkey
    cmp r13d, 1
    jne .die_done                            ; swallow repeat/release too
    call comp_blank
    jmp .die_done
.die_no_blankkey:

    ; Release (value 0) → KeyRelease to the focused window.
    cmp r13d, 0
    je .die_release
    ; Repeat (value 2) → KeyPress to the focused window (no grab re-fire).
    cmp r13d, 1
    jne .die_focus_press

    ; Fresh press: an ACTIVE keyboard grab overrides passive WM hotkey
    ; grabs (X semantics) — while rofi holds the keyboard, Mod4 combos go
    ; to rofi, not tile. deliver_to_focus routes to the grab holder.
    cmp dword [active_kbd_slot], 0
    jge .die_focus_press
    ; ...else a matching passive key-grab wins (WM hotkeys); else focus.
    mov edi, r12d
    movzx esi, byte [mod_state]
    call find_key_grab
    test rax, rax
    jz .die_focus_press
    mov edi, [rax + 4]                       ; grab client slot
    mov esi, r12d                            ; keycode
    movzx ecx, byte [mod_state]
    mov edx, [rax + 0]                       ; grab window
    mov r8d, 2                               ; KeyPress
    call send_key_press
    jmp .die_done

.die_focus_press:
    mov esi, r12d
    mov r8d, 2                               ; KeyPress
    call deliver_to_focus
    jmp .die_done
.die_release:
    mov esi, r12d
    mov r8d, 3                               ; KeyRelease
    call deliver_to_focus
    jmp .die_done

    ; --- Pointer motion / wheel (EV_REL) ----------------------------------
.die_rel:
    movzx ecx, word [rbx + 18]               ; REL code
    movsxd rdx, dword [rbx + 20]             ; delta (signed)
    test ecx, ecx                            ; REL_X = 0
    je .die_rel_x
    cmp ecx, 1                               ; REL_Y
    je .die_rel_y
    cmp ecx, 8                               ; REL_WHEEL
    je .die_wheel
    jmp .die_done
.die_rel_x:
    mov eax, edx
    SCALE_SENS
    add eax, [cursor_x]
    jns .die_rx_hi
    xor eax, eax
.die_rx_hi:
    mov ecx, [screen_w]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [cursor_x], eax
    jmp .die_motion
.die_rel_y:
    mov eax, edx
    SCALE_SENS
    add eax, [cursor_y]
    jns .die_ry_hi
    xor eax, eax
.die_ry_hi:
    mov ecx, [screen_h]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [cursor_y], eax
.die_motion:
    call cursor_move_hw                      ; move the sprite (one cheap ioctl)
    call deliver_pointer_motion
    jmp .die_done
.die_wheel:
    test edx, edx
    jz .die_done
    mov r12d, 4                              ; wheel up → button 4
    jns .die_wheel_send
    mov r12d, 5                              ; wheel down → button 5
.die_wheel_send:
    mov edi, 4                               ; ButtonPress
    mov esi, r12d
    call deliver_pointer_button
    mov edi, 5                               ; ButtonRelease
    mov esi, r12d
    call deliver_pointer_button
    jmp .die_done

    ; --- Touchpad absolute motion (EV_ABS ABS_X/ABS_Y) --------------------
    ; Precision touchpads report finger position absolutely, not as deltas.
    ; Convert to relative cursor movement (delta from the last sample, x2 for
    ; sensitivity). The anchor is reset on each new contact (BTN_TOUCH) so
    ; lifting and re-placing a finger doesn't teleport the cursor.
.die_abs:
    movzx ecx, word [rbx + 18]               ; ABS code
    mov edx, [rbx + 20]                      ; absolute value
    test ecx, ecx                            ; ABS_X = 0
    je .die_abs_x
    cmp ecx, 1                               ; ABS_Y
    je .die_abs_y
    cmp ecx, 0x2f                            ; ABS_MT_SLOT
    je .die_mt_slot
    cmp ecx, 0x39                            ; ABS_MT_TRACKING_ID
    je .die_mt_trk
    cmp ecx, 0x35                            ; ABS_MT_POSITION_X
    je .die_mt_x
    cmp ecx, 0x36                            ; ABS_MT_POSITION_Y
    je .die_mt_y
    jmp .die_done                            ; ignore pressure/other ABS
.die_abs_x:
    cmp dword [abs_have_x], 0
    jne .die_abs_x_move
    mov [abs_last_x], edx                    ; first sample: anchor only
    mov dword [abs_have_x], 1
    jmp .die_done
.die_abs_x_move:
    mov eax, edx
    sub eax, [abs_last_x]                     ; delta (1x sensitivity)
    mov [abs_last_x], edx
    ; tap_moved += |delta|
    mov r8d, eax
    mov r9d, r8d
    sar r9d, 31
    xor r8d, r9d
    sub r8d, r9d
    add [tap_moved], r8d
    cmp dword [finger_count], 2               ; 2+ fingers: skip ABS X — a drag
    jge .die_done                              ; uses MT (right finger), scroll is Y
.die_abs_x_apply:
    SCALE_SENS
    add eax, [cursor_x]
    jns .die_abs_x_hi
    xor eax, eax
.die_abs_x_hi:
    mov ecx, [screen_w]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [cursor_x], eax
    jmp .die_motion
.die_abs_y:
    cmp dword [abs_have_y], 0
    jne .die_abs_y_move
    mov [abs_last_y], edx
    mov dword [abs_have_y], 1
    jmp .die_done
.die_abs_y_move:
    mov eax, edx
    sub eax, [abs_last_y]
    mov [abs_last_y], edx
    mov r8d, eax
    mov r9d, r8d
    sar r9d, 31
    xor r8d, r9d
    sub r8d, r9d
    add [tap_moved], r8d
    cmp dword [finger_count], 2               ; <2 fingers: move from ABS
    jl .die_abs_y_apply
    cmp dword [button_state], 0                ; 2+ fingers + button → drag: MT
    jne .die_done                              ; handles it (skip ABS Y)
    jmp .die_scroll_y                          ; 2+ fingers, no button → scroll
.die_abs_y_apply:
    SCALE_SENS
    add eax, [cursor_y]
    jns .die_abs_y_hi
    xor eax, eax
.die_abs_y_hi:
    mov ecx, [screen_h]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [cursor_y], eax
    jmp .die_motion
    ; Two-finger vertical scroll: accumulate Y delta, emit a wheel notch
    ; (button 5 down / 4 up) every SCROLL_NOTCH units.
.die_scroll_y:
    add [scroll_accum], eax
.die_scroll_dn:
    cmp dword [scroll_accum], 60
    jl .die_scroll_up
    sub dword [scroll_accum], 60
    mov edi, 4
    mov esi, 5
    call deliver_pointer_button
    mov edi, 5
    mov esi, 5
    call deliver_pointer_button
    jmp .die_scroll_dn
.die_scroll_up:
    cmp dword [scroll_accum], -60
    jg .die_done
    add dword [scroll_accum], 60
    mov edi, 4
    mov esi, 4
    call deliver_pointer_button
    mov edi, 5
    mov esi, 4
    call deliver_pointer_button
    jmp .die_scroll_up

    ; --- Multitouch (MT-B) per-finger tracking ----------------------------
    ; Used only for the 2-finger drag (button held): the single-touch ABS_X/Y
    ; follows the stationary click finger, so we follow the actual fingers
    ; here. Each moving finger contributes its delta to the cursor; the still
    ; click finger contributes ~0, so the cursor tracks the dragging finger.
.die_mt_slot:
    cmp edx, 2
    jb .die_mts_ok
    mov edx, 2                               ; clamp out-of-range to dead slot
.die_mts_ok:
    mov [mt_cur_slot], edx
    jmp .die_done
.die_mt_trk:
    mov ecx, [mt_cur_slot]
    cmp ecx, 2
    jae .die_done
    mov dword [mt_have_x + rcx*4], 0          ; re-anchor on finger touch / lift
    mov dword [mt_have_y + rcx*4], 0
    jmp .die_done
.die_mt_x:
    mov ecx, [mt_cur_slot]
    cmp ecx, 2
    jae .die_done
    cmp dword [finger_count], 2               ; MT drives cursor only in
    jl .die_done                              ; 2-finger-drag mode (button held);
    cmp dword [button_state], 0               ; otherwise ABS_X/Y handles motion
    je .die_done
    cmp dword [mt_have_x + rcx*4], 0
    jne .die_mt_x_move
    mov [mt_last_x + rcx*4], edx              ; first sample: anchor only
    mov dword [mt_have_x + rcx*4], 1
    jmp .die_done
.die_mt_x_move:
    mov eax, edx
    sub eax, [mt_last_x + rcx*4]
    mov [mt_last_x + rcx*4], edx
    SCALE_SENS
    add eax, [cursor_x]
    jns .die_mt_x_hi
    xor eax, eax
.die_mt_x_hi:
    mov ecx, [screen_w]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [cursor_x], eax
    jmp .die_motion
.die_mt_y:
    mov ecx, [mt_cur_slot]
    cmp ecx, 2
    jae .die_done
    cmp dword [finger_count], 2
    jl .die_done
    cmp dword [button_state], 0
    je .die_done
    cmp dword [mt_have_y + rcx*4], 0
    jne .die_mt_y_move
    mov [mt_last_y + rcx*4], edx
    mov dword [mt_have_y + rcx*4], 1
    jmp .die_done
.die_mt_y_move:
    mov eax, edx
    sub eax, [mt_last_y + rcx*4]
    mov [mt_last_y + rcx*4], edx
    SCALE_SENS
    add eax, [cursor_y]
    jns .die_mt_y_hi
    xor eax, eax
.die_mt_y_hi:
    mov ecx, [screen_h]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [cursor_y], eax
    jmp .die_motion

    ; --- Mouse / touchpad buttons (EV_KEY, code >= 0x100) -----------------
.die_button:
    cmp r12d, 0x14a                          ; BTN_TOUCH (finger contact)
    je .die_btn_touch
    cmp r12d, 0x145                          ; BTN_TOOL_FINGER (1 finger)
    je .die_tool_one
    cmp r12d, 0x14d                          ; BTN_TOOL_DOUBLETAP (2 fingers)
    je .die_tool_two
    ; Real buttons: BTN_LEFT(0x110)->1, MIDDLE(0x112)->2, RIGHT(0x111)->3.
    ; Other BTN_* (TRIPLETAP, etc.) ignored.
    cmp r12d, 0x110
    je .die_btn_left
    cmp r12d, 0x111
    je .die_btn_right
    cmp r12d, 0x112
    je .die_btn_middle
    jmp .die_done

.die_tool_one:
    test r13d, r13d
    jz .die_done
    mov dword [finger_count], 1
    mov dword [abs_have_x], 0                 ; re-anchor on finger-config change
    mov dword [abs_have_y], 0
    jmp .die_done
.die_tool_two:
    test r13d, r13d
    jz .die_done
    mov dword [finger_count], 2
    mov dword [tap_fingers], 2                ; for two-finger tap = right-click
    mov dword [abs_have_x], 0
    mov dword [abs_have_y], 0
    mov dword [scroll_accum], 0
    jmp .die_done

.die_btn_touch:
    mov dword [abs_have_x], 0                 ; re-anchor motion on each contact
    mov dword [abs_have_y], 0
    test r13d, r13d
    jz .die_touch_up
    ; Finger down: start tap tracking (timestamp + movement reset).
    mov rax, [rbx + 0]
    mov [tap_sec], rax
    mov rax, [rbx + 8]
    mov [tap_usec], rax
    mov dword [tap_moved], 0
    mov dword [tap_fingers], 1
    jmp .die_done
.die_touch_up:
    mov dword [finger_count], 0
    ; Tap = quick (<250ms) release with little movement → synthesize a click.
    mov rax, [rbx + 0]
    sub rax, [tap_sec]
    imul rax, rax, 1000000
    mov rcx, [rbx + 8]
    sub rcx, [tap_usec]
    add rax, rcx                              ; elapsed microseconds
    cmp rax, 250000
    jg .die_done
    mov ecx, 50
    cmp dword [tap_fingers], 2                ; two fingers jitter more —
    jne .die_tap_thresh                       ; allow ~2.5mm instead of ~1mm
    mov ecx, 120
.die_tap_thresh:
    cmp [tap_moved], ecx
    jae .die_done
    mov esi, 1                                ; 1-finger tap → left button
    cmp dword [tap_fingers], 2
    jne .die_tap_emit
    mov esi, 3                                ; 2-finger tap → right button
.die_tap_emit:
    mov edi, 4                                ; ButtonPress
    push rsi
    call deliver_pointer_button
    pop rsi
    mov edi, 5                                ; ButtonRelease
    call deliver_pointer_button
    jmp .die_done
.die_btn_left:
    ; Clickpad "clickfinger": a physical press with 2 fingers resting is a
    ; right-click (the libinput convention this laptop's pad is used to).
    ; The mapped button is remembered so the release matches even if a
    ; finger lifted mid-press (else button 3 would stay stuck down).
    test r13d, r13d
    jz .die_btn_left_rel
    mov esi, 1
    cmp dword [finger_count], 2
    jl .die_btn_left_store
    mov esi, 3
.die_btn_left_store:
    mov [clickpad_btn], esi
    jmp .die_btn_have
.die_btn_left_rel:
    mov esi, [clickpad_btn]
    test esi, esi                            ; release before any press (BSS 0)
    jnz .die_btn_have
    mov esi, 1
    jmp .die_btn_have
.die_btn_right:
    mov esi, 3
    jmp .die_btn_have
.die_btn_middle:
    mov esi, 2
.die_btn_have:
    ; Send first (so 'state' reflects pre-event mask), then update the mask.
    test r13d, r13d
    jz .die_btn_release
    mov edi, 4                               ; ButtonPress
    push rsi
    call deliver_pointer_button
    pop rsi
    mov ecx, esi
    dec ecx
    mov eax, 0x100
    shl eax, cl
    or [button_state], eax
    jmp .die_done
.die_btn_release:
    mov edi, 5                               ; ButtonRelease
    push rsi
    call deliver_pointer_button
    pop rsi
    mov ecx, esi
    dec ecx
    mov eax, 0x100
    shl eax, cl
    not eax
    and [button_state], eax
    jmp .die_done

.die_done:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_at_point — topmost mapped non-root window whose geometry contains
; (cursor_x, cursor_y). Returns its record ptr in rax, or 0 (over root).
; Last match in table order wins (≈ most-recently-created on top).
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; send_expose — edi = client slot, esi = window xid, edx = x, ecx = y,
; r8d = width, r9d = height. Emits a 32-byte Expose event (count = 0).
; ----------------------------------------------------------------------------
send_expose:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi                            ; xid
    mov r13d, edx                            ; x
    mov r14d, ecx                            ; y
    mov r15d, r8d                            ; width
    push r9                                   ; height
    mov eax, edi                             ; slot
    call client_meta_addr                    ; rax = meta (+0 fd, +8 seq)
    mov rbx, rax
    lea rsi, [reply_buf]
    xor eax, eax
    mov [rsi + 0], rax
    mov [rsi + 8], rax
    mov [rsi + 16], rax
    mov [rsi + 24], rax
    mov byte [rsi + 0], 12                    ; Expose
    mov eax, [rbx + 8]
    mov [rsi + 2], ax                         ; seq
    mov [rsi + 4], r12d                       ; window
    mov [rsi + 8], r13w                       ; x
    mov [rsi + 10], r14w                      ; y
    mov [rsi + 12], r15w                      ; width
    pop rax                                   ; height
    mov [rsi + 14], ax                        ; height (+16 count stays 0)
    mov edi, [rbx]                            ; fd
    mov edx, 32
    EV_SEND                                    ; non-blocking (see EV_SEND macro)
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; expose_under_window — rdi = record of a window being hidden/destroyed. For
; each OTHER mapped non-root window below it (lower stk) that selected
; ExposureMask and overlaps it, send an Expose for the overlap (in that
; window's coords) so the client repaints the region it blanked.
; ----------------------------------------------------------------------------
expose_under_window:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                             ; hidden window record
    xor ebx, ebx
.euw_loop:
    cmp ebx, MAX_WINDOWS
    jge .euw_done
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea r13, [windows + rax]                  ; candidate W
    cmp r13, r12
    je .euw_next                             ; skip self
    mov eax, [r13]
    test eax, eax
    jz .euw_next
    cmp eax, X_ROOT_WINDOW
    je .euw_next
    cmp byte [r13 + 28], 0                    ; mapped?
    je .euw_next
    test dword [r13 + 24], 0x8000             ; ExposureMask selected?
    jz .euw_next
    mov eax, [r13 + 48]                       ; W.stk
    cmp eax, [r12 + 48]                       ; W below the hidden window?
    jae .euw_next
    ; --- x overlap: ex (r14d), iw (r10d) ---
    movsx r14d, word [r12 + 8]                ; hidden.x
    movsx eax, word [r13 + 8]                 ; W.x
    sub r14d, eax                             ; px = hidden.x - W.x
    mov eax, r14d
    movzx ecx, word [r12 + 12]                ; hidden.w
    add eax, ecx                             ; px + hidden.w (right edge in W)
    movzx ecx, word [r13 + 12]                ; W.w
    cmp eax, ecx
    jle .euw_x2
    mov eax, ecx                             ; clamp to W.w
.euw_x2:                                      ; eax = ex2
    test r14d, r14d
    jns .euw_xpos
    xor r14d, r14d                            ; ex = max(0, px)
.euw_xpos:
    sub eax, r14d                             ; iw = ex2 - ex
    jle .euw_next
    mov r10d, eax                             ; iw
    ; --- y overlap: ey (r15d), ih (r11d) ---
    movsx r15d, word [r12 + 10]               ; hidden.y
    movsx eax, word [r13 + 10]                ; W.y
    sub r15d, eax                             ; py
    mov eax, r15d
    movzx ecx, word [r12 + 14]                ; hidden.h
    add eax, ecx
    movzx ecx, word [r13 + 14]                ; W.h
    cmp eax, ecx
    jle .euw_y2
    mov eax, ecx
.euw_y2:                                      ; eax = ey2
    test r15d, r15d
    jns .euw_ypos
    xor r15d, r15d                            ; ey = max(0, py)
.euw_ypos:
    sub eax, r15d                             ; ih = ey2 - ey
    jle .euw_next
    mov r11d, eax                             ; ih
    ; --- W's client slot from its xid ---
    mov eax, [r13]
    cmp eax, X_RID_BASE
    jb .euw_next
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .euw_next
    mov edi, eax                             ; client slot
    mov esi, [r13]                            ; W xid
    mov edx, r14d                             ; x
    mov ecx, r15d                             ; y
    mov r8d, r10d                             ; width
    mov r9d, r11d                             ; height
    call send_expose
.euw_next:
    inc ebx
    jmp .euw_loop
.euw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

window_at_point:
    ; Absolute-aware pick: a window counts only if its WHOLE ancestor chain
    ; is mapped, and its rect is tested at its ABSOLUTE origin (child x/y
    ; are parent-relative). The old parent-local test let a nested child of
    ; an UNMAPPED toplevel (firefox's content child while its tab lived on
    ; another workspace) swallow clicks anywhere its parent-relative rect
    ; happened to land — tray right-clicks opened firefox menus. Winner's
    ; absolute origin lands in wap_abs_x/y for event-coordinate math.
    push rbx
    push r12
    push r14
    push r15
    xor ebx, ebx
    xor r12d, r12d                           ; best stk = 0 (topmost wins)
    mov qword [wap_best], 0
.wap_loop:
    cmp ebx, MAX_WINDOWS
    jge .wap_done
    mov r8, rbx
    imul r8, WINDOW_REC_SIZE
    lea r8, [windows + r8]
    mov r9d, [r8]                            ; xid
    test r9d, r9d
    jz .wap_next
    cmp r9d, X_ROOT_WINDOW
    je .wap_next
    cmp byte [r8 + 28], 0                     ; mapped?
    je .wap_next
    mov r9d, [r8 + 48]                        ; stk: can it beat the best at
    cmp r9d, r12d                             ; all? (cheap pre-filter before
    jbe .wap_next                             ; the ancestor walk)
    ; --- ancestor walk: every ancestor mapped; accumulate absolute origin
    movsx r14d, word [r8 + 8]                 ; abs x
    movsx r15d, word [r8 + 10]                ; abs y
    mov edi, [r8 + 4]                         ; parent xid
.wap_anc:
    test edi, edi
    jz .wap_anc_ok
    cmp edi, X_ROOT_WINDOW
    je .wap_anc_ok
    push r8
    push r9
    call window_lookup                        ; rax = ancestor (clobbers rax only)
    pop r9
    pop r8
    test rax, rax
    jz .wap_next                              ; orphaned → not clickable
    cmp byte [rax + 28], 0                    ; unmapped ancestor → invisible
    je .wap_next
    movsx ecx, word [rax + 8]
    add r14d, ecx
    movsx ecx, word [rax + 10]
    add r15d, ecx
    mov edi, [rax + 4]
    jmp .wap_anc
.wap_anc_ok:
    ; --- point inside the absolute rect? (ecx/edx = window-local px/py)
    mov ecx, [cursor_x]
    sub ecx, r14d
    js .wap_next
    movzx eax, word [r8 + 12]                 ; w
    cmp ecx, eax
    jge .wap_next
    mov edx, [cursor_y]
    sub edx, r15d
    js .wap_next
    movzx eax, word [r8 + 14]                 ; h
    cmp edx, eax
    jge .wap_next
    ; SHAPE input region: an empty input shape means click-through (spot's
    ; overlay) — the window never becomes the pick.
    mov edi, [r8]
    mov esi, ecx                              ; px window-local
    ; edx = py window-local
    call shape_input_hit                      ; preserves all regs
    jnz .wap_next                             ; ZF=0 → pass through
    mov r12d, r9d                             ; new topmost stk
    mov [wap_best], r8
    mov [wap_abs_x], r14d
    mov [wap_abs_y], r15d
.wap_next:
    inc ebx
    jmp .wap_loop
.wap_done:
    mov rax, [wap_best]
    pop r15
    pop r14
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_at_point_deep — the DEEPEST mapped window (input-only included) whose
; ABSOLUTE rect contains (cursor_x, cursor_y). Descends the tree from root,
; taking the topmost sibling that contains the point at each level and
; accumulating the absolute origin. Returns the record ptr in rax (0 if over
; root only); wapd_abs_x/wapd_abs_y hold that window's absolute origin.
; A real server delivers pointer events here — GTK menu items are input-only
; child windows, and the click must carry that window as its event-window or
; GTK can't tell which item was hit.
; ----------------------------------------------------------------------------
window_at_point_deep:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r13d, [cursor_x]
    mov r14d, [cursor_y]
    mov dword [wapd_abs_x], 0                  ; origin starts at root (0,0)
    mov dword [wapd_abs_y], 0
    mov eax, X_ROOT_WINDOW
    mov [wapd_cur_parent], eax
    xor r15, r15                              ; result = none
.wapd_descend:
    xor ebx, ebx
    xor r12, r12                              ; best child this level
    mov dword [wapd_best_stk], 0
.wapd_scan:
    cmp ebx, MAX_WINDOWS
    jge .wapd_level_done
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea rax, [windows + rax]                  ; candidate C
    mov ecx, [rax]
    test ecx, ecx
    jz .wapd_scan_next
    cmp ecx, X_ROOT_WINDOW
    je .wapd_scan_next
    mov ecx, [rax + 4]                        ; parent
    cmp ecx, [wapd_cur_parent]
    jne .wapd_scan_next
    cmp byte [rax + 28], 0                    ; mapped?
    je .wapd_scan_next
    movsx ecx, word [rax + 8]
    add ecx, [wapd_abs_x]                     ; child abs x
    cmp r13d, ecx
    jl .wapd_scan_next
    movzx edx, word [rax + 12]
    add edx, ecx
    cmp r13d, edx
    jge .wapd_scan_next
    movsx ecx, word [rax + 10]
    add ecx, [wapd_abs_y]                     ; child abs y
    cmp r14d, ecx
    jl .wapd_scan_next
    movzx edx, word [rax + 14]
    add edx, ecx
    cmp r14d, edx
    jge .wapd_scan_next
    mov ecx, [rax + 48]                       ; contains point — topmost wins
    cmp ecx, [wapd_best_stk]
    jb .wapd_scan_next
    ; SHAPE input region check (empty region = click-through)
    mov edi, [rax]
    movsx esi, word [rax + 8]
    add esi, [wapd_abs_x]
    neg esi
    add esi, r13d                             ; px window-local
    movsx edx, word [rax + 10]
    add edx, [wapd_abs_y]
    neg edx
    add edx, r14d                             ; py window-local
    call shape_input_hit                      ; preserves all regs
    jnz .wapd_scan_next                       ; ZF=0 → pass through
    mov ecx, [rax + 48]
    mov [wapd_best_stk], ecx
    mov r12, rax
.wapd_scan_next:
    inc ebx
    jmp .wapd_scan
.wapd_level_done:
    test r12, r12
    jz .wapd_done                             ; no child holds the point → stop
    mov r15, r12                              ; descend
    movsx eax, word [r12 + 8]
    add [wapd_abs_x], eax
    movsx eax, word [r12 + 10]
    add [wapd_abs_y], eax
    mov eax, [r12]
    mov [wapd_cur_parent], eax
    jmp .wapd_descend
.wapd_done:
    mov rax, r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; grab_pointer_target — with a pointer grab active, choose the delivery target
; the owner_events way: the deepest window under the cursor if it belongs to
; the grab's client, otherwise the grab window itself. Returns the record ptr
; in rax; wapd_abs_x/wapd_abs_y hold the target's absolute origin either way.
; ----------------------------------------------------------------------------
; grab_owner_target — owner-events=False active grab: rax = the GRAB window's
; record (0 if gone) and wapd_abs_x/y = its absolute origin, so the shared
; delivery code emits the event against the grab window with grab-relative
; coordinates — X semantics for owner_events=False (scrot -s relies on it).
grab_owner_target:
    mov edi, [ptr_grab_win]
    call window_lookup
    test rax, rax
    jz .got_ret
    push rax
    mov edi, [ptr_grab_win]
    call window_abs_xy                       ; r10d/r11d = absolute origin
    mov [wapd_abs_x], r10d
    mov [wapd_abs_y], r11d
    pop rax
.got_ret:
    ret

grab_pointer_target:
    push rbx
    call window_at_point_deep                 ; rax = deepest record (or 0)
    test rax, rax
    jz .gpt_grab
    mov ecx, [rax]                            ; deepest xid → slot
    sub ecx, X_RID_BASE
    shr ecx, 21
    cmp ecx, [ptr_grab_slot]                  ; the GRABBING CLIENT's slot —
    jne .gpt_grab                             ; NOT the grab window's XID band
                                              ; (garbage when grabbing on root,
                                              ; which is what rofi does)
    pop rbx
    ret                                       ; rax = deepest (owner-events)
.gpt_grab:
    mov edi, [ptr_grab_win]
    call window_lookup
    test rax, rax
    jz .gpt_done
    push rax
    mov edi, [ptr_grab_win]
    call window_abs_xy                        ; r10d/r11d = grab window origin
    mov [wapd_abs_x], r10d
    mov [wapd_abs_y], r11d
    pop rax
.gpt_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_crossing — edi = event code (7 EnterNotify / 8 LeaveNotify),
; rsi = window record ptr. Sent to the window's own client when its event
; mask selects it (Enter 0x10 / Leave 0x20). detail Nonlinear, mode Normal,
; same-screen flag set. GTK menu items prelight and activate on these.
; ----------------------------------------------------------------------------
send_crossing:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi                            ; code
    mov r13, rsi                             ; record
    mov r14d, edx                            ; detail (0 Ancestor / 2 Inferior / 3 Nonlinear)
    mov ecx, 0x10
    cmp r12d, 7
    je .sx_mask
    mov ecx, 0x20
.sx_mask:
    bt dword [r13 + 52], r12d                ; XI2 Enter/Leave selected →
    jc .sx_deliver                           ; skip the core-mask gate
    test [r13 + 24], ecx                     ; target window wants it?
    jnz .sx_deliver
    cmp dword [ptr_grab_win], 0              ; else the grab wants it?
    je .sx_done                              ; (mirrors motion/button fallback)
    test [ptr_grab_mask], ecx
    jz .sx_done
.sx_deliver:
    mov eax, [r13]                           ; xid → owner slot
    cmp eax, X_RID_BASE
    jb .sx_done
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .sx_done
    mov ebx, eax                             ; slot
    mov edi, [r13]
    call window_abs_xy                       ; r10d/r11d = abs origin
    bt dword [r13 + 52], r12d                ; XI2 route (evtype 7/8 = codes)
    jnc .sx_core
    mov r8d, [cursor_x]
    sub r8d, r10d
    mov r9d, [cursor_y]
    sub r9d, r11d
    mov edi, ebx
    mov esi, r12d
    mov edx, r14d                            ; detail
    mov ecx, [r13]
    call send_xi2_crossing
    jmp .sx_done
.sx_core:
    lea rdi, [reply_buf]
    mov [rdi + 0], r12b                      ; code 7/8
    mov [rdi + 1], r14b                      ; detail
    mov word [rdi + 2], 0                    ; seq (patched by sender)
    mov eax, [server_time_ms]
    mov [rdi + 4], eax                       ; time
    mov dword [rdi + 8], X_ROOT_WINDOW       ; root
    mov eax, [r13]
    mov [rdi + 12], eax                      ; event window
    mov dword [rdi + 16], 0                  ; child None
    mov eax, [cursor_x]
    mov [rdi + 20], ax                       ; root-x
    mov ecx, eax
    sub ecx, r10d
    mov eax, [cursor_y]
    mov [rdi + 22], ax                       ; root-y
    sub eax, r11d
    mov [rdi + 24], cx                       ; event-x
    mov [rdi + 26], ax                       ; event-y
    mov eax, [button_state]
    movzx ecx, byte [mod_state]
    or eax, ecx
    mov [rdi + 28], ax                       ; state
    mov byte [rdi + 30], 0                   ; mode Normal
    mov byte [rdi + 31], 2                   ; flags: same-screen
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
.sx_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_is_inferior — edi = candidate xid, esi = ancestor xid.
; al = 1 iff edi is a strict descendant of esi (parent-chain walk).
; ----------------------------------------------------------------------------
window_is_inferior:
    push rbx
    mov ebx, esi
.wii_loop:
    test edi, edi
    jz .wii_no
    cmp edi, X_ROOT_WINDOW
    je .wii_no
    call window_lookup
    test rax, rax
    jz .wii_no
    mov edi, [rax + 4]                        ; parent
    cmp edi, ebx
    je .wii_yes
    jmp .wii_loop
.wii_yes:
    mov eax, 1
    pop rbx
    ret
.wii_no:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; pointer_crossings — rbx = record of the window now under the pointer.
; When it changed since last motion: LeaveNotify to the old window,
; EnterNotify to the new, with X-correct details: entering an inferior →
; Leave(old, Inferior) + Enter(new, Ancestor); the reverse mirrored; else
; Nonlinear. GTK keeps a widget's prelight on Leave(detail=Inferior) —
; without this every deep-window hop mass-unhighlights the whole widget
; chain and floods repaints. Runs BEFORE any motion-mask gating — menu
; item windows select Enter/Leave without PointerMotion. Preserves regs.
; ----------------------------------------------------------------------------
pointer_crossings:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov eax, [rbx]
    cmp eax, [last_enter_win]
    je .pc_done
    mov r8d, 3                               ; leave detail = Nonlinear
    mov r9d, 3                               ; enter detail = Nonlinear
    mov edi, [last_enter_win]
    test edi, edi
    jz .pc_details_done
    mov edi, [rbx]                           ; new inferior of old?
    mov esi, [last_enter_win]
    call window_is_inferior
    test al, al
    jz .pc_chk_up
    mov r8d, 2                               ; Leave(old, Inferior)
    xor r9d, r9d                             ; Enter(new, Ancestor)
    jmp .pc_details_done
.pc_chk_up:
    mov edi, [last_enter_win]                ; old inferior of new?
    mov esi, [rbx]
    call window_is_inferior
    test al, al
    jz .pc_details_done
    xor r8d, r8d                             ; Leave(old, Ancestor)
    mov r9d, 2                               ; Enter(new, Inferior)
.pc_details_done:
    mov edi, [last_enter_win]
    test edi, edi
    jz .pc_enter
    call window_lookup
    test rax, rax
    jz .pc_enter
    push r9
    mov rsi, rax
    mov edi, 8                               ; LeaveNotify
    mov edx, r8d
    call send_crossing
    pop r9
.pc_enter:
    mov eax, [rbx]
    mov [last_enter_win], eax
    mov edi, 7                               ; EnterNotify
    mov rsi, rbx
    mov edx, r9d
    call send_crossing
    call cursor_sync                         ; new window may define a cursor
.pc_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; sync_pointer_window — recompute the window under the (stationary) pointer
; and emit Enter/Leave if it changed. Real servers send crossings whenever
; the window under the pointer changes for ANY reason — map, unmap,
; configure, destroy, reparent — not just motion. GDK silently drops wheel
; button events for windows it never got an Enter for (clicks survive),
; so a window mapped under a parked cursor (tile workspace switch) had
; dead two-finger scrolling in firefox until the pointer moved.
; ----------------------------------------------------------------------------
sync_pointer_window:
    push rbx
    call window_at_point
    test rax, rax
    jz .spw_cur
    mov rbx, rax
    call pointer_crossings
.spw_cur:
    call cursor_sync                         ; window/grab cursor may differ now
    pop rbx
    ret

; ----------------------------------------------------------------------------
; border_damage — rdi = window record. Damage the window rect expanded by
; border_width (the ring lives OUTSIDE w×h; tile recolours it per focus
; change via CWBorderPixel). No-op when unmapped or borderless.
; Preserves all registers the CW value walker relies on.
; ----------------------------------------------------------------------------
border_damage:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    movzx r9d, word [rdi + 16]               ; border width
    test r9d, r9d
    jz .bdm_out
    cmp byte [rdi + 28], 0                   ; mapped?
    je .bdm_out
    mov eax, r9d
    neg eax                                  ; local x = -bw
    mov edx, eax                             ; local y = -bw
    movzx ecx, word [rdi + 12]
    lea ecx, [rcx + r9*2]                    ; w + 2bw
    movzx r8d, word [rdi + 14]
    lea r8d, [r8 + r9*2]                     ; h + 2bw
    call damage_add_local
    mov byte [comp_dirty], 1
.bdm_out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; brd_fill — eax = x, esi = y, edi = w, ecx = h (screen coords), edx =
; colour. Solid fill clipped to bw_clip (which is itself screen-clipped).
; ----------------------------------------------------------------------------
brd_fill:
    push rbx
    push r12
    push r13
    push r14
    push rbp
    mov ebp, edx                             ; colour
    mov r12d, eax
    add r12d, edi                            ; x2
    mov r13d, esi
    add r13d, ecx                            ; y2
    cmp eax, [bw_clip_x1]
    jge .bf_x1
    mov eax, [bw_clip_x1]
.bf_x1:
    cmp esi, [bw_clip_y1]
    jge .bf_y1
    mov esi, [bw_clip_y1]
.bf_y1:
    cmp r12d, [bw_clip_x2]
    jle .bf_x2
    mov r12d, [bw_clip_x2]
.bf_x2:
    cmp r13d, [bw_clip_y2]
    jle .bf_y2
    mov r13d, [bw_clip_y2]
.bf_y2:
    sub r12d, eax                            ; w after clip
    jle .bf_out
    sub r13d, esi                            ; h after clip
    jle .bf_out
    mov ebx, eax                             ; x
    mov r14, [drm_dumb_addr]
.bf_row:
    mov eax, esi
    imul eax, [drm_dumb_pitch]
    mov rdi, r14
    add rdi, rax
    mov eax, ebx
    lea rdi, [rdi + rax*4]
    mov eax, ebp
    mov ecx, r12d
    rep stosd
    inc esi
    dec r13d
    jnz .bf_row
.bf_out:
    pop rbp
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; border_draw — rdi = window record. Paint the X border ring (border_width
; > 0) in border_pixel around the w×h geometry, clipped to bw_clip. tile
; insets tiled clients by the border so the ring lands exactly on the cell
; edge; the focused window's ring is brighter (tile recolours per focus).
; ----------------------------------------------------------------------------
border_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    movzx r15d, word [rbx + 16]              ; border width
    test r15d, r15d
    jz .brd_out
    cmp byte [rbx + 19], 2                   ; InputOnly → no border
    je .brd_out
    mov edi, [rbx]
    call window_abs_xy                       ; r10d/r11d = abs origin
    mov r12d, r10d                           ; x
    mov r13d, r11d                           ; y
    mov eax, [rbx + 56]                      ; border_pixel
    or  eax, 0xFF000000
    movzx r14d, word [rbx + 12]              ; w
    movzx ebx, word [rbx + 14]               ; h (record ptr done)
    push rax                                 ; colour at [rsp]
    ; top: (x-bw, y-bw, w+2bw, bw)
    mov eax, r12d
    sub eax, r15d
    mov esi, r13d
    sub esi, r15d
    lea edi, [r14 + r15*2]
    mov ecx, r15d
    mov edx, [rsp]
    call brd_fill
    ; bottom: (x-bw, y+h, w+2bw, bw)
    mov eax, r12d
    sub eax, r15d
    lea esi, [r13 + rbx]
    lea edi, [r14 + r15*2]
    mov ecx, r15d
    mov edx, [rsp]
    call brd_fill
    ; left: (x-bw, y, bw, h)
    mov eax, r12d
    sub eax, r15d
    mov esi, r13d
    mov edi, r15d
    mov ecx, ebx
    mov edx, [rsp]
    call brd_fill
    ; right: (x+w, y, bw, h)
    lea eax, [r12 + r14]
    mov esi, r13d
    mov edi, r15d
    mov ecx, ebx
    mov edx, [rsp]
    call brd_fill
    pop rax
.brd_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; core_motion_wanted — eax = a core event mask. Returns ZF=0 (jnz) if a
; MotionNotify should be delivered for the current button_state:
;   PointerMotionMask   (0x40)          → always
;   Button[1-5]MotionMask (0x100..0x1000) → while THAT button is held
;   ButtonMotionMask    (0x2000)        → while ANY button is held
; The per-button selection bits line up with button_state's bits, so an AND
; tests "selected AND held" in one step. This is what makes drag-select work
; (scrot -s, DND): those grab with ButtonMotionMask, not PointerMotionMask.
; Clobbers eax only (ecx/edx preserved).
; ----------------------------------------------------------------------------
core_motion_wanted:
    push rcx
    push rdx
    test eax, 0x40                           ; PointerMotionMask → unconditional
    jnz .cmw_yes
    mov edx, eax
    and edx, 0x1F00                          ; Button1..5MotionMask bits selected
    and edx, [button_state]                  ; ...AND that button currently held
    jnz .cmw_yes
    test eax, 0x2000                          ; ButtonMotionMask → any button held
    jz .cmw_no
    cmp dword [button_state], 0
    jne .cmw_yes
.cmw_no:
    xor eax, eax                             ; ZF=1 → don't deliver
    pop rdx
    pop rcx
    ret
.cmw_yes:
    mov eax, 1
    test eax, eax                            ; ZF=0 → deliver
    pop rdx
    pop rcx
    ret

; deliver_pointer_motion — send MotionNotify to the window under the cursor
; (or, during a grab, to the grabbing client) if the core mask wants motion
; for the current button_state (see core_motion_wanted). No-op otherwise.
; ----------------------------------------------------------------------------
deliver_pointer_motion:
    push rbx
    cmp dword [ptr_grab_win], 0              ; pointer grabbed?
    je .dpm_point
    cmp byte [ptr_grab_owner], 0             ; owner-events False → report
    jne .dpm_gdeep                           ; against the grab window
    call grab_owner_target
    test rax, rax
    jz .dpm_done
    mov rbx, rax
    mov eax, [ptr_grab_mask]                 ; gate on the grab's mask only
    call core_motion_wanted                  ; (scrot -s: ButtonMotionMask)
    jz .dpm_done
    jmp .dpm_gdeliver
.dpm_gdeep:
    call grab_pointer_target                 ; deepest client window, else grab win
    test rax, rax
    jz .dpm_done
    mov rbx, rax
    call pointer_crossings                   ; Enter/Leave BEFORE motion gating
    ; owner_events: motion over a client window is reported per THAT window's
    ; mask, not the grab's. GTK grabs the toplevel with a mask that may omit
    ; PointerMotion, but the menu window selects it — without honouring the
    ; target's mask, motion is dropped, so menu items never highlight/select
    ; and a click has no selected item to activate.
    test dword [rbx + 52], 0x40             ; XI2 Motion selected → skip core gate
    jnz .dpm_gdeliver
    mov eax, [rbx + 24]                     ; target window's core mask wants motion?
    call core_motion_wanted
    jnz .dpm_gdeliver
    mov eax, [ptr_grab_mask]                ; else the grab's mask (scrot -s: Button
    call core_motion_wanted                 ; MotionMask while dragging → deliver)
    jz .dpm_done
.dpm_gdeliver:
    mov r8d, [cursor_x]
    sub r8d, [wapd_abs_x]                    ; event-x (absolute-aware)
    mov r9d, [cursor_y]
    sub r9d, [wapd_abs_y]                    ; event-y
    mov eax, [ptr_grab_slot]                 ; grabs deliver to the GRABBING
    cmp eax, MAX_CLIENTS                      ; client (window may be root)
    jae .dpm_done
    cmp byte [ptr_grab_xi2], 0               ; format keys on the GRAB, not
    jne .dpm_xi2                             ; a foreign XI2 mask on the target
    jmp .dpm_core
.dpm_point:
    call window_at_point
    test rax, rax
    jz .dpm_done
    mov rbx, rax
    call pointer_crossings                   ; Enter/Leave BEFORE motion gating
    test dword [rbx + 52], 0x40              ; XI2 Motion selected?
    jnz .dpm_calc
    mov eax, [rbx + 24]                      ; core mask (Pointer/Button motion)
    call core_motion_wanted
    jz .dpm_done
.dpm_calc:
    mov r8d, [cursor_x]
    sub r8d, [wap_abs_x]                     ; event-x (absolute origin — a
    mov r9d, [cursor_y]                      ; child's own x/y is parent-
    sub r9d, [wap_abs_y]                     ; relative)
.dpm_emit:
    mov eax, [rbx]                           ; xid → owner slot
    cmp eax, X_RID_BASE
    jb .dpm_done
    sub eax, X_RID_BASE
    shr eax, 21
.dpm_emit_slot:
    cmp eax, MAX_CLIENTS
    jae .dpm_done
    ; Non-grab (point) path: XI2 iff the target window selected XI_Motion.
    test dword [rbx + 52], 0x40
    jz .dpm_core
.dpm_xi2:
    mov edi, eax                             ; slot
    mov esi, 6                               ; XI_Motion
    xor edx, edx
    mov ecx, [rbx]
    call send_xi2_device_event
    jmp .dpm_done
.dpm_core:
    push r8
    push r9
    mov edi, eax                             ; slot
    mov esi, 6                               ; MotionNotify
    xor edx, edx                             ; detail 0
    mov ecx, [rbx]                           ; window
    pop r9
    pop r8
    call send_pointer_event
.dpm_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; deliver_pointer_button — edi = event code (4 press / 5 release),
; esi = button number (1/2/3/4/5). Sends to the window under the cursor if
; it selected ButtonPress (0x04) / ButtonRelease (0x08).
; ----------------------------------------------------------------------------
deliver_pointer_button:
    push rbx
    push r12
    push r13
    mov r12d, edi                            ; code
    mov r13d, esi                            ; button
    cmp dword [ptr_grab_win], 0              ; pointer grabbed? (open menu, DND...)
    je .dpb_point
    cmp byte [ptr_grab_owner], 0             ; owner-events False → the event
    jne .dpb_gdeep                           ; window IS the grab window (scrot -s
    call grab_owner_target                   ; does XWindowEvent(root, ...))
    test rax, rax
    jz .dpb_done
    mov rbx, rax
    mov ecx, 0x04
    cmp r12d, 4
    je .dpb_gomask
    mov ecx, 0x08
.dpb_gomask:
    test [ptr_grab_mask], ecx                ; gate on the grab's mask only
    jz .dpb_done
    jmp .dpb_gdeliver
.dpb_gdeep:
    call grab_pointer_target                 ; deepest client window, else grab win
    test rax, rax
    jz .dpb_done
    mov rbx, rax
    mov ecx, 0x04                            ; press vs release mask bit
    cmp r12d, 4
    je .dpb_gmask
    mov ecx, 0x08
.dpb_gmask:
    bt dword [rbx + 52], r12d                ; XI2 press/release selected →
    jc .dpb_gdeliver                         ; skip the core-mask gate
    test [rbx + 24], ecx                     ; owner_events: target window wants it?
    jnz .dpb_gdeliver
    test [ptr_grab_mask], ecx                ; else the grab itself wants it?
    jz .dpb_done
.dpb_gdeliver:
    mov r8d, [cursor_x]
    sub r8d, [wapd_abs_x]                    ; event-x (absolute-aware)
    mov r9d, [cursor_y]
    sub r9d, [wapd_abs_y]                    ; event-y
    mov eax, [ptr_grab_slot]                 ; grabs deliver to the GRABBING
    cmp eax, MAX_CLIENTS                      ; client (window may be root)
    jae .dpb_done
    ; Grab format keys on HOW the grab was taken (ptr_grab_xi2), NOT the
    ; target window's XI2 mask — a foreign XI2 selection on root would
    ; otherwise send a core grabber (rofi) an XI2 event it never asked for.
    cmp byte [ptr_grab_xi2], 0
    jne .dpb_xi2
    jmp .dpb_core
.dpb_point:
    call window_at_point
    test rax, rax
    jz .dpb_done
    mov rbx, rax
    mov ecx, 0x04                            ; ButtonPressMask
    cmp r12d, 4
    je .dpb_mask
    mov ecx, 0x08                            ; ButtonReleaseMask
.dpb_mask:
    bt dword [rbx + 52], r12d                ; XI2 selected → skip core gate
    jc .dpb_calc
    test [rbx + 24], ecx
    jz .dpb_done
.dpb_calc:
    mov r8d, [cursor_x]
    sub r8d, [wap_abs_x]                     ; event-x (absolute origin)
    mov r9d, [cursor_y]
    sub r9d, [wap_abs_y]                     ; event-y
.dpb_emit:
    mov eax, [rbx]
    cmp eax, X_RID_BASE
    jb .dpb_done
    sub eax, X_RID_BASE
    shr eax, 21
.dpb_emit_slot:
    cmp eax, MAX_CLIENTS
    jae .dpb_done
    ; Non-grab (focus/point) path: XI2 iff the target window selected it.
    bt dword [rbx + 52], r12d
    jnc .dpb_core
.dpb_xi2:
    mov edi, eax                             ; slot
    mov esi, r12d                            ; evtype (4/5 = core codes)
    mov edx, r13d                            ; detail = button
    mov ecx, [rbx]                           ; window
    call send_xi2_device_event
    jmp .dpb_done
.dpb_core:
    push r8
    push r9
    mov edi, eax                             ; slot
    mov esi, r12d                            ; code
    mov edx, r13d                            ; detail = button
    mov ecx, [rbx]                           ; window
    pop r9
    pop r8
    call send_pointer_event
.dpb_done:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_pointer_event — edi = client slot, esi = event code (4/5/6),
; edx = detail (button# or 0), ecx = window xid, r8d = event-x, r9d = event-y.
; Root coords come from cursor_x/y; state from button_state | mod_state.
; ----------------------------------------------------------------------------
send_pointer_event:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi                             ; slot
    mov r12d, esi                            ; code
    mov r13d, edx                            ; detail
    mov r14d, ecx                            ; window
    mov r15d, r8d                            ; event-x
    push r9                                   ; event-y
    mov eax, ebx
    call client_meta_addr
    mov rdi, rax                             ; meta ptr
    lea rsi, [reply_buf]
    mov [rsi + 0], r12b                      ; code
    mov [rsi + 1], r13b                      ; detail
    mov eax, [rdi + 8]
    mov [rsi + 2], ax                        ; seq
    mov eax, [server_time_ms]
    mov [rsi + 4], eax                       ; time (real ms, not CurrentTime)
    mov dword [rsi + 8], X_ROOT_WINDOW
    mov [rsi + 12], r14d                     ; event window
    mov dword [rsi + 16], 0                  ; child
    mov eax, [cursor_x]
    mov [rsi + 20], ax                       ; root-x
    mov eax, [cursor_y]
    mov [rsi + 22], ax                       ; root-y
    mov [rsi + 24], r15w                     ; event-x
    pop rax                                   ; event-y
    mov [rsi + 26], ax                       ; event-y
    mov eax, [button_state]
    movzx ecx, byte [mod_state]
    or eax, ecx
    mov [rsi + 28], ax                       ; state
    mov byte [rsi + 30], 1                   ; same-screen
    mov byte [rsi + 31], 0
    mov edi, [rdi]                           ; client fd
    mov rdx, 32
    EV_SEND
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_set_input_focus — rsi = req ptr (+4 focus window). Records the
; focus target so key events route there.
; ----------------------------------------------------------------------------
handle_set_input_focus:
    mov eax, [rsi + 4]
    mov [focus_window], eax
    ret

; ----------------------------------------------------------------------------
; first_mapped_window — returns the xid of the first mapped non-root window
; in eax, or 0. Used as the default key target when no focus is set (no WM).
; ----------------------------------------------------------------------------
first_mapped_window:
    push rbx
    xor ebx, ebx
.fmw_loop:
    cmp ebx, MAX_WINDOWS
    jge .fmw_none
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea rax, [windows + rax]
    mov edx, [rax]
    test edx, edx
    jz .fmw_next
    cmp edx, X_ROOT_WINDOW
    je .fmw_next
    cmp byte [rax + 28], 0                    ; mapped?
    je .fmw_next
    mov eax, edx                              ; xid
    pop rbx
    ret
.fmw_next:
    inc ebx
    jmp .fmw_loop
.fmw_none:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; deliver_to_focus — esi = x11 keycode, r8d = event code (2/3). Routes the
; key event to the focused window's client (or the first mapped window when
; focus is None/PointerRoot or stale). No-op if no suitable window.
; ----------------------------------------------------------------------------
deliver_to_focus:
    push rbx
    push r12
    push r13
    mov r12d, esi                            ; keycode
    mov r13d, r8d                            ; event code
    ; An ACTIVE keyboard grab (XGrabKeyboard — rofi, GTK menus) takes every
    ; key event, press AND release, overriding focus. Without this route
    ; rofi showed but no typed key ever reached it.
    mov eax, [active_kbd_slot]
    test eax, eax
    js .dtf_nograb
    cmp byte [kbd_grab_xi2], 0               ; XIGrabDevice → XI2 key events
    je .dtf_grab_core
    mov edi, [active_kbd_window]
    call window_abs_xy                       ; r10d/r11d = grab window origin
    mov r8d, [cursor_x]
    sub r8d, r10d
    mov r9d, [cursor_y]
    sub r9d, r11d
    mov edi, [active_kbd_slot]
    mov esi, r13d                            ; evtype (2/3 = core codes)
    mov edx, r12d                            ; detail = keycode
    mov ecx, [active_kbd_window]
    call send_xi2_device_event
    jmp .dtf_done
.dtf_grab_core:
    mov edi, eax
    mov esi, r12d
    movzx ecx, byte [mod_state]
    mov edx, [active_kbd_window]
    mov r8d, r13d
    call send_key_press
    jmp .dtf_done
.dtf_nograb:
    ; Pick the target window.
    mov eax, [focus_window]
    cmp eax, 1                               ; 0=None, 1=PointerRoot
    jbe .dtf_default
    mov edi, eax
    push rax
    call window_lookup
    pop rcx
    test rax, rax
    jz .dtf_default
    cmp byte [rax + 28], 0                    ; mapped?
    je .dtf_default
    mov ebx, ecx                              ; target xid
    jmp .dtf_have
.dtf_default:
    call first_mapped_window
    test eax, eax
    jz .dtf_done
    mov ebx, eax
.dtf_have:
    ; owner slot = (xid - X_RID_BASE) >> 21
    mov eax, ebx
    cmp eax, X_RID_BASE
    jb .dtf_done
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .dtf_done
    push rax
    mov edi, ebx
    call window_lookup                        ; XI2 selected on the target?
    pop rcx
    test rax, rax
    jz .dtf_done
    bt dword [rax + 52], r13d                 ; evtype 2/3 = core key codes
    jnc .dtf_core
    mov edi, ebx
    call window_abs_xy                        ; r10d/r11d = window origin
    mov r8d, [cursor_x]
    sub r8d, r10d
    mov r9d, [cursor_y]
    sub r9d, r11d
    mov eax, ebx
    sub eax, X_RID_BASE
    shr eax, 21
    mov edi, eax
    mov esi, r13d                             ; evtype
    mov edx, r12d                             ; detail = keycode
    mov ecx, ebx                              ; window
    call send_xi2_device_event
    jmp .dtf_done
.dtf_core:
    mov edi, ecx                              ; client slot
    mov esi, r12d                             ; keycode
    movzx ecx, byte [mod_state]
    mov edx, ebx                              ; window
    mov r8d, r13d                             ; event code
    call send_key_press
.dtf_done:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; find_key_grab — edi = x11 keycode, esi = mod state. Returns matching
; grab record ptr in rax, or 0.
; ----------------------------------------------------------------------------
find_key_grab:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    xor ebx, ebx
.fkg_loop:
    cmp ebx, MAX_KEY_GRABS
    jge .fkg_miss
    mov rax, rbx
    imul rax, KEY_GRAB_SIZE
    lea rax, [key_grabs + rax]
    cmp dword [rax], 0
    je .fkg_next
    movzx ecx, byte [rax + 8]
    cmp ecx, r12d
    jne .fkg_next
    movzx ecx, word [rax + 10]
    cmp ecx, r13d
    jne .fkg_next
    pop r13
    pop r12
    pop rbx
    ret
.fkg_next:
    inc ebx
    jmp .fkg_loop
.fkg_miss:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_key_press — edi = client slot, esi = x11 keycode, ecx = mod
; state, edx = window, r8d = event code (2 = KeyPress, 3 = KeyRelease).
; Emits a 32-byte key event on the client's fd.
; ----------------------------------------------------------------------------
send_key_press:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, r8d                             ; event code
    push rcx                                  ; mod_state on stack
    mov eax, ebx
    call client_meta_addr
    mov rdi, rax                              ; meta ptr

    lea rsi, [reply_buf]
    mov [rsi + 0], r14b                       ; KeyPress (2) / KeyRelease (3)
    mov [rsi + 1], r12b                       ; detail (keycode)
    mov eax, [rdi + 8]
    mov [rsi + 2], ax                         ; seq (client's last)
    mov eax, [server_time_ms]
    mov [rsi + 4], eax                        ; time (real ms, not CurrentTime)
    mov dword [rsi + 8], X_ROOT_WINDOW        ; root
    mov [rsi + 12], r13d                      ; event window
    mov dword [rsi + 16], 0                   ; child
    mov dword [rsi + 20], 0                   ; root-x, root-y
    mov dword [rsi + 24], 0                   ; event-x, event-y
    pop rax                                   ; mod_state
    mov [rsi + 28], ax                        ; state
    mov byte [rsi + 30], 1                    ; same-screen
    mov byte [rsi + 31], 0

    mov edi, [rdi]                            ; client fd
    mov rdx, 32
    EV_SEND
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4e — SubstructureRedirect routing.
; ============================================================================
; The WM (tile) sets EM_SUBSTRUCTURE_REDIRECT on root via
; ChangeWindowAttributes; from that moment, any non-WM client's
; MapWindow / ConfigureWindow on a child of root is INTERCEPTED — the
; request goes to the WM as a MapRequest / ConfigureRequest event
; instead of executing directly. The WM looks at it, decides where
; the window goes, and re-issues MapWindow / ConfigureWindow itself
; (which run normally since the requester is the redirect owner).
;
; SubstructureNotify, set in the same event mask, sends MapNotify /
; ConfigureNotify / UnmapNotify to the WM on every actual map /
; configure / unmap of a child — so the WM can keep its view of the
; tree consistent.
; ============================================================================

; ----------------------------------------------------------------------------
; handle_reparent_window — rsi = req ptr.
;
; Request: +4 window, +8 parent, +12 x (s16), +14 y (s16)
; ============================================================================
handle_reparent_window:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi                              ; requester slot
    mov edi, [rsi + 4]
    mov r14, rsi                              ; req
    call window_lookup
    test rax, rax
    jnz .rp_have
    mov edi, ebx                              ; window gone → BadWindow (strip's
    mov esi, [r14 + 4]                        ; mid-dock race relies on it)
    mov edx, 7
    call send_bad_window
    jmp .rp_done
.rp_have:
    mov r12, rax                              ; window record
    mov r13d, [rax + 4]                       ; OLD parent xid
    mov rdi, rax                              ; damage the OLD position
    call damage_add_window
    mov ecx, [r14 + 8]
    mov [r12 + 4], ecx                        ; new parent
    mov dx, [r14 + 12]
    mov [r12 + 8], dx                         ; new x
    mov dx, [r14 + 14]
    mov [r12 + 10], dx                        ; new y
    mov rdi, r12                              ; ...and the NEW one
    call damage_add_window
    mov byte [comp_dirty], 1                  ; was missing: screen stayed
                                              ; stale after every reparent
    ; ReparentNotify to the OLD parent's SubstructureNotify subscriber —
    ; strip undocks a tray icon whose owner reparents it AWAY (GTK status
    ; icons dock via XEmbed before snixembed's SNI watcher exists, then
    ; switch to SNI and pull the icon back: without this event, strip
    ; kept the slot forever = the ghost gap at the tray's right edge.
    mov edi, r13d
    call window_lookup
    test rax, rax
    jz .rp_notify_win
    test dword [rax + 24], EM_SUBSTRUCTURE_NOTIFY
    jz .rp_notify_win
    cmp dword [rax], X_ROOT_WINDOW
    jne .rp_old_owner
    movsx edi, byte [rax + 30]                ; root → the WM's redirect owner
    cmp edi, 0
    jl .rp_notify_win
    jmp .rp_old_send
.rp_old_owner:
    mov edi, [rax]
    sub edi, X_RID_BASE
    shr edi, 21
    cmp edi, MAX_CLIENTS
    jae .rp_notify_win
.rp_old_send:
    mov esi, [rax]                            ; event window = old parent
    mov edx, [r12]                            ; window
    mov ecx, [r12 + 4]                        ; new parent
    call send_reparent_notify
.rp_notify_win:
    ; ...and to the window's own StructureNotify selector (its owner).
    test dword [r12 + 24], EM_STRUCTURE_NOTIFY
    jz .rp_done
    mov eax, [r12]
    cmp eax, X_RID_BASE
    jb .rp_done
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .rp_done
    mov edi, eax
    mov esi, [r12]                            ; event window = the window
    mov edx, [r12]
    mov ecx, [r12 + 4]
    call send_reparent_notify
.rp_done:
    call sync_pointer_window
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_reparent_notify — edi = slot, esi = event window, edx = window,
; ecx = new parent. ReparentNotify (21): event@4, window@8, parent@12,
; x@16 (s16), y@18, override-redirect@20.
; ----------------------------------------------------------------------------
send_reparent_notify:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 21                   ; ReparentNotify
    mov [rdi + 4], r12d                      ; event
    mov [rdi + 8], r13d                      ; window
    mov [rdi + 12], r14d                     ; parent
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_xi2_to_slot — edi = slot, rsi = event buffer, edx = length in bytes.
; Variable-size sibling of send_event_to_slot for XI2 GenericEvents.
; ----------------------------------------------------------------------------
send_xi2_to_slot:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    push rdx
    mov eax, r12d
    call client_meta_addr
    mov ebx, [rax]                           ; fd
    mov ecx, [rax + 8]                       ; seq
    mov [r13 + 2], cx
    pop rdx
    mov edi, ebx
    mov rsi, r13
    EV_SEND
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_xi2_device_event — XI2 Key/Button/Motion as a GenericEvent (35).
; edi = slot, esi = evtype (2 KeyPress / 3 KeyRelease / 4 ButtonPress /
; 5 ButtonRelease / 6 Motion — same numbers as the core codes), edx =
; detail (keycode / button), ecx = event window xid, r8d/r9d = event x/y
; (window-local). 84 bytes: fixed 80 + one buttons-mask word (GTK reads
; held buttons from it during drags). Coordinates are FP1616.
; ----------------------------------------------------------------------------
send_xi2_device_event:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    lea rdi, [xi2_buf]
    xor eax, eax
    mov ecx, 11
    push rdi
    rep stosq
    pop rdi
    mov byte [rdi + 0], 35                   ; GenericEvent
    mov byte [rdi + 1], XI_MAJOR
    mov dword [rdi + 4], 13                  ; (84-32)/4
    mov [rdi + 8], r12w                      ; evtype
    mov eax, 2                               ; deviceid: master pointer...
    cmp r12d, 3
    ja .sxd_dev
    mov eax, 3                               ; ...or master keyboard for keys
.sxd_dev:
    mov [rdi + 10], ax
    mov [rdi + 52], ax                       ; sourceid = deviceid
    mov eax, [server_time_ms]
    mov [rdi + 12], eax
    mov [rdi + 16], r13d                     ; detail
    mov dword [rdi + 20], X_ROOT_WINDOW
    mov [rdi + 24], r14d                     ; event window
    mov eax, [cursor_x]
    shl eax, 16
    mov [rdi + 32], eax                      ; root_x FP1616
    mov eax, [cursor_y]
    shl eax, 16
    mov [rdi + 36], eax
    mov eax, r8d
    shl eax, 16
    mov [rdi + 40], eax                      ; event_x
    mov eax, r9d
    shl eax, 16
    mov [rdi + 44], eax
    mov word [rdi + 48], 1                   ; buttons_len = 1 word
    movzx eax, byte [mod_state]
    mov [rdi + 60], eax                      ; mods.base
    mov [rdi + 72], eax                      ; mods.effective
    mov eax, [button_state]
    shr eax, 7                               ; core bits 8+ → XI mask bits 1+
    mov [rdi + 80], eax                      ; buttons mask
    mov edi, ebx
    lea rsi, [xi2_buf]
    mov edx, 84
    call send_xi2_to_slot
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_xi2_crossing — XI2 Enter/Leave/FocusIn/FocusOut GenericEvent.
; edi = slot, esi = evtype (7 Enter / 8 Leave / 9 FocusIn / 10 FocusOut),
; edx = detail (0 Ancestor / 2 Inferior / 3 Nonlinear), ecx = window xid,
; r8d/r9d = event x/y (window-local). 72 bytes (buttons_len = 0).
; ----------------------------------------------------------------------------
send_xi2_crossing:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    lea rdi, [xi2_buf]
    xor eax, eax
    mov ecx, 9
    push rdi
    rep stosq
    pop rdi
    mov byte [rdi + 0], 35
    mov byte [rdi + 1], XI_MAJOR
    mov dword [rdi + 4], 10                  ; (72-32)/4
    mov [rdi + 8], r12w                      ; evtype
    mov word [rdi + 10], 2                   ; deviceid = master pointer
    mov eax, [server_time_ms]
    mov [rdi + 12], eax
    mov word [rdi + 16], 2                   ; sourceid
    mov [rdi + 19], r13b                     ; detail (mode @18 = Normal = 0)
    mov dword [rdi + 20], X_ROOT_WINDOW
    mov [rdi + 24], r14d                     ; event window
    mov eax, [cursor_x]
    shl eax, 16
    mov [rdi + 32], eax
    mov eax, [cursor_y]
    shl eax, 16
    mov [rdi + 36], eax
    mov eax, r8d
    shl eax, 16
    mov [rdi + 40], eax
    mov eax, r9d
    shl eax, 16
    mov [rdi + 44], eax
    mov byte [rdi + 48], 1                   ; same_screen
    mov eax, [focus_window]                  ; focus = is this the focus window?
    cmp eax, r14d
    sete byte [rdi + 49]
    movzx eax, byte [mod_state]
    mov [rdi + 52], eax                      ; mods.base
    mov [rdi + 64], eax                      ; mods.effective
    mov edi, ebx
    lea rsi, [xi2_buf]
    mov edx, 72
    call send_xi2_to_slot
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_event_to_slot — edi = client slot, rsi = 32-byte event buffer.
; Writes the buffer to the client's fd; events DON'T use sequence
; numbers the way replies do, but the seq slot is normally the
; client's last-sent seq, which we have in meta + 8.
; ----------------------------------------------------------------------------
send_event_to_slot:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    mov eax, r12d
    call client_meta_addr
    mov ebx, [rax]                            ; fd
    mov ecx, [rax + 8]                        ; seq
    mov [r13 + 2], cx                         ; patch into event[2..3]
    mov edi, ebx
    mov rsi, r13
    mov rdx, 32
    EV_SEND
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_map_request — edi = slot, esi = parent xid, edx = window xid.
;
; MapRequest event (32 bytes):
;   +0  code = 20         +1  0
;   +2  sequence          +4  parent
;   +8  window            +12..31 pad
; ----------------------------------------------------------------------------
send_map_request:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 20
    mov byte [rdi + 1], 0
    mov word [rdi + 2], 0
    mov dword [rdi + 4], r12d
    mov dword [rdi + 8], r13d
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_configure_request — edi = slot, rsi = original req ptr,
; edx = window xid, ecx = parent xid.
;
; The original request has all the geometry fields starting at +8;
; we just unpack them. Stack-mode comes from request +1, value-mask
; from request +8 (low 16 bits).
;
; ConfigureRequest event (32 bytes):
;   +0  code = 23         +1  stack-mode
;   +2  sequence          +4  parent
;   +8  window            +12 sibling
;   +16 x (s16)           +18 y (s16)
;   +20 width (u16)       +22 height (u16)
;   +24 border-width (u16) +26 value-mask (u16)
;   +28..31 pad
;
; The original ConfigureWindow value-list is variable-length; we walk
; the mask to pull each present value. Geometry fields default to the
; window's current values when not in the mask.
; ----------------------------------------------------------------------------
send_configure_request:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov r12, rsi                              ; req ptr
    mov r13d, edx                             ; window xid
    mov r14d, ecx                             ; parent xid

    ; Look up window to grab current geometry as defaults.
    mov edi, r13d
    call window_lookup
    mov r15, rax                              ; window record or 0

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 23
    movzx eax, byte [r12 + 1]                 ; stack-mode (we forward it)
    mov [rdi + 1], al
    mov word [rdi + 2], 0
    mov [rdi + 4], r14d
    mov [rdi + 8], r13d
    mov dword [rdi + 12], 0                   ; sibling (we ignore CFG_SIBLING)

    ; Defaults from window record.
    xor eax, eax
    test r15, r15
    jz .scr_defaults_done
    mov ax, [r15 + 8]
    mov [rdi + 16], ax
    mov ax, [r15 + 10]
    mov [rdi + 18], ax
    mov ax, [r15 + 12]
    mov [rdi + 20], ax
    mov ax, [r15 + 14]
    mov [rdi + 22], ax
    mov ax, [r15 + 16]
    mov [rdi + 24], ax
.scr_defaults_done:

    ; Walk value-mask + value-list and overwrite defaults where present.
    movzx ecx, word [r12 + 8]
    mov [rdi + 26], cx                        ; value-mask
    lea r9, [r12 + 12]
    test ecx, CFG_X
    jz .scr_y
    mov eax, [r9]
    mov [rdi + 16], ax
    add r9, 4
.scr_y:
    test ecx, CFG_Y
    jz .scr_w
    mov eax, [r9]
    mov [rdi + 18], ax
    add r9, 4
.scr_w:
    test ecx, CFG_WIDTH
    jz .scr_h
    mov eax, [r9]
    mov [rdi + 20], ax
    add r9, 4
.scr_h:
    test ecx, CFG_HEIGHT
    jz .scr_b
    mov eax, [r9]
    mov [rdi + 22], ax
    add r9, 4
.scr_b:
    test ecx, CFG_BORDER_WIDTH
    jz .scr_pad
    mov eax, [r9]
    mov [rdi + 24], ax
.scr_pad:
    mov dword [rdi + 28], 0

    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_map_notify — edi = slot, esi = event window (the parent),
; edx = child window.
;
; MapNotify event (32 bytes):
;   +0  code = 19         +1  0
;   +2  sequence          +4  event (the window with the notify mask)
;   +8  window (the child)
;   +12 override-redirect (BOOL)
;   +13..31 pad
; ----------------------------------------------------------------------------
send_map_notify:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 19
    mov byte [rdi + 1], 0
    mov word [rdi + 2], 0
    mov [rdi + 4], r12d
    mov [rdi + 8], r13d
    ; Look up child for its override-redirect flag.
    push rdi
    mov edi, r13d
    call window_lookup
    test rax, rax
    jz .smn_or_none
    movzx ecx, byte [rax + 29]
    pop rdi
    mov [rdi + 12], cl
    jmp .smn_pad
.smn_or_none:
    pop rdi
    mov byte [rdi + 12], 0
.smn_pad:
    mov byte [rdi + 13], 0
    mov word [rdi + 14], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_configure_notify — edi = recipient slot, rsi = window record ptr.
; Sends a ConfigureNotify for the window to its own client (StructureNotify).
;   ConfigureNotify (32 bytes): code 22, event@4, window@8, above@12=None,
;   x@16, y@18, width@20, height@22, border@24, override-redirect@26.
; ----------------------------------------------------------------------------
send_configure_notify:
    push rbx
    push r12
    mov ebx, edi                               ; recipient slot
    mov r12, rsi                               ; window record
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 22
    mov byte [rdi + 1], 0
    mov word [rdi + 2], 0
    mov eax, [r12]                             ; window xid
    mov [rdi + 4], eax                         ; event window
    mov [rdi + 8], eax                         ; window
    mov dword [rdi + 12], 0                    ; above-sibling = None
    mov ax, [r12 + 8]
    mov [rdi + 16], ax                         ; x
    mov ax, [r12 + 10]
    mov [rdi + 18], ax                         ; y
    mov ax, [r12 + 12]
    mov [rdi + 20], ax                         ; width
    mov ax, [r12 + 14]
    mov [rdi + 22], ax                         ; height
    mov ax, [r12 + 16]
    mov [rdi + 24], ax                         ; border-width
    movzx eax, byte [r12 + 29]
    mov [rdi + 26], al                         ; override-redirect
    mov byte [rdi + 27], 0
    mov dword [rdi + 28], 0
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_bad_window — edi = client slot, esi = the bad xid, edx = major opcode.
; X error 3 (BadWindow) with the client's CURRENT sequence number. A request
; on a nonexistent window must ERROR, not vanish: strip docks tray icons
; with Reparent/Configure/Map and relies on BadWindow to drop an icon whose
; owner destroyed it mid-dock (the nm-applet SNI-switch race) — silence
; leaks the slot as a tray ghost.
; ----------------------------------------------------------------------------
send_bad_window:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov eax, ebx
    call client_meta_addr
    mov rbx, rax
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 0                    ; Error
    mov byte [rdi + 1], 3                    ; BadWindow
    mov eax, [rbx + 8]
    mov [rdi + 2], ax                        ; sequence
    mov [rdi + 4], r12d                      ; bad resource id
    mov [rdi + 10], r13b                     ; major opcode
    mov edi, [rbx]                           ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov edx, 32
    syscall
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_destroy_notify — edi = client slot, esi = event window, edx = window.
; DestroyNotify (17). Clients that select StructureNotify on their own
; window and destroy it BLOCK until this arrives (scrot -s waits for its
; selection overlay to be really gone before grabbing the screen).
; ----------------------------------------------------------------------------
send_destroy_notify:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [reply_buf]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov byte [rdi + 0], 17                   ; DestroyNotify
    mov [rdi + 4], r12d                      ; event
    mov [rdi + 8], r13d                      ; window
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; send_unmap_notify — same signature as send_map_notify.
;
; UnmapNotify event (32 bytes):
;   +0  code = 18         +1  0
;   +2  sequence          +4  event
;   +8  window            +12 from-configure (BOOL, false here)
;   +13..31 pad
; ----------------------------------------------------------------------------
send_unmap_notify:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 18
    mov byte [rdi + 1], 0
    mov word [rdi + 2], 0
    mov [rdi + 4], r12d
    mov [rdi + 8], r13d
    mov byte [rdi + 12], 0
    mov byte [rdi + 13], 0
    mov word [rdi + 14], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, ebx
    lea rsi, [reply_buf]
    call send_event_to_slot
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4f — software compositor.
; ============================================================================
; init_compositor sets up the same DRM dumb buffer + framebuffer + CRTC
; as the phase-2b --modeset test, but persistently (no sleep, no
; restore). recomposite_screen walks the window tree and paints each
; mapped window's rect into the buffer in a per-XID colour.
;
; For phase 4f MVP, windows are solid-colour placeholders — there's no
; real backing pixmap or drawing primitive support yet. That arrives in
; later phases (CreatePixmap, PutImage, PolyFillRectangle, RENDER).
; What this commit ships: TILE'S WINDOWS SHOW UP ON THE PANEL, in their
; right positions, and re-render when they move / appear / disappear.
;
; Requires --display flag + root + no other DRM master. Without that,
; init_compositor logs a failure and the server continues network-only.
; ============================================================================

%define COMP_BG_COLOR        0x00102030     ; dark blue background

; ----------------------------------------------------------------------------
; init_compositor — persistent counterpart to do_modeset.
;
; On success: compositor_active = 1; drm_dumb_addr / drm_dumb_pitch /
; drm_modes_buf populated. Returns 0.
; On failure: prints a one-line reason and returns -1; serve_loop
; continues network-only.
; ----------------------------------------------------------------------------
init_compositor:
    push rbx
    push r12
    push r13

    ; --- open card and take master ---
    call drm_try_open
    test rax, rax
    js .ic_fail_open
    mov [drm_fd], rax
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_SET_MASTER
    xor edx, edx
    syscall
    test rax, rax
    js .ic_fail_master

    ; --- resources + outputs: primary panel + optional external ---
    call drm_probe_resources
    call modeset_pick_outputs
    test eax, eax
    jz .ic_fail_no_conn
    mov r13d, [drm_chosen_crtc]

    ; --- buffers: create both wide dumb buffers + fbs ---
    call compositor_create_buffers
    test rax, rax
    js .ic_fail_other

    ; --- GETCRTC: save the console's current CRTC state so a clean exit
    ;     (Ctrl+C, SIGTERM) can restore the text VT instead of leaving
    ;     the panel showing a freed framebuffer (= black, needs a VT
    ;     switch to recover — the "stuck screen" Geir kept hitting).
    lea rdi, [drm_crtc_save]
    xor eax, eax
    mov ecx, 13
    rep stosq
    mov [drm_crtc_save + 12], r13d
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETCRTC
    lea rdx, [drm_crtc_save]
    syscall

    ; --- SETCRTC both outputs (crtc 1 at fb x=0, crtc 2 panned to ext_x) ---
    call compositor_program_crtcs
    test rax, rax
    js .ic_fail_other

    mov byte [compositor_active], 1

    ; Arm the screen auto-off clock. The framerc parser ran before this and
    ; left cfg_blank_ms = -1 (sentinel) when no blank_timeout line existed —
    ; apply the 600s default in that case (explicit 0 = never stays 0).
    cmp dword [cfg_blank_ms], -1
    jne .ic_blank_cfg_ok
    mov dword [cfg_blank_ms], 600000
.ic_blank_cfg_ok:
    call now_mono_ms
    mov [last_input_mono], rax
    mov byte [blank_state], 0

    ; Bring up the hardware cursor sprite (non-fatal if unsupported).
    call init_hw_cursor

    ; Install SIGINT / SIGTERM / SIGHUP handlers so Ctrl+C (or kill)
    ; restores the console cleanly instead of leaving a black panel.
    mov edi, SIGINT
    call install_exit_handler
    mov edi, SIGTERM
    call install_exit_handler
    mov edi, SIGHUP
    call install_exit_handler

    ; Log what we got so we can verify mode/pitch/size after the fact.
    mov rsi, log_prefix
    mov rdx, 7
    call write_stderr
    mov rsi, log_comp_pre
    mov rdx, log_comp_pre_len
    call write_stderr
    mov eax, [screen_w]
    call write_u64_stderr
    mov rsi, log_comp_x
    mov rdx, 1
    call write_stderr
    mov eax, [screen_h]
    call write_u64_stderr
    mov rsi, log_comp_pitch
    mov rdx, log_comp_pitch_len
    call write_stderr
    mov eax, [drm_dumb_pitch]
    call write_u64_stderr
    mov rsi, log_comp_size
    mov rdx, log_comp_size_len
    call write_stderr
    mov rax, [drm_dumb_size]
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr

    mov dword [dmg_count0], -1               ; both buffers start fully stale
    mov dword [dmg_count1], -1
    mov byte [comp_dirty], 1
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

.ic_fail_open:
    mov rsi, probe_open_fail
    mov rdx, probe_open_fail_len
    call write_stderr
    jmp .ic_fail
.ic_fail_master:
    mov rsi, ms_master_fail
    mov rdx, ms_master_fail_len
    call write_stderr
    jmp .ic_fail
.ic_fail_no_conn:
    mov rsi, ms_no_conn
    mov rdx, ms_no_conn_len
    call write_stderr
    jmp .ic_fail
.ic_fail_other:
    mov rsi, ms_err_step
    mov rdx, ms_err_step_len
    call write_stderr
.ic_fail:
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; compositor_create_buffers — CREATE_DUMB/MAP/mmap/fill/ADDFB for both
; buffers at the current output dims (panel_w/h + ext_w/h). Sets screen_w/h,
; the root window record dims and all drm_dumb_*/comp_* state. rax = 0 ok,
; -1 fail. Callable at init and again at hotplug reconfigure.
; ----------------------------------------------------------------------------
compositor_create_buffers:
    ; --- CREATE_DUMB at fb dims (spans both outputs) × 32 bpp ---
    lea rdi, [drm_dumb_create]
    xor eax, eax
    mov ecx, 4
    rep stosq
    ; fb width = panel_w (+ ext_w when a second output is live), height =
    ; max of the two modes. Advertise the fb dims to X clients (setup
    ; reply + root window record slot 0); root rec width is at windows+12.
    mov eax, [panel_w]
    mov edx, [panel_h]
    cmp byte [ext_active], 0
    je .ccb_dims_done
    add eax, [ext_w]
    cmp edx, [ext_h]
    jge .ccb_dims_done
    mov edx, [ext_h]
.ccb_dims_done:
    mov [drm_dumb_create + 4], eax
    mov [screen_w], eax
    mov word [windows + 12], ax
    mov [drm_dumb_create + 0], edx
    mov [screen_h], edx
    mov word [windows + 14], dx
    ; Re-centre the pointer on the real panel size.
    mov eax, [screen_w]
    shr eax, 1
    mov [cursor_x], eax
    mov eax, [screen_h]
    shr eax, 1
    mov [cursor_y], eax
    mov dword [drm_dumb_create + 8], 32
    mov dword [drm_dumb_create + 12], 0
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CREATE_DUMB
    lea rdx, [drm_dumb_create]
    syscall
    test rax, rax
    js .ccb_fail
    mov eax, [drm_dumb_create + 16]
    mov [drm_dumb_handle], eax
    mov eax, [drm_dumb_create + 20]
    mov [drm_dumb_pitch], eax
    mov rax, [drm_dumb_create + 24]
    mov [drm_dumb_size], rax

    ; --- MAP_DUMB → mmap ---
    lea rdi, [drm_dumb_map]
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov eax, [drm_dumb_handle]
    mov [drm_dumb_map], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_MAP_DUMB
    lea rdx, [drm_dumb_map]
    syscall
    test rax, rax
    js .ccb_fail
    mov rax, [drm_dumb_map + 8]
    mov [drm_dumb_offset], rax

    mov rax, SYS_MMAP
    xor edi, edi
    mov rsi, [drm_dumb_size]
    mov edx, PROT_RW
    mov r10d, MAP_SHARED
    mov r8, [drm_fd]
    mov r9, [drm_dumb_offset]
    syscall
    cmp rax, -4096
    ja .ccb_fail
    mov [drm_dumb_addr], rax

    ; --- Initial background fill BEFORE ADDFB. The phase 2b modeset
    ;     path works exactly because it does this order: fill → ADDFB
    ;     → SETCRTC. The kernel's ADDFB sets up GTT coherency on the
    ;     buffer's current pages; writes done AFTER ADDFB sit in CPU
    ;     write-back cache and never reach the panel without an
    ;     explicit flush. So we paint the initial blue here.
    mov rdi, [drm_dumb_addr]
    mov rcx, [drm_dumb_size]
    shr rcx, 2
    mov eax, COMP_BG_COLOR
    rep stosd

    ; --- ADDFB ---
    lea rdi, [drm_fb_cmd]
    xor eax, eax
    mov ecx, 7
    rep stosd
    mov eax, [drm_dumb_create + 4]
    mov [drm_fb_cmd + 4], eax
    mov eax, [drm_dumb_create + 0]
    mov [drm_fb_cmd + 8], eax
    mov eax, [drm_dumb_pitch]
    mov [drm_fb_cmd + 12], eax
    mov dword [drm_fb_cmd + 16], 32
    mov dword [drm_fb_cmd + 20], 24
    mov eax, [drm_dumb_handle]
    mov [drm_fb_cmd + 24], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_ADDFB
    lea rdx, [drm_fb_cmd]
    syscall
    test rax, rax
    js .ccb_fail
    mov eax, [drm_fb_cmd]
    mov [drm_fb_id], eax

    ; Record buffer 0 (the one SETCRTC will show first = front).
    mov rax, [drm_dumb_addr]
    mov [comp_addr + 0], rax
    mov eax, [drm_fb_id]
    mov [comp_fbid + 0], eax
    mov eax, [drm_dumb_handle]
    mov [comp_handle + 0], eax

    ; --- Create buffer 1 (back). Same dims/pitch/size as buffer 0. The
    ;     compositor renders the back buffer then PAGE_FLIPs to it, which
    ;     forces the display engine to re-scan at vblank — the only way to
    ;     beat FBC/PSR staleness on a legacy framebuffer (DIRTYFB is
    ;     unsupported: returns -ENOENT). ---
    lea rdi, [drm_dumb_create]
    xor eax, eax
    mov ecx, 4
    rep stosq
    mov eax, [screen_w]
    mov [drm_dumb_create + 4], eax
    mov eax, [screen_h]
    mov [drm_dumb_create + 0], eax
    mov dword [drm_dumb_create + 8], 32
    mov dword [drm_dumb_create + 12], 0
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CREATE_DUMB
    lea rdx, [drm_dumb_create]
    syscall
    test rax, rax
    js .ccb_fail
    mov eax, [drm_dumb_create + 16]
    mov [comp_handle + 4], eax               ; buffer 1 handle
    ; MAP_DUMB
    lea rdi, [drm_dumb_map]
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov eax, [comp_handle + 4]
    mov [drm_dumb_map], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_MAP_DUMB
    lea rdx, [drm_dumb_map]
    syscall
    test rax, rax
    js .ccb_fail
    mov rax, [drm_dumb_map + 8]
    mov [drm_dumb_offset], rax               ; reuse as temp
    ; mmap
    mov rax, SYS_MMAP
    xor edi, edi
    mov rsi, [drm_dumb_size]
    mov edx, PROT_RW
    mov r10d, MAP_SHARED
    mov r8, [drm_fd]
    mov r9, [drm_dumb_offset]
    syscall
    cmp rax, -4096
    ja .ccb_fail
    mov [comp_addr + 8], rax                 ; buffer 1 addr
    ; fill buffer 1 blue
    mov rdi, rax
    mov rcx, [drm_dumb_size]
    shr rcx, 2
    mov eax, COMP_BG_COLOR
    rep stosd
    ; ADDFB for buffer 1
    lea rdi, [drm_fb_cmd]
    xor eax, eax
    mov ecx, 7
    rep stosd
    mov eax, [drm_dumb_create + 4]
    mov [drm_fb_cmd + 4], eax
    mov eax, [drm_dumb_create + 0]
    mov [drm_fb_cmd + 8], eax
    mov eax, [drm_dumb_pitch]
    mov [drm_fb_cmd + 12], eax
    mov dword [drm_fb_cmd + 16], 32
    mov dword [drm_fb_cmd + 20], 24
    mov eax, [comp_handle + 4]
    mov [drm_fb_cmd + 24], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_ADDFB
    lea rdx, [drm_fb_cmd]
    syscall
    test rax, rax
    js .ccb_fail
    mov eax, [drm_fb_cmd]
    mov [comp_fbid + 4], eax                 ; buffer 1 fbid
    mov dword [comp_back], 1                  ; render buffer 1 first (front=0)

    xor eax, eax
    ret
.ccb_fail:
    mov rax, -1
    ret

; ----------------------------------------------------------------------------
; encoder_pick_crtc — edi = encoder id, esi = crtc id to exclude (0 = none).
; GETENCODER, then: the encoder's current crtc if usable, else the first
; crtc in possible_crtcs that isn't excluded. eax = crtc id, 0 = none.
; ----------------------------------------------------------------------------
encoder_pick_crtc:
    push rbx
    push r12
    mov r12d, esi                            ; excluded crtc
    mov ebx, edi                             ; encoder id
    lea rdi, [drm_encoder_buf]
    xor eax, eax
    mov ecx, 5
    rep stosd
    mov [drm_encoder_buf], ebx
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETENCODER
    lea rdx, [drm_encoder_buf]
    syscall
    test rax, rax
    js .epc_none
    mov eax, [drm_encoder_buf + 8]           ; current crtc
    test eax, eax
    jz .epc_mask
    cmp eax, r12d
    jne .epc_ret
.epc_mask:
    mov ecx, [drm_encoder_buf + 12]          ; possible_crtcs (bit i = crtc_ids[i])
    xor edx, edx
.epc_scan:
    cmp edx, [drm_res_buf + 36]              ; count_crtcs
    jge .epc_none
    bt ecx, edx
    jnc .epc_next
    mov eax, [drm_crtc_ids + rdx*4]
    cmp eax, r12d
    jne .epc_ret
.epc_next:
    inc edx
    jmp .epc_scan
.epc_none:
    xor eax, eax
.epc_ret:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; modeset_pick_outputs — choose output 1 (first connected connector, its
; preferred mode -> mode1_save/panel_w/h, crtc -> drm_chosen_crtc) and, when
; present, output 2 (next connected connector on a DIFFERENT crtc ->
; mode2_save/ext_*, ext_active=1). eax = 1 ok, 0 = no usable connector.
; Re-runnable: hotplug calls this again after a uevent.
; ----------------------------------------------------------------------------
modeset_pick_outputs:
    push rbx
    push r12
    push r13
    mov byte [ext_active], 0
    call modeset_find_connector              ; r12d = conn id, fills conn/modes buf
    test eax, eax
    jz .mpo_fail
    mov [drm_chosen_conn], r12d
    lea rsi, [drm_modes_buf]                 ; save mode 1 before the second
    lea rdi, [mode1_save]                    ; scan clobbers the scratch bufs
    mov ecx, 17
    rep movsd
    movzx eax, word [mode1_save + 4]
    mov [panel_w], eax
    movzx eax, word [mode1_save + 14]
    mov [panel_h], eax
    mov edi, [drm_conn_buf + 44]             ; encoder id
    xor esi, esi
    call encoder_pick_crtc
    test eax, eax
    jz .mpo_fail
    mov [drm_chosen_crtc], eax

    ; --- scan for a second connected connector (skip output 1's) ---
    mov r13d, [drm_res_buf + 40]             ; count_connectors
    xor ebx, ebx
.mpo2_loop:
    cmp ebx, r13d
    jge .mpo_ok                              ; none -> single output
    mov r12d, [drm_conn_ids + rbx*4]
    cmp r12d, [drm_chosen_conn]
    je .mpo2_next
    lea rdi, [drm_conn_buf]
    xor eax, eax
    mov ecx, 10
    rep stosq
    mov [drm_conn_buf + 32], dword DRM_MAX_MODES
    mov [drm_conn_buf + 36], dword DRM_MAX_PROPS
    mov [drm_conn_buf + 40], dword DRM_MAX_IDS
    mov [drm_conn_buf + 48], r12d
    lea rax, [drm_enc_arr]
    mov [drm_conn_buf + 0], rax
    lea rax, [drm_modes_buf]
    mov [drm_conn_buf + 8], rax
    lea rax, [drm_props_arr]
    mov [drm_conn_buf + 16], rax
    lea rax, [drm_propvals_arr]
    mov [drm_conn_buf + 24], rax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_GETCONNECTOR
    lea rdx, [drm_conn_buf]
    syscall
    test rax, rax
    js .mpo2_next
    cmp dword [drm_conn_buf + 60], DRM_MODE_CONNECTED
    jne .mpo2_next
    cmp dword [drm_conn_buf + 32], 0         ; count_modes
    je .mpo2_next
    mov edi, [drm_conn_buf + 44]             ; its encoder
    mov esi, [drm_chosen_crtc]               ; must land on a different crtc
    call encoder_pick_crtc
    test eax, eax
    jz .mpo2_next
    mov [ext_crtc], eax
    mov [ext_conn], r12d
    lea rsi, [drm_modes_buf]
    lea rdi, [mode2_save]
    mov ecx, 17
    rep movsd
    movzx eax, word [mode2_save + 4]
    mov [ext_w], eax
    movzx eax, word [mode2_save + 14]
    mov [ext_h], eax
    mov eax, [panel_w]
    mov [ext_x], eax
    mov byte [ext_active], 1
    jmp .mpo_ok
.mpo2_next:
    inc ebx
    jmp .mpo2_loop
.mpo_ok:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.mpo_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; compositor_program_crtcs — SETCRTC output 1 (fb x=0) and, when live,
; output 2 (fb x=ext_x: the pan offset selects its slice of the wide fb).
; rax < 0 = output 1 failed (fatal); an output-2 failure just drops
; ext_active back to 0 and returns 0.
; ----------------------------------------------------------------------------
compositor_program_crtcs:
    mov eax, [drm_chosen_conn]
    mov [drm_set_conn_id], eax
    lea rdi, [drm_crtc_set]
    xor eax, eax
    mov ecx, 13
    rep stosq
    lea rax, [drm_set_conn_id]
    mov [drm_crtc_set + 0], rax
    mov dword [drm_crtc_set + 8], 1
    mov eax, [drm_chosen_crtc]
    mov [drm_crtc_set + 12], eax
    mov eax, [drm_fb_id]
    mov [drm_crtc_set + 16], eax
    mov dword [drm_crtc_set + 32], 1
    lea rsi, [mode1_save]
    lea rdi, [drm_crtc_set + 36]
    mov ecx, 17
    rep movsd
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_set]
    syscall
    test rax, rax
    js .cpc_ret
    cmp byte [ext_active], 0
    je .cpc_ok
    mov eax, [ext_conn]
    mov [drm_set_conn_id2], eax
    lea rdi, [drm_crtc_set2]
    xor eax, eax
    mov ecx, 13
    rep stosq
    lea rax, [drm_set_conn_id2]
    mov [drm_crtc_set2 + 0], rax
    mov dword [drm_crtc_set2 + 8], 1
    mov eax, [ext_crtc]
    mov [drm_crtc_set2 + 12], eax
    mov eax, [drm_fb_id]
    mov [drm_crtc_set2 + 16], eax
    mov eax, [ext_x]
    mov [drm_crtc_set2 + 20], eax            ; x pan into the wide fb
    mov dword [drm_crtc_set2 + 32], 1
    lea rsi, [mode2_save]
    lea rdi, [drm_crtc_set2 + 36]
    mov ecx, 17
    rep movsd
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_set2]
    syscall
    test rax, rax
    jns .cpc_ok
    mov byte [ext_active], 0                 ; external refused its mode:
.cpc_ok:                                     ; run single-output, don't die
    xor eax, eax
.cpc_ret:
    ret

; ----------------------------------------------------------------------------
; init_uevent_socket — netlink KOBJECT_UEVENT socket, group 1, non-blocking.
; Fully passive: one extra pollfd, zero wakeups until the kernel reports a
; connector change. Leaves uevent_fd = -1 (slot ignored) when unavailable
; or when there is no real DRM to reconfigure.
; ----------------------------------------------------------------------------
init_uevent_socket:
    mov dword [uevent_fd], -1
    mov dword [vtactive_fd], -1
    cmp byte [compositor_active], 0
    je .ius_done
    cmp byte [fbtest_mode], 0
    jne .ius_done
    ; --- VT watcher: open tty0/active; the first read arms the sysfs
    ; POLLPRI AND records which VT is ours (frame starts on its own VT).
    mov rax, SYS_OPEN
    lea rdi, [str_vtactive]
    xor esi, esi                             ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .ius_netlink
    mov [vtactive_fd], eax
    call vt_read_active
    mov [own_vt], eax
.ius_netlink:
    mov rax, SYS_SOCKET
    mov edi, 16                              ; AF_NETLINK
    mov esi, 2 | 0x800 | 0x80000             ; DGRAM | NONBLOCK | CLOEXEC
    mov edx, 15                              ; NETLINK_KOBJECT_UEVENT
    syscall
    test rax, rax
    js .ius_done
    mov [uevent_fd], eax
    lea rdi, [nl_addr]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 4], eax
    mov word [rdi], 16                       ; nl_family = AF_NETLINK
    mov dword [rdi + 8], 1                   ; nl_groups = 1 (kernel uevents)
    mov rax, SYS_BIND
    mov edi, [uevent_fd]
    lea rsi, [nl_addr]
    mov edx, 12
    syscall
    test rax, rax
    jns .ius_done
    mov rax, SYS_CLOSE                       ; bind refused → feature off
    mov edi, [uevent_fd]
    syscall
    mov dword [uevent_fd], -1
.ius_done:
    ret

; ----------------------------------------------------------------------------
; compositor_reconfigure — a DRM connector changed: re-pick outputs, rebuild
; the (possibly resized) framebuffers, reprogram both CRTCs, re-seat the
; cursor, force a full repaint and tell RandR subscribers (tile rediscovers
; its outputs and retiles).
; ----------------------------------------------------------------------------
compositor_reconfigure:
    cmp byte [compositor_active], 0
    je .crc_done
    cmp byte [fbtest_mode], 0
    jne .crc_done
    cmp byte [blank_state], 1                ; wake first: reprogramming dark
    jne .crc_awake                           ; CRTCs would fight the blank
    call comp_unblank
.crc_awake:
    ; Snapshot the output config. VT reacquire's own SETCRTC fires a DRM
    ; change uevent; a reconfigure that changes NOTHING must not rebuild —
    ; the RRScreenChangeNotify makes strip exit(0) to re-init, dropping
    ; every docked tray icon on each TTY round trip.
    mov eax, [drm_chosen_conn]
    push rax
    mov eax, [panel_w]
    push rax
    mov eax, [panel_h]
    push rax
    movzx eax, byte [ext_active]
    push rax
    mov eax, [ext_conn]
    push rax
    mov eax, [ext_w]
    push rax
    mov eax, [ext_h]
    push rax
    call drm_probe_resources
    call modeset_pick_outputs
    test eax, eax
    jz .crc_unchanged                        ; no connector at all: keep as-is
    pop r9                                   ; ext_h
    pop r8                                   ; ext_w
    pop rdx                                  ; ext_conn
    pop rcx                                  ; ext_active
    pop rsi                                  ; panel_h
    pop rdi                                  ; panel_w
    pop rax                                  ; drm_chosen_conn
    cmp eax, [drm_chosen_conn]
    jne .crc_changed
    cmp edi, [panel_w]
    jne .crc_changed
    cmp esi, [panel_h]
    jne .crc_changed
    movzx eax, byte [ext_active]
    cmp ecx, eax
    jne .crc_changed
    test eax, eax                            ; both single-output → done
    jz .crc_done
    cmp edx, [ext_conn]
    jne .crc_changed
    cmp r8d, [ext_w]
    jne .crc_changed
    cmp r9d, [ext_h]
    jne .crc_changed
    jmp .crc_done                            ; identical config: no-op
.crc_unchanged:
    add rsp, 56                              ; drop the snapshot
    jmp .crc_done
.crc_changed:
    call compositor_release_buffers
    call compositor_create_buffers
    test rax, rax
    js .crc_done                             ; alloc failed — nothing sane left
    call compositor_program_crtcs
    cmp dword [cursor_ready], 0
    je .crc_nocur
    mov edi, [drm_chosen_crtc]               ; re-seat the sprite on (possibly
    mov esi, [cursor_handle]                 ; new) crtc 1
    call cursor_set_bo
    mov eax, [drm_chosen_crtc]
    mov [cursor_crtc], eax
.crc_nocur:
    mov eax, [screen_w]                      ; clamp the pointer into the new
    dec eax                                  ; screen (it may have shrunk)
    cmp [cursor_x], eax
    jle .crc_xok
    mov [cursor_x], eax
.crc_xok:
    mov eax, [screen_h]
    dec eax
    cmp [cursor_y], eax
    jle .crc_yok
    mov [cursor_y], eax
.crc_yok:
    call cursor_move_hw
    mov byte [flip_pending], 0
    mov dword [dmg_count0], -1               ; full repaint, both buffers
    mov dword [dmg_count1], -1
    mov byte [comp_dirty], 1
    call rr_emit_screen_change
    mov rsi, log_hotplug
    mov rdx, log_hotplug_len
    call write_stderr
.crc_done:
    ret

; ----------------------------------------------------------------------------
; compositor_release_buffers — RMFB → munmap → DESTROY_DUMB for both
; buffers (the middle of compositor_shutdown, shared with hotplug
; reconfigure which rebuilds them at the new size right after).
; ----------------------------------------------------------------------------
compositor_release_buffers:
    mov eax, [comp_fbid + 0]
    mov [drm_dumb_destroy], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_RMFB
    lea rdx, [drm_dumb_destroy]
    syscall
    mov rax, SYS_MUNMAP
    mov rdi, [comp_addr + 0]
    mov rsi, [drm_dumb_size]
    syscall
    mov eax, [comp_handle + 0]
    mov [drm_dumb_destroy], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_DESTROY_DUMB
    lea rdx, [drm_dumb_destroy]
    syscall
    mov eax, [comp_fbid + 4]
    mov [drm_dumb_destroy], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_RMFB
    lea rdx, [drm_dumb_destroy]
    syscall
    mov rax, SYS_MUNMAP
    mov rdi, [comp_addr + 8]
    mov rsi, [drm_dumb_size]
    syscall
    mov eax, [comp_handle + 4]
    mov [drm_dumb_destroy], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_DESTROY_DUMB
    lea rdx, [drm_dumb_destroy]
    syscall
    ret

; ----------------------------------------------------------------------------
; init_hw_cursor — create a 64x64 ARGB cursor BO, draw an arrow into it, and
; set it on the CRTC via the DRM cursor plane. Non-fatal on failure (leaves
; cursor_ready=0; pointer events still work, just no visible sprite).
; ----------------------------------------------------------------------------
init_hw_cursor:
    push rbx
    ; CREATE_DUMB 64x64x32
    lea rdi, [drm_cursor_create]
    xor eax, eax
    mov ecx, 4
    rep stosq
    mov dword [drm_cursor_create + 0], 64    ; height
    mov dword [drm_cursor_create + 4], 64    ; width
    mov dword [drm_cursor_create + 8], 32    ; bpp
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CREATE_DUMB
    lea rdx, [drm_cursor_create]
    syscall
    test rax, rax
    js .ihc_fail
    mov eax, [drm_cursor_create + 16]        ; handle
    mov [cursor_handle], eax
    ; MAP_DUMB
    lea rdi, [drm_cursor_map]
    xor eax, eax
    mov ecx, 2
    rep stosq
    mov eax, [cursor_handle]
    mov [drm_cursor_map + 0], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_MAP_DUMB
    lea rdx, [drm_cursor_map]
    syscall
    test rax, rax
    js .ihc_fail
    ; mmap the BO: size = pitch * 64
    mov eax, [drm_cursor_create + 20]        ; pitch
    shl eax, 6                               ; * 64
    xor edi, edi
    mov esi, eax                             ; length
    mov edx, PROT_RW
    mov r10d, MAP_SHARED
    mov r8, [drm_fd]
    mov r9, [drm_cursor_map + 8]             ; offset
    mov rax, SYS_MMAP
    syscall
    cmp rax, -4096
    ja .ihc_fail
    mov [cursor_fb_addr], rax
    call cursor_clear_bo
    mov esi, [cursor_argb]
    call draw_cursor_arrow
    mov dword [cur_shape], CUR_ARROW         ; re-sync picks the real shape on
    mov dword [cur_hot_x], 0                 ; the next crossing
    mov dword [cur_hot_y], 0
    ; CURSOR ioctl — set the BO.
    lea rdi, [drm_cursor]
    xor eax, eax
    mov ecx, 7
    rep stosd
    mov dword [drm_cursor + 0], DRM_MODE_CURSOR_BO
    mov eax, [drm_chosen_crtc]
    mov [drm_cursor + 4], eax                ; crtc_id
    mov dword [drm_cursor + 16], 64          ; width
    mov dword [drm_cursor + 20], 64          ; height
    mov eax, [cursor_handle]
    mov [drm_cursor + 24], eax               ; handle
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CURSOR
    lea rdx, [drm_cursor]
    syscall
    test rax, rax
    js .ihc_fail
    mov dword [cursor_ready], 1
    mov eax, [drm_chosen_crtc]
    mov [cursor_crtc], eax                   ; sprite lives on output 1 now
    call cursor_move_hw                      ; place at the centred start pos
.ihc_fail:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; cursor_clear_bo — zero the cursor BO (fully transparent).
; ----------------------------------------------------------------------------
cursor_clear_bo:
    mov rdi, [cursor_fb_addr]
    xor eax, eax
    mov ecx, [drm_cursor_create + 20]        ; pitch
    shl ecx, 4                               ; * 64 / 4 = dwords
    rep stosd
    ret

; ----------------------------------------------------------------------------
; draw_cursor_arrow — paint the arrow (tip/hotspot at 0,0) into the cursor
; BO. esi = interior fill (premultiplied ARGB); outline is opaque black.
; The BO must be cleared first (cursor_clear_bo).
; ----------------------------------------------------------------------------
draw_cursor_arrow:
    push r12
    push r13
    push r14
    push r15
    mov r15, [cursor_fb_addr]
    mov r14d, [drm_cursor_create + 20]       ; pitch (bytes/row)
    xor r13d, r13d                           ; y
.dca_row:
    cmp r13d, 15                             ; ARROW_H (slightly smaller)
    jge .dca_done
    xor r12d, r12d                           ; x
.dca_col:
    cmp r12d, r13d                           ; while x <= y
    jg .dca_row_next
    mov eax, esi                             ; interior fill (arrow: framerc
                                             ; cursor_color; accent: cursor_accent)
    test r12d, r12d
    jz .dca_black                            ; left edge
    cmp r12d, r13d
    je .dca_black                            ; diagonal edge
    cmp r13d, 14                             ; bottom edge (ARROW_H-1)
    je .dca_black
    jmp .dca_plot
.dca_black:
    mov eax, 0xFF000000                       ; black (opaque)
.dca_plot:
    mov r8d, r13d
    imul r8d, r14d                           ; y * pitch
    lea r8, [r8 + r12*4]                     ; + x*4
    mov [r15 + r8], eax
    inc r12d
    jmp .dca_col
.dca_row_next:
    inc r13d
    jmp .dca_row
.dca_done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ----------------------------------------------------------------------------
; cursor_hline — plot pixels [eax..edx) on row ecx of the cursor BO,
; offset by r8d on both axes, colour r9d. Clips to the 64x64 BO.
; ----------------------------------------------------------------------------
cursor_hline:
    push rax
    push rcx
    push r10
    push r11
    add ecx, r8d
    add eax, r8d
    add edx, r8d
    cmp ecx, 63
    jg .chl_out
    mov r10d, ecx
    imul r10d, [drm_cursor_create + 20]      ; y * pitch
    add r10, [cursor_fb_addr]
.chl_px:
    cmp eax, edx
    jge .chl_out
    cmp eax, 63
    jg .chl_out
    mov r11d, eax
    mov [r10 + r11*4], r9d
    inc eax
    jmp .chl_px
.chl_out:
    pop r11
    pop r10
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; draw_cursor_ibeam — text caret: 2px bar with serifs, white over a 1px
; black drop shadow. Hotspot centre (8,8).
; ----------------------------------------------------------------------------
draw_cursor_ibeam:
    mov r9d, 0xFF000000
    mov r8d, 1                               ; shadow pass, offset (+1,+1)
    call cursor_ibeam_pass
    mov r9d, 0xFFFFFFFF
    xor r8d, r8d                             ; main pass
    ; fall through
cursor_ibeam_pass:
    push rcx
    xor ecx, ecx                             ; row
.cib_row:
    cmp ecx, 16
    jge .cib_done
    mov eax, 7                               ; bar columns [7..9)
    mov edx, 9
    cmp ecx, 2
    jl .cib_serif
    cmp ecx, 14
    jl .cib_plot
.cib_serif:
    mov eax, 4                               ; serif columns [4..12)
    mov edx, 12
.cib_plot:
    call cursor_hline
    inc ecx
    jmp .cib_row
.cib_done:
    pop rcx
    ret

; ----------------------------------------------------------------------------
; draw_cursor_cross — crosshair (scrot -s region select): 2px cross,
; white over a 1px black drop shadow. Hotspot centre (8,8).
; ----------------------------------------------------------------------------
draw_cursor_cross:
    mov r9d, 0xFF000000
    mov r8d, 1
    call cursor_cross_pass
    mov r9d, 0xFFFFFFFF
    xor r8d, r8d
    ; fall through
cursor_cross_pass:
    push rcx
    xor ecx, ecx
.ccx_row:
    cmp ecx, 17
    jge .ccx_done
    mov eax, 7                               ; vertical stroke [7..9)
    mov edx, 9
    cmp ecx, 7
    jl .ccx_plot
    cmp ecx, 9
    jge .ccx_plot
    xor eax, eax                             ; horizontal stroke rows: [0..17)
    mov edx, 17
.ccx_plot:
    call cursor_hline
    inc ecx
    jmp .ccx_row
.ccx_done:
    pop rcx
    ret

; ----------------------------------------------------------------------------
; draw_cursor_shape — edi = sprite id. Sets the hotspot and repaints the
; cursor BO. State-only (no draw) when the sprite isn't up (fbtest).
; ----------------------------------------------------------------------------
draw_cursor_shape:
    push rbx
    mov ebx, edi
    mov dword [cur_hot_x], 0
    mov dword [cur_hot_y], 0
    cmp dword [cursor_ready], 0
    je .dcs_out
    call cursor_clear_bo
    cmp ebx, CUR_BLANK
    je .dcs_out
    cmp ebx, CUR_IBEAM
    je .dcs_ibeam
    cmp ebx, CUR_CROSS
    je .dcs_cross
    mov esi, [cursor_argb]
    cmp ebx, CUR_ACCENT
    jne .dcs_arrow
    mov esi, [cfg_cursor_accent]
.dcs_arrow:
    call draw_cursor_arrow
    jmp .dcs_out
.dcs_ibeam:
    mov dword [cur_hot_x], 8
    mov dword [cur_hot_y], 8
    call draw_cursor_ibeam
    jmp .dcs_out
.dcs_cross:
    mov dword [cur_hot_x], 8
    mov dword [cur_hot_y], 8
    call draw_cursor_cross
.dcs_out:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; cursor_register — edi = cursor xid, esi = sprite id. Reuses the xid's
; slot, else first empty, else a rotating evictee.
; ----------------------------------------------------------------------------
cursor_register:
    push rbx
    xor ecx, ecx
.creg_scan:
    cmp ecx, MAX_CURSORS
    jge .creg_evict
    lea rbx, [cursor_tab + rcx*8]
    mov eax, [rbx]
    cmp eax, edi
    je .creg_store
    test eax, eax
    jz .creg_store
    inc ecx
    jmp .creg_scan
.creg_evict:
    mov ecx, [cursor_tab_next]
    inc dword [cursor_tab_next]
    and ecx, MAX_CURSORS - 1
    lea rbx, [cursor_tab + rcx*8]
.creg_store:
    mov [rbx], edi
    mov [rbx + 4], esi
    pop rbx
    ret

; cursor_shape_of — edi = cursor xid → eax = sprite id, or -1 unknown/None.
cursor_shape_of:
    test edi, edi
    jz .cso_none
    xor ecx, ecx
.cso_scan:
    cmp ecx, MAX_CURSORS
    jge .cso_none
    cmp [cursor_tab + rcx*8], edi
    je .cso_hit
    inc ecx
    jmp .cso_scan
.cso_hit:
    mov eax, [cursor_tab + rcx*8 + 4]
    ret
.cso_none:
    mov eax, -1
    ret

; ----------------------------------------------------------------------------
; cursor_sync — resolve the effective cursor (active grab's cursor →
; window-ancestor chain under the pointer → arrow) and repaint the sprite
; if the shape changed. Event-driven only: crossings, grab changes,
; CWCursor changes. Zero idle cost; repaint only on actual shape change.
; ----------------------------------------------------------------------------
cursor_sync:
    push rbx
    push r12
    cmp dword [ptr_grab_win], 0
    je .csy_window
    mov edi, [ptr_grab_cursor]
    test edi, edi
    jz .csy_window
    call cursor_shape_of
    cmp eax, -1
    jne .csy_have
.csy_window:
    mov ebx, [last_enter_win]
.csy_walk:
    test ebx, ebx
    jz .csy_arrow
    mov edi, ebx
    call window_lookup
    test rax, rax
    jz .csy_arrow
    mov r12, rax
    mov edi, [rax + 60]                      ; window's cursor attribute
    test edi, edi
    jz .csy_up
    call cursor_shape_of
    cmp eax, -1
    jne .csy_have
.csy_up:
    cmp dword [r12], X_ROOT_WINDOW
    je .csy_arrow
    mov ebx, [r12 + 4]                       ; walk to parent
    jmp .csy_walk
.csy_arrow:
    xor eax, eax                             ; CUR_ARROW
.csy_have:
    cmp eax, [cur_shape]
    je .csy_out
    mov [cur_shape], eax
    mov edi, eax
    call draw_cursor_shape
    call cursor_move_hw                      ; hotspot may have shifted
.csy_out:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_create_glyph_cursor — CreateGlyphCursor (94). rsi = req:
;   +4 cid  +8 src font  +12 mask font  +16 source char u16
; Classify the standard cursor-font glyph onto a baked sprite. Toolkits
; reach this path with XCURSOR_CORE=1 (session env) — theme cursors
; would otherwise arrive as unclassifiable RENDER images.
; ----------------------------------------------------------------------------
handle_create_glyph_cursor:
    mov edi, [rsi + 4]                       ; cid
    movzx eax, word [rsi + 16]               ; cursor-font glyph
    mov esi, CUR_IBEAM
    cmp eax, 152                             ; XC_xterm (text)
    je .cgc_reg
    mov esi, CUR_CROSS
    cmp eax, 34                              ; XC_crosshair (scrot -s)
    je .cgc_reg
    cmp eax, 33                              ; XC_cross
    je .cgc_reg
    cmp eax, 130                             ; XC_tcross
    je .cgc_reg
    mov esi, CUR_ACCENT
    cmp eax, 58                              ; XC_hand1 (pressable)
    je .cgc_reg
    cmp eax, 60                              ; XC_hand2 (links/buttons)
    je .cgc_reg
    mov esi, CUR_ARROW
.cgc_reg:
    jmp cursor_register

; ----------------------------------------------------------------------------
; handle_create_pixmap_cursor — CreatePixmapCursor (93). rsi = req:
;   +4 cid  +8 source pixmap. GDK's blank cursor is a 1x1 pixmap cursor
; (firefox hides the pointer while typing) — tiny pixmaps map to the
; blank sprite, anything else to the arrow.
; ----------------------------------------------------------------------------
handle_create_pixmap_cursor:
    mov edi, [rsi + 8]                       ; source pixmap
    push qword [rsi + 4]                     ; cid (req ptr freed of duty)
    call pixmap_lookup
    pop rdi                                  ; cid
    mov esi, CUR_ARROW
    test rax, rax
    jz .cpc_reg
    cmp word [rax + 4], 4                    ; w ≤ 4 and h ≤ 4 → blank
    ja .cpc_reg
    cmp word [rax + 6], 4
    ja .cpc_reg
    mov esi, CUR_BLANK
.cpc_reg:
    jmp cursor_register

; ----------------------------------------------------------------------------
; cursor_move_hw — move the cursor sprite to (cursor_x, cursor_y) via one
; CURSOR MOVE ioctl. No-op if the sprite isn't up (network-only).
; ----------------------------------------------------------------------------
cursor_move_hw:
    cmp dword [cursor_ready], 0
    je .cmh_done
    ; Which output is the pointer on? ecx = its crtc, edx = crtc-local x.
    mov ecx, [drm_chosen_crtc]
    mov eax, [cursor_x]
    mov edx, eax
    cmp byte [ext_active], 0
    je .cmh_have
    cmp eax, [ext_x]
    jl .cmh_have
    mov ecx, [ext_crtc]
    sub edx, [ext_x]
.cmh_have:
    cmp ecx, [cursor_crtc]
    je .cmh_move
    ; Crossed outputs: hide the sprite on the old CRTC, show it on the new.
    ; Costs 2 extra ioctls only at the crossing, not per motion event.
    push rcx
    push rdx
    mov edi, [cursor_crtc]
    xor esi, esi                             ; BO 0 = hide
    call cursor_set_bo
    mov ecx, [rsp + 8]
    mov edi, ecx
    mov esi, [cursor_handle]
    call cursor_set_bo
    pop rdx
    pop rcx
    mov [cursor_crtc], ecx
.cmh_move:
    mov dword [drm_cursor + 0], DRM_MODE_CURSOR_MOVE
    mov [drm_cursor + 4], ecx                ; crtc_id
    sub edx, [cur_hot_x]                     ; hotspot (I-beam/cross centre)
    mov [drm_cursor + 8], edx                ; x (crtc-local)
    mov eax, [cursor_y]
    sub eax, [cur_hot_y]
    mov [drm_cursor + 12], eax               ; y
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CURSOR
    lea rdx, [drm_cursor]
    syscall
.cmh_done:
    ret

; cursor_set_bo — edi = crtc id, esi = cursor BO handle (0 = hide).
cursor_set_bo:
    push rbx
    push r12
    mov ebx, edi
    mov r12d, esi
    lea rdi, [drm_cursor]
    xor eax, eax
    mov ecx, 7
    rep stosd
    mov dword [drm_cursor + 0], DRM_MODE_CURSOR_BO
    mov [drm_cursor + 4], ebx
    mov dword [drm_cursor + 16], 64
    mov dword [drm_cursor + 20], 64
    mov [drm_cursor + 24], r12d
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CURSOR
    lea rdx, [drm_cursor]
    syscall
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; init_fbtest — DRM-free compositor for headless testing (--fbtest).
; Two anonymous buffers stand in for the DRM dumb buffers; the full
; composite path (damage lists, bg fill, blits, clflush, counters) runs;
; present is a plain buffer swap. Lets the whole pipeline be pixel-
; verified without a panel or root.
; ----------------------------------------------------------------------------
init_fbtest:
    push rbx
    mov word [drm_modes_buf + 4], 1920
    mov word [drm_modes_buf + 14], 1080
    mov dword [panel_w], 1920
    mov dword [panel_h], 1080
    mov eax, 1920
    cmp byte [ext_active], 0                  ; --fbtest2: fake external,
    je .ft_dims                               ; same 1920x1080, to the right
    mov dword [ext_x], 1920
    mov dword [ext_w], 1920
    mov dword [ext_h], 1080
    add eax, 1920
.ft_dims:
    mov [screen_w], eax
    mov dword [screen_h], 1080
    mov word [windows + 12], ax               ; root window record dims
    mov word [windows + 14], 1080
    shl eax, 2
    mov [drm_dumb_pitch], eax                 ; stride = screen_w*4
    imul eax, 1080
    mov [drm_dumb_size], rax
    xor ebx, ebx
.ft_buf:
    mov rax, SYS_MMAP
    xor edi, edi
    mov rsi, [drm_dumb_size]
    mov edx, 3                                ; PROT_READ|PROT_WRITE
    mov r10d, 0x22                            ; MAP_PRIVATE|MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
    test rax, rax
    js .ft_fail
    mov [comp_addr + rbx*8], rax
    mov rdi, rax
    mov rcx, [drm_dumb_size]
    shr rcx, 2
    mov eax, COMP_BG_COLOR
    rep stosd
    inc ebx
    cmp ebx, 2
    jl .ft_buf
    mov dword [comp_back], 1
    mov dword [dmg_count0], -1
    mov dword [dmg_count1], -1
    mov byte [compositor_active], 1
    mov byte [comp_dirty], 1
    lea rsi, [log_fbtest]
    mov rdx, log_fbtest_len
    call write_stderr
.ft_fail:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; damage_add — record a screen-space dirty rect for the compositor.
;   eax = x, edx = y, ecx = w, r8d = h  (s32, screen coords)
; Clamps to the screen and appends to BOTH buffers' stale lists
; (containment-deduped; overflow → whole-screen fallback, which is safe:
; over-repainting is correct, unlike clip over-approximation). No-op when
; the compositor is off. Preserves all registers.
; ----------------------------------------------------------------------------
damage_add:
    cmp byte [compositor_active], 0
    je .da_ret0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r9d, eax                              ; x1
    mov r10d, edx                             ; y1
    mov r11d, eax
    add r11d, ecx                             ; x2
    mov ebx, edx
    add ebx, r8d                              ; y2
    test r9d, r9d
    jns .da_x1ok
    xor r9d, r9d
.da_x1ok:
    test r10d, r10d
    jns .da_y1ok
    xor r10d, r10d
.da_y1ok:
    mov eax, [screen_w]                       ; fb width (spans all outputs)
    cmp r11d, eax
    jle .da_x2ok
    mov r11d, eax
.da_x2ok:
    mov eax, [screen_h]
    cmp ebx, eax
    jle .da_y2ok
    mov ebx, eax
.da_y2ok:
    cmp r9d, r11d
    jge .da_done
    cmp r10d, ebx
    jge .da_done
    lea rdi, [dmg_rects0]
    lea rsi, [dmg_count0]
    call .da_append
    lea rdi, [dmg_rects1]
    lea rsi, [dmg_count1]
    call .da_append
.da_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.da_ret0:
    ret
; local: append rect (r9d,r10d,r11d,ebx) to list rdi / count at rsi
.da_append:
    mov ecx, [rsi]
    test ecx, ecx
    js .da_ap_ret                             ; already whole-screen
    jz .da_ap_store
    mov rax, rdi                              ; containment scan
    mov edx, ecx
.da_ap_scan:
    cmp r9d, [rax + 0]
    jl .da_ap_next
    cmp r10d, [rax + 4]
    jl .da_ap_next
    cmp r11d, [rax + 8]
    jg .da_ap_next
    cmp ebx, [rax + 12]
    jg .da_ap_next
    ret                                       ; contained in an existing rect
.da_ap_next:
    add rax, 16
    dec edx
    jnz .da_ap_scan
    cmp ecx, DMG_MAX
    jl .da_ap_store
    mov dword [rsi], -1                       ; overflow → whole screen
    ret
.da_ap_store:
    mov eax, ecx
    shl eax, 4
    add rax, rdi
    mov [rax + 0], r9d
    mov [rax + 4], r10d
    mov [rax + 8], r11d
    mov [rax + 12], ebx
    inc dword [rsi]
.da_ap_ret:
    ret

; ----------------------------------------------------------------------------
; damage_add_local — rdi = window record, eax = x, edx = y, ecx = w, r8d = h
; in WINDOW-LOCAL coords. Converts to screen via the parent-chain walk
; (children of non-root parents land where the compositor draws them) and
; calls damage_add. Clobbers rax, rcx, rdx, rdi.
; ----------------------------------------------------------------------------
damage_add_local:
    push r10
    push r11
    push rsi
    mov esi, eax                              ; save x
    push rdx                                  ; save y
    push rcx                                  ; save w
    mov edi, [rdi]
    call window_abs_xy                        ; r10d/r11d = abs origin
    pop rcx
    pop rdx
    add edx, r11d
    mov eax, esi
    add eax, r10d
    call damage_add
    pop rsi
    pop r11
    pop r10
    ret

; ----------------------------------------------------------------------------
; damage_rect_list — rdi = rect list (x s16, y s16, w u16, h u16 each),
; esi = rect count, rdx = window record ptr. Damages the bbox of the list
; offset to screen coords. Preserves all registers.
; ----------------------------------------------------------------------------
damage_rect_list:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    test esi, esi
    jz .drl_done
    mov rbx, rdx                              ; window rec
    mov ecx, 0x7FFFFFFF                       ; x1
    mov r8d, 0x7FFFFFFF                       ; y1
    mov r9d, 0x80000000                       ; x2
    mov r10d, 0x80000000                      ; y2
.drl_loop:
    movsx eax, word [rdi + 0]
    cmp eax, ecx
    jge .drl_1
    mov ecx, eax
.drl_1:
    movzx edx, word [rdi + 4]
    add edx, eax
    cmp edx, r9d
    jle .drl_2
    mov r9d, edx
.drl_2:
    movsx eax, word [rdi + 2]
    cmp eax, r8d
    jge .drl_3
    mov r8d, eax
.drl_3:
    movzx edx, word [rdi + 6]
    add edx, eax
    cmp edx, r10d
    jle .drl_4
    mov r10d, edx
.drl_4:
    add rdi, 8
    dec esi
    jnz .drl_loop
    sub r9d, ecx                              ; w
    jle .drl_done
    sub r10d, r8d                             ; h
    jle .drl_done
    mov eax, ecx                              ; local x
    mov edx, r8d                              ; local y
    mov ecx, r9d                              ; w
    mov r8d, r10d                             ; h
    mov rdi, rbx                              ; window rec → abs conversion
    call damage_add_local
.drl_done:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ----------------------------------------------------------------------------
; damage_add_window — rdi = window record ptr. Damages the window's screen
; rect using the larger of configured (+12/+14) and backing (+40/+42) dims
; (blit uses backing, configure the former). Preserves all registers.
; ----------------------------------------------------------------------------
damage_add_window:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push rdi
    mov edi, [rdi]
    call window_abs_xy                        ; r10d/r11d = abs origin
    pop rdi
    mov eax, r10d                             ; x (absolute)
    mov edx, r11d                             ; y
    movzx ecx, word [rdi + 12]                ; configured w
    movzx r8d, word [rdi + 40]                ; backing w
    cmp ecx, r8d
    jge .daw_w
    mov ecx, r8d
.daw_w:
    movzx r8d, word [rdi + 14]                ; configured h
    movzx r9d, word [rdi + 42]                ; backing h
    cmp r8d, r9d
    jge .daw_h
    mov r8d, r9d
.daw_h:
    movzx r9d, word [rdi + 16]                ; border ring is part of the
    sub eax, r9d                              ; window's screen footprint
    sub edx, r9d
    lea ecx, [rcx + r9*2]
    lea r8d, [r8 + r9*2]
    call damage_add
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; recomposite_screen — paint background (via rep stosd over the whole
; dumb buffer — proven to work in do_modeset), then walk every mapped
; non-root window and draw its rect in a per-XID colour. No-op if
; compositor_active is 0.
; ----------------------------------------------------------------------------
recomposite_screen:
    cmp byte [compositor_active], 0
    je .rs_done
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Select the back buffer and ITS stale-damage list.
    mov eax, [comp_back]
    mov rcx, [comp_addr + rax*8]
    mov [drm_dumb_addr], rcx
    lea r14, [dmg_rects0]
    lea r15, [dmg_count0]
    test eax, eax
    jz .rs_have_list
    lea r14, [dmg_rects1]
    lea r15, [dmg_count1]
.rs_have_list:
    mov eax, [r15]
    test eax, eax
    jz .rs_done_pop                           ; buffer already clean → nothing
    inc dword [rs_counter]                    ; DIAG (clobbers flags!)
    cmp eax, 0
    jl .rs_full                               ; -1 → whole-screen repaint

    ; --- Damage path: for each stale rect, bg-fill it, then repaint the
    ; window stack clipped to it (bw_clip). Painter's order holds per rect.
    mov r13d, eax                             ; remaining rects
    mov rbx, r14                              ; rect cursor
.rs_rect_loop:
    mov eax, [rbx + 0]
    mov [bw_clip_x1], eax
    mov edx, [rbx + 4]
    mov [bw_clip_y1], edx
    mov ecx, [rbx + 8]
    mov [bw_clip_x2], ecx
    mov r8d, [rbx + 12]
    mov [bw_clip_y2], r8d
    sub ecx, eax                              ; w
    sub r8d, edx                              ; h
    mov esi, ecx
    imul esi, r8d
    movsxd rsi, esi
    add [comp_px_fill], rsi                   ; PERF counter
    mov esi, edx                              ; y
    mov edi, ecx                              ; w
    mov ecx, r8d                              ; h
    call bg_fill_rect                         ; wallpaper (or solid) for this rect
    call .rs_window_walk
    add rbx, 16
    dec r13d
    jnz .rs_rect_loop

    ; --- clflush only the damaged lines (write-back cache → RAM so the
    ; display engine scans fresh pixels). 64-byte lines per damaged row.
    mov r13d, [r15]
    mov rbx, r14
.rs_fr_rect:
    mov r8d, [rbx + 4]                        ; y
.rs_fr_row:
    cmp r8d, [rbx + 12]
    jge .rs_fr_next
    mov eax, r8d
    imul eax, [drm_dumb_pitch]
    mov rdi, [drm_dumb_addr]
    add rdi, rax
    mov edx, [rbx + 0]
    shl edx, 2
    and edx, 0xFFFFFFC0                       ; line-align left edge
    add rdi, rdx
    mov ecx, [rbx + 8]
    shl ecx, 2
    add ecx, 63
    and ecx, 0xFFFFFFC0                       ; round right edge up
    sub ecx, edx
    jle .rs_fr_rownext
    add [comp_px_flush], rcx                  ; PERF counter (bytes)
.rs_fr_line:
    clflush [rdi]
    add rdi, 64
    sub ecx, 64
    ja .rs_fr_line
.rs_fr_rownext:
    inc r8d
    jmp .rs_fr_row
.rs_fr_next:
    add rbx, 16
    dec r13d
    jnz .rs_fr_rect
    sfence
    jmp .rs_present

.rs_full:
    ; --- Whole-screen path (overflow fallback / first paint) ---
    xor eax, eax
    mov [bw_clip_x1], eax
    mov [bw_clip_y1], eax
    mov eax, [screen_w]
    mov [bw_clip_x2], eax
    mov eax, [screen_h]
    mov [bw_clip_y2], eax
    xor eax, eax                              ; whole-screen bg (wallpaper/solid)
    xor esi, esi
    mov edi, [screen_w]
    mov ecx, [screen_h]
    call bg_fill_rect
    mov rax, [drm_dumb_size]
    shr rax, 2
    add [comp_px_fill], rax                   ; PERF counter
    call .rs_window_walk
    mov rdi, [drm_dumb_addr]
    mov rcx, [drm_dumb_size]
    add [comp_px_flush], rcx                  ; PERF counter
.rs_flush_all:
    clflush [rdi]
    add rdi, 64
    sub rcx, 64
    ja .rs_flush_all
    sfence

.rs_present:
    mov dword [r15], 0                        ; this buffer is now clean
    cmp byte [fbtest_mode], 0
    jne .rs_fb_swap                           ; test mode: no DRM, just swap

    ; --- PAGE_FLIP the CRTC to the back buffer, ASYNC: the completion
    ; event is drained by the serve loop (drm_fd is in its poll set), so
    ; the server never stalls a vblank here. flip_pending gates the next
    ; composite until the event arrives.
    mov ebx, [comp_back]
    lea rdi, [drm_page_flip]
    mov eax, [drm_chosen_crtc]
    mov [rdi + 0], eax                       ; crtc_id
    mov eax, [comp_fbid + rbx*4]
    mov [rdi + 4], eax                       ; fb_id
    mov dword [rdi + 8], DRM_MODE_PAGE_FLIP_EVENT
    mov dword [rdi + 12], 0                  ; reserved
    mov qword [rdi + 16], 0                  ; user_data
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_PAGE_FLIP
    lea rdx, [drm_page_flip]
    syscall

    cmp byte [dirtyfb_logged], 0             ; log the first flip's rc once
    jne .rs_flip_logged
    mov byte [dirtyfb_logged], 1
    push rax
    mov rsi, log_pageflip
    mov rdx, log_pageflip_len
    call write_stderr
    pop rax
    push rax
    call write_i64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    pop rax
.rs_flip_logged:
    test rax, rax
    js .rs_no_swap                           ; flip rejected → stale until damage
    cmp byte [drm_poll_dead], 0              ; no completion events any more →
    jne .rs_fb_swap                          ; fire-and-forget, never gate
    mov byte [flip_pending], 1
    ; Second output: flip its CRTC to the same buffer. flip_pending counts
    ; in-flight flips; the composite gate waits for both completions (the
    ; effective composite rate becomes the slower display's — X11 norm).
    cmp byte [ext_active], 0
    je .rs_fb_swap
    lea rdi, [drm_page_flip]
    mov eax, [ext_crtc]
    mov [rdi + 0], eax
    mov eax, [comp_fbid + rbx*4]
    mov [rdi + 4], eax
    mov dword [rdi + 8], DRM_MODE_PAGE_FLIP_EVENT
    mov dword [rdi + 12], 0
    mov qword [rdi + 16], 0
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_PAGE_FLIP
    lea rdx, [drm_page_flip]
    syscall
    test rax, rax
    js .rs_fb_swap                           ; ext flip refused: don't gate on it
    inc byte [flip_pending]
.rs_fb_swap:
    mov eax, [comp_back]                     ; swap: submitted buffer is the
    xor eax, 1                               ; new front; render the other next
    mov [comp_back], eax
    jmp .rs_done_pop
.rs_no_swap:
    ; Flip rejected (VT switch / master contention): the buffer is painted
    ; but never presented, and its damage list is already cleared. Mark it
    ; fully stale so the NEXT genuine damage repaints it whole and submits a
    ; fresh flip. Deliberately NO self-retrigger: with a persistently failing
    ; flip that would burn a full repaint + clflush per input event.
    mov dword [r15], -1
.rs_done_pop:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.rs_done:
    ret

; local: stk-ordered walk blitting every mapped backed window, clipped to
; bw_clip. Preserves the caller's rbx/r12/r13.
.rs_window_walk:
    ; Composite the window TREE, not a flat stk list: each window is drawn,
    ; then its children on top, recursively (depth-first, siblings in stk
    ; order). A flat stk sort drew a nested child UNDER its parent whenever
    ; the parent's stk was higher (Firefox renders into a full-size child of
    ; its toplevel; the blank toplevel had the higher stk and hid it).
    mov edi, X_ROOT_WINDOW
    call rs_composite_children
    ret

; ----------------------------------------------------------------------------
; rs_composite_children — edi = parent xid. Blits every mapped child of
; `parent` in ascending stk order, recursing into each so children draw on
; top of parents (correct X stacking, and it honours the current dirty-rect
; clip via blit_window). Recursion depth = window-tree depth (small). All
; loop state is stack-local so recursion nests cleanly; blit_window preserves
; the callee-saved regs used here.
; ----------------------------------------------------------------------------
rs_composite_children:
    push rbx                                  ; parent xid
    push r13                                  ; last stk drawn at THIS level
    push r14                                  ; chosen record ptr
    push r15                                  ; min stk this pass
    mov ebx, edi
    xor r13d, r13d                            ; 0 = none yet (real stk >= 1)
.rcc_pass:
    xor r14, r14                              ; chosen = none
    mov r15d, 0xFFFFFFFF                       ; min stk this pass
    xor ecx, ecx                              ; slot
.rcc_find:
    cmp ecx, MAX_WINDOWS
    jge .rcc_find_done
    mov rax, rcx
    imul rax, WINDOW_REC_SIZE
    lea rax, [windows + rax]
    mov edx, [rax]                            ; xid
    test edx, edx
    jz .rcc_next
    cmp edx, X_ROOT_WINDOW
    je .rcc_next
    cmp [rax + 4], ebx                        ; child of THIS parent?
    jne .rcc_next
    cmp byte [rax + 28], 0                    ; mapped?
    je .rcc_next
    mov edx, [rax + 48]                       ; stk
    cmp edx, r13d
    jbe .rcc_next                             ; already drawn at this level
    cmp edx, r15d
    jae .rcc_next                             ; not the smallest still pending
    mov r15d, edx
    mov r14, rax
.rcc_next:
    inc ecx
    jmp .rcc_find
.rcc_find_done:
    test r14, r14
    jz .rcc_done
    mov r13d, r15d                            ; advance last-drawn stk
    mov rdi, r14                              ; border ring first (it lives
    call border_draw                          ; outside w×h; early-out bw=0)
    cmp byte [r14 + 31], 0                    ; has backing? blit it (a backless
    je .rcc_recurse                          ; container still needs its kids)
    mov rdi, r14
    call blit_window_shaped
.rcc_recurse:
    mov edi, [r14]                            ; recurse into this child's subtree
    call rs_composite_children
    jmp .rcc_pass
.rcc_done:
    pop r15
    pop r14
    pop r13
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_color — edi = xid. Returns a non-dark RGB colour in eax.
; ----------------------------------------------------------------------------
window_color:
    mov eax, edi
    imul eax, eax, 0x9E3779B1
    or eax, 0x808080
    and eax, 0x00FFFFFF
    ret

; ----------------------------------------------------------------------------
; draw_rect — eax = x (s32), esi = y (s32), edi = w (u32), ecx = h (u32),
; edx = colour.
;
; Cleanly clips to screen bounds, then writes one row per outer
; iteration via rep stosd. All persistent values held in callee-saved
; registers so the inner loop's rep stosd (which clobbers rcx/rdi)
; can't lose them.
;
; Register plan:
;   rbx = x (after clipping)
;   r12 = current y
;   r13 = w in pixels (after clipping)
;   r14 = rows remaining
;   r15 = drm_dumb_addr
;   rbp = colour
; ----------------------------------------------------------------------------
draw_rect:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov ebp, edx                             ; ebp = colour

    ; --- Clip x and width ---
    mov r12d, [screen_w]
    mov r13d, [screen_h]
    test eax, eax
    jns .dr_x_ok
    add edi, eax                              ; w shrinks by |x|
    xor eax, eax                              ; x = 0
.dr_x_ok:
    cmp eax, r12d
    jge .dr_done                              ; x off-screen
    mov edx, eax
    add edx, edi                              ; x + w
    cmp edx, r12d
    jbe .dr_w_ok
    mov edi, r12d
    sub edi, eax                              ; w = screen_w - x
.dr_w_ok:
    cmp edi, 0
    jle .dr_done                              ; w ≤ 0

    ; --- Clip y and height ---
    test esi, esi
    jns .dr_y_ok
    add ecx, esi
    xor esi, esi
.dr_y_ok:
    cmp esi, r13d
    jge .dr_done
    mov edx, esi
    add edx, ecx
    cmp edx, r13d
    jbe .dr_h_ok
    mov ecx, r13d
    sub ecx, esi
.dr_h_ok:
    cmp ecx, 0
    jle .dr_done

    ; --- Latch values into callee-saved registers ---
    mov ebx, eax                              ; rbx = x
    mov r12d, esi                             ; r12 = current y
    mov r13d, edi                             ; r13 = w
    mov r14d, ecx                             ; r14 = rows remaining
    mov r15, [drm_dumb_addr]

.dr_row:
    test r14d, r14d
    jz .dr_done

    ; Row start = addr + y*pitch + x*4
    mov rdi, r15
    mov eax, r12d
    imul eax, [drm_dumb_pitch]
    add rdi, rax
    mov eax, ebx
    shl eax, 2
    add rdi, rax

    ; Paint w pixels in this row.
    mov ecx, r13d
    mov eax, ebp
    rep stosd

    inc r12d
    dec r14d
    jmp .dr_row

.dr_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; load_wallpaper — if ~/.framerc set `background = <raw>`, read the raw BGRX
; file (screen_w*screen_h*4 bytes) into wallpaper_buf and point wallpaper_ptr
; at it. Any failure (no path, can't open, wrong size, too big) leaves
; wallpaper_ptr = 0 → the compositor falls back to the solid COMP_BG_COLOR.
; Called once at startup, after init_compositor has set screen_w/screen_h.
; ----------------------------------------------------------------------------
load_wallpaper:
    mov qword [wallpaper_ptr], 0
    cmp byte [wallpaper_path], 0
    je .lw_ret                                ; no background configured
    push rbx
    push r12
    push r13
    ; expected = screen_w * screen_h * 4, and it must fit wallpaper_buf
    mov eax, [screen_w]
    imul eax, [screen_h]
    cmp eax, WALL_MAX / 4
    ja .lw_close_none                         ; panel bigger than our buffer
    shl eax, 2
    mov r12d, eax                             ; r12 = expected bytes
    mov rax, SYS_OPEN
    lea rdi, [wallpaper_path]
    xor esi, esi                              ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .lw_none                               ; can't open → solid bg
    mov r13d, eax                             ; r13 = fd
    xor ebx, ebx                              ; bytes read so far
.lw_read:
    mov edx, r12d
    sub edx, ebx                              ; remaining
    jz .lw_full                               ; got the whole image
    mov rax, SYS_READ
    mov edi, r13d
    lea rsi, [wallpaper_buf + rbx]
    syscall
    test rax, rax
    jle .lw_close_none                        ; EOF/short/error → wrong size
    add ebx, eax
    jmp .lw_read
.lw_full:
    mov rax, SYS_CLOSE
    mov edi, r13d
    syscall
    lea rax, [wallpaper_buf]
    mov [wallpaper_ptr], rax                  ; success
    jmp .lw_pop
.lw_close_none:
    mov rax, SYS_CLOSE
    mov edi, r13d
    syscall
.lw_none:
    mov qword [wallpaper_ptr], 0
.lw_pop:
    pop r13
    pop r12
    pop rbx
.lw_ret:
    ret

; ----------------------------------------------------------------------------
; bg_fill_rect — paint the background of one rect (eax=x, esi=y, edi=w,
; ecx=h). With no wallpaper it is exactly draw_rect(COMP_BG_COLOR). With a
; wallpaper loaded it copies the matching sub-region from wallpaper_buf, so a
; moved/closed window exposes the image (not a solid trail). Same screen
; clipping as draw_rect. wallpaper stride = screen_w*4 (raw is tightly packed).
; ----------------------------------------------------------------------------
bg_fill_rect:
    cmp qword [wallpaper_ptr], 0
    jne .bfr_wall
    mov edx, COMP_BG_COLOR
    jmp draw_rect                             ; tail-call: solid fill + return
.bfr_wall:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov r12d, [screen_w]
    mov r13d, [screen_h]
    ; --- clip x / w ---
    test eax, eax
    jns .bfr_x_ok
    add edi, eax
    xor eax, eax
.bfr_x_ok:
    cmp eax, r12d
    jge .bfr_done
    mov edx, eax
    add edx, edi
    cmp edx, r12d
    jbe .bfr_w_ok
    mov edi, r12d
    sub edi, eax
.bfr_w_ok:
    cmp edi, 0
    jle .bfr_done
    ; --- clip y / h ---
    test esi, esi
    jns .bfr_y_ok
    add ecx, esi
    xor esi, esi
.bfr_y_ok:
    cmp esi, r13d
    jge .bfr_done
    mov edx, esi
    add edx, ecx
    cmp edx, r13d
    jbe .bfr_h_ok
    mov ecx, r13d
    sub ecx, esi
.bfr_h_ok:
    cmp ecx, 0
    jle .bfr_done
    ; --- latch: rbx=x, r12=y, r13=w, r14=rows, rbp=wall stride ---
    mov ebx, eax
    mov r12d, esi
    mov r13d, edi
    mov r14d, ecx
    mov r15, [drm_dumb_addr]
    mov ebp, [screen_w]
    shl ebp, 2                                ; wallpaper stride = screen_w*4
.bfr_row:
    test r14d, r14d
    jz .bfr_done
    ; dest = drm_dumb_addr + y*drm_pitch + x*4
    mov rdi, r15
    mov eax, r12d
    imul eax, [drm_dumb_pitch]
    add rdi, rax
    mov eax, ebx
    shl eax, 2
    add rdi, rax
    ; src = wallpaper_ptr + y*stride + x*4
    mov rsi, [wallpaper_ptr]
    mov eax, r12d
    imul eax, ebp
    add rsi, rax
    mov eax, ebx
    shl eax, 2
    add rsi, rax
    mov ecx, r13d
    rep movsd
    inc r12d
    dec r14d
    jmp .bfr_row
.bfr_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4f — clean exit / console restore.
; ============================================================================
; A compositor that holds DRM master must restore the console on exit,
; or the panel keeps showing frame's (now freed) framebuffer — black,
; recoverable only by a VT switch. We install handlers for SIGINT
; (Ctrl+C), SIGTERM (kill / the test script's cleanup), and SIGHUP so
; any of them runs compositor_shutdown before exiting.
; ============================================================================

; ----------------------------------------------------------------------------
; now_mono_ms — rax = CLOCK_MONOTONIC in milliseconds.
; ----------------------------------------------------------------------------
now_mono_ms:
    push rcx
    mov rax, SYS_CLOCK_GETTIME
    mov edi, CLOCK_MONOTONIC
    lea rsi, [mono_ts]
    syscall
    mov rax, [mono_ts]
    imul rax, rax, 1000
    push rax
    mov rax, [mono_ts + 8]
    xor edx, edx
    mov rcx, 1000000
    div rcx
    pop rcx
    add rax, rcx
    pop rcx
    ret

; ----------------------------------------------------------------------------
; now_real_ms — rax = CLOCK_REALTIME in milliseconds (low bits; X time is
; CARD32 and wraps). REALTIME, not MONOTONIC: server_time_ms is otherwise
; stamped from evdev event timestamps, which default to CLOCK_REALTIME —
; the two sources must share a timebase or event times jump backwards.
; ----------------------------------------------------------------------------
now_real_ms:
    push rcx
    mov rax, SYS_CLOCK_GETTIME
    xor edi, edi                             ; CLOCK_REALTIME
    lea rsi, [mono_ts]
    syscall
    mov rax, [mono_ts]
    imul rax, rax, 1000
    push rax
    mov rax, [mono_ts + 8]
    xor edx, edx
    mov rcx, 1000000
    div rcx
    pop rcx
    add rax, rcx
    pop rcx
    ret

; ----------------------------------------------------------------------------
; comp_blank — panel off after blank_timeout of idle: SETCRTC with no fb and
; no mode disables the CRTC; the display engine and eDP panel power down.
; ----------------------------------------------------------------------------
comp_blank:
    cmp byte [compositor_active], 0
    je .cb_out
    cmp byte [fbtest_mode], 0                ; no panel, no CRTC — and a set
    jne .cb_out                              ; blank_state would eat composites
    cmp byte [blank_state], 0
    jne .cb_out
    lea rdi, [blank_crtc_cmd]
    xor eax, eax
    mov ecx, 13
    rep stosq
    mov eax, [drm_chosen_crtc]
    mov [blank_crtc_cmd + 12], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [blank_crtc_cmd]
    syscall
    cmp byte [ext_active], 0                 ; the external sleeps too
    je .cb_one
    mov eax, [ext_crtc]
    mov [blank_crtc_cmd + 12], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [blank_crtc_cmd]
    syscall
.cb_one:
    mov byte [blank_state], 1
    lea rsi, [log_blank]
    mov rdx, log_blank_len
    call write_stderr
.cb_out:
    ret

; ----------------------------------------------------------------------------
; comp_unblank — input arrived while dark: replay the compositor's SETCRTC
; (drm_crtc_set stays populated from init) and force a full repaint.
; ----------------------------------------------------------------------------
comp_unblank:
    cmp byte [blank_state], 1
    jne .cu_out
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_set]
    syscall
    cmp byte [ext_active], 0
    je .cu_one
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_set2]
    syscall
.cu_one:
    mov byte [blank_state], 0
    mov byte [flip_pending], 0               ; any in-flight flip died with the CRTC
    mov dword [dmg_count0], -1               ; whole-screen repaint, both buffers
    mov dword [dmg_count1], -1
    mov byte [comp_dirty], 1
    lea rsi, [log_unblank]
    mov rdx, log_unblank_len
    call write_stderr
.cu_out:
    ret

; ----------------------------------------------------------------------------
; install_exit_handler — edi = signal number. Installs exit_handler with
; the kernel sigaction ABI (needs SA_RESTORER + a restorer trampoline,
; since we're libc-free).
; ----------------------------------------------------------------------------
install_exit_handler:
    push rdi
    lea rdi, [sig_sa_buf]
    lea rax, [exit_handler]
    mov [rdi + 0], rax                       ; sa_handler
    mov qword [rdi + 8], SA_RESTORER         ; sa_flags
    lea rax, [sig_restorer]
    mov [rdi + 16], rax                      ; sa_restorer
    mov qword [rdi + 24], 0                  ; sa_mask
    pop rdi                                   ; signum
    mov rax, SYS_RT_SIGACTION
    ; rdi = signum already
    lea rsi, [sig_sa_buf]
    xor edx, edx                             ; oldact = NULL
    mov r10, 8                               ; sigsetsize
    syscall
    ret

sig_restorer:
    mov rax, SYS_RT_SIGRETURN
    syscall

; ----------------------------------------------------------------------------
; exit_handler — restore the console CRTC, drop DRM master, exit 0.
; Async-signal context, but every call here is a raw syscall (all
; async-signal-safe) so this is fine.
; ----------------------------------------------------------------------------
exit_handler:
    call compositor_shutdown
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

; ----------------------------------------------------------------------------
; switch_vt — edi = target VT number. Restore the console + drop DRM master,
; then VT_ACTIVATE to that VT, then exit (which releases the evdev grab so the
; target VT gets the keyboard). The kernel can't switch VTs for us while we
; hold the grab, so frame does it itself — same as a real X server.
; ----------------------------------------------------------------------------
switch_vt:
    mov [pending_vt], edi
    cmp dword [vtactive_fd], 0               ; no VT watcher (open failed) →
    jl .sv_legacy                            ; legacy behavior: clean exit
    cmp byte [vt_away], 0
    jne .sv_act                              ; already away: just re-activate
    mov byte [vt_away], 1
    call vt_release_display
.sv_act:
    call vt_console_open
    test rax, rax
    js .sv_fail
    push rax
    mov rdi, rax
    mov rax, SYS_IOCTL
    mov esi, 0x5606                          ; VT_ACTIVATE
    mov edx, [pending_vt]
    syscall
    mov rdx, rax                             ; ioctl result (survives close)
    pop rdi
    mov rax, SYS_CLOSE
    syscall
    test rdx, rdx
    jns .sv_done
.sv_fail:
    ; The kernel REFUSED the switch (EINVAL: target gone, or this VT is
    ; KD_GRAPHICS under VT_AUTO). We already released the display and
    ; gated input on vt_away — staying away now means a dead session
    ; (frozen screen, ignored input, even the zap gated) until reboot.
    ; Take the display straight back instead: the switch simply no-ops.
    cmp byte [vt_away], 0
    je .sv_done
    call vt_reacquire
.sv_done:
    ret
.sv_legacy:
    call compositor_shutdown
    call vt_console_open
    test rax, rax
    js .sv_exit
    mov rdi, rax                             ; /dev/tty0 fd
    mov rax, SYS_IOCTL
    mov esi, 0x5606                          ; VT_ACTIVATE
    mov edx, [pending_vt]
    syscall
.sv_exit:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

; ----------------------------------------------------------------------------
; vt_console_open — open the console for VT ioctls. Rootless frame cannot
; open /dev/tty0 (root-only 0600); the launcher chowns the session VT to
; geir, so open /dev/tty<own_vt> when known, /dev/tty0 otherwise (root /
; legacy). O_WRONLY: ioctls need no read mode. rax = fd (negative on fail).
; ----------------------------------------------------------------------------
vt_console_open:
    mov eax, [own_vt]
    test eax, eax
    jz .vco_tty0
    mov rcx, '/dev/tty'                      ; 8 bytes exactly
    mov [vt_dev_path], rcx
    lea rdi, [vt_dev_path + 8]
    cmp eax, 9
    jle .vco_1dig
    mov ecx, 10
    xor edx, edx
    div ecx                                  ; eax = tens, edx = ones
    add eax, '0'
    mov [rdi], al
    add edx, '0'
    mov [rdi + 1], dl
    mov byte [rdi + 2], 0
    jmp .vco_open
.vco_1dig:
    add eax, '0'
    mov [rdi], al
    mov byte [rdi + 1], 0
.vco_open:
    mov rax, SYS_OPEN
    lea rdi, [vt_dev_path]
    mov esi, 1                               ; O_WRONLY
    xor edx, edx
    syscall
    ret
.vco_tty0:
    mov rax, SYS_OPEN
    lea rdi, [str_dev_tty0]
    mov esi, 1
    xor edx, edx
    syscall
    ret

; ----------------------------------------------------------------------------
; vt_release_display — hand the display to the console: external CRTC off,
; console CRTC restored, DRM master dropped (fbcon can then repaint the
; target VT), all evdev grabs released (the console gets the keyboard),
; input state reset (keys held across the switch would otherwise stick).
; The serve loop keeps running — clients are served while we're away.
; ----------------------------------------------------------------------------
vt_release_display:
    push rbx
    cmp byte [compositor_active], 0
    je .vrd_done
    cmp byte [fbtest_mode], 0
    jne .vrd_done
    mov byte [blank_state], 0                ; console owns the panel now
    mov byte [flip_pending], 0
    cmp byte [ext_active], 0
    je .vrd_ext_done
    lea rdi, [blank_crtc_cmd]
    xor eax, eax
    mov ecx, 13
    rep stosq
    mov eax, [ext_crtc]
    mov [blank_crtc_cmd + 12], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [blank_crtc_cmd]
    syscall
.vrd_ext_done:
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_save]                 ; console's saved CRTC state
    syscall
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_DROP_MASTER
    xor edx, edx
    syscall
    ; ungrab every input fd + reset input state
    xor ebx, ebx
.vrd_ungrab:
    cmp ebx, [input_fd_count]
    jge .vrd_input_done
    mov edi, [input_fds + rbx*4]
    test edi, edi
    js .vrd_next
    mov rax, SYS_IOCTL
    mov esi, 0x40044590                      ; EVIOCGRAB
    xor edx, edx                             ; 0 = release
    syscall
.vrd_next:
    inc ebx
    jmp .vrd_ungrab
.vrd_input_done:
    mov dword [mod_state], 0                 ; keys held across the switch
    mov dword [button_state], 0              ; must not stick
    lea rdi, [keys_down]
    xor eax, eax
    mov ecx, 4
    rep stosq
.vrd_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; vt_reacquire — our VT is active again: take DRM master back, re-grab
; input, reprogram both CRTCs, re-seat the cursor, full repaint.
; ----------------------------------------------------------------------------
vt_reacquire:
    push rbx
    cmp byte [compositor_active], 0
    je .vra_done
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_SET_MASTER
    xor edx, edx
    syscall
    test rax, rax
    js .vra_done                             ; master busy: stay away, the next
    mov byte [vt_away], 0                    ; VT event retries
    xor ebx, ebx
.vra_grab:
    cmp ebx, [input_fd_count]
    jge .vra_grabbed
    mov edi, [input_fds + rbx*4]
    test edi, edi
    js .vra_next
    call maybe_grab_input                    ; keyboard/pointer check + EVIOCGRAB
.vra_next:
    inc ebx
    jmp .vra_grab
.vra_grabbed:
    call compositor_program_crtcs
    cmp dword [cursor_ready], 0
    je .vra_nocur
    mov edi, [drm_chosen_crtc]
    mov esi, [cursor_handle]
    call cursor_set_bo
    mov eax, [drm_chosen_crtc]
    mov [cursor_crtc], eax
    call cursor_move_hw
.vra_nocur:
    call now_mono_ms                         ; re-arm the blank clock
    mov [last_input_mono], rax
    mov dword [dmg_count0], -1
    mov dword [dmg_count1], -1
    mov byte [comp_dirty], 1
    mov rsi, log_vtback
    mov rdx, log_vtback_len
    call write_stderr
.vra_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; vt_read_active — lseek(0) + read tty0/active ("ttyN\n"), eax = N (0 on
; error). Reading also re-arms the sysfs POLLPRI.
; ----------------------------------------------------------------------------
vt_read_active:
    mov edi, [vtactive_fd]
    test edi, edi
    js .vra_zero
    mov rax, SYS_LSEEK
    xor esi, esi
    xor edx, edx
    syscall
    mov rax, SYS_READ
    mov edi, [vtactive_fd]
    lea rsi, [vtact_buf]
    mov rdx, 15
    syscall
    test rax, rax
    jle .vra_zero
    ; parse the digits after "tty"
    xor eax, eax
    xor ecx, ecx
.vrd_digit:
    cmp ecx, 15
    jge .vra_ret
    movzx edx, byte [vtact_buf + rcx]
    sub edx, '0'
    cmp edx, 9
    ja .vrd_skip
    imul eax, eax, 10
    add eax, edx
.vrd_skip:
    cmp byte [vtact_buf + rcx], 10           ; newline ends it
    je .vra_ret
    inc ecx
    jmp .vrd_digit
.vra_zero:
    xor eax, eax
.vra_ret:
    ret

; ----------------------------------------------------------------------------
; compositor_shutdown — restore the saved CRTC (text console), drop
; master, close the DRM fd. No-op if the compositor never activated.
; Safe to call more than once.
; ----------------------------------------------------------------------------
compositor_shutdown:
    cmp byte [compositor_active], 0
    je .cs_done
    mov byte [compositor_active], 0          ; idempotent guard
    cmp byte [fbtest_mode], 0                ; --fbtest has no DRM/panel to
    jne .cs_done                             ; restore (buffers are anon mmaps)

    ; 1. Restore the console's original CRTC. drm_crtc_save was filled by
    ;    GETCRTC in init_compositor; replaying it via SETCRTC puts the text
    ;    framebuffer back on the panel (and off frame's soon-to-be-freed fb).
    ;    The external CRTC (which the console never used) is switched OFF
    ;    first so it doesn't keep scanning the about-to-be-freed fb.
    cmp byte [ext_active], 0
    je .cs_ext_off_done
    lea rdi, [blank_crtc_cmd]
    xor eax, eax
    mov ecx, 13
    rep stosq
    mov eax, [ext_crtc]
    mov [blank_crtc_cmd + 12], eax
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [blank_crtc_cmd]
    syscall
.cs_ext_off_done:
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_save]
    syscall

    ; 2. Tear down BOTH compositor buffers: RMFB → munmap → DESTROY_DUMB. Doing
    ;    this deterministically here (not implicitly at exit) is what lets the
    ;    next DRM master — gdm/Xorg — reclaim KMS cleanly. Leaving frame's fbs
    ;    registered across the master handoff can wedge the next modeset.
    call compositor_release_buffers

    ; 3. Drop DRM master, then CLOSE the fd — releasing master + every remaining
    ;    resource before we exit, so gdm/Xorg finds a fully-free device.
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_DROP_MASTER
    xor edx, edx
    syscall
    mov rax, SYS_CLOSE
    mov rdi, [drm_fd]
    syscall
.cs_done:
    ret

; ============================================================================
; ============================================================================
; PHASE 4g — graphics contexts, window backing store, drawing primitives.
; ============================================================================
; Clients now draw real content. Each window gets a lazily-mmap'd ARGB
; backing buffer; CreateGC/ChangeGC track foreground+background;
; PolyFillRectangle and PutImage write into the backing buffer; the
; compositor blits each window's backing onto the panel.
; ============================================================================

; ----------------------------------------------------------------------------
; init_gcs — zero the GC table.
; ----------------------------------------------------------------------------
init_gcs:
    push rbx
    lea rdi, [gcs]
    xor eax, eax
    mov ecx, MAX_GCS * GC_REC_SIZE
    rep stosb
    pop rbx
    ret

; ----------------------------------------------------------------------------
; gc_lookup — edi = gcid. Returns record ptr in rax, or 0.
; ----------------------------------------------------------------------------
gc_lookup:
    push rbx
    xor ebx, ebx
.gl_loop:
    cmp ebx, MAX_GCS
    jge .gl_miss
    mov rax, rbx
    imul rax, GC_REC_SIZE
    lea rax, [gcs + rax]
    cmp [rax], edi
    je .gl_hit
    inc ebx
    jmp .gl_loop
.gl_hit:
    pop rbx
    ret
.gl_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; gc_alloc — edi = gcid. Existing record if present, else first empty
; slot marked with gcid. 0 if table full.
; ----------------------------------------------------------------------------
gc_alloc:
    push rbx
    push r12
    mov r12d, edi
    call gc_lookup
    test rax, rax
    jnz .ga_done
    xor ebx, ebx
.ga_loop:
    cmp ebx, MAX_GCS
    jge .ga_full
    mov rax, rbx
    imul rax, GC_REC_SIZE
    lea rax, [gcs + rax]
    cmp dword [rax], 0
    je .ga_take
    inc ebx
    jmp .ga_loop
.ga_take:
    mov [rax], r12d
    mov dword [rax + 4], 0x00FFFFFF          ; default fg = white
    mov dword [rax + 8], 0                    ; default bg = black
    push rax                                  ; clear the slot's clip entry
    lea rcx, [gcs]
    sub rax, rcx
    shr rax, 4
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [gc_clips]
    mov dword [rcx + rax], 0                  ; count 0 = no clip
    pop rax
.ga_done:
    pop r12
    pop rbx
    ret
.ga_full:
    lea rsi, [dbg_gcfull]                    ; DIAG: table full, create dropped
    mov edx, 7
    call write_stderr
    xor eax, eax
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; apply_gc_values — r13 = gc record, ecx = value-mask, rdx = value-list.
; GC value-mask: bit 2 (0x04) = foreground, bit 3 (0x08) = background.
; Other bits are consumed (cursor advances) but ignored.
; ----------------------------------------------------------------------------
apply_gc_values:
    push rbx
    push r12
    push r14
    mov ebx, ecx
    mov r12, rdx
    xor r14d, r14d
.agv_loop:
    test ebx, ebx
    jz .agv_done
    bt ebx, 0
    jnc .agv_skip
    mov eax, [r12]
    cmp r14d, 2
    je .agv_fg
    cmp r14d, 3
    je .agv_bg
    cmp r14d, 19
    je .agv_clipmask
    jmp .agv_adv
.agv_fg:
    mov [r13 + 4], eax
    jmp .agv_adv
.agv_bg:
    mov [r13 + 8], eax
    jmp .agv_adv
.agv_clipmask:
    ; clip-mask value: None clears the clip; pixmap masks are unsupported
    ; and also clear (over-draw beats black-splash). Rect clips come in
    ; via SetClipRectangles which overwrites the entry afterwards.
    push rax
    push rcx
    mov rax, r13
    lea rcx, [gcs]
    sub rax, rcx
    shr rax, 4
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [gc_clips]
    mov dword [rcx + rax], 0
    pop rcx
    pop rax
.agv_adv:
    add r12, 4
.agv_skip:
    shr ebx, 1
    inc r14d
    jmp .agv_loop
.agv_done:
    pop r14
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_create_gc — edi = slot, rsi = req ptr.
;   +4 cid, +8 drawable, +12 value-mask, +16 value-list
; No reply.
; ----------------------------------------------------------------------------
handle_create_gc:
    push rbx
    push r13
    mov rbx, rsi
    mov edi, [rbx + 4]                        ; cid
    test edi, edi
    jz .cg_done
    call gc_alloc
    test rax, rax
    jz .cg_done
    mov r13, rax
    mov ecx, [rbx + 12]                       ; value-mask
    test ecx, ecx
    jz .cg_done
    lea rdx, [rbx + 16]
    call apply_gc_values
.cg_done:
    pop r13
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_change_gc — edi = slot, rsi = req ptr.
;   +4 gc, +8 value-mask, +12 value-list
; No reply.
; ----------------------------------------------------------------------------
handle_change_gc:
    push rbx
    push r13
    mov rbx, rsi
    mov edi, [rbx + 4]
    call gc_lookup
    test rax, rax
    jz .chg_done
    mov r13, rax
    mov ecx, [rbx + 8]
    test ecx, ecx
    jz .chg_done
    lea rdx, [rbx + 12]
    call apply_gc_values
.chg_done:
    pop r13
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_free_gc — rsi = req ptr (+4 gc). Clears the slot. No reply.
; ----------------------------------------------------------------------------
handle_free_gc:
    push rbx
    mov edi, [rsi + 4]
    call gc_lookup
    test rax, rax
    jz .fg_done
    mov dword [rax], 0
.fg_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_set_clip_rectangles — rsi = req ptr, edx = req bytes (opcode 59).
;   +1 ordering (ignored)  +4 gc  +8 clip-x-origin s16  +10 clip-y-origin
;   +12 rect list (x s16, y s16, w u16, h u16 each).
; Stores the clip on the GC's clip entry; an empty list clips everything
; out (X semantics). No reply.
; ----------------------------------------------------------------------------
handle_set_clip_rectangles:
    push rbx
    push r12
    mov rbx, rsi
    mov r12d, edx
    mov edi, [rbx + 4]
    call gc_lookup
    test rax, rax
    jz .scr_done
    lea rcx, [gcs]
    sub rax, rcx
    shr rax, 4                                ; GC slot (rec size 16)
    imul rax, CLIP_ENTRY_SIZE
    lea rdi, [gc_clips]
    add rdi, rax                              ; clip entry
    lea rsi, [rbx + 8]                        ; origins + rects
    mov edx, r12d
    sub edx, 12
    js .scr_done
    shr edx, 3                                ; rect count
    call clip_store
.scr_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_apply_back_pixmap — rdi = window record, esi = pixmap xid. Copies
; the pixmap into the window's backing (allocating it if needed) — frame's
; take on CW_BACK_PIXMAP: materialise once at set time instead of consulting
; the pixmap at every expose. Enough for spot's snapshot cover; a client that
; mutates the pixmap afterwards and expects live refresh would need more.
; Preserves rbx/r12/r13/r14 (apply_cw_values' live registers).
; ----------------------------------------------------------------------------
window_apply_back_pixmap:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                             ; window rec
    mov edi, esi
    call pixmap_lookup
    test rax, rax
    jz .abp_out
    mov r13, rax                             ; pixmap rec
    mov r15, [r13 + 16]                      ; src backing
    test r15, r15
    jz .abp_out
    mov rdi, r12
    call window_ensure_backing
    test rax, rax
    jz .abp_out
    mov r14, rax                             ; dst backing
    ; copy w = min(dst stride, src w); copy h = min(dst h, src h)
    movzx r8d, word [r12 + 40]
    movzx edx, word [r13 + 4]
    cmp edx, r8d
    cmovb r8d, edx
    movzx r9d, word [r12 + 42]
    movzx edx, word [r13 + 6]
    cmp edx, r9d
    cmovb r9d, edx
    xor ebx, ebx                             ; row
.abp_row:
    cmp ebx, r9d
    jge .abp_damage
    movzx eax, word [r12 + 40]               ; dst stride
    imul eax, ebx
    lea rdi, [r14 + rax*4]
    movzx eax, word [r13 + 4]                ; src stride
    imul eax, ebx
    lea rsi, [r15 + rax*4]
    mov ecx, r8d
    rep movsd
    inc ebx
    jmp .abp_row
.abp_damage:
    mov rdi, r12
    movzx ecx, word [r12 + 12]               ; w
    movzx r8d, word [r12 + 14]               ; h
    xor eax, eax
    xor edx, edx
    call damage_add_local
    mov byte [comp_dirty], 1
.abp_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; window_ensure_backing — rdi = window record ptr. Guarantees a backing
; buffer matching the window's current w×h, filled with back_pixel on
; fresh allocation. Returns backing ptr in rax (0 on mmap failure).
; ----------------------------------------------------------------------------
window_ensure_backing:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi                             ; record
    movzx r12d, word [rbx + 12]              ; want w
    movzx r13d, word [rbx + 14]              ; want h
    ; Reuse if already allocated at the right size.
    cmp byte [rbx + 31], 0
    je .web_alloc
    movzx eax, word [rbx + 40]
    cmp eax, r12d
    jne .web_realloc
    movzx eax, word [rbx + 42]
    cmp eax, r13d
    jne .web_realloc
    mov rax, [rbx + 32]                      ; already good
    jmp .web_done
.web_realloc:
    mov rax, SYS_MUNMAP
    mov rdi, [rbx + 32]
    movzx esi, word [rbx + 40]
    movzx ecx, word [rbx + 42]
    imul esi, ecx
    shl esi, 2
    syscall
    mov byte [rbx + 31], 0
.web_alloc:
    ; bytes = w*h*4
    mov eax, r12d
    imul eax, r13d
    shl eax, 2
    test eax, eax
    jz .web_fail                             ; zero-size window
    mov r14d, eax                            ; bytes
    mov rax, SYS_MMAP
    xor edi, edi
    mov esi, r14d
    mov edx, PROT_RW
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9, r9
    syscall
    cmp rax, -4096
    ja .web_fail
    mov [rbx + 32], rax                      ; backing_ptr
    mov [rbx + 40], r12w                     ; backing_w
    mov [rbx + 42], r13w                     ; backing_h
    mov byte [rbx + 31], 1                   ; has_backing
    mov rdi, rbx                             ; fresh backing = whole window
    call damage_add_window                   ; changed (back_pixel fill)
    ; Fill with back_pixel.
    mov rdi, rax
    mov ecx, r12d
    imul ecx, r13d                           ; pixel count
    mov eax, [rbx + 44]                      ; back_pixel
    push rbx
    rep stosd
    pop rbx
    mov rax, [rbx + 32]
.web_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.web_fail:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_poly_fill_rectangle — edi = slot, rsi = req ptr, edx = req bytes.
;   +4 drawable, +8 gc, +12 rectangles[] (each: x s16, y s16, w u16, h u16)
; Fills each rect into the drawable window's backing buffer with the GC
; foreground colour. No reply.
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; clip_store — parse a SetClipRectangles-shaped rect list into a clip entry.
;   rdi = clip entry ptr, rsi = wire ptr (s16 ox, s16 oy, then rects of
;   x s16, y s16, w u16, h u16), edx = rect count.
; Empty list → count -1 (clip everything out, X semantics). More than
; CLIP_MAX_RECTS → collapse to one bounding box.
; ----------------------------------------------------------------------------
clip_store:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    test r14d, r14d
    jnz .cs_have
    mov dword [r12], -1
    jmp .cs_done
.cs_have:
    movsx ebx, word [r13 + 0]                 ; clip-x-origin
    movsx r15d, word [r13 + 2]                ; clip-y-origin
    add r13, 4
    cmp r14d, CLIP_MAX_RECTS
    jle .cs_exact
    ; Overflow: keep the first CLIP_MAX_RECTS rects and DROP the rest.
    ; Never fall back to the bounding box — GTK's end_paint blits a
    ; buffer whose inter-rect gaps are never-written zeros; a bbox clip
    ; copies those zeros over live window content (the "GIMP repaints
    ; black on hover" bug). Under-clipping only leaves a stale sliver.
    mov r14d, CLIP_MAX_RECTS
.cs_exact:
    mov [r12], r14d
    lea rdi, [r12 + 4]
.cs_ex_loop:
    movsx eax, word [r13 + 0]
    add eax, ebx
    mov [rdi + 0], eax                        ; x1
    movsx ecx, word [r13 + 2]
    add ecx, r15d
    mov [rdi + 4], ecx                        ; y1
    movzx edx, word [r13 + 4]
    add edx, eax
    mov [rdi + 8], edx                        ; x2
    movzx edx, word [r13 + 6]
    add edx, ecx
    mov [rdi + 12], edx                       ; y2
    add r13, 8
    add rdi, 16
    dec r14d
    jnz .cs_ex_loop
.cs_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; clip_test_point — edi = x, esi = y vs the [cur_clip] entry.
; Returns al = 1 (draw) / 0 (clipped out). Clobbers rax, rcx, rdx.
; ----------------------------------------------------------------------------
clip_test_point:
    push rbx
    mov rbx, [cur_clip]
    test rbx, rbx
    jz .ctp_yes
    mov ecx, [rbx]
    test ecx, ecx
    jz .ctp_yes
    js .ctp_no
    lea rdx, [rbx + 4]
.ctp_loop:
    cmp edi, [rdx + 0]
    jl .ctp_next
    cmp edi, [rdx + 8]
    jge .ctp_next
    cmp esi, [rdx + 4]
    jl .ctp_next
    cmp esi, [rdx + 12]
    jge .ctp_next
.ctp_yes:
    mov eax, 1
    pop rbx
    ret
.ctp_next:
    add rdx, 16
    dec ecx
    jnz .ctp_loop
.ctp_no:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; clipped_fb_fill — fb_fill honoring [cur_clip]: no clip → plain fb_fill;
; empty clip → nothing; else one fb_fill per rect intersection.
; Args identical to fb_fill (rdi buf, esi stride, edx bufh, eax x, r8d y,
; r9d w, r10d h, r11d colour).
; ----------------------------------------------------------------------------
clipped_fb_fill:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 48
    mov r12, [cur_clip]
    test r12, r12
    jz .cff_plain
    mov ebx, [r12]
    test ebx, ebx
    jz .cff_plain
    js .cff_ret
    mov [rsp + 0], rdi                        ; buf
    mov [rsp + 8], esi                        ; stride
    mov [rsp + 12], edx                       ; bufh
    mov [rsp + 16], eax                       ; x
    mov [rsp + 20], r8d                       ; y
    add eax, r9d
    mov [rsp + 24], eax                       ; x2
    mov eax, [rsp + 20]
    add eax, r10d
    mov [rsp + 28], eax                       ; y2
    mov [rsp + 32], r11d                      ; colour
    lea r13, [r12 + 4]
.cff_loop:
    mov eax, [rsp + 16]
    cmp eax, [r13 + 0]
    jge .cff_x1
    mov eax, [r13 + 0]
.cff_x1:
    mov r14d, eax                             ; ix1
    mov eax, [rsp + 24]
    cmp eax, [r13 + 8]
    jle .cff_x2
    mov eax, [r13 + 8]
.cff_x2:
    sub eax, r14d
    jle .cff_next
    mov r9d, eax                              ; iw
    mov eax, [rsp + 20]
    cmp eax, [r13 + 4]
    jge .cff_y1
    mov eax, [r13 + 4]
.cff_y1:
    mov r15d, eax                             ; iy1
    mov eax, [rsp + 28]
    cmp eax, [r13 + 12]
    jle .cff_y2
    mov eax, [r13 + 12]
.cff_y2:
    sub eax, r15d
    jle .cff_next
    mov r10d, eax                             ; ih
    mov rdi, [rsp + 0]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov eax, r14d
    mov r8d, r15d
    mov r11d, [rsp + 32]
    call fb_fill
.cff_next:
    add r13, 16
    dec ebx
    jnz .cff_loop
.cff_ret:
    add rsp, 48
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.cff_plain:
    add rsp, 48
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp fb_fill

handle_poly_fill_rectangle:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 16                              ; [rsp]=backing_w [rsp+8]=backing_h
    mov rbx, rsi                             ; req ptr
    mov r12d, edx                            ; req bytes

    ; GC foreground + clip.
    mov qword [cur_clip], 0
    mov edi, [rbx + 8]
    call gc_lookup
    test rax, rax
    jz .pfr_done
    mov r15d, [rax + 4]                      ; foreground colour
    lea rcx, [gcs]
    sub rax, rcx                              ; GC slot offset
    shr rax, 4                                ; slot index (GC_REC_SIZE 16)
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [gc_clips]
    add rax, rcx
    mov [cur_clip], rax                      ; clipped_fb_fill honours it

    ; Resolve drawable backing — window OR pixmap (glass fills its
    ; double-buffer pixmap with cells via PolyFillRectangle).
    mov edi, [rbx + 4]
    call drawable_get_backing
    test rax, rax
    jz .pfr_done
    mov r13, rax                             ; backing ptr
    mov [rsp + 0], edx                       ; backing_w (stride)
    mov [rsp + 8], ecx                       ; backing_h

    ; Iterate rectangles. Count = (req_bytes - 12) / 8.
    lea r14, [rbx + 12]                       ; rect cursor
    mov eax, r12d
    sub eax, 12
    jle .pfr_done
    shr eax, 3
    mov ebp, eax                             ; remaining rects
.pfr_loop:
    test ebp, ebp
    jz .pfr_done
    mov rdi, r13
    mov esi, [rsp + 0]                       ; backing_w (stride)
    mov edx, [rsp + 8]                       ; backing_h
    movsx eax, word [r14 + 0]                ; rect x
    movsx r8d, word [r14 + 2]                ; rect y
    movzx r9d, word [r14 + 4]                ; rect w
    movzx r10d, word [r14 + 6]               ; rect h
    mov r11d, r15d                           ; colour
    call clipped_fb_fill
    add r14, 8
    dec ebp
    jmp .pfr_loop
.pfr_done:
    mov qword [cur_clip], 0
    ; Recomposite only if the dst is a window (pixmap fills don't show
    ; until CopyArea'd to a window).
    mov edi, [rbx + 4]
    call window_lookup
    test rax, rax
    jz .pfr_ret
    mov byte [comp_dirty], 1
    mov rdx, rax                              ; damage bbox of the rect list
    lea rdi, [rbx + 12]
    mov esi, r12d
    sub esi, 12
    shr esi, 3
    call damage_rect_list
.pfr_ret:
    add rsp, 16
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; fb_fill — fill a rectangle in an arbitrary 32-bpp buffer, clipped to
; the buffer bounds.
;   rdi = buffer base
;   esi = buffer width  (stride, pixels)
;   edx = buffer height
;   eax = rect x (s32)
;   r8d = rect y (s32)
;   r9d = rect w
;   r10d = rect h
;   r11d = colour
; ----------------------------------------------------------------------------
fb_fill:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi                             ; buf
    mov r12d, esi                            ; stride
    mov r13d, edx                            ; buf height
    mov ebp, r11d                            ; colour

    ; Clip x / w.
    test eax, eax
    jns .fbf_x_ok
    add r9d, eax                             ; w += x
    xor eax, eax
.fbf_x_ok:
    cmp eax, r12d
    jge .fbf_ret
    mov ecx, eax
    add ecx, r9d
    cmp ecx, r12d
    jbe .fbf_w_ok
    mov r9d, r12d
    sub r9d, eax
.fbf_w_ok:
    cmp r9d, 0
    jle .fbf_ret

    ; Clip y / h.
    test r8d, r8d
    jns .fbf_y_ok
    add r10d, r8d
    xor r8d, r8d
.fbf_y_ok:
    cmp r8d, r13d
    jge .fbf_ret
    mov ecx, r8d
    add ecx, r10d
    cmp ecx, r13d
    jbe .fbf_h_ok
    mov r10d, r13d
    sub r10d, r8d
.fbf_h_ok:
    cmp r10d, 0
    jle .fbf_ret

    ; Draw. r14 = x, r15 = current y, r10 = rows remaining.
    mov r14d, eax                            ; x
    mov r15d, r8d                            ; y
.fbf_row:
    test r10d, r10d
    jz .fbf_ret
    mov eax, r15d
    imul eax, r12d                           ; y*stride
    add eax, r14d                            ; + x
    lea rdi, [rbx + rax*4]
    mov ecx, r9d                             ; w pixels
    mov eax, ebp
    rep stosd
    inc r15d
    dec r10d
    jmp .fbf_row
.fbf_ret:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ----------------------------------------------------------------------------
; handle_put_image — edi = slot, rsi = req ptr, edx = req bytes.
;   +1 format (2 = ZPixmap)   +4 drawable   +8 gc
;   +12 width u16   +14 height u16   +16 dst-x s16   +18 dst-y s16
;   +20 left-pad u8   +21 depth u8   +24 data
; Only ZPixmap depth 24/32 (4 bytes/pixel). Copies the image into the
; window backing at (dst-x, dst-y), clipped. No reply.
;
; Loop-invariant scalars live in a stack frame; pointers in callee-saved
; registers. No pushes inside the row loop.
;   stack: +0 imgw  +8 imgh  +16 backing_w  +24 backing_h
;          +32 dsty  +40 dst_x0  +48 src_x0  +56 copy_w
;   rbx = backing ptr   rbp = src data ptr   r12d = row
; ----------------------------------------------------------------------------
handle_put_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 80
    mov r13, rsi                             ; req ptr

    cmp byte [r13 + 1], 2                     ; ZPixmap?
    jne .pi_done
    movzx eax, byte [r13 + 21]               ; depth
    cmp eax, 24
    je .pi_ok_depth
    cmp eax, 32
    jne .pi_done
.pi_ok_depth:
    mov edi, [r13 + 4]                        ; drawable (window OR pixmap)
    call drawable_get_backing
    test rax, rax
    jz .pi_done
    mov rbx, rax                            ; backing ptr (dst base)
    mov [rsp + 16], edx                     ; backing_w (stride)
    mov [rsp + 24], ecx                     ; backing_h

    ; GC clip: GDK's client-buffer uploads cover the paint BOUNDS with the
    ; clip set to the damage region; unpainted buffer areas are zeros, so
    ; an unclipped PutImage blacks out the neighbours (menubar bug).
    mov qword [rsp + 64], 0
    mov edi, [r13 + 8]                       ; gc id
    call gc_lookup
    test rax, rax
    jz .pi_noclipgc
    lea rcx, [gcs]
    sub rax, rcx
    shr rax, 4
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [gc_clips]
    add rax, rcx
    mov ecx, [rax]
    test ecx, ecx
    jz .pi_noclipgc                          ; no clip
    js .pi_done                              ; empty clip → draw nothing
    mov [rsp + 64], rax                      ; active clip entry
.pi_noclipgc:

    lea rbp, [r13 + 24]                      ; src data ptr
    movzx eax, word [r13 + 12]              ; imgw
    mov [rsp + 0], eax
    movzx eax, word [r13 + 14]              ; imgh
    mov [rsp + 8], eax
    movsx eax, word [r13 + 18]             ; dsty
    mov [rsp + 32], eax

    ; X-axis clip (row-independent). dstx in ecx.
    movsx ecx, word [r13 + 16]             ; dstx
    xor r8d, r8d                            ; src_x0
    mov r9d, ecx                            ; dst_x0
    test ecx, ecx
    jns .pi_dx_ok
    mov r8d, ecx
    neg r8d                                  ; src_x0 = -dstx
    xor r9d, r9d                             ; dst_x0 = 0
.pi_dx_ok:
    mov [rsp + 40], r9d                      ; dst_x0
    mov [rsp + 48], r8d                      ; src_x0
    ; copy_w = min(imgw - src_x0, backing_w - dst_x0)
    mov eax, [rsp + 0]
    sub eax, r8d
    jle .pi_done
    mov edx, [rsp + 16]
    sub edx, r9d
    jle .pi_done
    cmp eax, edx
    jle .pi_cw
    mov eax, edx
.pi_cw:
    mov [rsp + 56], eax                      ; copy_w

    xor r12d, r12d                           ; row = 0
.pi_row:
    mov eax, [rsp + 8]                       ; imgh
    cmp r12d, eax
    jge .pi_done
    ; dy = dsty + row
    mov eax, [rsp + 32]
    add eax, r12d
    js .pi_row_next
    cmp eax, [rsp + 24]                      ; backing_h
    jge .pi_done
    mov r10d, eax                            ; dy (keep across segment math)
    cmp qword [rsp + 64], 0                  ; clip active?
    jne .pi_row_clipped
    ; dst = backing + (dy*backing_w + dst_x0)*4
    mov ecx, r10d
    imul ecx, [rsp + 16]
    add ecx, [rsp + 40]
    lea rdi, [rbx + rcx*4]
    ; src = srcdata + (row*imgw + src_x0)*4
    mov eax, r12d
    imul eax, [rsp + 0]
    add eax, [rsp + 48]
    lea rsi, [rbp + rax*4]
    mov ecx, [rsp + 56]                      ; copy_w
    rep movsd
    jmp .pi_row_next
.pi_row_clipped:
    ; one sub-copy per clip rect ∩ this row's dst segment
    mov r14, [rsp + 64]
    mov r15d, [r14]                          ; rect count (>0)
    add r14, 4
.pi_seg_loop:
    cmp r10d, [r14 + 4]                      ; dy ≥ rect.y1?
    jl .pi_seg_next
    cmp r10d, [r14 + 12]                     ; dy < rect.y2?
    jge .pi_seg_next
    mov ecx, [rsp + 40]                      ; seg_x0 = max(dst_x0, rect.x1)
    cmp ecx, [r14 + 0]
    jge .pi_sx
    mov ecx, [r14 + 0]
.pi_sx:
    mov edx, [rsp + 40]                      ; seg_x1 = min(dst_x0+copy_w, rect.x2)
    add edx, [rsp + 56]
    cmp edx, [r14 + 8]
    jle .pi_sx2
    mov edx, [r14 + 8]
.pi_sx2:
    sub edx, ecx                             ; seg_w
    jle .pi_seg_next
    ; dst = backing + (dy*stride + seg_x0)*4
    mov eax, r10d
    imul eax, [rsp + 16]
    add eax, ecx
    lea rdi, [rbx + rax*4]
    ; src = data + (row*imgw + src_x0 + (seg_x0 - dst_x0))*4
    mov eax, r12d
    imul eax, [rsp + 0]
    add eax, [rsp + 48]
    add eax, ecx
    sub eax, [rsp + 40]
    lea rsi, [rbp + rax*4]
    mov ecx, edx
    rep movsd
.pi_seg_next:
    add r14, 16
    dec r15d
    jnz .pi_seg_loop
.pi_row_next:
    inc r12d
    jmp .pi_row
.pi_done:
    ; Recomposite only if the dst is a window (pixmap PutImage, e.g. glass's
    ; per-colour pen-pixmap update, must NOT trigger a full repaint).
    mov edi, [r13 + 4]
    call window_lookup
    test rax, rax
    jz .pi_ret
    mov byte [comp_dirty], 1
    mov rdi, rax                              ; damage the uploaded rect
    movsx eax, word [r13 + 16]
    movsx edx, word [r13 + 18]
    movzx ecx, word [r13 + 12]                ; imgw
    movzx r8d, word [r13 + 14]                ; imgh
    call damage_add_local
.pi_ret:
    add rsp, 80
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_shm_put_image — ShmPutImage (MIT-SHM minor 3). rsi = req ptr.
;   +4 drawable +8 gc +12 totalWidth +14 totalHeight +16 srcX +18 srcY
;   +20 srcWidth +22 srcHeight +24 dstX s16 +26 dstY s16 +28 depth +29 format
;   +32 shmseg +36 offset
; Blits the (srcX,srcY,srcWidth,srcHeight) sub-rect of the totalWidth-strided
; ZPixmap image in the attached segment to the drawable at (dstX,dstY). Same
; backing + GC clipping as handle_put_image; the source is shared memory
; (no image bytes on the wire), bounds-checked against the segment size.
;   stack: +0 stride  +8 rows  +16 backing_w  +24 backing_h  +32 dsty
;          +40 dst_x0 +48 src_x0 +56 copy_w  +64 clip_entry  +72 srcWidth
;   rbx = backing ptr  rbp = src base ptr  r12d = row
; ----------------------------------------------------------------------------
handle_shm_put_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 80
    mov [rsp + 76], edi                      ; slot (for ShmCompletion)
    mov r13, rsi                             ; req ptr

    cmp byte [r13 + 29], 2                    ; format ZPixmap?
    jne .spi_ret
    movzx eax, byte [r13 + 28]               ; depth 24/32
    cmp eax, 24
    je .spi_depth_ok
    cmp eax, 32
    jne .spi_ret
.spi_depth_ok:
    mov edi, [r13 + 4]                        ; drawable
    call drawable_get_backing
    test rax, rax
    jz .spi_ret
    mov rbx, rax                            ; backing ptr
    mov [rsp + 16], edx                     ; backing_w (stride, px)
    mov [rsp + 24], ecx                     ; backing_h

    mov edi, [r13 + 32]                      ; shmseg
    call shm_seg_lookup                     ; rax=addr rdx=size
    test rax, rax
    jz .spi_ret
    mov r14, rax                            ; seg addr
    mov r15, rdx                            ; seg size

    ; bounds: offset + totalWidth*totalHeight*4 must fit the segment (64-bit)
    movzx eax, word [r13 + 12]              ; totalWidth → stride
    mov [rsp + 0], eax
    movzx ecx, word [r13 + 14]              ; totalHeight
    mov r8, rax
    imul r8, rcx
    shl r8, 2
    mov eax, [r13 + 36]                      ; offset (u32)
    add r8, rax
    cmp r8, r15
    ja .spi_ret                             ; would read past the segment

    ; src base = addr + offset + (srcY*stride + srcX)*4
    mov rbp, r14
    mov eax, [r13 + 36]
    add rbp, rax
    movzx eax, word [r13 + 18]              ; srcY
    imul eax, [rsp + 0]
    movzx ecx, word [r13 + 16]             ; srcX
    add eax, ecx
    lea rbp, [rbp + rax*4]

    movzx eax, word [r13 + 22]              ; srcHeight → rows
    mov [rsp + 8], eax
    movzx eax, word [r13 + 20]              ; srcWidth
    mov [rsp + 72], eax
    movsx eax, word [r13 + 26]             ; dstY
    mov [rsp + 32], eax

    ; GC clip (identical to handle_put_image)
    mov qword [rsp + 64], 0
    mov edi, [r13 + 8]
    call gc_lookup
    test rax, rax
    jz .spi_noclip
    lea rcx, [gcs]
    sub rax, rcx
    shr rax, 4
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [gc_clips]
    add rax, rcx
    mov ecx, [rax]
    test ecx, ecx
    jz .spi_noclip
    js .spi_ret
    mov [rsp + 64], rax
.spi_noclip:

    ; x-clip: dstX → dst_x0, src_x0
    movsx ecx, word [r13 + 24]             ; dstX
    xor r8d, r8d
    mov r9d, ecx
    test ecx, ecx
    jns .spi_dx_ok
    mov r8d, ecx
    neg r8d
    xor r9d, r9d
.spi_dx_ok:
    mov [rsp + 40], r9d                      ; dst_x0
    mov [rsp + 48], r8d                      ; src_x0
    mov eax, [rsp + 72]                      ; copy_w = min(srcWidth-src_x0, bw-dst_x0)
    sub eax, r8d
    jle .spi_recomp
    mov edx, [rsp + 16]
    sub edx, r9d
    jle .spi_recomp
    cmp eax, edx
    jle .spi_cw
    mov eax, edx
.spi_cw:
    mov [rsp + 56], eax

    xor r12d, r12d
.spi_row:
    mov eax, [rsp + 8]                       ; rows
    cmp r12d, eax
    jge .spi_recomp
    mov eax, [rsp + 32]                      ; dsty + row
    add eax, r12d
    js .spi_row_next
    cmp eax, [rsp + 24]                      ; backing_h
    jge .spi_recomp
    mov r10d, eax                            ; dy
    cmp qword [rsp + 64], 0
    jne .spi_row_clipped
    mov ecx, r10d                            ; dst = backing + (dy*bw + dst_x0)*4
    imul ecx, [rsp + 16]
    add ecx, [rsp + 40]
    lea rdi, [rbx + rcx*4]
    mov eax, r12d                            ; src = base + (row*stride + src_x0)*4
    imul eax, [rsp + 0]
    add eax, [rsp + 48]
    lea rsi, [rbp + rax*4]
    mov ecx, [rsp + 56]
    rep movsd
    jmp .spi_row_next
.spi_row_clipped:
    mov r14, [rsp + 64]
    mov r15d, [r14]
    add r14, 4
.spi_seg_loop:
    cmp r10d, [r14 + 4]
    jl .spi_seg_next
    cmp r10d, [r14 + 12]
    jge .spi_seg_next
    mov ecx, [rsp + 40]
    cmp ecx, [r14 + 0]
    jge .spi_sx
    mov ecx, [r14 + 0]
.spi_sx:
    mov edx, [rsp + 40]
    add edx, [rsp + 56]
    cmp edx, [r14 + 8]
    jle .spi_sx2
    mov edx, [r14 + 8]
.spi_sx2:
    sub edx, ecx
    jle .spi_seg_next
    mov eax, r10d
    imul eax, [rsp + 16]
    add eax, ecx
    lea rdi, [rbx + rax*4]
    mov eax, r12d
    imul eax, [rsp + 0]
    add eax, [rsp + 48]
    add eax, ecx
    sub eax, [rsp + 40]
    lea rsi, [rbp + rax*4]
    mov ecx, edx
    rep movsd
.spi_seg_next:
    add r14, 16
    dec r15d
    jnz .spi_seg_loop
.spi_row_next:
    inc r12d
    jmp .spi_row

.spi_recomp:
    mov edi, [r13 + 4]                        ; recomposite iff drawable is a window
    call window_lookup
    test rax, rax
    jz .spi_ret
    mov byte [comp_dirty], 1
    mov rdi, rax
    movsx eax, word [r13 + 24]             ; dstX
    movsx edx, word [r13 + 26]             ; dstY
    movzx ecx, word [r13 + 20]             ; srcWidth
    movzx r8d, word [r13 + 22]             ; srcHeight
    call damage_add_local
.spi_ret:
    ; ShmCompletion (sendEvent flag +30): Chromium's software presenter
    ; throttles on this event — without it the UI freezes after two
    ; frames (the FortiClient white window). Sent on every exit: the
    ; semantic is "server is done with the segment", success or not.
    cmp byte [r13 + 30], 0
    je .spi_out
    lea rdi, [xi2_buf]                       ; event scratch (single-threaded)
    xor eax, eax
    mov ecx, 4
    push rdi
    rep stosq
    pop rdi
    mov byte [rdi + 0], SHM_EVENT_BASE       ; ShmCompletion
    mov eax, [r13 + 4]
    mov [rdi + 4], eax                       ; drawable
    mov word [rdi + 8], 3                    ; minorEvent = ShmPutImage
    mov byte [rdi + 10], SHM_MAJOR           ; majorEvent
    mov eax, [r13 + 32]
    mov [rdi + 12], eax                      ; shmseg
    mov eax, [r13 + 36]
    mov [rdi + 16], eax                      ; offset
    mov eax, [rsp + 76]                      ; slot
    call client_meta_addr
    mov ecx, [rax + 8]                       ; seq
    mov [xi2_buf + 2], cx
    mov edi, [rax]                           ; fd
    lea rsi, [xi2_buf]
    mov edx, 32
    EV_SEND
.spi_out:
    add rsp, 80
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; blit_window_shaped — rdi = window record ptr. If the window has a SHAPE
; bounding region, blit each region rect separately by intersecting it with
; the current bw_clip (painter's order already put the content beneath, so
; the punched-out areas show through). Unshaped windows take the plain path
; with zero overhead beyond one table probe.
; ----------------------------------------------------------------------------
blit_window_shaped:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi                             ; record
    mov edi, [r12]                           ; xid
    xor esi, esi                             ; kind = bounding
    call shape_slot_find
    test rax, rax
    jz .bws_plain
    mov r13, rax                             ; shape slot
    ; save the caller's clip
    mov eax, [bw_clip_x1]
    mov [bws_clip_save + 0], eax
    mov eax, [bw_clip_y1]
    mov [bws_clip_save + 4], eax
    mov eax, [bw_clip_x2]
    mov [bws_clip_save + 8], eax
    mov eax, [bw_clip_y2]
    mov [bws_clip_save + 12], eax
    ; window absolute origin (rects are window-local)
    mov edi, [r12]
    call window_abs_xy                       ; r10d/r11d
    mov [bws_abs_x], r10d
    mov [bws_abs_y], r11d
    xor r14d, r14d                           ; rect index
.bws_loop:
    cmp r14d, [r13 + 8]
    jge .bws_restore
    lea rbx, [r14*8]
    lea rbx, [r13 + rbx + 16]                ; rect ptr
    movsx eax, word [rbx]                    ; x1 = abs_x + rx
    add eax, [bws_abs_x]
    movsx edx, word [rbx + 2]                ; y1 = abs_y + ry
    add edx, [bws_abs_y]
    movzx ecx, word [rbx + 4]                ; x2 = x1 + rw
    add ecx, eax
    movzx r8d, word [rbx + 6]                ; y2 = y1 + rh
    add r8d, edx
    ; intersect with the saved clip
    cmp eax, [bws_clip_save + 0]
    jge .bws_k1
    mov eax, [bws_clip_save + 0]
.bws_k1:
    cmp edx, [bws_clip_save + 4]
    jge .bws_k2
    mov edx, [bws_clip_save + 4]
.bws_k2:
    cmp ecx, [bws_clip_save + 8]
    jle .bws_k3
    mov ecx, [bws_clip_save + 8]
.bws_k3:
    cmp r8d, [bws_clip_save + 12]
    jle .bws_k4
    mov r8d, [bws_clip_save + 12]
.bws_k4:
    cmp eax, ecx
    jge .bws_next                            ; empty intersection
    cmp edx, r8d
    jge .bws_next
    mov [bw_clip_x1], eax
    mov [bw_clip_y1], edx
    mov [bw_clip_x2], ecx
    mov [bw_clip_y2], r8d
    mov rdi, r12
    call blit_window
.bws_next:
    inc r14d
    jmp .bws_loop
.bws_restore:
    mov eax, [bws_clip_save + 0]
    mov [bw_clip_x1], eax
    mov eax, [bws_clip_save + 4]
    mov [bw_clip_y1], eax
    mov eax, [bws_clip_save + 8]
    mov [bw_clip_x2], eax
    mov eax, [bws_clip_save + 12]
    mov [bw_clip_y2], eax
    jmp .bws_out
.bws_plain:
    mov rdi, r12
    call blit_window
.bws_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; blit_window — rdi = window record ptr. Copies the window's backing
; buffer to the dumb framebuffer at (win.x, win.y), clipped to the
; screen. Backing stride = backing_w.
;
;   stack: +0 backing_w  +8 backing_h  +16 win_y  +24 dst_x0
;          +32 src_x0  +40 copy_w  +48 screen_h
;   rbx = backing ptr   r12d = ry
; ----------------------------------------------------------------------------
blit_window:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 64
    mov r13, rdi                             ; record

    mov edi, [r13]                           ; absolute origin (children of
    call window_abs_xy                       ; non-root parents draw where
    mov r14d, r10d                           ; they actually live)
    mov eax, r11d
    mov [rsp + 16], eax
    movzx eax, word [r13 + 40]            ; backing_w (stride)
    mov [rsp + 0], eax
    movzx eax, word [r13 + 42]            ; backing_h
    mov [rsp + 8], eax
    mov rbx, [r13 + 32]                    ; backing ptr
    mov eax, [screen_h]
    mov [rsp + 48], eax
    mov r15d, [screen_w]
    xor eax, eax                           ; depth-32 (ARGB visual) windows
    cmp byte [r13 + 18], 32                ; blend instead of copy — real
    sete al                                ; transparency (glass opacity)
    mov [rsp + 56], al

    ; X clip. win x in r14d.
    xor r8d, r8d                           ; src_x0
    mov r9d, r14d                          ; dst_x0 = x
    test r14d, r14d
    jns .bw_dx_ok
    mov r8d, r14d
    neg r8d                                 ; src_x0 = -x
    xor r9d, r9d                            ; dst_x0 = 0
.bw_dx_ok:
    ; bw_clip X: shift the left edge into the clip, cap the right edge
    mov eax, [bw_clip_x1]
    cmp r9d, eax
    jge .bw_cx1
    sub eax, r9d                            ; delta
    add r9d, eax
    add r8d, eax
.bw_cx1:
    mov [rsp + 24], r9d                     ; dst_x0
    mov [rsp + 32], r8d                     ; src_x0
    ; copy_w = min(backing_w - src_x0, screen_w - dst_x0, clip_x2 - dst_x0)
    mov eax, [rsp + 0]
    sub eax, r8d
    jle .bw_done
    mov edx, r15d
    sub edx, r9d
    jle .bw_done
    cmp eax, edx
    jle .bw_cw0
    mov eax, edx
.bw_cw0:
    mov edx, [bw_clip_x2]
    sub edx, r9d
    jle .bw_done
    cmp eax, edx
    jle .bw_cw
    mov eax, edx
.bw_cw:
    mov [rsp + 40], eax                     ; copy_w

    ; start at the first backing row inside the clip: ry0 = clip_y1 - win_y
    xor r12d, r12d                          ; ry = 0
    mov eax, [bw_clip_y1]
    sub eax, [rsp + 16]
    jle .bw_row
    mov r12d, eax
.bw_row:
    mov eax, [rsp + 8]                      ; backing_h
    cmp r12d, eax
    jge .bw_done
    ; dy = win_y + ry
    mov eax, [rsp + 16]
    add eax, r12d
    js .bw_row_next
    cmp eax, [rsp + 48]                     ; screen_h
    jge .bw_done
    cmp eax, [bw_clip_y2]                   ; past the clip → done
    jge .bw_done
    ; dst = drm_dumb_addr + dy*pitch + dst_x0*4
    mov ecx, eax
    imul ecx, [drm_dumb_pitch]
    mov rdi, [drm_dumb_addr]
    add rdi, rcx
    mov eax, [rsp + 24]                     ; dst_x0
    lea rdi, [rdi + rax*4]
    ; src = backing + (ry*backing_w + src_x0)*4
    mov eax, r12d
    imul eax, [rsp + 0]
    add eax, [rsp + 32]
    lea rsi, [rbx + rax*4]
    mov ecx, [rsp + 40]                     ; copy_w
    add [comp_px_blit], rcx                 ; PERF counter
    cmp byte [rsp + 56], 0
    jne .bw_blend
    rep movsd
.bw_row_next:
    inc r12d
    jmp .bw_row

    ; --- ARGB row: STRAIGHT-alpha src-over (glass writes A=opacity with
    ; unscaled RGB; its text cells are opaque, so the a=255 fast path
    ; covers glyphs and only the translucent background pays the blend;
    ; for premultiplied toolkit pixels a=255 regions are identical).
.bw_blend:
    mov eax, [rsi]
    mov edx, eax
    shr edx, 24                             ; a
    cmp edx, 255
    je .bw_bl_store
    test edx, edx
    jz .bw_bl_next
    mov ebp, 255
    sub ebp, edx                            ; na = 255 - a
    mov r8d, [rdi]                          ; dst pixel
    ; blue
    movzx r9d, al
    imul r9d, edx
    movzx r10d, r8b
    imul r10d, ebp
    add r9d, r10d
    mov r10d, r9d                           ; /255 ≈ (t + (t>>8) + 1) >> 8
    shr r10d, 8
    lea r9d, [r9 + r10 + 1]
    shr r9d, 8
    mov r11d, r9d
    ; green
    mov r9d, eax
    shr r9d, 8
    and r9d, 0xFF
    imul r9d, edx
    mov r10d, r8d
    shr r10d, 8
    and r10d, 0xFF
    imul r10d, ebp
    add r9d, r10d
    mov r10d, r9d
    shr r10d, 8
    lea r9d, [r9 + r10 + 1]
    shr r9d, 8
    shl r9d, 8
    or  r11d, r9d
    ; red
    mov r9d, eax
    shr r9d, 16
    and r9d, 0xFF
    imul r9d, edx
    mov r10d, r8d
    shr r10d, 16
    and r10d, 0xFF
    imul r10d, ebp
    add r9d, r10d
    mov r10d, r9d
    shr r10d, 8
    lea r9d, [r9 + r10 + 1]
    shr r9d, 8
    shl r9d, 16
    or  r11d, r9d
    or  r11d, 0xFF000000                    ; fb stays opaque
    mov [rdi], r11d
    jmp .bw_bl_next
.bw_bl_store:
    mov [rdi], eax
.bw_bl_next:
    add rsi, 4
    add rdi, 4
    dec ecx
    jnz .bw_blend
    jmp .bw_row_next
.bw_done:
    add rsp, 64
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4h — pixmaps + CopyArea + ClearArea + PolyRectangle.
; ============================================================================
; Offscreen pixmap drawables, the copy/clear ops every toolkit uses, and
; rectangle outlines. drawable_get_backing unifies windows and pixmaps so
; the drawing ops work on either.
; ============================================================================

; ----------------------------------------------------------------------------
; init_pixmaps — zero the pixmap table.
; ----------------------------------------------------------------------------
init_pixmaps:
    push rbx
    lea rdi, [pixmaps]
    xor eax, eax
    mov ecx, MAX_PIXMAPS * PIXMAP_REC_SIZE
    rep stosb
    pop rbx
    ret

; ----------------------------------------------------------------------------
; pixmap_lookup — edi = pid. Returns record ptr in rax, or 0.
; ----------------------------------------------------------------------------
pixmap_lookup:
    push rbx
    xor ebx, ebx
.pxl_loop:
    cmp ebx, MAX_PIXMAPS
    jge .pxl_miss
    mov rax, rbx
    imul rax, PIXMAP_REC_SIZE
    lea rax, [pixmaps + rax]
    cmp [rax], edi
    je .pxl_hit
    inc ebx
    jmp .pxl_loop
.pxl_hit:
    pop rbx
    ret
.pxl_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; drawable_get_backing — edi = drawable xid. Resolves either a window
; (ensuring its backing) or a pixmap. Returns:
;   rax = backing ptr (0 if not found / no backing)
;   edx = width (pixels, = stride)
;   ecx = height
; ----------------------------------------------------------------------------
drawable_get_backing:
    push rbx
    ; Try window first.
    push rdi
    call window_lookup
    pop rdi
    test rax, rax
    jz .dgb_pixmap
    ; It's a window — ensure backing.
    cmp dword [rax], X_ROOT_WINDOW
    je .dgb_none                             ; root has no backing buffer
    mov rbx, rax
    push rbx
    mov rdi, rbx
    call window_ensure_backing
    pop rbx
    test rax, rax
    jz .dgb_none
    movzx edx, word [rbx + 40]               ; backing_w
    movzx ecx, word [rbx + 42]               ; backing_h
    pop rbx
    ret
.dgb_pixmap:
    call pixmap_lookup
    test rax, rax
    jz .dgb_none
    movzx edx, word [rax + 4]                ; width
    movzx ecx, word [rax + 6]                ; height
    mov rax, [rax + 16]                      ; backing ptr
    test rax, rax
    jz .dgb_none
    pop rbx
    ret
.dgb_none:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_create_pixmap — rsi = req ptr.
;   +1 depth   +4 pid   +8 drawable   +12 width u16   +14 height u16
; mmap a w*h*4 backing buffer (zero-filled by the kernel). No reply.
; ----------------------------------------------------------------------------
handle_create_pixmap:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rsi
    mov edi, [rbx + 4]                        ; pid
    test edi, edi
    jz .cpx_done
    movzx r13d, word [rbx + 12]              ; width
    movzx r14d, word [rbx + 14]              ; height
    test r13d, r13d
    jz .cpx_done
    test r14d, r14d
    jz .cpx_done

    ; Find an empty pixmap slot.
    xor ecx, ecx
.cpx_find:
    cmp ecx, MAX_PIXMAPS
    jl .cpx_scan
    lea rsi, [dbg_pxfull]                    ; DIAG: table full, create dropped
    mov edx, 7
    call write_stderr
    jmp .cpx_done
.cpx_scan:
    mov rax, rcx
    imul rax, PIXMAP_REC_SIZE
    lea rax, [pixmaps + rax]
    cmp dword [rax], 0
    je .cpx_take
    inc ecx
    jmp .cpx_find
.cpx_take:
    mov r12, rax                             ; record ptr
    ; mmap w*h*4
    mov eax, r13d
    imul eax, r14d
    shl eax, 2
    push rax                                  ; bytes (for fill count via shr)
    mov rsi, rax
    mov rax, SYS_MMAP
    xor edi, edi
    mov edx, PROT_RW
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9, r9
    syscall
    pop rcx                                   ; bytes (unused now)
    cmp rax, -4096
    ja .cpx_done
    ; Fill the record.
    mov ecx, [rbx + 4]
    mov [r12 + 0], ecx                        ; pid
    mov [r12 + 4], r13w                       ; width
    mov [r12 + 6], r14w                       ; height
    movzx ecx, byte [rbx + 1]
    mov [r12 + 8], cl                         ; depth
    mov [r12 + 16], rax                       ; backing ptr
.cpx_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_free_pixmap — rsi = req ptr (+4 pixmap). munmap + clear. No reply.
; ----------------------------------------------------------------------------
handle_free_pixmap:
    push rbx
    mov edi, [rsi + 4]
    call pixmap_lookup
    test rax, rax
    jz .fpx_done
    mov rbx, rax
    ; munmap w*h*4
    mov rdi, [rbx + 16]
    movzx esi, word [rbx + 4]
    movzx ecx, word [rbx + 6]
    imul esi, ecx
    shl esi, 2
    mov rax, SYS_MUNMAP
    syscall
    mov dword [rbx], 0                        ; clear slot
    mov qword [rbx + 16], 0
.fpx_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_clear_area — rsi = req ptr.
;   +1 exposures   +4 window   +8 x s16   +10 y s16   +12 w u16   +14 h u16
; Fills the region in the window's backing with its back_pixel. A w or h
; of 0 means "to the edge of the window". No reply.
; ----------------------------------------------------------------------------
handle_clear_area:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov edi, [rbx + 4]                        ; window
    call window_lookup
    test rax, rax
    jz .ca_done
    mov r12, rax
    cmp dword [r12], X_ROOT_WINDOW
    je .ca_done
    mov rdi, r12
    call window_ensure_backing
    test rax, rax
    jz .ca_done
    mov r13, rax                             ; backing

    ; geometry
    movsx eax, word [rbx + 8]                ; x
    movsx r8d, word [rbx + 10]               ; y
    movzx r9d, word [rbx + 12]               ; w
    movzx r10d, word [rbx + 14]              ; h
    ; w==0 → backing_w - x ; h==0 → backing_h - y
    test r9d, r9d
    jnz .ca_w_ok
    movzx r9d, word [r12 + 40]
    sub r9d, eax
.ca_w_ok:
    test r10d, r10d
    jnz .ca_h_ok
    movzx r10d, word [r12 + 42]
    sub r10d, r8d
.ca_h_ok:
    mov [dmg_lat + 0], eax                   ; latch the fill rect for damage
    mov [dmg_lat + 4], r8d
    mov [dmg_lat + 8], r9d
    mov [dmg_lat + 12], r10d
    mov rdi, r13
    movzx esi, word [r12 + 40]               ; backing_w (stride)
    movzx edx, word [r12 + 42]               ; backing_h
    mov r11d, [r12 + 44]                      ; back_pixel
    call fb_fill
    mov byte [comp_dirty], 1
    mov rdi, r12                              ; damage the cleared rect
    mov eax, [dmg_lat + 0]
    mov edx, [dmg_lat + 4]
    mov ecx, [dmg_lat + 8]
    mov r8d, [dmg_lat + 12]
    call damage_add_local
.ca_done:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_copy_area — rsi = req ptr.
;   +4 src-drawable  +8 dst-drawable  +12 gc
;   +16 src-x s16  +18 src-y s16  +20 dst-x s16  +22 dst-y s16
;   +24 width u16  +26 height u16
; Copies a rect from src backing to dst backing, clipped to both. If the
; dst is a window, recomposites. No reply.
;
; Stack frame holds loop-invariant scalars; pointers in callee-saved regs.
;   +0 src_ptr  +8 dst_ptr  +16 src_stride  +24 dst_stride
;   +32 src_h   +40 dst_h   +48 sx  +56 sy  +64 dx  +72 dy
;   +80 copy_w  +88 copy_h
; ----------------------------------------------------------------------------
handle_copy_area:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 160
    mov rbx, rsi                             ; req ptr

    ; Resolve src.
    mov edi, [rbx + 4]
    call drawable_get_backing
    test rax, rax
    jz .cpa_done
    mov [rsp + 0], rax                       ; src_ptr
    mov [rsp + 16], edx                      ; src_stride (=width)
    mov [rsp + 32], ecx                      ; src_h
    ; Resolve dst.
    mov edi, [rbx + 8]
    call drawable_get_backing
    test rax, rax
    jz .cpa_done
    mov [rsp + 8], rax                       ; dst_ptr
    mov [rsp + 24], edx                      ; dst_stride
    mov [rsp + 40], ecx                      ; dst_h

    ; Coords.
    movsx eax, word [rbx + 16]
    mov [rsp + 48], eax                      ; sx
    movsx eax, word [rbx + 18]
    mov [rsp + 56], eax                      ; sy
    movsx eax, word [rbx + 20]
    mov [rsp + 64], eax                      ; dx
    movsx eax, word [rbx + 22]
    mov [rsp + 72], eax                      ; dy
    movzx eax, word [rbx + 24]
    mov [rsp + 80], eax                      ; copy_w
    movzx eax, word [rbx + 26]
    mov [rsp + 88], eax                      ; copy_h

    ; --- Clip. We adjust sx/sy/dx/dy/copy_w/copy_h so both src and dst
    ; rects stay in bounds. Handle negative src/dst origins by trimming
    ; from the top-left.
    ; Left edge: shift = max(0, -sx, -dx)
    xor ecx, ecx
    mov eax, [rsp + 48]
    neg eax
    cmp eax, ecx
    cmovg ecx, eax
    mov eax, [rsp + 64]
    neg eax
    cmp eax, ecx
    cmovg ecx, eax                           ; ecx = left shift
    add [rsp + 48], ecx
    add [rsp + 64], ecx
    sub [rsp + 80], ecx
    ; Top edge: shift = max(0, -sy, -dy)
    xor ecx, ecx
    mov eax, [rsp + 56]
    neg eax
    cmp eax, ecx
    cmovg ecx, eax
    mov eax, [rsp + 72]
    neg eax
    cmp eax, ecx
    cmovg ecx, eax
    add [rsp + 56], ecx
    add [rsp + 72], ecx
    sub [rsp + 88], ecx
    ; Right edge: copy_w = min(copy_w, src_stride - sx, dst_stride - dx)
    mov eax, [rsp + 16]
    sub eax, [rsp + 48]
    mov edx, [rsp + 80]
    cmp eax, edx
    cmovl edx, eax
    mov eax, [rsp + 24]
    sub eax, [rsp + 64]
    cmp eax, edx
    cmovl edx, eax
    mov [rsp + 80], edx
    cmp edx, 0
    jle .cpa_done
    ; Bottom edge: copy_h = min(copy_h, src_h - sy, dst_h - dy)
    mov eax, [rsp + 32]
    sub eax, [rsp + 56]
    mov edx, [rsp + 88]
    cmp eax, edx
    cmovl edx, eax
    mov eax, [rsp + 40]
    sub eax, [rsp + 72]
    cmp eax, edx
    cmovl edx, eax
    mov [rsp + 88], edx
    cmp edx, 0
    jle .cpa_done

    ; --- GC clip stage: honour SetClipRectangles by running the row copy
    ; once per clip-rect ∩ dst-rect. GTK's end_paint blits a buffer whose
    ; unpainted regions are zeros, clipped to the damage region — copying
    ; unclipped splashes black over neighbouring content.
    mov rbp, rsp                             ; frame base for .cpa_copy
    mov edi, [rbx + 12]                      ; gc id
    call gc_lookup
    test rax, rax
    jz .cpa_noclip
    lea rcx, [gcs]
    sub rax, rcx
    shr rax, 4                                ; GC slot (rec size 16)
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [gc_clips]
    add rax, rcx
    mov ecx, [rax]                            ; clip count
    test ecx, ecx
    jz .cpa_noclip
    js .cpa_blit_done                         ; empty clip → draw nothing
    lea r13, [rax + 4]                        ; rect cursor
    mov r14d, ecx
.cpa_clip_loop:
    mov eax, [rbp + 64]                       ; dx
    cmp eax, [r13 + 0]
    jge .cpa_cx1
    mov eax, [r13 + 0]
.cpa_cx1:
    mov [rbp + 104], eax                      ; dx'
    mov ecx, [rbp + 64]
    add ecx, [rbp + 80]                       ; dx + w
    cmp ecx, [r13 + 8]
    jle .cpa_cx2
    mov ecx, [r13 + 8]
.cpa_cx2:
    sub ecx, eax
    jle .cpa_clip_next
    mov [rbp + 112], ecx                      ; w'
    mov edx, [rbp + 72]                       ; dy
    cmp edx, [r13 + 4]
    jge .cpa_cy1
    mov edx, [r13 + 4]
.cpa_cy1:
    mov [rbp + 108], edx                      ; dy'
    mov ecx, [rbp + 72]
    add ecx, [rbp + 88]                       ; dy + h
    cmp ecx, [r13 + 12]
    jle .cpa_cy2
    mov ecx, [r13 + 12]
.cpa_cy2:
    sub ecx, edx
    jle .cpa_clip_next
    mov [rbp + 116], ecx                      ; h'
    mov eax, [rbp + 104]                      ; sx' = sx + (dx'-dx)
    sub eax, [rbp + 64]
    add eax, [rbp + 48]
    mov [rbp + 96], eax
    mov eax, [rbp + 108]                      ; sy' = sy + (dy'-dy)
    sub eax, [rbp + 72]
    add eax, [rbp + 56]
    mov [rbp + 100], eax
    call .cpa_copy
.cpa_clip_next:
    add r13, 16
    dec r14d
    jnz .cpa_clip_loop
    jmp .cpa_blit_done
.cpa_noclip:
    mov eax, [rbp + 48]
    mov [rbp + 96], eax
    mov eax, [rbp + 56]
    mov [rbp + 100], eax
    mov eax, [rbp + 64]
    mov [rbp + 104], eax
    mov eax, [rbp + 72]
    mov [rbp + 108], eax
    mov eax, [rbp + 80]
    mov [rbp + 112], eax
    mov eax, [rbp + 88]
    mov [rbp + 116], eax
    call .cpa_copy
    jmp .cpa_blit_done
; local: copy rows per the active rect at [rbp+96..116] (sx',sy',dx',dy',w',h')
.cpa_copy:
    xor r12d, r12d
.cpa_crow:
    cmp r12d, [rbp + 116]
    jge .cpa_cdone
    mov eax, [rbp + 100]                      ; sy'
    add eax, r12d
    imul eax, [rbp + 16]                      ; src_stride
    add eax, [rbp + 96]                       ; sx'
    mov rsi, [rbp + 0]
    lea rsi, [rsi + rax*4]
    mov eax, [rbp + 108]                      ; dy'
    add eax, r12d
    imul eax, [rbp + 24]                      ; dst_stride
    add eax, [rbp + 104]                      ; dx'
    mov rdi, [rbp + 8]
    lea rdi, [rdi + rax*4]
    mov ecx, [rbp + 112]                      ; w'
    rep movsd
    inc r12d
    jmp .cpa_crow
.cpa_cdone:
    ret
.cpa_blit_done:
    ; If dst is a window, recomposite.
    mov edi, [rbx + 8]
    call window_lookup
    test rax, rax
    jz .cpa_done
    mov byte [comp_dirty], 1
    mov rdi, rax                              ; damage the clipped dst rect
    mov eax, [rbp + 64]
    mov edx, [rbp + 72]
    mov ecx, [rbp + 80]                       ; copy_w
    mov r8d, [rbp + 88]                       ; copy_h
    call damage_add_local
.cpa_done:
    add rsp, 160
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; ----------------------------------------------------------------------------
; rect_outline — draw a 1px rectangle outline via 4 fb_fill calls.
;   rdi = buf, esi = stride, edx = bufh, r8d = x, r9d = y, r10d = w,
;   r11d = h, ecx = colour.
; All inputs latched into a stack frame; fb_fill is called four times.
; ----------------------------------------------------------------------------
rect_outline:
    push rbx
    push rbp
    sub rsp, 64
    mov [rsp + 0], rdi                       ; buf
    mov [rsp + 8], esi                       ; stride
    mov [rsp + 12], edx                      ; bufh
    mov [rsp + 16], r8d                      ; x
    mov [rsp + 20], r9d                      ; y
    mov [rsp + 24], r10d                     ; w
    mov [rsp + 28], r11d                     ; h
    mov [rsp + 32], ecx                      ; colour

    ; top edge: (x, y, w, 1)
    mov rdi, [rsp + 0]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov eax, [rsp + 16]
    mov r8d, [rsp + 20]
    mov r9d, [rsp + 24]
    mov r10d, 1
    mov r11d, [rsp + 32]
    call fb_fill
    ; bottom edge: (x, y+h-1, w, 1)
    mov rdi, [rsp + 0]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov eax, [rsp + 16]
    mov r8d, [rsp + 20]
    add r8d, [rsp + 28]
    dec r8d
    mov r9d, [rsp + 24]
    mov r10d, 1
    mov r11d, [rsp + 32]
    call fb_fill
    ; left edge: (x, y, 1, h)
    mov rdi, [rsp + 0]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov eax, [rsp + 16]
    mov r8d, [rsp + 20]
    mov r9d, 1
    mov r10d, [rsp + 28]
    mov r11d, [rsp + 32]
    call fb_fill
    ; right edge: (x+w-1, y, 1, h)
    mov rdi, [rsp + 0]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov eax, [rsp + 16]
    add eax, [rsp + 24]
    dec eax
    mov r8d, [rsp + 20]
    mov r9d, 1
    mov r10d, [rsp + 28]
    mov r11d, [rsp + 32]
    call fb_fill

    add rsp, 64
    pop rbp
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_poly_rectangle — edi = slot (unused), rsi = req ptr, edx = bytes.
;   +4 drawable  +8 gc  +12 rectangles[] (x s16, y s16, w u16, h u16)
; Draws each rect's outline into the drawable's backing with the GC
; foreground. No reply.
;
;   rbx = req ptr   r12 = rect cursor   r13 = backing ptr
;   r14d = stride   r15d = bufh   rbp = (low) colour ; rect count on stack
; ----------------------------------------------------------------------------
handle_poly_rectangle:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 16
    mov rbx, rsi                             ; req ptr
    mov [rsp + 0], edx                        ; req bytes

    mov edi, [rbx + 4]
    call drawable_get_backing
    test rax, rax
    jz .prr_done
    mov r13, rax                             ; backing
    mov r14d, edx                            ; stride
    mov r15d, ecx                            ; bufh

    mov edi, [rbx + 8]
    call gc_lookup
    test rax, rax
    jz .prr_done
    mov ebp, [rax + 4]                        ; fg colour

    ; rect count = (bytes - 12) / 8
    mov eax, [rsp + 0]
    sub eax, 12
    jle .prr_done
    shr eax, 3
    mov [rsp + 4], eax                        ; remaining rects
    lea r12, [rbx + 12]
.prr_loop:
    cmp dword [rsp + 4], 0
    jle .prr_recomp
    mov rdi, r13
    mov esi, r14d
    mov edx, r15d
    movsx r8d, word [r12 + 0]                ; x
    movsx r9d, word [r12 + 2]                ; y
    movzx r10d, word [r12 + 4]               ; w
    movzx r11d, word [r12 + 6]               ; h
    mov ecx, ebp                             ; colour
    call rect_outline
    add r12, 8
    dec dword [rsp + 4]
    jmp .prr_loop
.prr_recomp:
    ; only windows recomposite (pixmap outlines repainted the screen for
    ; nothing before — pre-existing waste bug), and damage the rect bbox
    mov edi, [rbx + 4]
    call window_lookup
    test rax, rax
    jz .prr_done
    mov byte [comp_dirty], 1
    mov rdx, rax
    lea rdi, [rbx + 12]
    mov esi, [rsp + 0]
    sub esi, 12
    shr esi, 3
    call damage_rect_list
.prr_done:
    add rsp, 16
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 4i — SendEvent (synthetic event delivery).
; ============================================================================
; The ICCCM handshake real toolkits depend on: a WM (tile) sends a
; synthetic ConfigureNotify to a client window after tiling it, so the
; client learns its final geometry. Without this, GTK/Qt/Firefox render
; at the wrong size or never settle. Also used for WM_PROTOCOLS messages
; (WM_DELETE_WINDOW), _NET_WM_STATE changes, etc.
;
; We route the event to the client that OWNS the destination window. No
; per-window owner field is needed: the per-client rid_base means a
; window XID encodes its creator's slot directly —
;   slot = (xid - X_RID_BASE) >> 21
; (X_RID_BASE = 0x400000, each client's range is 0x200000 = 1<<21 wide).
; ============================================================================

; ----------------------------------------------------------------------------
; handle_send_event — rsi = req ptr.
;   +1 propagate (BOOL)   +4 destination (WINDOW)
;   +8 event-mask (CARD32)   +12 event (32 bytes)
;
; Delivers the 32-byte event to the destination window's owning client,
; with the synthetic bit (0x80) set in the event code (per spec). For a
; destination of root, routes to root's redirect owner (the WM) if set.
; No reply.
; ----------------------------------------------------------------------------
handle_send_event:
    push rbx
    push r12
    push r13
    mov rbx, rsi                             ; req ptr
    mov r12d, [rbx + 4]                       ; destination window

    ; Resolve the recipient client slot.
    cmp r12d, X_RID_BASE
    jb .se_maybe_root                        ; below client XID range
    mov eax, r12d
    sub eax, X_RID_BASE
    shr eax, 21                               ; slot = (xid - base) >> 21
    cmp eax, MAX_CLIENTS
    jae .se_done
    mov r13d, eax
    jmp .se_have_slot

.se_maybe_root:
    ; Destination is root (or pointer/focus, which we don't track).
    cmp r12d, X_ROOT_WINDOW
    jne .se_done
    ; Root events with a nonzero event-mask BROADCAST to every live client:
    ; the tray MANAGER announcement (strip) targets root with
    ; StructureNotify so XEmbed clients that started BEFORE the manager
    ; hear it. Mask 0 keeps the old redirect-owner-only route (MapRequest
    ; style WM traffic).
    cmp dword [rbx + 8], 0                   ; event-mask
    jne .se_root_broadcast
    mov edi, X_ROOT_WINDOW
    call window_lookup
    test rax, rax
    jz .se_done
    movsx eax, byte [rax + 30]                ; root.redirect_owner
    cmp eax, 0
    jl .se_done
    mov r13d, eax
    jmp .se_have_slot

.se_root_broadcast:
    lea rdi, [reply_buf]                     ; build the event once
    lea rsi, [rbx + 12]
    mov ecx, 4
.se_bc_copy:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .se_bc_copy
    or byte [reply_buf], 0x80
    xor r12d, r12d                           ; slot cursor
.se_bc_loop:
    cmp r12d, MAX_CLIENTS
    jge .se_done
    mov eax, r12d
    call client_meta_addr
    mov r13, rax
    cmp dword [r13], -1                      ; live fd?
    je .se_bc_next
    cmp byte [r13 + 4], CSTATE_RUNNING       ; never write events into a
    jne .se_bc_next                          ; handshake still in progress
    mov ecx, [r13 + 8]                       ; per-recipient seq stamp
    mov [reply_buf + 2], cx
    mov edi, [r13]
    lea rsi, [reply_buf]
    mov rdx, 32
    EV_SEND
.se_bc_next:
    inc r12d
    jmp .se_bc_loop

.se_have_slot:
    ; Validate the client slot is live (fd != -1).
    mov eax, r13d
    call client_meta_addr
    mov r13, rax                             ; meta ptr
    mov eax, [r13]                            ; fd
    cmp eax, -1
    je .se_done

    ; Build the outgoing 32-byte event in reply_buf: copy from req+12,
    ; set the synthetic bit (0x80) in the code byte.
    lea rdi, [reply_buf]
    lea rsi, [rbx + 12]
    mov ecx, 4
.se_copy:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .se_copy
    or byte [reply_buf], 0x80                 ; mark as SendEvent-synthetic
    ; Stamp the recipient's current sequence number into bytes 2-3.
    ; libxcb tracks sequences and aborts ("unknown sequence number") if a
    ; delivered event carries a stale/zero seq.
    mov ecx, [r13 + 8]                         ; recipient client's seq
    mov [reply_buf + 2], cx

    ; Write the event to the recipient's fd.
    mov edi, [r13]                            ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall
.se_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; ============================================================================
; PHASE 9 (start) — RENDER extension.
; ============================================================================
; The extension modern toolkits + glass use for anti-aliased glyphs and
; ARGB compositing. This is the foundation: extension negotiation
; (QueryExtension reports RENDER present, in handle_query_extension) and
; the RENDER request dispatcher with QueryVersion. PictFormats, Pictures,
; glyph sets, and Composite come next.
;
; A RENDER request arrives as a normal X request whose opcode byte is
; RENDER_MAJOR; byte 1 is the RENDER minor opcode.
; ============================================================================

; ----------------------------------------------------------------------------
; handle_render — edi = slot, rsi = req ptr, edx = req bytes.
; Dispatches on the minor opcode (req byte 1).
;   0 = QueryVersion
; Unknown minors are accepted silently (no reply) for now.
; ----------------------------------------------------------------------------
handle_render:
    push rbx
    push r12
    mov ebx, edi                             ; slot
    mov r12, rsi                             ; req ptr
    movzx eax, byte [r12 + 1]                ; minor opcode
    cmp eax, 0
    je .hr_query_version
    cmp eax, 1
    je .hr_query_pict_formats
    cmp eax, 4
    je .hr_create_picture
    cmp eax, 7
    je .hr_free_picture
    cmp eax, 26
    je .hr_fill_rectangles
    cmp eax, 8
    je .hr_composite
    cmp eax, 17
    je .hr_create_glyphset
    cmp eax, 19
    je .hr_free_glyphset
    cmp eax, 20
    je .hr_add_glyphs
    cmp eax, 33
    je .hr_create_solid_fill
    cmp eax, 23
    je .hr_composite_glyphs
    cmp eax, 24
    je .hr_composite_glyphs
    cmp eax, 25
    je .hr_composite_glyphs
    cmp eax, 10
    je .hr_trapezoids
    cmp eax, 5
    je .hr_change_picture
    cmp eax, 6
    je .hr_set_pic_clip
    cmp eax, 28
    je .hr_set_pic_transform
    ; Unhandled minor — leave it (logged by the generic request logger).
    jmp .hr_done

.hr_set_pic_transform:
    mov rdi, r12
    call render_set_pic_transform
    jmp .hr_done

.hr_trapezoids:
    mov rdi, r12
    call render_trapezoids
    jmp .hr_done

.hr_change_picture:
    mov rdi, r12
    call render_change_picture
    jmp .hr_done

.hr_set_pic_clip:
    mov rdi, r12
    call render_set_pic_clip
    jmp .hr_done

.hr_create_picture:
    mov rdi, r12
    call render_create_picture
    jmp .hr_done

.hr_free_picture:
    mov rdi, r12
    call render_free_picture
    jmp .hr_done

.hr_fill_rectangles:
    mov rdi, r12
    call render_fill_rectangles
    jmp .hr_done

.hr_composite:
    mov rdi, r12
    call render_composite
    jmp .hr_done

.hr_create_glyphset:
    mov rdi, r12
    call render_create_glyphset
    jmp .hr_done

.hr_free_glyphset:
    mov rdi, r12
    call render_free_glyphset
    jmp .hr_done

.hr_add_glyphs:
    mov rdi, r12
    call render_add_glyphs
    jmp .hr_done

.hr_create_solid_fill:
    mov rdi, r12
    call render_create_solid_fill
    jmp .hr_done

.hr_composite_glyphs:
    mov rdi, r12
    call render_composite_glyphs
    jmp .hr_done

.hr_query_version:
    ; Reply: server's supported RENDER version.
    ;   +0 reply(1) +2 seq +4 len(0) +8 major +12 minor +16..31 pad
    mov eax, ebx
    call client_meta_addr                    ; rax = meta
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1                    ; reply
    mov byte [rdi + 1], 0
    mov ecx, [rax + 8]                       ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0                   ; length
    mov dword [rdi + 8], RENDER_VERSION_MAJOR
    mov dword [rdi + 12], RENDER_VERSION_MINOR
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, [rax]                           ; fd
    push rax
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall
    pop rax
    jmp .hr_done

; --- QueryPictFormats: report the 5 standard formats (ARGB32, RGB24, A8,
;     A4, A1) and one screen mapping our depth-24 + depth-32 visuals to
;     formats. libXrender BLOCKS on this during setup, so it must reply.
;     ALL FIVE standard formats are required: cairo trusts the advertised
;     RENDER version and feeds XRenderFindStandardFormat() results into
;     XRenderCreatePicture with no null check — a missing A1 crashed
;     firefox (GDK's blank cursor paints a 1x1 depth-1 bitmap via cairo).
;     216-byte reply (32 fixed + 184 variable).
.hr_query_pict_formats:
    mov eax, ebx
    call client_meta_addr
    mov r12, rax                             ; meta (req ptr no longer needed)
    ; Zero the 216-byte reply region.
    lea rdi, [reply_buf]
    xor eax, eax
    mov ecx, 27
    rep stosq
    ; --- fixed reply header ---
    mov byte  [reply_buf + 0], 1             ; reply
    mov ecx, [r12 + 8]                       ; seq
    mov [reply_buf + 2], cx
    mov dword [reply_buf + 4], 46            ; reply length (variable 4-byte units)
    mov dword [reply_buf + 8], 5             ; numFormats
    mov dword [reply_buf + 12], 1            ; numScreens
    mov dword [reply_buf + 16], 2            ; numDepths
    mov dword [reply_buf + 20], 2            ; numVisuals
    mov dword [reply_buf + 24], 1            ; numSubpixels
    ; --- PICTFORMINFO ARGB32 @ 32 (id 0x30, depth 32) ---
    mov dword [reply_buf + 32], 0x30
    mov byte  [reply_buf + 36], 1            ; type = Direct
    mov byte  [reply_buf + 37], 32           ; depth
    mov word  [reply_buf + 40], 16           ; red shift
    mov word  [reply_buf + 42], 0xff         ; red mask
    mov word  [reply_buf + 44], 8            ; green shift
    mov word  [reply_buf + 46], 0xff
    mov word  [reply_buf + 48], 0            ; blue shift
    mov word  [reply_buf + 50], 0xff
    mov word  [reply_buf + 52], 24           ; alpha shift
    mov word  [reply_buf + 54], 0xff
    ; --- PICTFORMINFO RGB24 @ 60 (id 0x31, depth 24, no alpha) ---
    mov dword [reply_buf + 60], 0x31
    mov byte  [reply_buf + 64], 1
    mov byte  [reply_buf + 65], 24
    mov word  [reply_buf + 68], 16           ; red
    mov word  [reply_buf + 70], 0xff
    mov word  [reply_buf + 72], 8            ; green
    mov word  [reply_buf + 74], 0xff
    mov word  [reply_buf + 76], 0            ; blue
    mov word  [reply_buf + 78], 0xff
    ; alpha shift/mask @ 80/82 stay 0
    ; --- PICTFORMINFO A8 @ 88 (id 0x32, depth 8, alpha only) ---
    mov dword [reply_buf + 88], 0x32
    mov byte  [reply_buf + 92], 1
    mov byte  [reply_buf + 93], 8
    ; rgb shifts/masks @ 96..107 stay 0
    mov word  [reply_buf + 108], 0           ; alpha shift
    mov word  [reply_buf + 110], 0xff        ; alpha mask
    ; --- PICTFORMINFO A4 @ 116 (id 0x33, depth 4, alpha only) ---
    mov dword [reply_buf + 116], 0x33
    mov byte  [reply_buf + 120], 1
    mov byte  [reply_buf + 121], 4
    ; rgb shifts/masks @ 124..135 stay 0; alpha shift @ 136 stays 0
    mov word  [reply_buf + 138], 0x0f        ; alpha mask
    ; --- PICTFORMINFO A1 @ 144 (id 0x34, depth 1, alpha only) ---
    mov dword [reply_buf + 144], 0x34
    mov byte  [reply_buf + 148], 1
    mov byte  [reply_buf + 149], 1
    ; rgb shifts/masks @ 152..163 stay 0; alpha shift @ 164 stays 0
    mov word  [reply_buf + 166], 0x01        ; alpha mask
    ; --- PICTSCREEN 0 @ 172 ---
    mov dword [reply_buf + 172], 2           ; numDepths
    mov dword [reply_buf + 176], 0x31        ; fallback format (RGB24)
    ; PICTDEPTH depth 24 @ 180
    mov byte  [reply_buf + 180], 24          ; depth
    mov word  [reply_buf + 182], 1           ; numVisuals
    mov dword [reply_buf + 188], 0x20        ; visual id (depth-24)
    mov dword [reply_buf + 192], 0x31        ; → RGB24
    ; PICTDEPTH depth 32 @ 196
    mov byte  [reply_buf + 196], 32
    mov word  [reply_buf + 198], 1
    mov dword [reply_buf + 204], 0x21        ; visual id (depth-32)
    mov dword [reply_buf + 208], 0x30        ; → ARGB32
    ; --- subpixel order @ 212 (SubPixelUnknown = 0) stays 0 ---
    mov edi, [r12]                           ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 216
    syscall
.hr_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; init_pictures — zero the Picture table.
; ----------------------------------------------------------------------------
init_pictures:
    push rbx
    lea rdi, [pictures]
    xor eax, eax
    mov ecx, MAX_PICTURES * PICTURE_REC_SIZE
    rep stosb
    pop rbx
    ret

; ----------------------------------------------------------------------------
; picture_lookup — edi = pid. Returns record ptr in rax, or 0.
; ----------------------------------------------------------------------------
picture_lookup:
    push rbx
    xor ebx, ebx
.pl_loop:
    cmp ebx, MAX_PICTURES
    jge .pl_miss
    mov rax, rbx
    imul rax, PICTURE_REC_SIZE
    lea rax, [pictures + rax]
    cmp [rax], edi
    je .pl_hit
    inc ebx
    jmp .pl_loop
.pl_hit:
    pop rbx
    ret
.pl_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_create_picture — rdi = req ptr.
;   +4 pid   +8 drawable   +12 format   +16 value-mask   +20 value-list
; Records pid → (drawable, format). value-list ignored for now. No reply.
; ----------------------------------------------------------------------------
render_create_picture:
    push rbx
    push r12
    mov r12, rdi
    mov edi, [r12 + 4]                        ; pid
    test edi, edi
    jz .rcp_done
    ; Find an empty slot (or reuse same pid).
    call picture_lookup
    test rax, rax
    jnz .rcp_fill
    xor ebx, ebx
.rcp_find:
    cmp ebx, MAX_PICTURES
    jl .rcp_scan
    lea rsi, [dbg_picfull]                   ; DIAG: table full, create dropped
    mov edx, 8
    call write_stderr
    jmp .rcp_done
.rcp_scan:
    mov rax, rbx
    imul rax, PICTURE_REC_SIZE
    lea rax, [pictures + rax]
    cmp dword [rax], 0
    je .rcp_fill
    inc ebx
    jmp .rcp_find
.rcp_fill:
    mov ecx, [r12 + 4]
    mov [rax + 0], ecx                        ; pid
    mov ecx, [r12 + 8]
    mov [rax + 4], ecx                        ; drawable
    mov ecx, [r12 + 12]
    mov [rax + 8], ecx                        ; format
    push rax
    call pic_clip_entry                       ; fresh picture → no clip
    mov dword [rax], 0
    pop rax
    call pic_xform_entry                      ; fresh picture → identity
    mov dword [rax], 0
.rcp_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_free_picture — rdi = req ptr (+4 picture). Clears the slot.
; ----------------------------------------------------------------------------
render_free_picture:
    push rbx
    mov edi, [rdi + 4]
    call picture_lookup
    test rax, rax
    jz .rfp_done
    mov dword [rax], 0
.rfp_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; pic_clip_entry — rax = picture record ptr → rax = its clip entry ptr.
; ----------------------------------------------------------------------------
pic_clip_entry:
    lea rcx, [pictures]
    sub rax, rcx
    shr rax, 4                                ; slot (rec size 16)
    imul rax, CLIP_ENTRY_SIZE
    lea rcx, [pic_clips]
    add rax, rcx
    ret

; ----------------------------------------------------------------------------
; pic_xform_entry — rax = picture record ptr → rax = its transform entry.
; ----------------------------------------------------------------------------
pic_xform_entry:
    lea rcx, [pictures]
    sub rax, rcx
    shr rax, 4
    imul rax, 28
    lea rcx, [pic_xforms]
    add rax, rcx
    ret

; ----------------------------------------------------------------------------
; render_set_pic_transform — rdi = req ptr (RENDER minor 28).
;   +4 picture, +8 nine FIXED values row-major (m11 m12 m13 / m21 m22 m23 /
;   m31 m32 m33). Stores the affine part; flag 0 when identity so the
;   composite fast path stays untouched. Projective row ignored.
; ----------------------------------------------------------------------------
render_set_pic_transform:
    push rbx
    push r12
    mov rbx, rdi
    mov edi, [rbx + 4]
    call picture_lookup
    test rax, rax
    jz .spt_done
    call pic_xform_entry
    mov r12, rax                              ; entry
    mov eax, [rbx + 8]                        ; m11
    mov [r12 + 4], eax
    mov ecx, [rbx + 12]                       ; m12
    mov [r12 + 8], ecx
    mov edx, [rbx + 16]                       ; m13
    mov [r12 + 12], edx
    ; identity check while loading the second row
    xor edi, edi                              ; nonzero-diff accumulator
    sub eax, 0x10000                          ; m11 - 1.0
    or edi, eax
    or edi, ecx                               ; m12
    or edi, edx                               ; m13
    mov eax, [rbx + 20]                       ; m21
    mov [r12 + 16], eax
    or edi, eax
    mov eax, [rbx + 24]                       ; m22
    mov [r12 + 20], eax
    sub eax, 0x10000
    or edi, eax
    mov eax, [rbx + 28]                       ; m23
    mov [r12 + 24], eax
    or edi, eax
    xor eax, eax
    test edi, edi
    setnz al
    mov [r12], eax                            ; flag: 1 iff non-identity
.spt_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_set_pic_clip — rdi = req ptr (RENDER minor 6).
;   +4 picture  +8 clip-x-origin s16  +10 clip-y-origin  +12 rect list.
; Same storage semantics as core SetClipRectangles. No reply.
; ----------------------------------------------------------------------------
render_set_pic_clip:
    push rbx
    mov rbx, rdi
    mov edi, [rbx + 4]
    call picture_lookup
    test rax, rax
    jz .rsc_done
    call pic_clip_entry
    mov rdi, rax                              ; clip entry
    lea rsi, [rbx + 8]                        ; origins + rects
    movzx edx, word [rbx + 2]
    shl edx, 2
    sub edx, 12
    js .rsc_done
    shr edx, 3                                ; rect count
    call clip_store
.rsc_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_change_picture — rdi = req ptr (RENDER minor 5).
;   +4 picture  +8 value-mask  +12 value list (CARD32 per set bit).
; Only CPClipMask (bit 6) matters here: None clears the picture's clip
; (pixmap masks unsupported → also clear). Other attributes stay ignored,
; but the value cursor is advanced per set bit so parsing stays aligned.
; ----------------------------------------------------------------------------
render_change_picture:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov edi, [rbx + 4]
    call picture_lookup
    test rax, rax
    jz .rcp2_done
    mov r13, rax                              ; picture rec
    mov r12d, [rbx + 8]                       ; value-mask
    lea r14, [rbx + 12]                       ; value cursor
    xor ecx, ecx                              ; bit index
.rcp2_loop:
    test r12d, r12d
    jz .rcp2_done
    bt r12d, 0
    jnc .rcp2_skip
    cmp ecx, 6                                ; CPClipMask
    jne .rcp2_adv
    push rcx
    mov rax, r13
    call pic_clip_entry
    mov dword [rax], 0                        ; clear clip
    pop rcx
.rcp2_adv:
    add r14, 4
.rcp2_skip:
    shr r12d, 1
    inc ecx
    jmp .rcp2_loop
.rcp2_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_fill_rectangles — rdi = req ptr.
;   +4 op   +8 dst(PICTURE)   +12 RENDERCOLOR(red,green,blue,alpha u16 each)
;   +20 rects (x s16, y s16, w u16, h u16)
; Fills each rect into the dst Picture's drawable backing with the colour.
; PictOp is treated as Src (overwrite) for now. No reply.
;
;   rbx = req ptr   r12 = backing ptr   r13d = stride   r14d = bufh
;   r15d = ARGB pixel   rbp = rect cursor   [rsp]=remaining rects
; ----------------------------------------------------------------------------
render_fill_rectangles:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 16
    mov rbx, rdi                              ; req ptr

    ; Resolve dst Picture → drawable → backing.
    mov qword [cur_clip], 0
    mov edi, [rbx + 8]                        ; dst picture
    call picture_lookup
    test rax, rax
    jz .rfr_done
    push rax
    call pic_clip_entry                       ; honour the dst picture clip
    mov [cur_clip], rax
    pop rax
    mov edi, [rax + 4]                        ; drawable
    mov [rsp + 8], edi                        ; stash drawable for recomposite test
    call drawable_get_backing
    test rax, rax
    jz .rfr_done
    mov r12, rax                              ; backing ptr
    mov r13d, edx                             ; stride (width)
    mov r14d, ecx                             ; bufh

    ; Convert RENDERCOLOR (16-bit channels) → 8-bit ARGB.
    movzx eax, byte [rbx + 13]                ; red   high byte (red @12, hi @13)
    shl eax, 16
    mov r15d, eax
    movzx eax, byte [rbx + 15]                ; green high byte
    shl eax, 8
    or r15d, eax
    movzx eax, byte [rbx + 17]                ; blue  high byte
    or r15d, eax
    movzx eax, byte [rbx + 19]                ; alpha high byte
    shl eax, 24
    or r15d, eax

    ; rect count = (length*4 - 20) / 8
    movzx eax, word [rbx + 2]                 ; request length (4-byte units)
    shl eax, 2                                 ; bytes
    sub eax, 20
    jle .rfr_done
    shr eax, 3
    mov [rsp + 0], eax                         ; remaining rects
    lea rbp, [rbx + 20]                        ; rect cursor
.rfr_loop:
    cmp dword [rsp + 0], 0
    jle .rfr_recomp
    mov rdi, r12
    mov esi, r13d
    mov edx, r14d
    movsx eax, word [rbp + 0]                  ; x
    movsx r8d, word [rbp + 2]                  ; y
    movzx r9d, word [rbp + 4]                  ; w
    movzx r10d, word [rbp + 6]                 ; h
    mov r11d, r15d                             ; colour
    call clipped_fb_fill
    add rbp, 8
    dec dword [rsp + 0]
    jmp .rfr_loop
.rfr_recomp:
    mov qword [cur_clip], 0
    ; If the dst drawable is a window, recomposite to show it.
    mov edi, [rsp + 8]
    call window_lookup
    test rax, rax
    jz .rfr_done
    mov byte [comp_dirty], 1
    mov rdx, rax                              ; damage bbox of the rect list
    lea rdi, [rbx + 20]
    movzx esi, word [rbx + 2]
    shl esi, 2
    sub esi, 20
    shr esi, 3
    call damage_rect_list
.rfr_done:
    mov qword [cur_clip], 0
    add rsp, 16
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_trapezoids — rdi = req ptr (RENDER minor 10, CompositeTrapezoids).
;   +4 op   +8 src(PICTURE)   +12 dst(PICTURE)   +16 maskFormat
;   +20 xSrc s16  +22 ySrc s16  +24 trapezoid list (40 bytes each):
;     +0 top FIXED(16.16)   +4 bottom FIXED
;     +8 left LINEFIX (p1.x, p1.y, p2.x, p2.y — 4×FIXED)   +24 right LINEFIX
; cairo-xlib paints GTK widget backgrounds (menu bodies, hover highlights,
; rounded rects) with this request. Dropping it left the backing transparent
; black behind the glyph text — the "GIMP menus render black" bug.
; Simplification: opaque pixel-centre scanline fill, no edge anti-aliasing;
; op and maskFormat ignored. Menus use a solid opaque source, where this is
; exact except at 1-px rounded corners. No reply.
;
;   rbx = req ptr   rbp = trapezoid cursor   r12d = remaining traps
;   r13d = y (row)  r14d = y_end (excl)      r15d = x_start (pixel)
; ----------------------------------------------------------------------------
render_trapezoids:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi

    ; --- resolve dst Picture → drawable → backing (allocates if needed) ---
    mov edi, [rbx + 12]
    call picture_lookup
    test rax, rax
    jz .tz_done
    mov edi, [rax + 4]
    mov [tz_dst_drawable], edi
    call drawable_get_backing
    test rax, rax
    jz .tz_done
    mov [tz_dst_ptr], rax
    mov [tz_dst_stride], edx
    mov [tz_dst_h], ecx

    ; --- resolve src colour: solid fill, or sample the src image top-left
    ;     (cairo's non-solid src here is a 1×1 repeat pattern) ---
    mov edi, [rbx + 8]
    call picture_lookup
    test rax, rax
    jz .tz_done
    cmp dword [rax + 4], PICTURE_SOLID
    jne .tz_src_image
    mov ecx, [rax + 8]                        ; stored 8-bit ARGB
    jmp .tz_have_color
.tz_src_image:
    mov edi, [rax + 4]
    call drawable_get_backing
    test rax, rax
    jz .tz_done
    mov ecx, [rax]
.tz_have_color:
    ; op Src (1) replaces → force opaque (mirrors render_composite). Any other
    ; op blends Over by the source alpha: keep it; fully transparent = no-op.
    cmp byte [rbx + 4], 1
    jne .tz_op_over
    or ecx, 0xFF000000
    jmp .tz_color_ready
.tz_op_over:
    test ecx, 0xFF000000
    jz .tz_done                               ; alpha 0 → nothing to draw
.tz_color_ready:
    mov [tz_color], ecx

    ; --- trapezoid count = (length*4 - 24) / 40 ---
    movzx eax, word [rbx + 2]
    shl eax, 2
    sub eax, 24
    jle .tz_done
    xor edx, edx
    mov ecx, 40
    div ecx
    test eax, eax
    jz .tz_done
    mov r12d, eax
    lea rbp, [rbx + 24]

.tz_trap:
    ; y_start = (top + 0x7FFF) >> 16, clamped ≥ 0 (pixel-centre in/out rule)
    mov eax, [rbp + 0]
    add eax, 0x7FFF
    sar eax, 16
    test eax, eax
    jns .tz_ys_ok
    xor eax, eax
.tz_ys_ok:
    mov r13d, eax
    ; y_end (exclusive) = (bottom + 0x7FFF) >> 16, clamped ≤ dst_h
    mov eax, [rbp + 4]
    add eax, 0x7FFF
    sar eax, 16
    cmp eax, [tz_dst_h]
    jle .tz_ye_ok
    mov eax, [tz_dst_h]
.tz_ye_ok:
    mov r14d, eax

.tz_row:
    cmp r13d, r14d
    jge .tz_next_trap
    mov r11d, r13d
    shl r11d, 16
    add r11d, 0x8000                          ; yc = row centre in 16.16
    lea rsi, [rbp + 8]                        ; left edge line
    call .tz_line_x
    add eax, 0x7FFF
    sar eax, 16
    test eax, eax
    jns .tz_xl_ok
    xor eax, eax
.tz_xl_ok:
    mov r15d, eax                             ; x_start (clamped ≥ 0)
    lea rsi, [rbp + 24]                       ; right edge line (r11 preserved)
    call .tz_line_x
    add eax, 0x7FFF
    sar eax, 16
    cmp eax, [tz_dst_stride]
    jle .tz_xr_ok
    mov eax, [tz_dst_stride]
.tz_xr_ok:
    sub eax, r15d                             ; span width
    jle .tz_row_next
    mov ecx, eax                              ; pixel count
    mov eax, r13d
    imul eax, [tz_dst_stride]
    add eax, r15d
    mov rdi, [tz_dst_ptr]
    lea rdi, [rdi + rax*4]
    mov eax, [tz_color]
    cmp eax, 0xFF000000                       ; alpha 255? (unsigned: opaque ≥)
    jb .tz_span_blend
    rep stosd                                 ; opaque fast path
    jmp .tz_row_next
.tz_span_blend:
    ; translucent Over: out = (src*a + dst*(255-a)) / 255, per channel,
    ; /255 via (v*257+257)>>16 — same formula as render_composite .rc_blend.
    mov esi, eax                              ; src ARGB (constant for the span)
    mov r8d, eax
    shr r8d, 24                               ; a (1..254)
    mov r9d, 255
    sub r9d, r8d                              ; 255 - a
.tz_blend_px:
    mov edx, [rdi]                            ; dst pixel
    ; blue
    mov eax, esi
    and eax, 0xFF
    imul eax, r8d
    mov r10d, edx
    and r10d, 0xFF
    imul r10d, r9d
    add eax, r10d
    imul eax, 257
    add eax, 257
    shr eax, 16
    mov r11d, eax
    ; green
    mov eax, esi
    shr eax, 8
    and eax, 0xFF
    imul eax, r8d
    mov r10d, edx
    shr r10d, 8
    and r10d, 0xFF
    imul r10d, r9d
    add eax, r10d
    imul eax, 257
    add eax, 257
    shr eax, 16
    shl eax, 8
    or r11d, eax
    ; red
    mov eax, esi
    shr eax, 16
    and eax, 0xFF
    imul eax, r8d
    mov r10d, edx
    shr r10d, 16
    and r10d, 0xFF
    imul r10d, r9d
    add eax, r10d
    imul eax, 257
    add eax, 257
    shr eax, 16
    shl eax, 16
    or r11d, eax
    or r11d, 0xFF000000
    mov [rdi], r11d
    add rdi, 4
    dec ecx
    jnz .tz_blend_px
.tz_row_next:
    inc r13d
    jmp .tz_row

.tz_next_trap:
    add rbp, 40
    dec r12d
    jnz .tz_trap

    ; recomposite if the dst drawable is a window
    mov edi, [tz_dst_drawable]
    call window_lookup
    test rax, rax
    jz .tz_done
    mov byte [comp_dirty], 1
    ; damage: bbox over the trapezoid list (fixed-point → pixel, outward)
    mov r11, rax                              ; window rec
    movzx esi, word [rbx + 2]
    shl esi, 2
    sub esi, 24
    jle .tz_done
    xor edx, edx
    mov eax, esi
    mov esi, 40
    div esi
    mov esi, eax                              ; trap count
    test esi, esi
    jz .tz_done
    lea rdi, [rbx + 24]
    mov ecx, 0x7FFFFFFF                       ; x1
    mov r8d, 0x7FFFFFFF                       ; y1
    mov r9d, 0x80000000                       ; x2
    mov r10d, 0x80000000                      ; y2
.tz_dmg_loop:
    mov eax, [rdi + 0]                        ; top
    sar eax, 16
    cmp eax, r8d
    jge .tzd_1
    mov r8d, eax
.tzd_1:
    mov eax, [rdi + 4]                        ; bottom
    sar eax, 16
    inc eax
    cmp eax, r10d
    jle .tzd_2
    mov r10d, eax
.tzd_2:
    mov eax, [rdi + 8]                        ; left.p1x
    cmp eax, [rdi + 16]                       ; left.p2x
    jle .tzd_3
    mov eax, [rdi + 16]
.tzd_3:
    sar eax, 16
    cmp eax, ecx
    jge .tzd_4
    mov ecx, eax
.tzd_4:
    mov eax, [rdi + 24]                       ; right.p1x
    cmp eax, [rdi + 32]                       ; right.p2x
    jge .tzd_5
    mov eax, [rdi + 32]
.tzd_5:
    sar eax, 16
    inc eax
    cmp eax, r9d
    jle .tzd_6
    mov r9d, eax
.tzd_6:
    add rdi, 40
    dec esi
    jnz .tz_dmg_loop
    sub r9d, ecx                              ; w
    jle .tz_done
    sub r10d, r8d                             ; h
    jle .tz_done
    mov eax, ecx                              ; local x
    mov edx, r8d                              ; local y
    mov ecx, r9d                              ; w
    mov r8d, r10d                             ; h
    mov rdi, r11                              ; window rec
    call damage_add_local
.tz_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; .tz_line_x — rsi = LINEFIX ptr (p1x,p1y,p2x,p2y FIXED), r11d = y (FIXED).
; Returns eax = the line's x at that y (FIXED), 64-bit linear interpolation:
; x = p1x + (p2x-p1x)*(y-p1y)/(p2y-p1y). Horizontal degenerate → p1x.
; Deltas are saturated to ±(2^31-1) before the multiply (product then provably
; fits signed 64-bit) and the result to ±0x7FFF0000, so the caller's 32-bit
; consumption plus its +0x7FFF rounding can never wrap a huge off-screen x
; into an in-range span. Extreme (>32k px) inputs degrade to a clamped
; approximation; cairo never emits them.
; Clobbers rax, rcx, rdx, r8, r9, r10; preserves r11 and callee-saved regs.
.tz_line_x:
    movsxd r8, dword [rsi + 4]                ; p1y
    movsxd r9, dword [rsi + 12]               ; p2y
    sub r9, r8                                ; dy (flags for jz below)
    movsxd rcx, dword [rsi + 0]               ; p1x (movsxd leaves flags alone)
    jz .tz_lx_flat
    movsxd rax, dword [rsi + 8]               ; p2x
    sub rax, rcx                              ; dx (fits 33 bits)
    movsxd r10, r11d                          ; y
    sub r10, r8                               ; y - p1y (fits 33 bits)
    mov rdx, 0x7FFFFFFF                       ; saturate dx
    cmp rax, rdx
    jle .tz_lx_dx1
    mov rax, rdx
.tz_lx_dx1:
    neg rdx
    cmp rax, rdx
    jge .tz_lx_dx2
    mov rax, rdx
.tz_lx_dx2:
    neg rdx                                   ; saturate y - p1y
    cmp r10, rdx
    jle .tz_lx_dy1
    mov r10, rdx
.tz_lx_dy1:
    neg rdx
    cmp r10, rdx
    jge .tz_lx_dy2
    mov r10, rdx
.tz_lx_dy2:
    imul rax, r10                             ; ≤ (2^31-1)^2 < 2^62, no wrap
    cqo
    idiv r9
    add rax, rcx
    mov rdx, 0x7FFF0000                       ; saturate result for 32-bit caller
    cmp rax, rdx
    jle .tz_lx_r1
    mov rax, rdx
.tz_lx_r1:
    neg rdx
    cmp rax, rdx
    jge .tz_lx_r2
    mov rax, rdx
.tz_lx_r2:
    ret
.tz_lx_flat:
    mov rax, rcx
    ret

; ============================================================================
; PHASE 9 — RENDER glyphs (text). CreateGlyphSet / AddGlyphs / CreateSolidFill
; / CompositeGlyphs. Clients rasterise glyphs (freetype) and upload A8
; coverage masks; we blend a solid source through each mask onto the dst.
; ============================================================================

; ----------------------------------------------------------------------------
; render_create_glyphset — rdi = req ptr (+4 gsid, +8 format). No reply.
; ----------------------------------------------------------------------------
render_create_glyphset:
    push rbx
    mov ecx, [rdi + 4]                        ; gsid
    test ecx, ecx
    jz .cgs_done
    mov edx, [rdi + 8]                        ; format
    xor ebx, ebx
.cgs_find:
    cmp ebx, MAX_GLYPHSETS
    jge .cgs_done
    mov rax, rbx
    imul rax, GLYPHSET_REC
    lea rax, [glyphsets + rax]
    cmp dword [rax], 0
    je .cgs_take
    inc ebx
    jmp .cgs_find
.cgs_take:
    mov [rax + 0], ecx
    mov [rax + 4], edx
.cgs_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_free_glyphset — rdi = req ptr (+4 glyphset). Clears the set entry.
; (Glyph bitmaps stay in the pool; acceptable for a session.)
; ----------------------------------------------------------------------------
render_free_glyphset:
    push rbx
    mov ecx, [rdi + 4]
    xor ebx, ebx
.fgs_find:
    cmp ebx, MAX_GLYPHSETS
    jge .fgs_done
    mov rax, rbx
    imul rax, GLYPHSET_REC
    lea rax, [glyphsets + rax]
    cmp [rax], ecx
    je .fgs_clear
    inc ebx
    jmp .fgs_find
.fgs_clear:
    mov dword [rax], 0
.fgs_done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; glyphset_format — edi = gsid. Returns the set's PICTFORMAT in eax, or 0.
; ----------------------------------------------------------------------------
glyphset_format:
    push rbx
    xor ebx, ebx
.gsf_loop:
    cmp ebx, MAX_GLYPHSETS
    jge .gsf_miss
    mov rax, rbx
    imul rax, GLYPHSET_REC
    lea rax, [glyphsets + rax]
    cmp [rax], edi
    je .gsf_hit
    inc ebx
    jmp .gsf_loop
.gsf_hit:
    mov eax, [rax + 4]                         ; format
    pop rbx
    ret
.gsf_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_add_glyphs — rdi = req ptr.
;   +4 glyphset   +8 numGlyphs   +12 glyphids[n]   then GLYPHINFO[n]
;   then concatenated A8 bitmaps (scanline padded to 4 bytes).
; Stores each glyph (metrics + bitmap copied into glyph_pool). No reply.
;
;   rbx=glyphset  r12=ids cursor  r13=info cursor  r14=data cursor
;   r15=remaining n  rbp=pool write ptr
; ----------------------------------------------------------------------------
render_add_glyphs:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi                              ; req ptr (reuse below)
    mov r15d, [rbx + 8]                        ; numGlyphs
    test r15d, r15d
    jz .ag_done
    mov ecx, [rbx + 4]                         ; glyphset id
    push rcx                                   ; [rsp+8] = glyphset id
    ; Determine bytes-per-pixel from the set's format: A8 (0x32) = 1,
    ; everything else (ARGB32/RGB24) = 4. Xft uploads ARGB32 glyphs when
    ; subpixel/LCD rendering is on, so this is the common case.
    mov edi, ecx
    call glyphset_format
    mov edx, 1
    cmp eax, 0x32
    je .ag_bpp_done
    mov edx, 4
.ag_bpp_done:
    push rdx                                   ; [rsp] = bpp, [rsp+8] = gsid
    lea r12, [rbx + 12]                        ; ids cursor
    mov eax, r15d
    lea r13, [r12 + rax*4]                      ; info cursor = ids + n*4
    mov eax, r15d
    imul eax, 12
    lea r14, [r13 + rax]                        ; data cursor = info + n*12
.ag_loop:
    test r15d, r15d
    jz .ag_pop
    ; capacity guards
    mov eax, [glyph_count]
    cmp eax, MAX_GLYPHS
    jge .ag_pop
    ; metrics
    movzx r8d, word [r13 + 0]                  ; width
    movzx r9d, word [r13 + 2]                  ; height
    ; stride: A8 (bpp 1) → (width+3)&~3 ; ARGB32 (bpp 4) → width*4
    cmp dword [rsp], 1                          ; bpp
    je .ag_stride1
    mov r10d, r8d
    shl r10d, 2                                 ; width*4
    jmp .ag_stride_done
.ag_stride1:
    lea eax, [r8 + 3]
    and eax, ~3
    mov r10d, eax
.ag_stride_done:
    ; size = stride * height
    mov eax, r10d
    imul eax, r9d
    mov r11d, eax                              ; bitmap size
    ; pool capacity
    mov ecx, [glyph_pool_used]
    lea edx, [rcx + r11]
    cmp edx, GLYPH_POOL_SIZE
    ja .ag_pop                                  ; pool full → stop
    ; --- write glyph record ---
    mov eax, [glyph_count]
    imul eax, GLYPH_REC_SIZE
    lea rbp, [glyph_recs + rax]
    mov edx, [rsp + 8]                          ; glyphset id
    mov [rbp + 0], edx
    mov edx, [r12]                              ; glyphid
    mov [rbp + 4], edx
    mov [rbp + 8], r8w                          ; width
    mov [rbp + 10], r9w                         ; height
    mov ax, [r13 + 4]
    mov [rbp + 12], ax                          ; gx
    mov ax, [r13 + 6]
    mov [rbp + 14], ax                          ; gy
    mov ax, [r13 + 8]
    mov [rbp + 16], ax                          ; xoff
    mov ax, [r13 + 10]
    mov [rbp + 18], ax                          ; yoff
    mov eax, [glyph_pool_used]
    mov [rbp + 20], eax                         ; bitmap_off
    mov [rbp + 24], r10w                        ; stride
    mov edx, [rsp]                              ; bpp
    mov [rbp + 26], dx                          ; bpp
    ; --- copy bitmap into pool ---
    push rsi
    push rdi
    mov edi, [glyph_pool_used]
    lea rdi, [glyph_pool + rdi]
    mov rsi, r14
    mov ecx, r11d
    rep movsb
    pop rdi
    pop rsi
    ; advance pool + counters
    add [glyph_pool_used], r11d
    inc dword [glyph_count]
    add r14, r11                                ; data cursor += size
    add r12, 4                                  ; next glyphid
    add r13, 12                                 ; next GLYPHINFO
    dec r15d
    jmp .ag_loop
.ag_pop:
    add rsp, 16                                 ; drop bpp + glyphset id
.ag_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_create_solid_fill — rdi = req ptr.
;   +4 pid   +8 RENDERCOLOR (red,green,blue,alpha u16)
; Records a solid-source Picture (drawable = PICTURE_SOLID, colour in
; the format field). No reply.
; ----------------------------------------------------------------------------
render_create_solid_fill:
    push rbx
    push r12
    mov r12, rdi
    mov edi, [r12 + 4]                          ; pid
    test edi, edi
    jz .csf_done
    call picture_lookup
    test rax, rax
    jnz .csf_fill
    xor ebx, ebx
.csf_find:
    cmp ebx, MAX_PICTURES
    jge .csf_done
    mov rax, rbx
    imul rax, PICTURE_REC_SIZE
    lea rax, [pictures + rax]
    cmp dword [rax], 0
    je .csf_fill
    inc ebx
    jmp .csf_find
.csf_fill:
    mov ecx, [r12 + 4]
    mov [rax + 0], ecx                          ; pid
    mov dword [rax + 4], PICTURE_SOLID          ; drawable = solid sentinel
    ; colour → 8-bit ARGB in format field
    movzx ecx, byte [r12 + 15]                  ; alpha hi
    shl ecx, 24
    movzx edx, byte [r12 + 9]                   ; red hi
    shl edx, 16
    or ecx, edx
    movzx edx, byte [r12 + 11]                  ; green hi
    shl edx, 8
    or ecx, edx
    movzx edx, byte [r12 + 13]                  ; blue hi
    or ecx, edx
    mov [rax + 8], ecx                          ; format field = ARGB colour
.csf_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; glyph_find — edi = gsid, esi = glyphid. Returns rec ptr in rax, or 0.
; ----------------------------------------------------------------------------
glyph_find:
    push rbx
    xor ebx, ebx
.gf_loop:
    cmp ebx, [glyph_count]
    jge .gf_miss
    mov rax, rbx
    imul rax, GLYPH_REC_SIZE
    lea rax, [glyph_recs + rax]
    cmp [rax + 0], edi
    jne .gf_next
    cmp [rax + 4], esi
    je .gf_hit
.gf_next:
    inc ebx
    jmp .gf_loop
.gf_hit:
    pop rbx
    ret
.gf_miss:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; glyph_blend — composite one glyph's A8 mask through cg_src onto cg_dst.
;   ecx = dst_x (s32, bitmap top-left)   r8d = dst_y (s32)   r9 = glyph rec
; Over operator: dst = src*a + dst*(1-a), a = coverage*srcAlpha/255.
; Division by 255 via (v*257+257)>>16.
;   rbx=bitmap ptr  r10d=width  r11d=height  r12d=stride
;   r13d=dst_x  r14d=dst_y  r15=row index
; ----------------------------------------------------------------------------
glyph_blend:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov r13d, ecx                              ; dst_x
    mov r14d, r8d                              ; dst_y
    movzx r10d, word [r9 + 8]                  ; width
    movzx r11d, word [r9 + 10]                 ; height
    movzx r12d, word [r9 + 24]                 ; stride
    cmp r13d, [cg_dmg + 0]                     ; grow the run's damage bbox
    jge .gb_d1
    mov [cg_dmg + 0], r13d
.gb_d1:
    cmp r14d, [cg_dmg + 4]
    jge .gb_d2
    mov [cg_dmg + 4], r14d
.gb_d2:
    lea eax, [r13 + r10]
    cmp eax, [cg_dmg + 8]
    jle .gb_d3
    mov [cg_dmg + 8], eax
.gb_d3:
    lea eax, [r14 + r11]
    cmp eax, [cg_dmg + 12]
    jle .gb_d4
    mov [cg_dmg + 12], eax
.gb_d4:
    movzx eax, word [r9 + 26]                   ; bpp (1=A8, 4=ARGB32)
    mov [gb_bpp], eax
    mov eax, [r9 + 20]                         ; bitmap_off
    lea rbx, [glyph_pool + rax]                ; bitmap ptr
    xor r15d, r15d                             ; row = 0
.gb_row:
    cmp r15d, r11d
    jge .gb_done
    mov eax, r14d
    add eax, r15d                              ; dy
    js .gb_row_next
    cmp eax, [cg_dst_h]
    jge .gb_done
    ; col loop
    push r15
    xor ebp, ebp                               ; col = 0
.gb_col:
    cmp ebp, r10d
    jge .gb_col_done
    mov eax, r13d
    add eax, ebp                               ; dx
    js .gb_col_next
    cmp eax, [cg_dst_stride]
    jge .gb_col_next
    ; coverage byte offset = row*stride + (A8: col ; ARGB32: col*4 + 3 = alpha)
    mov ecx, r15d
    imul ecx, r12d
    cmp dword [gb_bpp], 1
    je .gb_cov_a8
    mov edx, ebp
    shl edx, 2
    add ecx, edx
    add ecx, 3                                  ; alpha channel of ARGB pixel
    jmp .gb_cov_read
.gb_cov_a8:
    add ecx, ebp
.gb_cov_read:
    movzx ecx, byte [rbx + rcx]                ; cov
    test ecx, ecx
    jz .gb_col_next
    ; dst pixel addr = cg_dst_ptr + (dy*stride + dx)*4
    mov edx, r14d
    add edx, r15d                              ; dy
    imul edx, [cg_dst_stride]
    add edx, eax                               ; + dx
    mov rdi, [cg_dst_ptr]
    lea rdi, [rdi + rdx*4]                      ; dst pixel ptr
    ; a = cov * srcAlpha / 255
    mov eax, [cg_src]
    shr eax, 24
    and eax, 0xff                              ; src alpha
    imul eax, ecx                               ; cov * sa
    imul eax, 257
    add eax, 257
    shr eax, 16                                 ; a = (cov*sa)/255
    mov r8d, eax                                ; a (0..255)
    mov r9d, 255
    sub r9d, eax                                ; 255 - a
    mov edx, [rdi]                               ; dst pixel
    ; blue
    mov eax, [cg_src]
    and eax, 0xff
    imul eax, r8d
    mov ecx, edx
    and ecx, 0xff
    imul ecx, r9d
    add eax, ecx
    imul eax, 257
    add eax, 257
    shr eax, 16                                 ; nb
    mov ecx, eax                                ; ecx accumulates result, blue
    ; green
    mov eax, [cg_src]
    shr eax, 8
    and eax, 0xff
    imul eax, r8d
    mov esi, edx
    shr esi, 8
    and esi, 0xff
    imul esi, r9d
    add eax, esi
    imul eax, 257
    add eax, 257
    shr eax, 16                                 ; ng
    shl eax, 8
    or ecx, eax
    ; red
    mov eax, [cg_src]
    shr eax, 16
    and eax, 0xff
    imul eax, r8d
    mov esi, edx
    shr esi, 16
    and esi, 0xff
    imul esi, r9d
    add eax, esi
    imul eax, 257
    add eax, 257
    shr eax, 16                                 ; nr
    shl eax, 16
    or ecx, eax
    or ecx, 0xFF000000                          ; opaque dst
    mov [rdi], ecx
.gb_col_next:
    inc ebp
    jmp .gb_col
.gb_col_done:
    pop r15
.gb_row_next:
    inc r15d
    jmp .gb_row
.gb_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_composite_glyphs — rdi = req ptr (minor 23/24/25 = id size 1/2/4).
;   +1 minor  +4 op  +8 src  +12 dst  +16 maskFormat  +20 glyphset
;   +24 xSrc  +26 ySrc   +28 GLYPHLIST
; Blends a solid source through each glyph mask onto the dst Picture.
;
;   rbx=req ptr  r12=glyphlist cursor  r13=req end  r14d=pen_x  r15d=pen_y
;   rbp=current glyphset id  [rsp+0]=glyph id size (1/2/4)
; ----------------------------------------------------------------------------
render_composite_glyphs:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 16
    mov rbx, rdi
    mov dword [cg_dmg + 0], 0x7FFFFFFF        ; reset the run's damage bbox
    mov dword [cg_dmg + 4], 0x7FFFFFFF
    mov dword [cg_dmg + 8], 0x80000000
    mov dword [cg_dmg + 12], 0x80000000

    ; glyph id size from minor opcode
    movzx eax, byte [rbx + 1]
    mov ecx, 1                                  ; minor 23 → 1
    cmp eax, 24
    je .cog_sz2
    cmp eax, 25
    je .cog_sz4
    jmp .cog_szdone
.cog_sz2:
    mov ecx, 2
    jmp .cog_szdone
.cog_sz4:
    mov ecx, 4
.cog_szdone:
    mov [rsp + 0], ecx                          ; id size

    ; --- resolve src colour into cg_src ---
    mov dword [cg_src], 0xFFFFFFFF              ; default white opaque
    mov edi, [rbx + 8]                          ; src picture
    call picture_lookup
    test rax, rax
    jz .cog_have_src
    cmp dword [rax + 4], PICTURE_SOLID
    jne .cog_src_drawable
    mov ecx, [rax + 8]                          ; solid colour
    mov [cg_src], ecx
    jmp .cog_have_src
.cog_src_drawable:
    ; Non-solid src: sample its drawable's top-left pixel as the colour.
    mov edi, [rax + 4]
    call drawable_get_backing
    test rax, rax
    jz .cog_have_src
    mov ecx, [rax]                              ; top-left pixel
    mov [cg_src], ecx
.cog_have_src:

    ; --- resolve dst → backing into cg_dst_* ---
    mov edi, [rbx + 12]                         ; dst picture
    call picture_lookup
    test rax, rax
    jz .cog_done
    mov edi, [rax + 4]                          ; dst drawable
    mov [rsp + 8], edi                          ; stash for recomposite test
    call drawable_get_backing
    test rax, rax
    jz .cog_done
    mov [cg_dst_ptr], rax
    mov [cg_dst_stride], edx
    mov [cg_dst_h], ecx

    ; current glyphset, pen, cursor, end
    mov ebp, [rbx + 20]                         ; glyphset
    xor r14d, r14d                              ; pen_x
    xor r15d, r15d                              ; pen_y
    lea r12, [rbx + 28]                         ; glyphlist cursor
    movzx eax, word [rbx + 2]                   ; request length (units)
    shl eax, 2
    lea r13, [rbx + rax]                        ; request end

.cog_elt:
    ; need at least 8 bytes for an element header
    lea rax, [r12 + 8]
    cmp rax, r13
    ja .cog_finish
    movzx eax, byte [r12]                       ; count
    cmp eax, 255
    je .cog_switch
    ; element: pad(3) @ r12+1, deltax @ r12+4 (s16), deltay @ r12+6 (s16)
    movsx ecx, word [r12 + 4]
    add r14d, ecx                               ; pen_x += deltax
    movsx ecx, word [r12 + 6]
    add r15d, ecx                               ; pen_y += deltay
    mov edx, eax                                ; count
    add r12, 8                                   ; advance past header
    ; draw `count` glyphs
.cog_glyph:
    test edx, edx
    jz .cog_glyph_done
    push rdx                                     ; save count (caller-saved)
    mov ecx, [rsp + 8]                           ; id size (1/2/4); [rsp+8] after push
    cmp ecx, 1
    je .cog_id1
    cmp ecx, 2
    je .cog_id2
    mov edi, [r12]                               ; 4-byte id
    jmp .cog_idgot
.cog_id1:
    movzx edi, byte [r12]
    jmp .cog_idgot
.cog_id2:
    movzx edi, word [r12]
.cog_idgot:
    add r12, rcx                                 ; advance cursor by id size (32-bit clean)
    mov esi, edi                                 ; glyphid
    mov edi, ebp                                 ; gsid
    call glyph_find
    test rax, rax
    jz .cog_glyph_after
    mov r9, rax                                  ; glyph rec
    movsx ecx, word [r9 + 12]                    ; gx
    mov edi, r14d
    sub edi, ecx                                  ; dst_x = pen_x - gx
    movsx ecx, word [r9 + 14]                     ; gy
    mov r8d, r15d
    sub r8d, ecx                                  ; dst_y = pen_y - gy
    ; advance pen BEFORE glyph_blend (it clobbers r9/eax/ecx; r14/r15 are
    ; preserved by glyph_blend's push list).
    movsx eax, word [r9 + 16]
    add r14d, eax                                 ; pen_x += xoff
    movsx eax, word [r9 + 18]
    add r15d, eax                                 ; pen_y += yoff
    mov ecx, edi                                  ; glyph_blend arg: dst_x
    call glyph_blend                              ; ecx=dst_x, r8d=dst_y, r9=rec
.cog_glyph_after:
    pop rdx
    dec edx
    jmp .cog_glyph
.cog_glyph_done:
    ; pad cursor to 4-byte boundary relative to request start
    mov rax, r12
    sub rax, rbx
    and eax, 3
    jz .cog_elt
    mov ecx, 4
    sub ecx, eax
    add r12, rcx
    jmp .cog_elt
.cog_switch:
    ; count==255: next 4 bytes (after pad) are a new glyphset id
    mov ebp, [r12 + 4]
    add r12, 8
    jmp .cog_elt
.cog_finish:
    ; recomposite if dst drawable is a window
    mov edi, [rsp + 8]
    call window_lookup
    test rax, rax
    jz .cog_done
    mov byte [comp_dirty], 1
    mov ecx, [cg_dmg + 0]                     ; damage the run's bbox
    cmp ecx, [cg_dmg + 8]
    jge .cog_done
    mov rdi, rax
    mov eax, ecx                              ; local x
    mov edx, [cg_dmg + 4]                     ; local y
    mov ecx, [cg_dmg + 8]
    sub ecx, eax                              ; w
    mov r8d, [cg_dmg + 12]
    sub r8d, edx                              ; h
    call damage_add_local
.cog_done:
    add rsp, 16
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; render_composite — rdi = req ptr (RENDER minor 8).
;   +4 op   +8 src   +12 mask   +16 dst
;   +20 xSrc +22 ySrc  +24 xMask +26 yMask  +28 xDst +30 yDst
;   +32 width +34 height
; Composites a width×height region from src onto dst. mask is ignored for
; now (emoji/image blits don't use one; glyph masking goes through
; CompositeGlyphs). op Src(1) copies; anything else blends Over using the
; source alpha. src may be a solid-fill colour or an image drawable. No reply.
;
;   rbx=req ptr  r12d=op  r13d=dst drawable  r14d=dy  r15d=dx
; ----------------------------------------------------------------------------
render_composite:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi

    movzx r12d, byte [rbx + 4]                  ; op

    ; --- resolve dst ---
    mov qword [cur_clip], 0
    mov edi, [rbx + 16]
    call picture_lookup
    test rax, rax
    jz .rc_done
    push rax
    call pic_clip_entry                       ; honour the dst picture clip
    cmp dword [rax], 0
    je .rc_noclip_set                         ; count 0 → leave cur_clip 0
    mov [cur_clip], rax
.rc_noclip_set:
    pop rax
    mov edi, [rax + 4]
    mov r13d, edi                               ; dst drawable
    call drawable_get_backing
    test rax, rax
    jz .rc_done
    mov [co_dst_ptr], rax
    mov [co_dst_stride], edx
    mov [co_dst_h], ecx

    ; --- resolve src ---
    mov dword [co_src_solid], 0
    mov qword [co_src_xform], 0
    mov edi, [rbx + 8]
    call picture_lookup
    test rax, rax
    jz .rc_done
    cmp dword [rax + 4], PICTURE_SOLID
    jne .rc_src_drawable
    mov ecx, [rax + 8]
    mov [co_src_color], ecx
    mov dword [co_src_solid], 1
    jmp .rc_src_done
.rc_src_drawable:
    push rax
    call pic_xform_entry                      ; src transform (0 if identity)
    cmp dword [rax], 0
    je .rc_no_xform
    mov [co_src_xform], rax
.rc_no_xform:
    pop rax
    mov edi, [rax + 4]
    call drawable_get_backing
    test rax, rax
    jz .rc_done
    mov [co_src_ptr], rax
    mov [co_src_stride], edx
    mov [co_src_w], edx                         ; stride == width for our buffers
    mov [co_src_h], ecx
.rc_src_done:

    ; --- region loop ---
    xor r14d, r14d                              ; dy = 0
.rc_row:
    movzx eax, word [rbx + 34]                  ; height
    cmp r14d, eax
    jge .rc_finish
    xor r15d, r15d                              ; dx = 0
.rc_col:
    movzx eax, word [rbx + 32]                  ; width
    cmp r15d, eax
    jge .rc_row_next
    ; dst coords
    movsx eax, word [rbx + 28]                  ; xDst
    add eax, r15d                                ; dstx
    js .rc_col_next
    cmp eax, [co_dst_stride]
    jge .rc_col_next
    mov ebp, eax                                 ; dstx (keep)
    movsx eax, word [rbx + 30]                  ; yDst
    add eax, r14d                                ; dsty
    js .rc_col_next
    cmp eax, [co_dst_h]
    jge .rc_col_next
    ; dst picture clip (cur_clip set iff a clip is active)
    cmp qword [cur_clip], 0
    je .rc_clip_ok
    push rax
    mov edi, ebp                                 ; x
    mov esi, eax                                 ; y
    call clip_test_point
    test al, al
    pop rax
    jz .rc_col_next
.rc_clip_ok:
    ; dst pixel ptr → rdi
    imul eax, [co_dst_stride]
    add eax, ebp
    mov rdi, [co_dst_ptr]
    lea rdi, [rdi + rax*4]
    ; --- fetch src pixel → esi (ARGB) ---
    cmp dword [co_src_solid], 1
    je .rc_src_solid
    cmp qword [co_src_xform], 0
    jne .rc_src_xformed
    ; image src: sample at (xSrc+dx, ySrc+dy)
    movsx eax, word [rbx + 20]                  ; xSrc
    add eax, r15d
    js .rc_col_next
    cmp eax, [co_src_w]
    jge .rc_col_next
    mov ecx, eax                                 ; srcx
    movsx eax, word [rbx + 22]                  ; ySrc
    add eax, r14d
    js .rc_col_next
    cmp eax, [co_src_h]
    jge .rc_col_next
    imul eax, [co_src_stride]
    add eax, ecx
    mov rsi, [co_src_ptr]
    mov esi, [rsi + rax*4]                        ; src ARGB
    jmp .rc_have_src
.rc_src_xformed:
    ; transformed src: (sx,sy) = M·(u,v,1), u = xSrc+dx, v = ySrc+dy;
    ; nearest-neighbour fetch, out-of-bounds → skip the pixel.
    mov r11, [co_src_xform]
    movsx rax, word [rbx + 20]
    movsxd rcx, r15d
    add rax, rcx                                 ; u
    movsx rcx, word [rbx + 22]
    movsxd rdx, r14d
    add rcx, rdx                                 ; v
    movsxd r8, dword [r11 + 4]                   ; m11
    imul r8, rax
    movsxd r9, dword [r11 + 8]                   ; m12
    imul r9, rcx
    add r8, r9
    movsxd r9, dword [r11 + 12]                  ; m13
    add r8, r9
    sar r8, 16                                   ; sx
    movsxd r10, dword [r11 + 16]                 ; m21
    imul r10, rax
    movsxd r9, dword [r11 + 20]                  ; m22
    imul r9, rcx
    add r10, r9
    movsxd r9, dword [r11 + 24]                  ; m23
    add r10, r9
    sar r10, 16                                  ; sy
    test r8, r8
    js .rc_col_next
    cmp r8d, [co_src_w]
    jge .rc_col_next
    test r10, r10
    js .rc_col_next
    cmp r10d, [co_src_h]
    jge .rc_col_next
    mov eax, r10d
    imul eax, [co_src_stride]
    add eax, r8d
    mov rsi, [co_src_ptr]
    mov esi, [rsi + rax*4]                        ; src ARGB
    jmp .rc_have_src
.rc_src_solid:
    mov esi, [co_src_color]
.rc_have_src:
    ; op: Src(1) = copy ; else Over by src alpha
    cmp r12d, 1
    jne .rc_over
    mov eax, esi
    or eax, 0xFF000000
    mov [rdi], eax
    jmp .rc_col_next
.rc_over:
    mov eax, esi
    shr eax, 24
    and eax, 0xff                               ; src alpha
    test eax, eax
    jz .rc_col_next                             ; fully transparent
    cmp eax, 255
    jne .rc_blend
    ; opaque → copy
    mov eax, esi
    or eax, 0xFF000000
    mov [rdi], eax
    jmp .rc_col_next
.rc_blend:
    ; dst = src*a + dst*(255-a), per channel, /255 via (v*257+257)>>16
    mov r8d, eax                                 ; a
    mov r9d, 255
    sub r9d, eax                                 ; 255-a
    mov edx, [rdi]                                ; dst pixel
    ; blue
    mov eax, esi
    and eax, 0xff
    imul eax, r8d
    mov ecx, edx
    and ecx, 0xff
    imul ecx, r9d
    add eax, ecx
    imul eax, 257
    add eax, 257
    shr eax, 16
    mov ecx, eax                                 ; result accumulator (B)
    ; green
    mov eax, esi
    shr eax, 8
    and eax, 0xff
    imul eax, r8d
    mov r10d, edx
    shr r10d, 8
    and r10d, 0xff
    imul r10d, r9d
    add eax, r10d
    imul eax, 257
    add eax, 257
    shr eax, 16
    shl eax, 8
    or ecx, eax
    ; red
    mov eax, esi
    shr eax, 16
    and eax, 0xff
    imul eax, r8d
    mov r10d, edx
    shr r10d, 16
    and r10d, 0xff
    imul r10d, r9d
    add eax, r10d
    imul eax, 257
    add eax, 257
    shr eax, 16
    shl eax, 16
    or ecx, eax
    or ecx, 0xFF000000
    mov [rdi], ecx
.rc_col_next:
    inc r15d
    jmp .rc_col
.rc_row_next:
    inc r14d
    jmp .rc_row
.rc_finish:
    mov edi, r13d                                ; dst drawable
    call window_lookup
    test rax, rax
    jz .rc_done
    mov byte [comp_dirty], 1
    mov rdi, rax                              ; damage the composite dst rect
    movsx eax, word [rbx + 28]
    movsx edx, word [rbx + 30]
    movzx ecx, word [rbx + 32]                ; width
    movzx r8d, word [rbx + 34]                ; height
    call damage_add_local
.rc_done:
    mov qword [cur_clip], 0
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_set_selection_owner — edi = slot, rsi = req. SetSelectionOwner (22).
; Request: +4 owner window, +8 selection atom, +12 time. Stores (selection →
; owner) in a small table. No reply. The tray manager (strip) claims
; _NET_SYSTEM_TRAY_S0 this way so tray apps can find it.
; ----------------------------------------------------------------------------
handle_set_selection_owner:
    push rbx
    mov ebx, [rsi + 4]                        ; owner window
    mov ecx, [rsi + 8]                        ; selection atom
    xor edx, edx
.sso_find:
    cmp edx, [sel_count]
    jge .sso_add
    cmp [sel_atoms + rdx*4], ecx
    je .sso_set
    inc edx
    jmp .sso_find
.sso_add:
    cmp edx, SEL_MAX
    jae .sso_done                             ; table full → drop
    mov [sel_atoms + rdx*4], ecx
    inc dword [sel_count]
.sso_set:
    mov [sel_owners + rdx*4], ebx
    mov edx, ebx                             ; new owner → arg
                                             ; ecx = selection (still) → arg
    call xfixes_emit_selection_notify        ; tell XFIXES subscribers (copyq)
.sso_done:
    pop rbx
    ret

; handle_get_selection_owner — edi = slot, rsi = req. GetSelectionOwner (23).
; Request: +4 selection atom. Replies the tracked owner (or None). glass
; queries this during init and BLOCKS on the reply, so it must be answered.
; ----------------------------------------------------------------------------
handle_get_selection_owner:
    push rbx
    push r12
    mov ebx, edi                             ; slot
    mov r12d, [rsi + 4]                       ; selection atom (save before clobber)
    xor ecx, ecx                             ; owner = None
    xor edx, edx
.gso_find:
    cmp edx, [sel_count]
    jge .gso_have
    mov eax, [sel_atoms + rdx*4]
    cmp eax, r12d
    jne .gso_next
    mov ecx, [sel_owners + rdx*4]
    jmp .gso_have
.gso_next:
    inc edx
    jmp .gso_find
.gso_have:
    test ecx, ecx                             ; unowned _NET_WM_CM_S0 → frame
    jnz .gso_reply                            ; itself is the compositor: answer
    cmp r12d, [netwm_cm_atom_srv]             ; root so ARGB clients (glass
    jne .gso_reply                            ; opacity) take the real-alpha path
    mov ecx, X_ROOT_WINDOW
.gso_reply:
    push rcx                                  ; owner
    mov eax, ebx
    call client_meta_addr
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1                     ; reply
    mov byte [rdi + 1], 0
    mov ecx, [rax + 8]                        ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0                    ; length
    pop rcx                                   ; owner
    mov [rdi + 8], ecx                        ; owner
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov edi, [rax]                            ; fd
    push rax
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 32
    syscall
    pop rax
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_convert_selection — edi = slot, rsi = req. ConvertSelection (24).
; Request: +4 requestor, +8 selection, +12 target, +16 property, +20 time.
; Owner tracked → forward a SelectionRequest (30) to the owner's client,
; which then answers the requestor itself (SendEvent SelectionNotify +
; property write — both paths frame already serves). No owner → the spec
; says the SERVER sends SelectionNotify (31) with property None. Dropping
; this request wedged every XConvertSelection caller (clipboard paste,
; tray MANAGER handshakes) in a blocked wait.
; ----------------------------------------------------------------------------
handle_convert_selection:
    push rbx
    push r12
    mov rbx, rsi
    ; Find the owner of selection atom [rbx+8].
    mov ecx, [rbx + 8]
    xor edx, edx
.cvs_find:
    cmp edx, [sel_count]
    jge .cvs_noowner
    cmp [sel_atoms + rdx*4], ecx
    je .cvs_check
    inc edx
    jmp .cvs_find
.cvs_check:
    mov r12d, [sel_owners + rdx*4]           ; owner window
    test r12d, r12d
    jz .cvs_noowner
    ; SelectionRequest to the owner's client slot.
    lea rdi, [reply_buf]
    mov dword [rdi], 30                      ; code 30, detail+seq zeroed
    mov eax, [rbx + 20]
    mov [rdi + 4], eax                       ; time
    mov [rdi + 8], r12d                      ; owner
    mov eax, [rbx + 4]
    mov [rdi + 12], eax                      ; requestor
    mov eax, [rbx + 8]
    mov [rdi + 16], eax                      ; selection
    mov eax, [rbx + 12]
    mov [rdi + 20], eax                      ; target
    mov eax, [rbx + 16]
    mov [rdi + 24], eax                      ; property
    mov dword [rdi + 28], 0
    mov eax, r12d                            ; owner xid → slot
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .cvs_noowner                         ; stale/bogus owner → None path
    mov r12d, eax
    call client_meta_addr
    cmp dword [rax], -1                      ; owner's fd still live?
    je .cvs_noowner
    mov edi, r12d
    lea rsi, [reply_buf]
    call send_event_to_slot
    jmp .cvs_done
.cvs_noowner:
    ; SelectionNotify (property None) straight back to the requestor.
    lea rdi, [reply_buf]
    mov dword [rdi], 31
    mov eax, [rbx + 20]
    mov [rdi + 4], eax                       ; time
    mov eax, [rbx + 4]
    mov [rdi + 8], eax                       ; requestor
    mov eax, [rbx + 8]
    mov [rdi + 12], eax                      ; selection
    mov eax, [rbx + 12]
    mov [rdi + 16], eax                      ; target
    mov dword [rdi + 20], 0                  ; property = None
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0
    mov eax, [rbx + 4]                       ; requestor xid → slot
    sub eax, X_RID_BASE
    shr eax, 21
    cmp eax, MAX_CLIENTS
    jae .cvs_done
    mov edi, eax
    lea rsi, [reply_buf]
    call send_event_to_slot
.cvs_done:
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_query_font — edi = slot. QueryFont (opcode 47).
; Replies a minimal but structurally-exact fixed-width font reply (no
; per-char CHARINFOs, no properties → reply length 7, 60 bytes total).
; Clients that use a core font (e.g. glass) read max-bounds char-width
; (offset 28), font-ascent (52), font-descent (54) and drain 32+len*4
; bytes — so the length field MUST be exact or the socket desyncs.
; Uniform metrics: width 6, ascent 11, descent 2 (≈ -misc-fixed-13).
; ----------------------------------------------------------------------------
handle_query_font:
    push rbx
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    push rax                                   ; meta
    ; zero 60 bytes
    lea rdi, [reply_buf]
    xor eax, eax
    mov ecx, 8
    rep stosq                                  ; 64 bytes (covers 60)
    pop rax                                     ; meta
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1                       ; reply
    mov ecx, [rax + 8]                          ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 7                       ; reply length = 7 + 2n + 3m, n=m=0
    ; min-bounds CHARINFO @8: width@12, ascent@14, descent@16
    mov word [rdi + 12], 6
    mov word [rdi + 14], 11
    mov word [rdi + 16], 2
    ; max-bounds CHARINFO @24: width@28, ascent@30, descent@32
    mov word [rdi + 28], 6
    mov word [rdi + 30], 11
    mov word [rdi + 32], 2
    ; min-char-or-byte2 @40 = 0 ; max-char-or-byte2 @42 = 255
    mov word [rdi + 42], 255
    ; default-char @44 = 0 ; nFontProps @46 = 0
    ; draw-direction @48 = 0 ; min-byte1 @49 = 0 ; max-byte1 @50 = 255
    mov byte [rdi + 50], 255
    mov byte [rdi + 51], 1                       ; all-chars-exist
    mov word [rdi + 52], 11                      ; font-ascent
    mov word [rdi + 54], 2                       ; font-descent
    ; nCharInfos @56 = 0
    mov edi, [rax]                               ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 60
    syscall
    pop rbx
    ret

; ----------------------------------------------------------------------------
; install_dump_handler / dump_handler — DEBUG. On SIGUSR1, log stats about
; the first mapped non-root window's backing buffer (size, count of pixels
; differing from back_pixel, and the centre pixel). Lets us check whether a
; client (glass) actually rendered content into its window, network-only.
; ----------------------------------------------------------------------------
install_dump_handler:
    lea rdi, [sig_sa_buf]
    lea rax, [dump_handler]
    mov [rdi + 0], rax
    mov qword [rdi + 8], SA_RESTORER
    lea rax, [sig_restorer]
    mov [rdi + 16], rax
    mov qword [rdi + 24], 0
    mov rax, SYS_RT_SIGACTION
    mov edi, SIGUSR1
    lea rsi, [sig_sa_buf]
    xor edx, edx
    mov r10, 8
    syscall
    ret

dump_handler:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rsi, dbg_dump_tag                     ; marker: handler fired
    mov edx, dbg_dump_tag_len
    call write_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    xor ebx, ebx
.dh_find:
    cmp ebx, MAX_WINDOWS
    jge .dh_done
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea r12, [windows + rax]
    mov eax, [r12]
    test eax, eax
    jz .dh_next
    cmp eax, X_ROOT_WINDOW
    je .dh_next
    ; log every non-root window regardless of mapped/backing state
    xor edx, edx                              ; nonbg count (0 if no backing)
    cmp byte [r12 + 31], 0                    ; has_backing?
    je .dh_log
    mov r13, [r12 + 32]                       ; backing ptr
    ; dump EVERY backed window to /tmp/frame_dump_<xid>.raw (per-xid, no gate)
    lea rdi, [dump_path_buf]
    lea rsi, [dump_prefix]
.dh_cp_pre:
    mov al, [rsi]
    test al, al
    jz .dh_cp_pre_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .dh_cp_pre
.dh_cp_pre_done:
    mov eax, [r12]                            ; xid
    call u64_to_ascii                         ; digits at rdi, returns rdi past
    lea rsi, [dump_suffix]                     ; ".raw",0
.dh_cp_suf:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .dh_cp_suf_done
    inc rsi
    inc rdi
    jmp .dh_cp_suf
.dh_cp_suf_done:
    ; --- write the raw ARGB backing to the per-xid path ---
    mov rax, SYS_OPEN
    lea rdi, [dump_path_buf]
    mov esi, 0x241                            ; O_WRONLY|O_CREAT|O_TRUNC
    mov edx, 0x1A4                            ; 0644
    syscall
    test rax, rax
    js .dh_wf_done
    push rax                                  ; fd
    movzx eax, word [r12 + 40]
    movzx ecx, word [r12 + 42]
    imul eax, ecx
    shl eax, 2                                ; w*h*4 bytes
    mov edx, eax
    mov rax, SYS_WRITE
    mov rdi, [rsp]
    mov rsi, [r12 + 32]
    syscall
    mov rax, SYS_CLOSE
    mov rdi, [rsp]
    syscall
    add rsp, 8
.dh_wf_done:
    movzx r14d, word [r12 + 40]
    movzx eax, word [r12 + 42]
    imul r14d, eax                            ; pixel count
    mov r15d, [r12 + 44]                      ; back_pixel
    xor ecx, ecx                              ; index
.dh_count:
    cmp ecx, r14d
    jge .dh_log
    mov eax, [r13 + rcx*4]
    cmp eax, r15d
    je .dh_count_next
    inc edx
.dh_count_next:
    inc ecx
    jmp .dh_count
.dh_log:
    push rdx                                  ; nonbg count
    mov rsi, dbg_dump_tag
    mov edx, dbg_dump_tag_len
    call write_stderr
    mov eax, [r12]                            ; xid
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    movzx eax, byte [r12 + 28]                ; mapped
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    movzx eax, byte [r12 + 31]                ; has_backing
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    movzx eax, word [r12 + 40]                ; w
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    movzx eax, word [r12 + 42]                ; h
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    movsx eax, word [r12 + 8]                 ; x (s16 → may print huge for -1;
    and eax, 0xFFFF                            ; print raw u16, decode client-side)
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    movsx eax, word [r12 + 10]                ; y
    and eax, 0xFFFF
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    mov eax, [r12 + 48]                       ; stk
    call write_u64_stderr
    mov rsi, dbg_sp
    mov edx, 1
    call write_stderr
    pop rax                                   ; nonbg count
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov rdx, 1
    call write_stderr
    jmp .dh_next
.dh_next:
    inc ebx
    jmp .dh_find
.dh_done:
    ; --- DIAG: dump BOTH compositor framebuffers + state line ---
    cmp byte [compositor_active], 0
    je .dh_nofb
    lea rsi, [dbg_fbstate]                    ; "FBSTATE back=N recomp=N"
    call write_str_stderr
    mov eax, [comp_back]
    call write_u64_stderr
    lea rsi, [dbg_spX]
    mov edx, 1
    call write_stderr
    mov eax, [rs_counter]
    call write_u64_stderr
    lea rsi, [dbg_pxblit]
    call write_str_stderr
    mov rax, [comp_px_blit]
    call write_u64_stderr
    lea rsi, [dbg_pxfill]
    call write_str_stderr
    mov rax, [comp_px_fill]
    call write_u64_stderr
    lea rsi, [dbg_pxflush]
    call write_str_stderr
    mov rax, [comp_px_flush]
    call write_u64_stderr
    lea rsi, [dbg_evdrop]
    call write_str_stderr
    mov eax, [ev_dropped]
    call write_u64_stderr
    lea rsi, [probe_conn_nl]
    mov edx, 1
    call write_stderr
    mov rax, SYS_OPEN                         ; fb0
    lea rdi, [dump_fb0_path]
    mov esi, 0x241
    mov edx, 0x1A4
    syscall
    test rax, rax
    js .dh_fb1
    push rax
    mov rdi, rax
    mov rsi, [comp_addr + 0]
    mov rdx, [drm_dumb_size]
    mov rax, SYS_WRITE
    syscall
    pop rdi
    mov rax, SYS_CLOSE
    syscall
.dh_fb1:
    mov rax, SYS_OPEN                         ; fb1
    lea rdi, [dump_fb1_path]
    mov esi, 0x241
    mov edx, 0x1A4
    syscall
    test rax, rax
    js .dh_nofb
    push rax
    mov rdi, rax
    mov rsi, [comp_addr + 8]
    mov rdx, [drm_dumb_size]
    mov rax, SYS_WRITE
    syscall
    pop rdi
    mov rax, SYS_CLOSE
    syscall
.dh_nofb:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
