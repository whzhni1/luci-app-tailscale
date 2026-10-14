#!/bin/sh
TS_PKG=tailscale
TS_DEF_TMP=/tmp/tailscale

ts_uci_get() {
	local value
	value="$(uci -q get "${TS_PKG}.$1.$2" 2>/dev/null)"
	if [ -z "$value" ]; then
		printf '%s' "$3"
	else
		printf '%s' "$value"
	fi
}

ts_tmpdir() {
	local dir
	dir="$(ts_uci_get main tmp_dir "$TS_DEF_TMP")"
	mkdir -p "$dir" "$dir/dl" 2>/dev/null
	printf '%s' "$dir"
}

log_line() {
	local file="$1" limit="$2" line="$3" bytes keep tmp
	bytes="$(wc -c <"$file" 2>/dev/null | tr -d ' ')"
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	if [ "$bytes" -ge "$limit" ]; then
		keep=$((limit / 2))
		tmp="$file.tmp"
		if [ "$keep" -gt 0 ]; then
			tail -c "$keep" "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
		else
			: >"$file"
		fi
	fi
	printf '%s\n' "$line" >>"$file"
}

daemon_log() {
	local enabled limit_kb limit_bytes errors dir file fifo daemon_pid reader_pid rc
	shift
	[ "$#" -gt 0 ] || exit 2
	enabled="$(ts_uci_get main log_enabled '1')"
	[ "$enabled" = "1" ] || exec "$@" >/dev/null 2>&1
	limit_kb="$(ts_uci_get main log_limit_kb '300')"
	case "$limit_kb" in ''|*[!0-9]*) limit_kb=300 ;; esac
	[ "$limit_kb" -gt 0 ] 2>/dev/null || limit_kb=300
	limit_bytes=$((limit_kb * 1024))
	errors="$(ts_uci_get main log_errors_only '0')"
	dir="$(ts_tmpdir)"
	file="$dir/daemon.log"
	fifo="$dir/daemon-$$.fifo"
	rm -f "$fifo"
	mkfifo "$fifo" 2>/dev/null || exec "$@" >/dev/null 2>&1
	{
		while IFS= read -r line || [ -n "$line" ]; do
			if [ "$errors" = "1" ]; then
				printf '%s\n' "$line" | grep -Eiq 'warn(ing)?|error|fatal|panic|critical' || continue
			fi
			log_line "$file" "$limit_bytes" "$line"
		done
	} <"$fifo" &
	reader_pid=$!
	"$@" >"$fifo" 2>&1 &
	daemon_pid=$!
	terminate() {
		kill "$daemon_pid" 2>/dev/null
		wait "$daemon_pid" 2>/dev/null
		kill "$reader_pid" 2>/dev/null
		wait "$reader_pid" 2>/dev/null
		rm -f "$fifo"
		exit 0
	}
	trap terminate TERM INT HUP
	wait "$daemon_pid"
	rc=$?
	wait "$reader_pid" 2>/dev/null
	trap - TERM INT HUP
	rm -f "$fifo"
	exit "$rc"
}

case "${1:-}" in
daemon) daemon_log "$@" ;;
*) printf 'usage: %s daemon <command> [arguments...]\n' "${0##*/}" >&2; exit 2 ;;
esac
