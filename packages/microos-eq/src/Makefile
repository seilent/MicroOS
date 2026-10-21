CFLAGS ?= -O2
OUT ?= microos-eq.so

$(OUT): eq.c rbj.c crossfeed.c
	$(CC) $(CFLAGS) $(DEFS) -std=gnu11 -fPIC -ffp-contract=off -fvisibility=hidden -shared $(LDFLAGS) -o $@ eq.c rbj.c crossfeed.c -lm
