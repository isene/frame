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
%define DRM_IOCTL_MODE_DESTROY_DUMB    0xC00464B4

%define SYS_POLL        7
%define SYS_MMAP        9
%define SYS_MUNMAP      11
%define SYS_NANOSLEEP   35
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
pollfd_buf:         resb (MAX_CLIENTS + 1 + 16) * 8

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
%define MAX_WINDOWS      512
%define WINDOW_REC_SIZE  48
windows:            resb MAX_WINDOWS * WINDOW_REC_SIZE

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
; keysym_table — flat per-X11-keycode keysym table. 2 keysyms per keycode
; (unshifted + shifted). Indexed by (kc - X_MIN_KEYCODE) * 8 + offset.
;
; Range: X11 keycodes 8..255 → (255 - 8 + 1) × 8 = 1984 bytes.
%define KEYCODE_RANGE        (X_MAX_KEYCODE - X_MIN_KEYCODE + 1)
keysym_table:       resb KEYCODE_RANGE * 8

; key_grabs[256] — per-grab record (16 B):
;   +0  window (u32)     0 = empty slot
;   +4  client_slot (u32)
;   +8  keycode (u8)     X11 keycode (= evdev code + 8)
;   +9  pad (1)
;   +10 modifiers (u16)
;   +12 pad (4)
%define MAX_KEY_GRABS        256
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
mod_state:          resd 1
focus_window:       resd 1               ; SetInputFocus target (0/1 = none/PointerRoot)

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

; ---- Phase 4f compositor state --------------------------------------------
compositor_requested: resb 1               ; set by --display argv flag
compositor_active:    resb 1               ; set to 1 after init_compositor wins
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
vendor_str:         db "frame"

log_prefix:         db "frame: ", 0
log_listening:      db "listening on display :", 0
log_accepted:       db "client connected", 10
log_accepted_len   equ $ - log_accepted
log_setup_ok:       db "setup reply sent (", 0
log_setup_ok_2:     db " bytes)", 10
log_setup_ok_2_len equ $ - log_setup_ok_2
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
dbg_ag_tag:         db 10, "AG: "
dbg_ag_tag_len      equ $ - dbg_ag_tag
dbg_sp:             db " "
dbg_dump_tag:       db "DUMP xid/w/h/nonbg: "
dbg_dump_tag_len    equ $ - dbg_dump_tag
dump_path:          db "/tmp/frame_win.raw", 0
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
    call init_clients
    call init_windows
    call init_gcs
    call init_pixmaps
    call init_pictures
    call init_properties
    call install_dump_handler
    call init_keysyms
    call init_input
    cmp byte [compositor_requested], 0
    je .skip_compositor
    call init_compositor
.skip_compositor:
    jmp serve_loop

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
    mov byte [rdi + 21], 1
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

    ; ---- 1 pixmap format (8 bytes): depth 24 in 32 bpp ----
    mov byte [rdi + 0], 24               ; depth
    mov byte [rdi + 1], X_FMT_BPP        ; bits-per-pixel
    mov byte [rdi + 2], X_SCANLINE_PAD   ; scanline pad
    mov byte [rdi + 3], 0
    mov dword [rdi + 4], 0
    add rdi, 8

    ; ---- 1 screen header (40 bytes) ----
    mov dword [rdi + 0],  X_ROOT_WINDOW
    mov dword [rdi + 4],  X_DEFAULT_CMAP
    mov dword [rdi + 8],  0x00FFFFFF     ; white pixel
    mov dword [rdi + 12], 0x00000000     ; black pixel
    mov dword [rdi + 16], 0              ; current input masks (we tell clients later)
    mov word  [rdi + 20], X_SCREEN_W
    mov word  [rdi + 22], X_SCREEN_H
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
    mov rsi, log_client_gone
    mov rdx, log_client_gone_len
    call write_stderr
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
    jge .sl_poll
    mov edx, [input_fds + rcx*4]             ; fd (or -1)
    mov eax, MAX_CLIENTS + 1
    add eax, ecx
    shl eax, 3
    mov [pollfd_buf + rax], edx
    mov word [pollfd_buf + rax + 4], 1       ; POLLIN
    mov word [pollfd_buf + rax + 6], 0
    inc ecx
    jmp .sl_build_in_loop
