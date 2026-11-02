/* regrab FIFO: tile's reload, as frame sees it. A WM grabs Mod4+g and
   Mod4+h, drops every grab with UngrabKey(AnyKey, AnyModifier), and grabs
   Mod4+h again. Another client grabs Mod4+j and keeps it. Then each key is
   pressed once. Prints who read each: g must reach the focused window,
   h the WM, j the other client. frame matched AnyKey as a real key, so
   the WM kept g. FIFO is the pipe frame reads through --testinput. */
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

static void key(int code, int value) { ev(EV_KEY, code, value); ev(EV_SYN, SYN_REPORT, 0); }

static void mod4(int code) {
    key(KEY_LEFTMETA, 1);
    key(code, 1);
    key(code, 0);
    key(KEY_LEFTMETA, 0);
}

static void count(Display *d, int *n) {    /* n[keycode] += presses read */
    XSync(d, False);
    while (XPending(d)) {
        XEvent e;
        XNextEvent(d, &e);
        if (e.type == KeyPress) n[e.xkey.keycode & 255]++;
    }
}

static void grab(Display *d, int kc) {    /* tile grabs each bind with Lock and NumLock */
    unsigned int extra[] = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask };
    for (int i = 0; i < 4; i++)
        XGrabKey(d, kc, Mod4Mask | extra[i], DefaultRootWindow(d), True, GrabModeAsync, GrabModeAsync);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    Display *wm = XOpenDisplay(NULL), *other = XOpenDisplay(NULL), *d = XOpenDisplay(NULL);
    pad = open(argv[1], O_WRONLY);
    if (!wm || !other || !d || pad < 0) return 2;
    int g = XKeysymToKeycode(wm, XK_g), h = XKeysymToKeycode(wm, XK_h), j = XKeysymToKeycode(wm, XK_j);
    grab(other, j);
    XSync(other, False);
    grab(wm, g);
    grab(wm, h);
    XSync(wm, False);
    XUngrabKey(wm, AnyKey, AnyModifier, DefaultRootWindow(wm));
    grab(wm, h);
    XSync(wm, False);

    XSetWindowAttributes a = { .override_redirect = True, .event_mask = KeyPressMask };
    Window w = XCreateWindow(d, DefaultRootWindow(d), 0, 0, 400, 300, 0, CopyFromParent,
                             InputOutput, CopyFromParent, CWOverrideRedirect | CWEventMask, &a);
    XMapWindow(d, w);
    XSync(d, False);
    XSetInputFocus(d, w, RevertToParent, CurrentTime);
    XSync(d, False);
    usleep(200000);

    mod4(KEY_G);
    mod4(KEY_H);
    mod4(KEY_J);
    usleep(300000);
    int nw[256] = { 0 }, no[256] = { 0 }, nd[256] = { 0 };
    count(wm, nw);
    count(other, no);
    count(d, nd);
    printf("g: wm %d window %d, h: wm %d, j: other %d\n", nw[g], nd[g], nw[h], no[j]);
    return 0;
}
