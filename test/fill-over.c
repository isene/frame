/* fill-over: lay half-black Over the left half of an orange window and an
 * invisible colour Over the right half, then print both colours.
 *
 * glass dims an idle window with a RENDER fill of half-black, op Over.
 * frame copied every fill as if the op were Src, so the window went
 * solid black. Over halves each channel: c86400 becomes 633100. */
#include <X11/Xlib.h>
#include <X11/extensions/Xrender.h>
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

    XGCValues v = { .foreground = 0xc86400 };
    GC gc = XCreateGC(d, w, GCForeground, &v);
    XFillRectangle(d, w, gc, 0, 0, 100, 100);
    Picture p = XRenderCreatePicture(d, w, XRenderFindVisualFormat(d, DefaultVisual(d, 0)), 0, NULL);
    XRenderColor half = { 0, 0, 0, 0x8000 }, none = { 0, 0, 0, 0 };
    XRenderFillRectangle(d, PictOpOver, p, &half, 0, 0, 50, 100);
    XRenderFillRectangle(d, PictOpOver, p, &none, 50, 0, 50, 100);
    XSync(d, False);
    usleep(300000);

    int at[2] = { 25, 75 };
    for (int i = 0; i < 2; i++) {
        XImage *g = XGetImage(d, root, 200 + at[i], 250, 1, 1, AllPlanes, ZPixmap);
        if (!g) return 1;
        printf("%s%06lx", i ? " " : "", XGetPixel(g, 0, 0) & 0xffffff);
    }
    printf("\n");
    return 0;
}