.sl_poll:
    mov rax, SYS_POLL
    lea rdi, [pollfd_buf]
    mov esi, MAX_CLIENTS + 1 + MAX_INPUTS
    mov edx, -1                              ; infinite timeout
    syscall
    test rax, rax
    js .sl_iter                              ; -EINTR or similar — re-poll

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
    jge .sl_iter
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

    ; Log this request so the user can see what the client asked for.
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call log_request
    pop rdx
    pop rax

    cmp eax, 1
    je .dr_create_window
    cmp eax, 2
    je .dr_change_window_attributes
    cmp eax, 3
    je .dr_get_window_attributes
    cmp eax, 25
    je .dr_send_event
    cmp eax, 23
    je .dr_get_selection_owner
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
    cmp eax, 55
    je .dr_create_gc
    cmp eax, 97
    je .dr_query_best_size
    cmp eax, 98
    je .dr_query_extension
    cmp eax, 99
    je .dr_list_extensions
    cmp eax, 101
    je .dr_get_keyboard_mapping
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
    ; Unhandled — already logged.
    jmp .dr_done

.dr_render:
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    call handle_render
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

.dr_list_extensions:
    mov edi, ebx
    call handle_list_extensions
    jmp .dr_done

.dr_get_keyboard_mapping:
    mov edi, ebx
    mov rsi, r12                             ; request ptr
    call handle_get_keyboard_mapping
    jmp .dr_done

.dr_get_window_attributes:
    mov edi, ebx
    mov rsi, r12
    call handle_get_window_attributes
    jmp .dr_done

.dr_grab_pointer:
    mov edi, ebx
    call handle_grab_pointer
    jmp .dr_done

