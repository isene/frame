# frame — pure-asm X11 display server (CHasm)

NASM    ?= nasm
LD      ?= ld
NFLAGS  := -f elf64
LFLAGS  :=

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin

all: frame

frame: frame.o
	$(LD) $(LFLAGS) $< -o $@

frame.o: frame.asm
	$(NASM) $(NFLAGS) $< -o $@

install: frame
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 frame $(DESTDIR)$(BINDIR)/frame

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/frame

clean:
	rm -f frame frame.o

.PHONY: all install uninstall clean deb

# ── Debian package ─────────────────────────────────────────────────────
# Version comes from the README badge (the repo's single version marker).
VERSION := $(shell grep -oP 'version-\K[0-9.]+(?=-blue)' README.md)

deb: frame
	rm -rf pkgroot
	$(MAKE) install DESTDIR=$(CURDIR)/pkgroot PREFIX=/usr
	install -Dm644 LICENSE pkgroot/usr/share/doc/frame/copyright
	install -d pkgroot/DEBIAN
	printf 'Package: frame\nVersion: $(VERSION)\nArchitecture: amd64\nMaintainer: Geir Isene <g@isene.com>\nSection: x11\nPriority: optional\nHomepage: https://github.com/isene/frame\nDescription: X11 display server in x86_64 assembly\n Talks DRM/KMS and evdev directly, serves the X11 wire protocol over a\n Unix socket. No libc, no Mesa, no Xorg. Experimental; hosts the CHasm\n desktop and mainstream clients like Firefox.\n' > pkgroot/DEBIAN/control
	dpkg-deb --build --root-owner-group pkgroot frame_$(VERSION)_amd64.deb
	rm -rf pkgroot
