/* overview FIFO: three windows the way tile leaves them (red and green on
   workspace 1, blue on workspace 3 and hidden), then Mod4+space, two Right
   presses and Enter on the fake keyboard. Prints the screen's pixels at
   each step and the workspace the WM is asked for. FIFO is the pipe frame
   reads through --testinput. The cells are for a 1920x1080 screen.
   "overview FIFO esc" instead opens it and presses Caps Lock, which the
   frame on FIFO must have remapped to Escape. */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <sys/time.h>
#include <unistd.h>

static int pad;
static Display *d, *wm;

static void ev(int type, int code, int value) {
    struct input_event e = { .type = type, .code = code, .value = value };
    gettimeofday(&e.time, NULL);
    if (write(pad, &e, sizeof e) != sizeof e) _exit(2);
}

static void key(int code, int down) { ev(EV_KEY, code, down); ev(EV_SYN, SYN_REPORT, 0); }

static void tap(int mod, int code) {
    if (mod) key(mod, 1);
    key(code, 1);
    key(code, 0);
    if (mod) key(mod, 0);
    usleep(300000);
}

static void px(int x, int y) {
    XImage *im = XGetImage(d, DefaultRootWindow(d), x, y, 1, 1, AllPlanes, ZPixmap);
    printf(" %06lx", im ? XGetPixel(im, 0, 0) & 0xffffff : 0UL);
    if (im) XDestroyImage(im);
}

static Window win(int x, int w, unsigned long colour, long desk) {
    Window r = DefaultRootWindow(d);
    Window v = XCreateSimpleWindow(d, r, x, 0, w, 1080, 0, 0, colour);
    XChangeProperty(d, v, XInternAtom(d, "_NET_WM_DESKTOP", False), XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&desk, 1);
    XMapWindow(d, v);
    GC gc = XCreateGC(d, v, 0, NULL);
    XSetForeground(d, gc, colour);
    XSync(d, False);
    usleep(100000);
    XFillRectangle(d, v, gc, 0, 0, w, 1080);
    XSync(d, False);
    usleep(100000);
    return v;
}

int main(int argc, char **argv) {
    if (argc < 2 || !(d = XOpenDisplay(NULL)) || !(wm = XOpenDisplay(NULL))) return 1;
    pad = open(argv[1], O_WRONLY);
    if (pad < 0) return 1;
    Window r = DefaultRootWindow(d);
    long zero = 0;
    XChangeProperty(d, r, XInternAtom(d, "_NET_CURRENT_DESKTOP", False), XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&zero, 1);
    win(0, 960, 0xff0000, 0);
    win(960, 960, 0x00ff00, 0);
    XUnmapWindow(d, win(0, 1920, 0x0000ff, 2));
    XSync(d, False);
    /* A second client plays the WM, to hear the overview's request. */
    XSelectInput(wm, DefaultRootWindow(wm), SubstructureRedirectMask);
    XSync(wm, False);
    usleep(200000);

    if (argc > 2) {                         /* "esc": the key that means Escape closes it */
        printf("open:");
        tap(KEY_LEFTMETA, KEY_SPACE);
        px(10, 10);
        printf(", caps lock as escape:");
        tap(0, KEY_CAPSLOCK);
        px(10, 10);
        printf("\n");
        return 0;
    }

    /* Cell 1 at x 24..379, cell 2 at 403.., cell 3 at 782..; rows 329..528. */
    printf("open:");
    tap(KEY_LEFTMETA, KEY_SPACE);
    px(10, 10); px(100, 450); px(300, 450); px(500, 450); px(900, 450); px(22, 450); px(781, 450);
    printf(", right 2:");
    tap(0, KEY_RIGHT);
    tap(0, KEY_RIGHT);
    px(22, 450); px(779, 450);
    printf(", enter:");
    tap(0, KEY_ENTER);
    px(100, 450); px(1500, 450);
    long asked = -1;
    while (XPending(wm)) {
        XEvent e;
        XNextEvent(wm, &e);
        if (e.type == ClientMessage &&
            e.xclient.message_type == XInternAtom(wm, "_NET_CURRENT_DESKTOP", True))
            asked = e.xclient.data.l[0];
    }
    printf(", asked for %ld\n", asked);
    return 0;
}