.dr_ungrab_pointer:
    ; No-op (we don't track pointer grabs yet); no reply.
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

.dr_get_selection_owner:
    mov edi, ebx
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

    ; Is the requested name "RENDER" (length 6)?
    movzx eax, word [r13 + 4]                ; name-length
    cmp eax, 6
    jne .qe_send
    lea rsi, [r13 + 8]
    lea rdi, [str_render]
    mov ecx, 6
.qe_cmp:
    mov al, [rsi]
    cmp al, [rdi]
    jne .qe_send
    inc rsi
    inc rdi
    dec ecx
    jnz .qe_cmp
    ; Match → report present with our major opcode.
    lea rdi, [reply_buf]
    mov byte [rdi + 8], 1                    ; present = True
    mov byte [rdi + 9], RENDER_MAJOR         ; major-opcode
    mov byte [rdi + 10], 0                   ; first-event
    mov byte [rdi + 11], RENDER_ERROR_BASE   ; first-error

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
    mov dword [r13], 0                       ; xid = 0 → empty
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
; handle_get_input_focus — edi = slot. Phase 4a stand-in: replies focus =
; PointerRoot (1), revert-to = PointerRoot (1). Real focus model lands in
; phase 4d (input).
;
; Reply (32 bytes):
;   +0 1                  +1 revert-to (PointerRoot=1)
;   +2 seq                +4 reply length 0
;   +8 focus (PointerRoot=1)
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
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; nExtensions
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
    mov dword [rdi + 8], 1                   ; focus = PointerRoot
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
    mov byte [rdi + 1], 2                    ; keysyms-per-keycode = 2
    mov edx, [r12 + 8]
    mov [rdi + 2], dx
    mov edx, ecx
    shl edx, 1                               ; reply length = count × 2 (each keysym = 1 4u)
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
    shl esi, 3                               ; bytes (8 per keycode)
    lea r9, [keysym_table + rsi]             ; source ptr
.gkm_emit:
    mov eax, [r9]
    mov [rdi], eax
    mov eax, [r9 + 4]
    mov [rdi + 4], eax
    add r9, 8
    add rdi, 8
    dec ecx
    jnz .gkm_emit
    pop rcx
.gkm_write:
    mov edx, ecx
    shl edx, 3                               ; body bytes = count × 8
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
    mov dword [rdi + 32], 0
    mov dword [rdi + 36], 0
    mov dword [rdi + 40], 0
    mov dword [rdi + 44], 0

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
    mov word  [rbx + 12], X_SCREEN_W
    mov word  [rbx + 14], X_SCREEN_H
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
window_destroy:
    push rbx
    push r12
    push r13
    cmp edi, X_ROOT_WINDOW
    je .wd_done
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
    mov dword [r13], 0                       ; mark empty
    mov byte [r13 + 31], 0                   ; has_backing = 0
    mov qword [r13 + 32], 0
    mov dword [r13 + 40], 0                  ; backing_w/h = 0
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
    cmp r14d, 1                              ; CW_BACK_PIXEL bit pos
    je .av_back_pixel
    cmp r14d, 9                              ; CW_OVERRIDE_REDIRECT bit pos
    je .av_override
    cmp r14d, 11                             ; CW_EVENT_MASK bit pos
    je .av_event_mask
    jmp .av_advance
.av_back_pixel:
    mov [r13 + 44], eax                      ; back_pixel
    jmp .av_advance
.av_override:
    mov [r13 + 29], al                       ; u8 boolean
    jmp .av_advance
.av_event_mask:
    mov [r13 + 24], eax
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
    mov [r13 + 20], eax                      ; visual
    mov dword [r13 + 24], 0                  ; event_mask (default 0)
    mov byte  [r13 + 28], 0                  ; mapped (false)
    mov byte  [r13 + 29], 0                  ; override-redirect (false)
    mov byte  [r13 + 30], -1                 ; redirect_owner (none)
    mov byte  [r13 + 31], 0                  ; has_backing (false)
    mov qword [r13 + 32], 0                  ; backing_ptr
    mov dword [r13 + 40], 0                  ; backing_cap
    mov dword [r13 + 44], 0                  ; back_pixel (default black)

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
    lea rdx, [r12 + 12]
    call apply_cw_values
    ; SubstructureRedirect ownership transfer.
    mov eax, [r13 + 24]
    test eax, EM_SUBSTRUCTURE_REDIRECT
    jz .cwa_clear_redirect
    mov [r13 + 30], bl
    jmp .cwa_done
.cwa_clear_redirect:
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
    mov ebx, edi
    mov edi, [rsi + 4]
    call window_destroy
    call recomposite_screen
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
    call window_lookup
    test rax, rax
    jz .mw_done
    mov r12, rax                              ; window record
    mov edi, [r12 + 4]                        ; parent xid
    call window_lookup
    test rax, rax
    jz .mw_just_map
    mov r13, rax                              ; parent record
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
    call recomposite_screen
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
    ; If parent has SubstructureNotify, notify the redirect-owner subscriber.
    test r13, r13
    jz .mw_done
    mov eax, [r13 + 24]
    test eax, EM_SUBSTRUCTURE_NOTIFY
    jz .mw_done
    movsx r14d, byte [r13 + 30]
    cmp r14d, 0
    jl .mw_done
    mov edi, r14d
    mov esi, [r13]                             ; parent xid (the event window)
    mov edx, [r12]                             ; child xid
    call send_map_notify
.mw_done:
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
    call recomposite_screen
    mov edi, [r12 + 4]
    call window_lookup
    test rax, rax
    jz .uw_done
    mov r13, rax
    mov eax, [r13 + 24]
    test eax, EM_SUBSTRUCTURE_NOTIFY
    jz .uw_done
    movsx r14d, byte [r13 + 30]
    cmp r14d, 0
    jl .uw_done
    mov edi, r14d
    mov esi, [r13]
    mov edx, [r12]
    call send_unmap_notify
.uw_done:
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
    jz .cfgw_done
    mov r13, rax                             ; record ptr

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
    add r14, 4
.cfgw_apply_done:
    ; If the window resized and has a backing buffer at the old size,
    ; drop it — the client will re-create it at the new size on its
    ; next draw (standard resize → repaint flow).
    cmp byte [r13 + 31], 0
    je .cfgw_recomp
    movzx eax, word [r13 + 40]               ; backing_w
    cmp ax, [r13 + 12]                        ; width
    jne .cfgw_drop_backing
    movzx eax, word [r13 + 42]               ; backing_h
    cmp ax, [r13 + 14]                        ; height
    je .cfgw_recomp
.cfgw_drop_backing:
    mov rax, SYS_MUNMAP
    mov rdi, [r13 + 32]
    movzx esi, word [r13 + 40]
    movzx ecx, word [r13 + 42]
    imul esi, ecx
    shl esi, 2
    syscall
    mov byte [r13 + 31], 0
    mov qword [r13 + 32], 0
    mov dword [r13 + 40], 0
.cfgw_recomp:
    call recomposite_screen
.cfgw_done:
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
    jmp .cp_done

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
    mov edi, [rsi + 4]                       ; window
    mov ebx, [rsi + 8]                       ; atom
    mov esi, ebx
    call property_find
    test rax, rax
    jz .dp_done
    mov dword [rax], 0                       ; mark empty
.dp_done:
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
; KS — set keysym_table[X11_KC]'s unshifted + shifted values.
; ----------------------------------------------------------------------------
%macro KS 3
    mov dword [keysym_table + (%1 - X_MIN_KEYCODE) * 8 + 0], %2
    mov dword [keysym_table + (%1 - X_MIN_KEYCODE) * 8 + 4], %3
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

; ----------------------------------------------------------------------------
; init_keysyms — populate keysym_table with US layout. Sparse population:
; keycodes not listed here stay at the all-zeros init (= NoSymbol).
; ----------------------------------------------------------------------------
init_keysyms:
    lea rdi, [keysym_table]
    xor eax, eax
    mov ecx, KEYCODE_RANGE * 2
    rep stosd

    ; X11 keycode = evdev keycode + 8.
    KS 9,  XK_Escape, XK_Escape
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
    KS 34, '[', '{'
    KS 35, ']', '}'
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
    KS 47, ';', ':'
    KS 48, "'", '"'
    KS 49, '`', '~'
    KS 50, XK_Shift_L, XK_Shift_L
    KS 51, '\', '|'
    KS 52, 'z', 'Z'
    KS 53, 'x', 'X'
    KS 54, 'c', 'C'
    KS 55, 'v', 'V'
    KS 56, 'b', 'B'
    KS 57, 'n', 'N'
    KS 58, 'm', 'M'
    KS 59, ',', '<'
    KS 60, '.', '>'
    KS 61, '/', '?'
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
    movzx eax, word [rbx + 16]               ; type
    cmp eax, EV_KEY
    jne .die_done

    movzx r12d, word [rbx + 18]              ; code (evdev keycode)
    mov r13d, [rbx + 20]                     ; value (0=rel,1=press,2=repeat)

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
    ; x11_keycode = evdev_code + 8 (kept in r12d from here on).
    add r12d, 8

    ; Release (value 0) → KeyRelease to the focused window.
    cmp r13d, 0
    je .die_release
    ; Repeat (value 2) → KeyPress to the focused window (no grab re-fire).
    cmp r13d, 1
    jne .die_focus_press

    ; Fresh press: a matching key-grab wins (WM hotkeys); else focus.
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

.die_done:
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
    mov edi, eax                              ; client slot
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
    mov dword [rsi + 4], 0                    ; time
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
    mov rax, SYS_WRITE
    mov rdx, 32
    syscall
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
    mov edi, [rsi + 4]
    call window_lookup
    test rax, rax
    jz .rp_done
    mov ecx, [rsi + 8]
    mov [rax + 4], ecx                        ; new parent
    mov dx, [rsi + 12]
    mov [rax + 8], dx                         ; new x
    mov dx, [rsi + 14]
    mov [rax + 10], dx                        ; new y
.rp_done:
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
    mov rax, SYS_WRITE
    mov edi, ebx
    mov rsi, r13
    mov rdx, 32
    syscall
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

    ; --- resources + first connected connector ---
    call drm_probe_resources
    call modeset_find_connector
    test eax, eax
    jz .ic_fail_no_conn
    mov [drm_chosen_conn], r12d

    ; --- GETENCODER → CRTC ---
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
    js .ic_fail_other
    mov eax, [drm_encoder_buf + 8]
    test eax, eax
    jnz .ic_have_crtc
    mov ecx, [drm_encoder_buf + 12]
    bsf rdx, rcx
    mov eax, [drm_crtc_ids + rdx*4]
.ic_have_crtc:
    mov r13d, eax
    mov [drm_chosen_crtc], eax

    ; --- CREATE_DUMB at hdisplay × vdisplay × 32 bpp ---
    lea rdi, [drm_dumb_create]
    xor eax, eax
    mov ecx, 4
    rep stosq
    movzx eax, word [drm_modes_buf + 4]      ; hdisplay
    mov [drm_dumb_create + 4], eax
    movzx eax, word [drm_modes_buf + 14]     ; vdisplay
    mov [drm_dumb_create + 0], eax
    mov dword [drm_dumb_create + 8], 32
    mov dword [drm_dumb_create + 12], 0
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CREATE_DUMB
    lea rdx, [drm_dumb_create]
    syscall
    test rax, rax
    js .ic_fail_other
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
    js .ic_fail_other
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
    ja .ic_fail_other
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
    js .ic_fail_other
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
    movzx eax, word [drm_modes_buf + 4]
    mov [drm_dumb_create + 4], eax
    movzx eax, word [drm_modes_buf + 14]
    mov [drm_dumb_create + 0], eax
    mov dword [drm_dumb_create + 8], 32
    mov dword [drm_dumb_create + 12], 0
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_CREATE_DUMB
    lea rdx, [drm_dumb_create]
    syscall
    test rax, rax
    js .ic_fail_other
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
    js .ic_fail_other
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
    ja .ic_fail_other
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
    js .ic_fail_other
    mov eax, [drm_fb_cmd]
    mov [comp_fbid + 4], eax                 ; buffer 1 fbid
    mov dword [comp_back], 1                  ; render buffer 1 first (front=0)

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

    ; --- SETCRTC: program the CRTC to scan our buffer ---
    mov eax, [drm_chosen_conn]
    mov [drm_set_conn_id], eax
    lea rdi, [drm_crtc_set]
    xor eax, eax
    mov ecx, 13
    rep stosq
    lea rax, [drm_set_conn_id]
    mov [drm_crtc_set + 0], rax
    mov dword [drm_crtc_set + 8], 1
    mov [drm_crtc_set + 12], r13d
    mov eax, [drm_fb_id]
    mov [drm_crtc_set + 16], eax
    mov dword [drm_crtc_set + 32], 1
    lea rsi, [drm_modes_buf]
    lea rdi, [drm_crtc_set + 36]
    mov ecx, 17
    rep movsd
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_set]
    syscall
    test rax, rax
    js .ic_fail_other

    mov byte [compositor_active], 1

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
    movzx eax, word [drm_modes_buf + 4]
    call write_u64_stderr
    mov rsi, log_comp_x
    mov rdx, 1
    call write_stderr
    movzx eax, word [drm_modes_buf + 14]
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

    call recomposite_screen
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

    ; Point drm_dumb_addr at the BACK buffer — every draw helper (the bg
    ; fill, draw_rect, blit_window) renders through drm_dumb_addr, so this
    ; one assignment redirects the whole repaint into the back buffer.
    ; We PAGE_FLIP to it at the end (.rs_done_pop).
    mov eax, [comp_back]
    mov rax, [comp_addr + rax*8]
    mov [drm_dumb_addr], rax

    ; --- Background fill across the whole (back) buffer.
    mov rdi, [drm_dumb_addr]
    mov rcx, [drm_dumb_size]
    shr rcx, 2
    mov eax, COMP_BG_COLOR
    rep stosd

    ; --- Walk the window table, draw every mapped non-root window.
    xor ebx, ebx
