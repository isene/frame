/* tap FIFO KIND: touch a fake touchpad and print the button events a plain
   window gets, each with the "buttons held" field frame put in it.
     tap1   one finger down and up in 60 ms
     tap2   the same with two fingers
     quick  touch, press the pad's button, let go, lift, all in 130 ms
   FIFO is the pipe frame reads through --testinput. */
#include <X11/Xlib.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

static int pad;

static void ev(int type, int code, int value) {
    struct input_event e = { .type = type, .code = code, .value = value };
    gettimeofday(&e.time, NULL);
    if (write(pad, &e, sizeof e) != sizeof e) _exit(2);
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    const char *kind = argv[2];
    Display *d = XOpenDisplay(NULL);
    pad = open(argv[1], O_WRONLY);
    if (!d || pad < 0) return 2;

    XSetWindowAttributes a = { .override_redirect = True,
                               .event_mask = ButtonPressMask | ButtonReleaseMask };
    Window w = XCreateWindow(d, DefaultRootWindow(d), 0, 0, 400, 300, 0, CopyFromParent,
                             InputOutput, CopyFromParent, CWOverrideRedirect | CWEventMask, &a);
    XMapWindow(d, w);
    XWarpPointer(d, None, w, 0, 0, 0, 0, 100, 100);
    XSync(d, False);
    usleep(200000);

    int two = !strcmp(kind, "tap2");
    ev(EV_KEY, BTN_TOUCH, 1);
    if (two) ev(EV_KEY, BTN_TOOL_DOUBLETAP, 1);
    ev(EV_SYN, SYN_REPORT, 0);
    if (!strcmp(kind, "quick")) {
        usleep(40000); ev(EV_KEY, BTN_LEFT, 1); ev(EV_SYN, SYN_REPORT, 0);
        usleep(50000); ev(EV_KEY, BTN_LEFT, 0); ev(EV_SYN, SYN_REPORT, 0);
        usleep(40000);
    } else
        usleep(60000);
    if (two) ev(EV_KEY, BTN_TOOL_DOUBLETAP, 0);
    ev(EV_KEY, BTN_TOUCH, 0);
    ev(EV_SYN, SYN_REPORT, 0);

    const char *sep = "";
    for (;;) {                                  /* print until 500 ms pass with no event */
        while (XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type != ButtonPress && e.type != ButtonRelease) continue;
            printf("%s%s %u 0x%03x", sep, e.type == ButtonPress ? "press" : "release",
                   e.xbutton.button, e.xbutton.state);
            sep = ", ";
        }
        fd_set r;
        FD_ZERO(&r);
        FD_SET(ConnectionNumber(d), &r);
        struct timeval wait = { 0, 500000 };
        if (select(ConnectionNumber(d) + 1, &r, NULL, NULL, &wait) <= 0) break;
    }
    printf("\n");
    return 0;
}
