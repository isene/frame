/* print-grab FIFO: a WM grabs Print, as tile's PrtSc bind does, and a popup
   holds the whole keyboard, as an open GTK menu does. Then Print and a are
   pressed once. Prints who read each: Print must reach the WM, so a
   screenshot can show the menu, and a the popup. frame sent every key to
   the popup. FIFO is the pipe frame reads through --testinput. */
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <sys/time.h>
#include <unistd.h>

static int pad;

static void ev(int type, int code, int value) {
    struct input_event e = { .type = type, .code = code, .value = value };
    gettimeofday(&e.time, NULL);
    if (write(pad, &e, sizeof e) != sizeof e) _exit(2);
}

static void tap(int code) {
    ev(EV_KEY, code, 1); ev(EV_SYN, SYN_REPORT, 0);
    ev(EV_KEY, code, 0); ev(EV_SYN, SYN_REPORT, 0);
}

static void count(Display *d, int *n) {    /* n[keycode] += presses read */
    XSync(d, False);
    while (XPending(d)) {
        XEvent e;
        XNextEvent(d, &e);
        if (e.type == KeyPress) n[e.xkey.keycode & 255]++;
    }
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    Display *wm = XOpenDisplay(NULL), *d = XOpenDisplay(NULL);
    pad = open(argv[1], O_WRONLY);
    if (!wm || !d || pad < 0) return 2;
    int pr = XKeysymToKeycode(wm, XK_Print), a = XKeysymToKeycode(wm, XK_a);
    unsigned int extra[] = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask };
    for (int i = 0; i < 4; i++)
        XGrabKey(wm, pr, extra[i], DefaultRootWindow(wm), True, GrabModeAsync, GrabModeAsync);
    XSync(wm, False);

    XSetWindowAttributes at = { .override_redirect = True, .event_mask = KeyPressMask };
    Window w = XCreateWindow(d, DefaultRootWindow(d), 0, 0, 200, 100, 0, CopyFromParent,
                             InputOutput, CopyFromParent, CWOverrideRedirect | CWEventMask, &at);
    XMapWindow(d, w);
    XSync(d, False);
    usleep(200000);
    if (XGrabKeyboard(d, w, False, GrabModeAsync, GrabModeAsync, CurrentTime) != GrabSuccess) return 3;
    XSync(d, False);
    usleep(100000);

    tap(pr - 8);
    tap(a - 8);
    usleep(300000);
    int nw[256] = { 0 }, nd[256] = { 0 };
    count(wm, nw);
    count(d, nd);
    printf("print: wm %d popup %d, a: wm %d popup %d\n", nw[pr], nd[pr], nw[a], nd[a]);
    return 0;
}
