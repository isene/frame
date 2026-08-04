%include "linux.inc"

%macro EV_SEND 0
    mov rax, SYS_SENDTO
    mov r10d, MSG_DONTWAIT
    xor r8d, r8d
    xor r9d, r9d
    syscall
    cmp rax, -11                 ; Linux EAGAIN
    jne %%ok
    inc dword [ev_dropped]
%%ok:
%endmacro

%macro FRAME_SYSCALL 0
    syscall
%endmacro

%macro FRAME_SIGACTION 0
    mov r10d, 8
    FRAME_SYSCALL
%endmacro
