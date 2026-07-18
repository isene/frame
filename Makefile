# frame — pure-asm X11 display server (CHasm)

NASM    ?= nasm
LD      ?= ld
PLATFORM ?= linux

ifeq ($(PLATFORM),linux)
PLATFORM_DEF := -DFRAME_PLATFORM_LINUX
PLATFORM_SRC := linux.asm linux.inc
else ifeq ($(PLATFORM),freebsd)
PLATFORM_DEF := -DFRAME_PLATFORM_FREEBSD
PLATFORM_SRC := freebsd.asm freebsd.inc
else
$(error unsupported PLATFORM '$(PLATFORM)' (expected linux or freebsd))
endif

NFLAGS  := -f elf64 $(PLATFORM_DEF)
LFLAGS  :=

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin

all: frame

frame: frame.o
	$(LD) $(LFLAGS) $< -o $@

frame.o: frame.asm $(PLATFORM_SRC)
	$(NASM) $(NFLAGS) $< -o $@

install: frame
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 frame $(DESTDIR)$(BINDIR)/frame

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/frame

clean:
	rm -f frame frame.o

.PHONY: all install uninstall clean
