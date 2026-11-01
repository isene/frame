/* held-key FIFO: a WM grabs Mod4+g the way tile binds a key, a plain
   window has the focus, and Mod4+g is held down on the fake keyboard long
   enough for the kernel to repeat it five times. Prints how many g presses
   the WM and the window each read. On X the WM owns the key until it is
   released, so the window reads none. FIFO is the pipe frame reads
   through --testinput. */
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

static int pad;

static void ev(int type, int code, int value) {
    struct input_event e = { .type = type, .code = code, .value = value };
    gettimeofday(&e.time, NULL);
    if (write(pad, &e, sizeof e) != sizeof e) _exit(2);
}

static void key(int code, int value) { ev(EV_KEY, code, value); ev(EV_SYN, SYN_REPORT, 0); }

static int presses(Display *d, int code) {    /* g presses read so far */
    int n = 0;
    while (XPending(d)) {
        XEvent e;
        XNextEvent(d, &e);
        if (e.type == KeyPress && (int)e.xkey.keycode == code) n++;
    }
    return n;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    Display *wm = XOpenDisplay(NULL), *d = XOpenDisplay(NULL);
    pad = open(argv[1], O_WRONLY);
    if (!wm || !d || pad < 0) return 2;
    int g = XKeysymToKeycode(wm, XK_g);
    XGrabKey(wm, g, Mod4Mask, DefaultRootWindow(wm), True, GrabModeAsync, GrabModeAsync);
    XSync(wm, False);

    XSetWindowAttributes a = { .override_redirect = True, .event_mask = KeyPressMask };
    Window w = XCreateWindow(d, DefaultRootWindow(d), 0, 0, 400, 300, 0, CopyFromParent,
                             InputOutput, CopyFromParent, CWOverrideRedirect | CWEventMask, &a);
    XMapWindow(d, w);
    XSync(d, False);
    XSetInputFocus(d, w, RevertToParent, CurrentTime);
    XSync(d, False);
    usleep(200000);

    key(KEY_LEFTMETA, 1);
    key(KEY_G, 1);
    for (int i = 0; i < 5; i++) key(KEY_G, 2);
    key(KEY_G, 0);
    key(KEY_LEFTMETA, 0);
    usleep(300000);
    XSync(wm, False);
    XSync(d, False);
    printf("wm %d, window %d\n", presses(wm, g), presses(d, g));
    return 0;
}
