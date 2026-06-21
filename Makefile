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

.PHONY: all install uninstall clean
