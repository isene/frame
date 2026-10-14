/* caps-lock FIFO: turn caps lock on and off the way ~/bin/toggle-capslock
   does, type on a fake keyboard, and print the light and what a plain
   window reads. FIFO is the pipe frame reads through --testinput. frame
   must run with the Norwegian keymap, where AltGr+e is the euro sign. */
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

static int pad;
static Display *d;

static void ev(int type, int code, int value) {
    struct input_event e = { .type = type, .code = code, .value = value };
    gettimeofday(&e.time, NULL);
    if (write(pad, &e, sizeof e) != sizeof e) _exit(2);
}

static void key(int code, int down) { ev(EV_KEY, code, down); ev(EV_SYN, SYN_REPORT, 0); }

static void tap(int mod, int code) {          /* one key, with a modifier held or 0 */
    if (mod) key(mod, 1);
    key(code, 1);
    key(code, 0);
    if (mod) key(mod, 0);
}

static void no_answer(int sig) {
    (void)sig;
    static const char m[] = "no answer to GetIndicatorState\n";
    if (write(1, m, sizeof m - 1)) {}
    _exit(1);
}

static unsigned light(void) {                 /* bit 0 = the Caps Lock light */
    unsigned s = 0;
    alarm(2);
    XkbGetIndicatorState(d, XkbUseCoreKbd, &s);
    alarm(0);
    return s & 1;
}

static void typed(char *out) {                /* the keys read until 300 ms pass quiet */
    *out = 0;
    for (;;) {
        while (XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type != KeyPress) continue;
            char buf[8];
            KeySym ks = NoSymbol;
            XLookupString(&e.xkey, buf, sizeof buf, &ks, NULL);
            if (ks == XK_Shift_L || ks == XK_ISO_Level3_Shift || ks == XK_Mode_switch) continue;
            const char *name = XKeysymToString(ks);
            if (*out) strcat(out, " ");
            strcat(out, name ? name : "?");
        }
        fd_set r;
        FD_ZERO(&r);
        FD_SET(ConnectionNumber(d), &r);
        struct timeval wait = { 0, 300000 };
        if (select(ConnectionNumber(d) + 1, &r, NULL, NULL, &wait) <= 0) break;
    }
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    signal(SIGALRM, no_answer);
    d = XOpenDisplay(NULL);
    pad = open(argv[1], O_WRONLY);
    if (!d || pad < 0) return 2;

    XSetWindowAttributes a = { .override_redirect = True, .event_mask = KeyPressMask };
    Window w = XCreateWindow(d, DefaultRootWindow(d), 0, 0, 400, 300, 0, CopyFromParent,
                             InputOutput, CopyFromParent, CWOverrideRedirect | CWEventMask, &a);
    XMapWindow(d, w);
    XSync(d, False);
    XSetInputFocus(d, w, RevertToParent, CurrentTime);
    XSync(d, False);
    usleep(200000);

    char on[256], off[256];
    unsigned l0 = light();
    XkbLockModifiers(d, XkbUseCoreKbd, LockMask, LockMask);
    XSync(d, False);
    unsigned l1 = light();
    tap(0, KEY_A);
    tap(KEY_LEFTSHIFT, KEY_A);
    tap(0, KEY_E);
    tap(KEY_RIGHTALT, KEY_E);
    tap(0, KEY_1);
    typed(on);
    XkbLockModifiers(d, XkbUseCoreKbd, LockMask, 0);
    XSync(d, False);
    unsigned l2 = light();
    tap(0, KEY_A);
    typed(off);
    printf("light %u %u %u, on: %s, off: %s\n", l0, l1, l2, on, off);
    return 0;
}
