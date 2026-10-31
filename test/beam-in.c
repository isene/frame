/* beam-in: put up a green window, draw in it once, and print how much of
 * it the screen shows 0.3 s later and 1.2 s later.
 *
 * With beam = N in ~/.framerc, a new window fades in over N ms, cell by
 * cell, so the early look shows part of it. Without it, the whole window
 * is there at once. Each look prints all, part or none. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <unistd.h>

static const char *look(Display *d, Window root)
{
    XImage *im = XGetImage(d, root, 100, 100, 200, 200, AllPlanes, ZPixmap);
    if (!im) return "error";
    int green = 0;
    for (int y = 0; y < 200; y++)
        for (int x = 0; x < 200; x++)
            green += (XGetPixel(im, x, y) & 0xffffff) == 0x00ff00;
    XDestroyImage(im);
    return green == 200 * 200 ? "all" : green ? "part" : "none";
}

int main(void)
{
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    Window root = DefaultRootWindow(d);
    Window w = XCreateSimpleWindow(d, root, 100, 100, 200, 200, 0, 0, 0);
    GC gc = XCreateGC(d, w, 0, NULL);
    XSetForeground(d, gc, 0x00ff00);
    XMapWindow(d, w);
    XFillRectangle(d, w, gc, 0, 0, 200, 200);
    XSync(d, False);
    usleep(300000);
    const char *early = look(d, root);
    usleep(900000);
    printf("at 0.3 s %s, at 1.2 s %s\n", early, look(d, root));
    return 0;
}
