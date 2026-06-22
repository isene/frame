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
%define DRM_IOCTL_MODE_CREATE_DUMB     0xC02064B2
%define DRM_IOCTL_MODE_MAP_DUMB        0xC01064B3
%define DRM_IOCTL_MODE_DESTROY_DUMB    0xC00464B4

%define SYS_POLL        7
%define SYS_MMAP        9
%define SYS_MUNMAP      11
%define SYS_NANOSLEEP   35
%define PROT_RW         3            ; PROT_READ | PROT_WRITE
%define MAP_SHARED      1

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
; demand-pages; the kernel never allocates physical RAM for an 8 KB buf
; the client never connects on). Committed cost at startup is ~2 KB
; (clients_meta is touched by init_clients).
%define MAX_CLIENTS      128
%define CLIENT_META_SIZE 16
%define CLIENT_BUF_SIZE  8192
%define CSTATE_SETUP     0
%define CSTATE_RUNNING   1
clients_meta:       resb MAX_CLIENTS * CLIENT_META_SIZE
clients_bufs:       resb MAX_CLIENTS * CLIENT_BUF_SIZE

; pollfd_buf[17] — listen_fd + up to 16 client fds. Rebuilt each poll
; iteration (sub-microsecond — 17 × 8 = 136 bytes of writes).
pollfd_buf:         resb (MAX_CLIENTS + 1) * 8

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

; ---- Phase 4b window table ------------------------------------------------
; windows[MAX_WINDOWS] — one 32-byte record per live window. Slot 0
; pre-occupied at startup by the root window (XID = X_ROOT_WINDOW). A
; slot with xid = 0 is empty.
;
; Layout (32 bytes):
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
;   +30 pad (2)
%define MAX_WINDOWS      512
%define WINDOW_REC_SIZE  32
windows:            resb MAX_WINDOWS * WINDOW_REC_SIZE

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
predef_atom_stream:
    db 7, "PRIMARY"
    db 9, "SECONDARY"
    db 3, "ARC"
    db 4, "ATOM"
    db 6, "BITMAP"
    db 8, "CARDINAL"
    db 8, "COLORMAP"
    db 6, "CURSOR"
    db 11, "CUT_BUFFER0"
    db 11, "CUT_BUFFER1"
    db 11, "CUT_BUFFER2"
    db 11, "CUT_BUFFER3"
    db 11, "CUT_BUFFER4"
    db 11, "CUT_BUFFER5"
    db 11, "CUT_BUFFER6"
    db 11, "CUT_BUFFER7"
    db 8, "DRAWABLE"
    db 4, "FONT"
    db 7, "INTEGER"
    db 6, "PIXMAP"
    db 5, "POINT"
    db 9, "RECTANGLE"
    db 16, "RESOURCE_MANAGER"
    db 13, "RGB_COLOR_MAP"
    db 12, "RGB_BEST_MAP"
    db 12, "RGB_BLUE_MAP"
    db 15, "RGB_DEFAULT_MAP"
    db 12, "RGB_GRAY_MAP"
    db 13, "RGB_GREEN_MAP"
    db 11, "RGB_RED_MAP"
    db 6, "STRING"
    db 8, "VISUALID"
    db 6, "WINDOW"
    db 10, "WM_COMMAND"
    db 8, "WM_HINTS"
    db 16, "WM_CLIENT_MACHINE"
    db 12, "WM_ICON_NAME"
    db 12, "WM_ICON_SIZE"
    db 7, "WM_NAME"
    db 15, "WM_NORMAL_HINTS"
    db 13, "WM_SIZE_HINTS"
    db 13, "WM_ZOOM_HINTS"
    db 9, "MIN_SPACE"
    db 10, "NORM_SPACE"
    db 9, "MAX_SPACE"
    db 9, "END_SPACE"
    db 13, "SUPERSCRIPT_X"
    db 13, "SUPERSCRIPT_Y"
    db 11, "SUBSCRIPT_X"
    db 11, "SUBSCRIPT_Y"
    db 18, "UNDERLINE_POSITION"
    db 19, "UNDERLINE_THICKNESS"
    db 16, "STRIKEOUT_ASCENT"
    db 17, "STRIKEOUT_DESCENT"
    db 12, "ITALIC_ANGLE"
    db 8, "X_HEIGHT"
    db 10, "QUAD_WIDTH"
    db 6, "WEIGHT"
    db 10, "POINT_SIZE"
    db 10, "RESOLUTION"
    db 9, "COPYRIGHT"
    db 6, "NOTICE"
    db 9, "FONT_NAME"
    db 11, "FAMILY_NAME"
    db 9, "FULL_NAME"
    db 10, "CAP_HEIGHT"
    db 8, "WM_CLASS"
    db 16, "WM_TRANSIENT_FOR"
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
    jne .check_watch_input
    cmp dword [rdi + 4], 'obe-'
    jne .check_watch_input
    cmp dword [rdi + 8], 'inpu'
    jne .check_watch_input
    cmp word [rdi + 12], 't'             ; 't' + NUL
    jne .check_watch_input
    call do_probe_input
    xor edi, edi
    mov rax, SYS_EXIT
    syscall
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

