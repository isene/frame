/* see-through: put up a half see-through window, draw in it twice, and
 * print what the screen shows inside it.
 *
 * The window's pixels are red with half alpha. frame mixes them with the
 * background under the window. The second draw covers a small part, so
 * frame mixes both a whole-screen redraw and a small one. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    int scr = DefaultScreen(d);
    Window root = RootWindow(d, scr);
    XVisualInfo vi;
    if (!XMatchVisualInfo(d, scr, 32, TrueColor, &vi)) { puts("no 32-bit visual"); return 1; }
    XSetWindowAttributes a = { 0 };
    a.colormap = XCreateColormap(d, root, vi.visual, AllocNone);
    a.background_pixel = 0x80ff0000;
    a.border_pixel = 0;
    a.override_redirect = True;
    Window w = XCreateWindow(d, root, 100, 100, 300, 200, 0, 32, InputOutput, vi.visual,
                             CWColormap | CWBackPixel | CWBorderPixel | CWOverrideRedirect, &a);
    GC gc = XCreateGC(d, w, 0, NULL);
    XSetForeground(d, gc, 0x80ff0000);
    XMapWindow(d, w);
    XFillRectangle(d, w, gc, 0, 0, 300, 200);
    XSync(d, False);
    usleep(300000);
    XFillRectangle(d, w, gc, 10, 10, 50, 20);
    XSync(d, False);
    usleep(300000);
    XImage *in = XGetImage(d, root, 250, 200, 1, 1, AllPlanes, ZPixmap);
    XImage *out = XGetImage(d, root, 50, 50, 1, 1, AllPlanes, ZPixmap);
    if (!in || !out) return 1;
    printf("inside %06lx, outside %06lx\n", XGetPixel(in, 0, 0) & 0xffffff, XGetPixel(out, 0, 0) & 0xffffff);
    return 0;
}
