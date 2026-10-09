/* prop-watch: one client watches the properties of another client's
   window. A copy too big for one request is sent in pieces this way: the
   owner of the copy waits for PropertyNotify on the taker's window before
   it sends the next piece. Prints how many events each side got. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <poll.h>
#include <stdio.h>

static int count(Display *d, int ms) {
    struct pollfd p = { ConnectionNumber(d), POLLIN, 0 };
    int n = 0;
    XFlush(d);
    for (;;) {
        while (XPending(d)) { XEvent e; XNextEvent(d, &e); if (e.type == PropertyNotify) n++; }
        if (poll(&p, 1, ms) <= 0) return n;
    }
}

static void touch(Display *a, Window w, Atom prop) {
    XChangeProperty(a, w, prop, XA_STRING, 8, PropModeReplace, (unsigned char *)"x", 1);
    XDeleteProperty(a, w, prop);
    XSync(a, False);
}

int main(void) {
    Display *a = XOpenDisplay(NULL), *b = XOpenDisplay(NULL);
    if (!a || !b) return 2;
    Window w = XCreateSimpleWindow(a, DefaultRootWindow(a), 0, 0, 10, 10, 0, 0, 0);
    Atom prop = XInternAtom(a, "PROP_WATCH_TEST", False);
    XSelectInput(a, w, PropertyChangeMask);
    XSync(a, False);
    XSelectInput(b, w, PropertyChangeMask);
    XSync(b, False);
    touch(a, w, prop);
    int owner = count(a, 200), watcher = count(b, 200);

    XSelectInput(b, w, NoEventMask);
    XSync(b, False);
    touch(a, w, prop);
    int stopped = count(b, 200);

    /* A watcher that goes away while watching: the next client lands in
       its place and must hear nothing it did not ask for. */
    XSelectInput(b, w, PropertyChangeMask);
    XSync(b, False);
    XCloseDisplay(b);
    Display *c = XOpenDisplay(NULL);
    if (!c) return 2;
    XSync(c, False);
    touch(a, w, prop);
    int stranger = count(c, 200);
    count(a, 0);

    printf("owner %d, watcher %d, after it stopped %d, a new client in its place %d\n",
           owner, watcher, stopped, stranger);
    return 0;
}
