#!/bin/sh
TS_BIN="$(uci -q get tailscale.main.bin_dir 2>/dev/null)"
[ -n "$TS_BIN" ] || TS_BIN=/usr/sbin
TS_LIBDIR="${TS_LIBDIR:-/usr/libexec/tailscale}"
TS_REAL_CLI="$TS_BIN/tailscale"
if [ "$#" -eq 2 ] && [ "$1" = update ] && [ "$2" = --yes ]; then
	if [ -x "$TS_LIBDIR/update.sh" ]; then
		exec "$TS_LIBDIR/update.sh" c2n-update
	fi
	exit 127
fi
exec "$TS_REAL_CLI" "$@"
