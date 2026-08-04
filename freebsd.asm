%include "freebsd.inc"

%macro FRAME_SYSCALL 0
    syscall
    jnc %%ok
    neg rax
%%ok:
%endmacro

%macro EV_SEND 0
    mov rax, SYS_SENDTO
    mov r10d, MSG_DONTWAIT
    xor r8d, r8d
    xor r9d, r9d
    FRAME_SYSCALL
    cmp rax, -EAGAIN
    jne %%ok
    inc dword [ev_dropped]
%%ok:
%endmacro

%macro FRAME_SIGACTION 0
    FRAME_SYSCALL
%endmacro
