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

%define AF_UNIX         1
%define SOCK_STREAM     1
%define DEFAULT_DISPLAY 7

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
    call atoi_or_default
    mov [display_num], rax

.main:
    call announce_listening
    call socket_setup
    test rax, rax
    js .die_bind

.accept_loop:
    call do_accept                       ; blocks until a client arrives
    test rax, rax
    js .accept_loop
    mov [client_fd], rax

    mov rsi, log_accepted
    mov rdx, log_accepted_len
    call write_stderr

    call handle_client                   ; handles one client to disconnect

    mov rsi, log_client_gone
    mov rdx, log_client_gone_len
    call write_stderr

    mov rax, SYS_CLOSE
    mov rdi, [client_fd]
    syscall
    jmp .accept_loop

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
; handle_client — full lifecycle of one client connection.
;   1. read the 12-byte setup-request prefix + variable auth tail
;   2. validate byte-order ('l' or 'B') + version (11.0)
;   3. emit the setup reply (success header + setup info + screen + visuals)
;   4. enter a read loop, log each request opcode/length, drop the body
; ============================================================================
handle_client:
    push rbx
    ; --- 1. Read setup prefix ---
    mov rax, SYS_READ
    mov rdi, [client_fd]
    lea rsi, [setup_req]
    mov rdx, 12
    syscall
    cmp rax, 12
    jne .hc_setup_bad
    ; byte-order: 'l' = 0x6C (LSB-first), 'B' = 0x42 (MSB-first). We
    ; require 'l' for now; switching would mean byte-swapping every
    ; multibyte field on every read and write, which we won't do until
    ; a real big-endian client surfaces.
    cmp byte [setup_req], 'l'
    jne .hc_setup_bad
    ; protocol major must be 11
    mov ax, [setup_req + 2]
    cmp ax, X_PROTO_MAJOR
    jne .hc_setup_bad

    ; --- 1b. Drain auth tail so we leave the socket aligned to the first
    ; real request. Auth name length is at +6, data length at +8.
    movzx eax, word [setup_req + 6]      ; auth name length
    add eax, 3
    and eax, ~3
    movzx ecx, word [setup_req + 8]      ; auth data length
    add ecx, 3
    and ecx, ~3
    add eax, ecx
    test eax, eax
    jz .hc_emit_setup
    cmp eax, 4096
    ja .hc_setup_bad
    mov rdx, rax
    mov rax, SYS_READ
    mov rdi, [client_fd]
    lea rsi, [setup_req + 12]
    syscall
    cmp rax, rdx
    jne .hc_setup_bad

.hc_emit_setup:
    call emit_setup_reply

    ; --- 2. Request loop ---
.hc_req_loop:
    mov rax, SYS_READ
    mov rdi, [client_fd]
    lea rsi, [req_buf]
    mov rdx, 65536
    syscall
    test rax, rax
    jle .hc_done
    mov rbx, rax                         ; bytes available

    ; Log each well-formed request: opcode at +0, length (in 4-byte units)
    ; at +2. For phase 1 we just print and discard; phase 2 wires this to
    ; a real dispatch table.
    xor ecx, ecx
.hc_walk:
    cmp rcx, rbx
    jge .hc_req_loop
    mov rax, rbx
    sub rax, rcx
    cmp rax, 4
    jl .hc_req_loop
    movzx eax, byte [req_buf + rcx]      ; opcode
    push rcx
    mov rdi, rax
    movzx eax, word [req_buf + rcx + 2]  ; length in 4-byte units
    mov rsi, rax
    call log_request
    pop rcx
    movzx eax, word [req_buf + rcx + 2]
    shl eax, 2                           ; bytes
    test eax, eax
    jnz .hc_advance
    mov eax, 4                           ; defensive: never advance 0
.hc_advance:
    add rcx, rax
    jmp .hc_walk

.hc_setup_bad:
    mov rsi, log_setup_bad
    mov rdx, log_setup_bad_len
    call write_stderr
.hc_done:
    pop rbx
    ret

; ============================================================================
; emit_setup_reply — write the success setup reply to client_fd. Body is
; assembled in req_buf; only one screen, depths 24 and 32, one visual per
; depth, one pixmap format (depth-24-in-32-bpp).
; ============================================================================
emit_setup_reply:
    push rbx
    push r12
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
    mov rdi, [client_fd]
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
