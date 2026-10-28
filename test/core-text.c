/* core-text: draw "A" with each of the four old text calls and print the
 * font width and the colour of a few pixels.
 *
 * xterm, rxvt and ssh-askpass draw text this way, in a font the server
 * holds. frame dropped these calls, so their windows came up blank. */
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
    Window w = XCreateWindow(d, root, 200, 200, 100, 40, 0, CopyFromParent, InputOutput,
                             CopyFromParent, CWBackPixel | CWOverrideRedirect, &a);
    XMapWindow(d, w);
    XSync(d, False);
    usleep(200000);

    XFontStruct *f = XLoadQueryFont(d, "fixed");
    if (!f) return 1;
    XGCValues v = { .foreground = 0xff0000, .background = 0x0000ff, .font = f->fid };
    GC gc = XCreateGC(d, w, GCForeground | GCBackground | GCFont, &v);
    XChar2b a16 = { 0, 'A' }, box = { 0x25, 0x00 };   /* U+2500 is not in the font */
    XDrawImageString(d, w, gc, 10, 20, "A", 1);
    XDrawString(d, w, gc, 40, 20, "A", 1);
    XDrawString16(d, w, gc, 60, 20, &a16, 1);
    XDrawImageString16(d, w, gc, 80, 20, &box, 1);
    XSync(d, False);
    usleep(300000);

    /* the top of the A is column 2 of row 2; row 7 is its bar, columns 0-4 */
    int at[7][2] = { { 12, 11 }, { 15, 16 }, { 42, 11 }, { 45, 16 }, { 62, 11 },
                     { 80, 11 }, { 81, 11 } };
    printf("width %d:", f->max_bounds.width);
    for (int i = 0; i < 7; i++) {
        XImage *g = XGetImage(d, root, 200 + at[i][0], 200 + at[i][1], 1, 1, AllPlanes, ZPixmap);
        if (!g) return 1;
        printf(" %06lx", XGetPixel(g, 0, 0) & 0xffffff);
    }
    printf("\n");
    return 0;
}
