/* close-flash: an app closes its window, and the WM shows the next tab, a
   terminal, in its place. frame painted the wallpaper for one frame in
   between: the flash when nsxiv quit back to glass. nsxiv destroys its window
   and then hangs up, so this does the same. Prints how many screen paints
   the close took (1 = straight to the terminal) and the colour then shown.
   Usage: close-flash <frame pid> <frame log> */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static Display *wm;

/* The WM: maps whatever asks, and remembers the last DestroyNotify. */
static Window destroyed;
static void wm_drain(int ms) {
    struct pollfd p = { ConnectionNumber(wm), POLLIN, 0 };
    XFlush(wm);
    for (;;) {
        while (XPending(wm)) {
            XEvent e;
            XNextEvent(wm, &e);
            if (e.type == MapRequest) XMapWindow(wm, e.xmaprequest.window);
            if (e.type == DestroyNotify) destroyed = e.xdestroywindow.window;
        }
        XFlush(wm);
        if (poll(&p, 1, ms) <= 0) return;
    }
}

/* Read the WM's events until a window is destroyed, then return at once,
   as tile does. */
static void wm_wait_destroy(void) {
    while (!destroyed) {
        XEvent e;
        XNextEvent(wm, &e);
        if (e.type == DestroyNotify) destroyed = e.xdestroywindow.window;
    }
}

/* Screen paints so far: the second number of frame's FBSTATE line. */
static long paints(int pid, const char *log) {
    kill(pid, SIGUSR1);
    usleep(300000);
    FILE *f = fopen(log, "r");
    if (!f) return -1;
    static char buf[1 << 20];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    for (size_t i = 0; i < n; i++) if (!buf[i]) buf[i] = ' ';
    char *last = NULL, *s = buf;
    while ((s = strstr(s, "FBSTATE back="))) last = s++;
    long back, count;
    if (!last || sscanf(last, "FBSTATE back=%ld %ld", &back, &count) != 2) return -1;
    return count;
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int pid = atoi(argv[1]);
    wm = XOpenDisplay(NULL);
    Display *term = XOpenDisplay(NULL), *app = XOpenDisplay(NULL);
    if (!wm || !term || !app) return 2;
    Window root = DefaultRootWindow(wm);
    XSelectInput(wm, root, SubstructureRedirectMask | SubstructureNotifyMask);
    wm_drain(100);

    Window t = XCreateSimpleWindow(term, root, 0, 0, 400, 300, 0, 0, 0x00ff00);
    XMapWindow(term, t);
    XFlush(term);
    wm_drain(200);
    Window a = XCreateSimpleWindow(app, root, 0, 0, 400, 300, 0, 0, 0xff0000);
    XMapWindow(app, a);
    XFlush(app);
    wm_drain(200);
    XUnmapWindow(wm, t);                        /* tabbed: the terminal hides */
    wm_drain(300);

    long before = paints(pid, argv[2]);
    XDestroyWindow(app, a);                     /* nsxiv quits */
    XCloseDisplay(app);
    wm_wait_destroy();
    XMapWindow(wm, t);                          /* the WM shows the terminal */
    wm_drain(300);
    long after = paints(pid, argv[2]);

    XImage *im = XGetImage(wm, root, 10, 10, 1, 1, AllPlanes, ZPixmap);
    unsigned long px = im ? XGetPixel(im, 0, 0) & 0xffffff : 0;
    printf("paints %ld, then %06lx\n", after - before, px);
    return 0;
}
