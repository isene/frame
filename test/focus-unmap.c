/* focus-unmap: give a window the keyboard, hide it, and print what it was
   told. X says a hidden window that had the keyboard gets FocusOut. A
   terminal lets go of the keys it thinks are held when that arrives. */
#include <X11/Xlib.h>
#include <poll.h>
#include <stdio.h>

static int seen[40];

static void drain(Display *d, int ms) {
    struct pollfd p = { ConnectionNumber(d), POLLIN, 0 };
    XFlush(d);
    for (;;) {
        while (XPending(d)) { XEvent e; XNextEvent(d, &e); if (e.type < 40) seen[e.type]++; }
        if (poll(&p, 1, ms) <= 0) return;
    }
}

int main(void) {
    Display *d = XOpenDisplay(NULL);
    if (!d) return 2;
    Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 200, 100, 0, 0, 0);
    XSelectInput(d, w, FocusChangeMask | StructureNotifyMask);
    XMapWindow(d, w);
    drain(d, 300);
    XSetInputFocus(d, w, RevertToPointerRoot, CurrentTime);
    drain(d, 300);
    XUnmapWindow(d, w);
    drain(d, 500);
    printf("FocusIn %d, UnmapNotify %d, FocusOut %d\n", seen[FocusIn], seen[UnmapNotify], seen[FocusOut]);
    return 0;
}