.rs_loop:
    cmp ebx, MAX_WINDOWS
    jge .rs_done_pop
    mov rax, rbx
    imul rax, WINDOW_REC_SIZE
    lea r12, [windows + rax]
    mov eax, [r12]
    test eax, eax
    jz .rs_next
    cmp eax, X_ROOT_WINDOW
    je .rs_next
    cmp byte [r12 + 28], 0
    je .rs_next

    ; If the window has a backing buffer with real content, blit it.
    cmp byte [r12 + 31], 0
    je .rs_flat
    mov rdi, r12
    call blit_window
    jmp .rs_next

.rs_flat:
    ; No backing yet — fill the window rect with its back_pixel, or a
    ; per-xid hash colour if back_pixel is 0 (so a zero-background
    ; window is still visible during development).
    mov r13d, [r12 + 44]                     ; back_pixel
    test r13d, r13d
    jnz .rs_flat_draw
    mov edi, [r12]
    call window_color
    mov r13d, eax
.rs_flat_draw:
    movsx eax, word [r12 + 8]
    movsx esi, word [r12 + 10]
    movzx edi, word [r12 + 12]
    movzx ecx, word [r12 + 14]
    mov edx, r13d
    call draw_rect

.rs_next:
    inc ebx
    jmp .rs_loop

