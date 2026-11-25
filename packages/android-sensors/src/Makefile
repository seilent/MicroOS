CFLAGS ?= -O2
OUT ?= waydroid-sensord
PKGS = libgbinder libglibutil glib-2.0

$(OUT): sensord.c ssc.c ssc.h
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra $$(pkg-config --cflags $(PKGS)) $(LDFLAGS) -o $@ sensord.c ssc.c \
		$$(pkg-config --libs $(PKGS))
