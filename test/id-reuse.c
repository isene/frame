/* id-reuse: an id that was a pixmap, freed, then given to a window, must
   find the window. frame keeps the last id that was no window, so a draw
   into a pixmap skips the 512 window slots; creating a window clears it.
   Draws into a pixmap, frees it, makes a window with the same id, fills it
   red and prints the colour the window then shows. */
#include <X11/Xlibint.h>
#include <X11/Xutil.h>
#include <stdio.h>

static XID next_id;
static XID (*real_alloc)(Display *);
static XID same_id(Display *d) { (void)d; return next_id; }

int main(void) {
    Display *d = XOpenDisplay(NULL);
    if (!d) return 2;
    Window root = DefaultRootWindow(d);
    GC gc = XCreateGC(d, root, 0, NULL);
    Pixmap p = XCreatePixmap(d, root, 10, 10, DefaultDepth(d, 0));
    XFillRectangle(d, p, gc, 0, 0, 10, 10);       /* a miss for every window */
    XSync(d, False);
    XFreePixmap(d, p);
    XSync(d, False);

    next_id = p;                                  /* the window gets p's id */
    real_alloc = d->resource_alloc;
    d->resource_alloc = same_id;
    XSetWindowAttributes a = { .override_redirect = True, .background_pixel = 0 };
    Window w = XCreateWindow(d, root, 0, 0, 200, 200, 0, CopyFromParent, InputOutput,
                             CopyFromParent, CWOverrideRedirect | CWBackPixel, &a);
    d->resource_alloc = real_alloc;
    XMapWindow(d, w);
    XSetForeground(d, gc, 0xff0000);
    XFillRectangle(d, w, gc, 0, 0, 200, 200);
    XSync(d, False);
    XImage *im = XGetImage(d, w, 100, 100, 1, 1, AllPlanes, ZPixmap);
    if (!im) return 3;
    printf("same id %s, %06lx\n", w == p ? "yes" : "no", XGetPixel(im, 0, 0) & 0xffffff);
    return 0;
}
