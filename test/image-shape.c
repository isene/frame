/* image-shape: fill a square shape with a small picture, scaled up ten
 * times, and print the colour of each quarter of the square.
 *
 * LibreOffice draws every photo this way: a shape filled with the photo
 * through a scale. frame filled the shape with the photo's first pixel. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrender.h>
#include <stdio.h>
#include <unistd.h>

int main(void)
{
    Display *d = XOpenDisplay(NULL);
    if (!d) return 1;
    int scr = DefaultScreen(d);
    Window root = RootWindow(d, scr);
    XSetWindowAttributes a = { .background_pixel = 0, .override_redirect = True };
    Window w = XCreateWindow(d, root, 200, 200, 100, 100, 0, CopyFromParent, InputOutput,
                             CopyFromParent, CWBackPixel | CWOverrideRedirect, &a);
    XMapWindow(d, w);
    XSync(d, False);
    usleep(200000);

    /* 2x2 picture: red, green / blue, white. The top byte is 0, as a
       24-bit picture has no alpha and the client need not fill it. */
    static unsigned px[4] = { 0xff0000, 0x00ff00, 0x0000ff, 0xffffff };
    Pixmap pm = XCreatePixmap(d, w, 2, 2, 24);
    GC gc = XCreateGC(d, pm, 0, NULL);
    XImage *im = XCreateImage(d, DefaultVisual(d, scr), 24, ZPixmap, 0, (char *)px, 2, 2, 32, 8);
    XPutImage(d, pm, gc, im, 0, 0, 0, 0, 2, 2);

    XRenderPictureAttributes pa = { .repeat = RepeatPad };
    Picture src = XRenderCreatePicture(d, pm, XRenderFindStandardFormat(d, PictStandardRGB24),
                                       CPRepeat, &pa);
    XTransform t = { { { XDoubleToFixed(0.1), 0, 0 },
                       { 0, XDoubleToFixed(0.1), 0 },
                       { 0, 0, XDoubleToFixed(1) } } };
    XRenderSetPictureTransform(d, src, &t);
    Picture dst = XRenderCreatePicture(d, w, XRenderFindVisualFormat(d, DefaultVisual(d, scr)), 0, NULL);

    /* one trapezoid: the square from (10,10) to (30,30) */
    XTrapezoid tr = { XDoubleToFixed(10), XDoubleToFixed(30),
                      { { XDoubleToFixed(10), XDoubleToFixed(10) }, { XDoubleToFixed(10), XDoubleToFixed(30) } },
                      { { XDoubleToFixed(30), XDoubleToFixed(10) }, { XDoubleToFixed(30), XDoubleToFixed(30) } } };
    XRenderCompositeTrapezoids(d, PictOpOver, src, dst, XRenderFindStandardFormat(d, PictStandardA8),
                               0, 0, &tr, 1);
    XSync(d, False);
    usleep(300000);

    int at[4][2] = { { 12, 12 }, { 27, 12 }, { 12, 27 }, { 27, 27 } };
    for (int i = 0; i < 4; i++) {
        XImage *g = XGetImage(d, root, 200 + at[i][0], 200 + at[i][1], 1, 1, AllPlanes, ZPixmap);
        if (!g) return 1;
        printf("%s%06lx", i ? " " : "", XGetPixel(g, 0, 0) & 0xffffff);
    }
    printf("\n");
    return 0;
}