.rs_done_pop:
    ; --- clflush the entire framebuffer. The DRM dumb-buffer mmap on
    ; i915 is write-back cached; our rep stosd + draw_rect writes land
    ; in CPU L1/L2 and never reach memory (and therefore never reach
    ; the panel's scan-out) without explicit flushing. clflush is
    ; per-64-byte cache line; we sweep the whole 9.2 MB buffer with one
    ; `rep`-flavoured loop. ~144k cache lines, sub-ms total.
    ; clflush the back buffer (CPU write-back cache → RAM) so the display
    ; engine reads our fresh pixels, not stale cache.
    mov rdi, [drm_dumb_addr]
    mov rcx, [drm_dumb_size]
.rs_flush:
    clflush [rdi]
    add rdi, 64
    sub rcx, 64
    ja .rs_flush
    sfence

    ; --- PAGE_FLIP the CRTC to the back buffer. The flip makes the
    ; display engine re-scan the new buffer at the next vblank, which
    ; defeats FBC/PSR staleness (DIRTYFB is unsupported on legacy FBs).
    ; ebx = back index.
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

    ; Log the first flip's return so we can confirm flips are accepted.
    cmp byte [dirtyfb_logged], 0
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
    js .rs_no_swap                           ; flip rejected → keep current front

    ; Drain the flip-complete event (blocking read; arrives at vblank,
    ; ~8 ms). Only one flip may be pending per CRTC, and we drain it
    ; synchronously here, so the next recomposite's flip never collides.
    mov rax, SYS_READ
    mov rdi, [drm_fd]
    lea rsi, [drm_event_buf]
    mov rdx, 64
    syscall

    ; Swap: the back buffer just became the front; render the other one
    ; next time.
    mov eax, [comp_back]
    xor eax, 1
    mov [comp_back], eax
.rs_no_swap:

    pop r13
    pop r12
    pop rbx
.rs_done:
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
    movzx r12d, word [drm_modes_buf + 4]     ; screen w
    movzx r13d, word [drm_modes_buf + 14]    ; screen h
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
; compositor_shutdown — restore the saved CRTC (text console), drop
; master, close the DRM fd. No-op if the compositor never activated.
; Safe to call more than once.
; ----------------------------------------------------------------------------
compositor_shutdown:
    cmp byte [compositor_active], 0
    je .cs_done
    mov byte [compositor_active], 0          ; idempotent guard

    ; Restore the console's original CRTC. drm_crtc_save was filled by
    ; GETCRTC in init_compositor; replaying it via SETCRTC puts the text
    ; framebuffer back on the panel.
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_MODE_SETCRTC
    lea rdx, [drm_crtc_save]
    syscall

    ; Drop DRM master so the next session (gdm/Xorg) can take it.
    mov rax, SYS_IOCTL
    mov rdi, [drm_fd]
    mov esi, DRM_IOCTL_DROP_MASTER
    xor edx, edx
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
.ga_done:
    pop r12
    pop rbx
    ret
.ga_full:
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
    jmp .agv_adv
.agv_fg:
    mov [r13 + 4], eax
    jmp .agv_adv
.agv_bg:
    mov [r13 + 8], eax
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

    ; GC foreground.
    mov edi, [rbx + 8]
    call gc_lookup
    test rax, rax
    jz .pfr_done
    mov r15d, [rax + 4]                      ; foreground colour

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
    call fb_fill
    add r14, 8
    dec ebp
    jmp .pfr_loop
.pfr_done:
    ; Recomposite only if the dst is a window (pixmap fills don't show
    ; until CopyArea'd to a window).
    mov edi, [rbx + 4]
    call window_lookup
    test rax, rax
    jz .pfr_ret
    call recomposite_screen
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
    sub rsp, 64
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
    ; dst = backing + (dy*backing_w + dst_x0)*4
    mov ecx, eax
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
    call recomposite_screen
.pi_ret:
    add rsp, 64
    pop rbp
    pop r15
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

    movsx r14d, word [r13 + 8]             ; win x
    movsx eax, word [r13 + 10]             ; win y
    mov [rsp + 16], eax
    movzx eax, word [r13 + 40]            ; backing_w (stride)
    mov [rsp + 0], eax
    movzx eax, word [r13 + 42]            ; backing_h
    mov [rsp + 8], eax
    mov rbx, [r13 + 32]                    ; backing ptr
    movzx eax, word [drm_modes_buf + 14]  ; screen h
    mov [rsp + 48], eax
    movzx r15d, word [drm_modes_buf + 4]  ; screen w

    ; X clip. win x in r14d.
    xor r8d, r8d                           ; src_x0
    mov r9d, r14d                          ; dst_x0 = x
    test r14d, r14d
    jns .bw_dx_ok
    mov r8d, r14d
    neg r8d                                 ; src_x0 = -x
    xor r9d, r9d                            ; dst_x0 = 0
.bw_dx_ok:
    mov [rsp + 24], r9d                     ; dst_x0
    mov [rsp + 32], r8d                     ; src_x0
    ; copy_w = min(backing_w - src_x0, screen_w - dst_x0)
    mov eax, [rsp + 0]
    sub eax, r8d
    jle .bw_done
    mov edx, r15d
    sub edx, r9d
    jle .bw_done
    cmp eax, edx
    jle .bw_cw
    mov eax, edx
.bw_cw:
    mov [rsp + 40], eax                     ; copy_w

    xor r12d, r12d                          ; ry = 0
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
    rep movsd
.bw_row_next:
    inc r12d
    jmp .bw_row
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
    jge .cpx_done
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
    mov rdi, r13
    movzx esi, word [r12 + 40]               ; backing_w (stride)
    movzx edx, word [r12 + 42]               ; backing_h
    mov r11d, [r12 + 44]                      ; back_pixel
    call fb_fill
    call recomposite_screen
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
    sub rsp, 112
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

    ; --- Copy rows. r12d = row 0..copy_h-1
    xor r12d, r12d
.cpa_row:
    cmp r12d, [rsp + 88]
    jge .cpa_blit_done
    ; src row ptr = src_ptr + ((sy+row)*src_stride + sx)*4
    mov eax, [rsp + 56]
    add eax, r12d
    imul eax, [rsp + 16]
    add eax, [rsp + 48]
    mov rsi, [rsp + 0]
    lea rsi, [rsi + rax*4]
    ; dst row ptr = dst_ptr + ((dy+row)*dst_stride + dx)*4
    mov eax, [rsp + 72]
    add eax, r12d
    imul eax, [rsp + 24]
    add eax, [rsp + 64]
    mov rdi, [rsp + 8]
    lea rdi, [rdi + rax*4]
    mov ecx, [rsp + 80]                      ; copy_w
    rep movsd
    inc r12d
    jmp .cpa_row
.cpa_blit_done:
    ; If dst is a window, recomposite.
    mov edi, [rbx + 8]
    call window_lookup
    test rax, rax
    jz .cpa_done
    call recomposite_screen
.cpa_done:
    add rsp, 112
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
    call recomposite_screen
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
    ; Destination is root (or pointer/focus, which we don't track). If
    ; root has a redirect owner (the WM), deliver there; else drop.
    cmp r12d, X_ROOT_WINDOW
    jne .se_done
    mov edi, X_ROOT_WINDOW
    call window_lookup
    test rax, rax
    jz .se_done
    movsx eax, byte [rax + 30]                ; root.redirect_owner
    cmp eax, 0
    jl .se_done
    mov r13d, eax

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
    ; Unhandled minor — leave it (logged by the generic request logger).
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

; --- QueryPictFormats: report 3 standard formats (ARGB32, RGB24, A8) and
;     one screen mapping our depth-24 + depth-32 visuals to formats.
;     libXrender BLOCKS on this during setup, so it must reply. 160-byte
;     reply (32 fixed + 128 variable).
.hr_query_pict_formats:
    mov eax, ebx
    call client_meta_addr
    mov r12, rax                             ; meta (req ptr no longer needed)
    ; Zero the 160-byte reply region.
    lea rdi, [reply_buf]
    xor eax, eax
    mov ecx, 20
    rep stosq
    ; --- fixed reply header ---
    mov byte  [reply_buf + 0], 1             ; reply
    mov ecx, [r12 + 8]                       ; seq
    mov [reply_buf + 2], cx
    mov dword [reply_buf + 4], 32            ; reply length (variable 4-byte units)
    mov dword [reply_buf + 8], 3             ; numFormats
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
    ; --- PICTSCREEN 0 @ 116 ---
    mov dword [reply_buf + 116], 2           ; numDepths
    mov dword [reply_buf + 120], 0x31        ; fallback format (RGB24)
    ; PICTDEPTH depth 24 @ 124
    mov byte  [reply_buf + 124], 24          ; depth
    mov word  [reply_buf + 126], 1           ; numVisuals
    mov dword [reply_buf + 132], 0x20        ; visual id (depth-24)
    mov dword [reply_buf + 136], 0x31        ; → RGB24
    ; PICTDEPTH depth 32 @ 140
    mov byte  [reply_buf + 140], 32
    mov word  [reply_buf + 142], 1
    mov dword [reply_buf + 148], 0x21        ; visual id (depth-32)
    mov dword [reply_buf + 152], 0x30        ; → ARGB32
    ; --- subpixel order @ 156 (SubPixelUnknown = 0) stays 0 ---
    mov edi, [r12]                           ; fd
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    mov rdx, 160
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
    jge .rcp_done
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
    mov edi, [rbx + 8]                        ; dst picture
    call picture_lookup
    test rax, rax
    jz .rfr_done
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
    call fb_fill
    add rbp, 8
    dec dword [rsp + 0]
    jmp .rfr_loop
.rfr_recomp:
    ; If the dst drawable is a window, recomposite to show it.
    mov edi, [rsp + 8]
    call window_lookup
    test rax, rax
    jz .rfr_done
    call recomposite_screen
.rfr_done:
    add rsp, 16
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
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
    call recomposite_screen
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
    mov edi, [rbx + 16]
    call picture_lookup
    test rax, rax
    jz .rc_done
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
    ; dst pixel ptr → rdi
    imul eax, [co_dst_stride]
    add eax, ebp
    mov rdi, [co_dst_ptr]
    lea rdi, [rdi + rax*4]
    ; --- fetch src pixel → esi (ARGB) ---
    cmp dword [co_src_solid], 1
    je .rc_src_solid
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
    call recomposite_screen
.rc_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; handle_get_selection_owner — edi = slot. GetSelectionOwner (opcode 23).
; Replies owner = None (0): we don't track selections yet. glass queries
; this during init and BLOCKS on the reply, so it must be answered.
; ----------------------------------------------------------------------------
handle_get_selection_owner:
    push rbx
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1                     ; reply
    mov byte [rdi + 1], 0
    mov ecx, [rax + 8]                        ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0                    ; length
    mov dword [rdi + 8], 0                    ; owner = None
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
    ; --- write the raw ARGB backing to /tmp/frame_win.raw (first backed win) ---
    mov rax, SYS_OPEN
    lea rdi, [dump_path]
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
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
