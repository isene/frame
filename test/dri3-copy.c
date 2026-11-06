// A GL client hands frame its own buffer through DRI3, then asks frame to
// copy the window into it (Mesa does this for a front buffer). frame mapped
// such buffers read-only, so the copy crashed frame and the whole session.
// Prints the colour the copy left in the buffer, or why it could not.
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xcb/xcb.h>

xcb_void_cookie_t xcb_dri3_pixmap_from_buffer_checked(
    xcb_connection_t *c, xcb_pixmap_t pixmap, xcb_drawable_t drawable,
    uint32_t size, uint16_t width, uint16_t height, uint16_t stride,
    uint8_t depth, uint8_t bpp, int32_t fd);
typedef struct { unsigned int sequence; } xcb_dri3_query_version_cookie_t;
xcb_dri3_query_version_cookie_t xcb_dri3_query_version(
    xcb_connection_t *c, uint32_t major, uint32_t minor);
void *xcb_dri3_query_version_reply(
    xcb_connection_t *c, xcb_dri3_query_version_cookie_t cookie,
    xcb_generic_error_t **e);

int main(void)
{
    enum { W = 64, H = 32, SIZE = W * H * 4 };
    xcb_connection_t *c = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(c)) { puts("copy: no display"); return 1; }
    xcb_screen_t *s = xcb_setup_roots_iterator(xcb_get_setup(c)).data;

    xcb_window_t win = xcb_generate_id(c);
    xcb_create_window(c, s->root_depth, win, s->root, 0, 0, W, H, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, s->root_visual, 0, NULL);
    xcb_map_window(c, win);
    xcb_gcontext_t gc = xcb_generate_id(c);
    uint32_t orange = 0xff8000;
    xcb_create_gc(c, gc, win, XCB_GC_FOREGROUND, &orange);
    xcb_rectangle_t all = { 0, 0, W, H };
    xcb_poly_fill_rectangle(c, win, gc, 1, &all);

    void *v = xcb_dri3_query_version_reply(c, xcb_dri3_query_version(c, 1, 2), NULL);
    if (!v) { puts("copy: no dri3"); return 1; }    // Mesa asks this first
    free(v);

    int fd = memfd_create("dri3-copy", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, SIZE) < 0) { puts("copy: no memfd"); return 1; }
    uint32_t *px = mmap(NULL, SIZE, PROT_READ, MAP_SHARED, fd, 0);
    xcb_pixmap_t pix = xcb_generate_id(c);
    xcb_generic_error_t *e = xcb_request_check(c,       // xcb closes fd
        xcb_dri3_pixmap_from_buffer_checked(c, pix, win, SIZE, W, H, W * 4,
                                            24, 32, fd));
    if (e || xcb_connection_has_error(c)) { puts("copy: no dri3 pixmap"); return 1; }

    xcb_copy_area(c, win, pix, gc, 0, 0, 0, 0, W, H);
    void *r = xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL);
    if (!r) { puts("copy: frame died"); return 1; }
    free(r);
    printf("copy: %06x\n", px[5 * W + 5] & 0xffffff);
    return 0;
}
