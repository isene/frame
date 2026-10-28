/* fill-poly: fill a triangle and a square given as relative points, and
 * print the colour of pixels inside, outside and on the edges.
 *
 * ssh-askpass draws its button edges with FillPoly. frame dropped the
 * call, so the buttons came up flat. Pixel (x, y) counts when the point
 * (x, y) is inside; on an edge, only when the inside is to its right or
 * below. Xvfb gives the same colours.
 *
 * A shape wholly left of the window must draw nothing. frame's rectangle
 * fill once filled the whole row there instead, for FillPoly and for
 * PolyFillRectangle alike. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    Window root = DefaultRootWindow(d);
    XSetWindowAttributes a = { .background_pixel = 0, .override_redirect = True };
    Window w = XCreateWindow(d, root, 200, 200, 100, 100, 0, CopyFromParent, InputOutput,
                             CopyFromParent, CWBackPixel | CWOverrideRedirect, &a);
    XMapWindow(d, w);
    XSync(d, False);
    usleep(200000);

    XGCValues v = { .foreground = 0x00ff00 };
    GC gc = XCreateGC(d, w, GCForeground, &v);
    XPoint tri[3] = { { 10, 10 }, { 50, 10 }, { 10, 50 } };
    XPoint square[4] = { { 60, 60 }, { 20, 0 }, { 0, 20 }, { -20, 0 } };
    XFillPolygon(d, w, gc, tri, 3, Convex, CoordModeOrigin);
    XFillPolygon(d, w, gc, square, 4, Convex, CoordModePrevious);
    XPoint off[3] = { { 7, 85 }, { -14, 88 }, { -14, 140 } };
    XFillPolygon(d, w, gc, off, 3, Convex, CoordModeOrigin);
    XFillRectangle(d, w, gc, -50, 90, 20, 5);
    XSync(d, False);
    usleep(300000);

    /* row 10 meets the slope at x 50: pixel 49 is in, 50 out */
    int at[8][2] = { { 12, 12 }, { 45, 45 }, { 49, 10 }, { 50, 10 },
                     { 60, 60 }, { 79, 79 }, { 80, 70 }, { 50, 93 } };
    for (int i = 0; i < 8; i++) {
        XImage *g = XGetImage(d, root, 200 + at[i][0], 200 + at[i][1], 1, 1, AllPlanes, ZPixmap);
        if (!g) return 1;
        printf("%s%06lx", i ? " " : "", XGetPixel(g, 0, 0) & 0xffffff);
    }
    printf("\n");
    return 0;
}