.main:
    call announce_listening
    call socket_setup
    test rax, rax
    js .die_bind
    call init_atoms
    call init_clients
    call init_windows
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
    mov dword [rdi + 0], X_RELEASE_NUMBER
    mov dword [rdi + 4], X_RID_BASE
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
    jge .sl_poll
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
.sl_poll:
    mov rax, SYS_POLL
    lea rdi, [pollfd_buf]
    mov esi, MAX_CLIENTS + 1
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
    jge .sl_iter
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
    mov edi, r13d
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
    cmp eax, 4
    je .dr_destroy_window
    cmp eax, 8
    je .dr_map_window
    cmp eax, 10
    je .dr_unmap_window
    cmp eax, 12
    je .dr_configure_window
    cmp eax, 14
    je .dr_get_geometry
    cmp eax, 15
    je .dr_query_tree
    cmp eax, 16
    je .dr_intern_atom
    cmp eax, 20
    je .dr_get_property
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
    ; Unhandled — already logged.
    jmp .dr_done

.dr_intern_atom:
    mov edi, ebx
    call handle_intern_atom
    jmp .dr_done

.dr_get_property:
    mov edi, ebx
    call handle_get_property
    jmp .dr_done

.dr_create_gc:
    ; No reply needed; we don't track GC state yet (phase 4f). Silently
    ; accept so clients that always create a GC at startup (xdpyinfo,
    ; libX11 internals) proceed instead of hanging on the next round-trip.
    jmp .dr_done

.dr_query_extension:
    mov edi, ebx
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
handle_query_extension:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0
    mov ecx, [r12 + 8]                       ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0                   ; present=0 + 3 zero bytes
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
; handle_get_property — edi = slot. Phase 4a stand-in: every property is
; reported as "doesn't exist" (format=0, type=None, length=0). Real
; property storage lands in phase 4c (window tree + properties).
;
; Reply (32 bytes):
;   +0 1 (Reply)          +1 format (0 = doesn't exist)
;   +2 seq (u16)          +4 reply length (4u, = 0)
;   +8 type (ATOM, 0 = None)
;   +12 bytes-after (u32)
;   +16 value length (u32)
;   +20..31 pad
; ============================================================================
handle_get_property:
    push rbx
    push r12
    mov ebx, edi
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 0                    ; format = 0
    mov ecx, [r12 + 8]                       ; seq
    mov [rdi + 2], cx
    mov dword [rdi + 4], 0
    mov dword [rdi + 8], 0                   ; type = None
    mov dword [rdi + 12], 0                  ; bytes-after
    mov dword [rdi + 16], 0                  ; value length
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
    mov ebx, edi                             ; slot
    mov r13, rsi                             ; request ptr
    mov eax, ebx
    call client_meta_addr
    mov r12, rax

    movzx ecx, byte [r13 + 5]                ; count of keycodes requested
    ; Clamp at 1024 to keep the reply within reply_buf (16 KB) with
    ; room to spare. count is u8 max 255 → 1020 bytes — safely under.

    lea rdi, [reply_buf]
    mov byte [rdi + 0], 1
    mov byte [rdi + 1], 1                    ; keysyms-per-keycode
    mov edx, [r12 + 8]                       ; seq
    mov [rdi + 2], dx
    mov [rdi + 4], ecx                       ; reply length in 4-byte units
    mov dword [rdi + 8], 0
    mov dword [rdi + 12], 0
    mov dword [rdi + 16], 0
    mov dword [rdi + 20], 0
    mov dword [rdi + 24], 0
    mov dword [rdi + 28], 0

    ; Body: count CARD32 zeros (= NoSymbol). Just clear the bytes.
    push rcx
    add rdi, 32
    mov eax, 0
    shl rcx, 2                               ; bytes (count * 4)
    push rcx
    rep stosb
    pop rcx
    add rcx, 32                              ; total bytes to write
    mov rdx, rcx
    pop rcx

    mov edi, [r12]
    mov rax, SYS_WRITE
    lea rsi, [reply_buf]
    syscall

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
    mov word  [rbx + 30], 0
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
    mov dword [r13], 0                       ; mark empty
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
    cmp r14d, 9                              ; CW_OVERRIDE_REDIRECT bit pos
    je .av_override
    cmp r14d, 11                             ; CW_EVENT_MASK bit pos
    je .av_event_mask
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

    ; Walk CW value-mask.
    mov ecx, [r12 + 28]
    test ecx, ecx
    jz .cw_done
    lea rdx, [r12 + 32]
    call apply_cw_values
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
    pop rbx
    ret

; ============================================================================
; handle_map_window — edi = slot, rsi = req ptr. Mark window's mapped flag.
;
; Request: +4 window
;
; No reply.
; ============================================================================
handle_map_window:
    push rbx
    mov ebx, edi
    mov edi, [rsi + 4]
    call window_lookup
    test rax, rax
    jz .mw_done
    mov byte [rax + 28], 1
.mw_done:
    pop rbx
    ret

; ============================================================================
; handle_unmap_window — symmetric to handle_map_window.
; ============================================================================
handle_unmap_window:
    push rbx
    mov ebx, edi
    mov edi, [rsi + 4]
    call window_lookup
    test rax, rax
    jz .uw_done
    mov byte [rax + 28], 0
.uw_done:
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
    mov ebx, edi
    mov r12, rsi
    mov edi, [r12 + 4]
    call window_lookup
    test rax, rax
    jz .cfgw_done
    mov r13, rax                             ; record ptr
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
    jz .cfgw_done
    add r14, 4
.cfgw_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
