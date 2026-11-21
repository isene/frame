// A GL window that does not fill the panel goes on a spare layer of the
// panel (direct_scanout = 2): frame shows its buffer as it is, with no
// copy. A popup over the window takes it off the layer again, and its
// newest frame shows under the popup. Prints what a screenshot sees.
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
xcb_void_cookie_t xcb_present_pixmap(
    xcb_connection_t *c, uint32_t window, uint32_t pixmap, uint32_t serial,
    uint32_t valid, uint32_t update, int16_t x_off, int16_t y_off,
    uint32_t target_crtc, uint32_t wait_fence, uint32_t idle_fence,
    uint32_t options, uint64_t target_msc, uint64_t divisor,
    uint64_t remainder, uint32_t notifies_len, const void *notifies);

typedef struct { unsigned int sequence; } xcb_dri3_query_version_cookie_t;
xcb_dri3_query_version_cookie_t xcb_dri3_query_version(
    xcb_connection_t *c, uint32_t major, uint32_t minor);
void *xcb_dri3_query_version_reply(
    xcb_connection_t *c, xcb_dri3_query_version_cookie_t cookie,
    xcb_generic_error_t **e);

enum { X = 100, Y = 80, W = 64, H = 32, SIZE = W * H * 4 };

static xcb_pixmap_t buffer(xcb_connection_t *c, xcb_window_t win, uint32_t colour)
{
    int fd = memfd_create("layer", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, SIZE) < 0) { puts("layer: no memfd"); exit(1); }
    uint32_t *px = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    for (int i = 0; i < W * H; i++) px[i] = colour;
    munmap(px, SIZE);
    xcb_pixmap_t pix = xcb_generate_id(c);
    xcb_generic_error_t *e = xcb_request_check(c,        // xcb closes fd
        xcb_dri3_pixmap_from_buffer_checked(c, pix, win, SIZE, W, H, W * 4,
                                            24, 32, fd));
    if (e) { puts("layer: no dri3 pixmap"); exit(1); }
    return pix;
}

static void settle(xcb_connection_t *c)     // frame has drawn what it got
{
    free(xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL));
    usleep(300000);
}

static uint32_t pixel(xcb_connection_t *c, xcb_window_t root, int x, int y)
{
    xcb_get_image_reply_t *r = xcb_get_image_reply(c,
        xcb_get_image(c, XCB_IMAGE_FORMAT_Z_PIXMAP, root, x, y, 1, 1, ~0u), NULL);
    if (!r) return 0xdead;
    uint32_t v = *(uint32_t *)xcb_get_image_data(r) & 0xffffff;
    free(r);
    return v;
}

int main(void)
{
    xcb_connection_t *c = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(c)) { puts("layer: no display"); return 1; }
    xcb_screen_t *s = xcb_setup_roots_iterator(xcb_get_setup(c)).data;

    void *v = xcb_dri3_query_version_reply(c, xcb_dri3_query_version(c, 1, 2), NULL);
    if (!v) { puts("layer: no dri3"); return 1; }   // Mesa asks this first
    free(v);

    xcb_window_t win = xcb_generate_id(c);
    xcb_create_window(c, s->root_depth, win, s->root, X, Y, W, H, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, s->root_visual, 0, NULL);
    xcb_map_window(c, win);
    settle(c);

    xcb_present_pixmap(c, win, buffer(c, win, 0x00ff00), 1, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, NULL);
    settle(c);
    uint32_t on_layer = pixel(c, s->root, X + 10, Y + 10);

    uint32_t over = 1;                       // override-redirect
    xcb_window_t pop = xcb_generate_id(c);
    xcb_create_window(c, s->root_depth, pop, s->root, X + 40, Y, 20, 10, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, s->root_visual,
                      XCB_CW_OVERRIDE_REDIRECT, &over);
    xcb_map_window(c, pop);
    xcb_gcontext_t gc = xcb_generate_id(c);
    uint32_t red = 0xff0000;
    xcb_create_gc(c, gc, pop, XCB_GC_FOREGROUND, &red);
    xcb_rectangle_t all = { 0, 0, 20, 10 };
    xcb_poly_fill_rectangle(c, pop, gc, 1, &all);

    xcb_present_pixmap(c, win, buffer(c, win, 0xffff00), 2, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, NULL);
    settle(c);
    uint32_t left = pixel(c, s->root, X + 10, Y + 10);
    uint32_t popup = pixel(c, s->root, X + 45, Y + 5);
    printf("layer %06x, left %06x under %06x\n", on_layer, left, popup);
    return 0;
}
