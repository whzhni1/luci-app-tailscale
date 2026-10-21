#!/bin/sh
TS_PKG=tailscale
TS_DEF_TMP=/tmp/tailscale
TS_DEF_BIN=/usr/sbin
TS_DEF_SOURCES='gitlab github r2'
TS_DEF_TIMEOUT=20
TS_DEF_RETRY=2
TS_DEF_TTL=3600
TS_DEF_JITTER=600
TS_DEF_DL=600
TS_DEF_KEEP=1
TS_DEF_TRYRUN=10
TS_DEF_GH_WINDOW=40
TS_PKG_LUCI=luci-app-tailscale
TS_RE_CORE='^tailscale_.*_linux-.*[.]tar[.]gz$'
TS_RE_LUCI='^luci-app-tailscale[_-][0-9].*[.][ai]pk$'
TS_DEF_STATE=/etc/tailscale
TS_DEF_SOCKET=/var/run/tailscale/tailscaled.sock
TS_DEF_TUN=tailscale0
TS_DEF_HIST=50
TS_DEF_LAN=lan
TS_DEF_WAN=wan
TS_DEF_UPWAIT=5
TS_DEF_BOOTWAIT=30
TS_DEF_UPTIMEOUT=600
TS_UPGRADE_MARKER=/tmp/tailscale-luci-app-upgrade
TS_PURGE_LIST=/tmp/tailscale-luci-app-purge
TS_BACKUP_FILE=/tmp/tailscale-luci-app-backup.tar.gz

ts_uci_get() {
	local section="$1" option="$2" default="$3" value
	value="$(uci -q get "${TS_PKG}.${section}.${option}" 2>/dev/null)"
	if [ -z "$value" ]; then
		printf '%s' "$default"
	else
		printf '%s' "$value"
	fi
}

ts_uci_set() {
	uci -q set "${TS_PKG}.$1.$2=$3"
}

ts_uci_commit() {
	uci -q commit "$TS_PKG"
}

ts_tmpdir() {
	local dir
	dir="$(ts_uci_get main tmp_dir "$TS_DEF_TMP")"
	mkdir -p "$dir" "$dir/dl" 2>/dev/null
	printf '%s' "$dir"
}

ts_router_model() {
	local model
	model="$(cat /tmp/sysinfo/model 2>/dev/null)"
	if [ -z "$model" ]; then
		model="$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null | head -n 1)"
	fi
	if [ -z "$model" ]; then
		model="$(uname -n 2>/dev/null)"
	fi
	printf '%s' "$model"
}

ts_task_begin() {
	local dir
	dir="$(ts_tmpdir)"
	printf '{"step":"begin","percent":0,"msg":"","done":false,"error":""}' >"$dir/task-$1.json"
	: >"$dir/task-$1.log"
}

ts_task_step() {
	local dir msg
	dir="$(ts_tmpdir)"
	msg="$(printf '%s' "$4" | tr -d '"\\' | tr '\n' ' ')"
	printf '{"step":"%s","percent":%s,"msg":"%s","done":false,"error":""}' "$2" "$3" "$msg" >"$dir/task-$1.json"
	printf '%s %s\n' "$2" "$msg" >>"$dir/task-$1.log"
}

ts_task_done() {
	local dir warning
	dir="$(ts_tmpdir)"
	warning="$3"
	if [ -z "$2" ]; then
		if [ -n "$warning" ]; then
			printf '{"step":"done","percent":100,"msg":"","done":true,"error":"","warning":"%s"}' "$warning" >"$dir/task-$1.json"
		else
			printf '{"step":"done","percent":100,"msg":"","done":true,"error":""}' >"$dir/task-$1.json"
		fi
	else
		printf '{"step":"error","percent":100,"msg":"","done":true,"error":"%s"}' "$2" >"$dir/task-$1.json"
	fi
	printf 'done %s\n' "$2" >>"$dir/task-$1.log"
}

ts_task_log() {
	local dir
	dir="$(ts_tmpdir)"
	printf '%s %s\n' "$2" "$3" >>"$dir/task-$1.log"
}

ts_lock() {
	local base="$1" pid stale
	if mkdir "$base.lock" 2>/dev/null; then
		printf '%s' "$$" >"$base.lock/pid"
		return 0
	fi
	pid="$(cat "$base.lock/pid" 2>/dev/null)"
	if [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	stale="$base.lock.stale.$$"
	if ! mv "$base.lock" "$stale" 2>/dev/null; then
		return 1
	fi
	rm -rf "$stale"
	if mkdir "$base.lock" 2>/dev/null; then
		printf '%s' "$$" >"$base.lock/pid"
		return 0
	fi
	return 1
}

ts_unlock() {
	rm -rf "$1.lock"
}

ts_fetch() {
	local url="$1" out="$2" max="$3" timeout retry attempt empty_seen
	timeout="$(ts_uci_get update timeout "$TS_DEF_TIMEOUT")"
	retry="$(ts_uci_get update retry "$TS_DEF_RETRY")"
	if [ -n "${TS_METADATA_TIMEOUT:-}" ]; then
		timeout="$TS_METADATA_TIMEOUT"
		max="$TS_METADATA_TIMEOUT"
		retry="${TS_METADATA_RETRIES:-0}"
	fi
	if [ -z "$max" ]; then
		max="$timeout"
	fi
	attempt=0
	empty_seen=0
	TS_FETCH_ERROR='fetch_fail'
	TS_FETCH_MSG=''
	while [ "$attempt" -le "$retry" ]; do
		if command -v curl >/dev/null 2>&1; then
			if TS_FETCH_MSG="$(curl -fsSL -S --connect-timeout "$timeout" --max-time "$max" -o "$out" "$url" 2>&1)"; then
				if [ -s "$out" ]; then
					TS_FETCH_ERROR=''
					return 0
				fi
				empty_seen=1
			fi
		elif command -v uclient-fetch >/dev/null 2>&1; then
			if TS_FETCH_MSG="$(uclient-fetch --timeout="$max" -O "$out" "$url" 2>&1)"; then
				if [ -s "$out" ]; then
					TS_FETCH_ERROR=''
					return 0
				fi
				empty_seen=1
			fi
		elif command -v wget >/dev/null 2>&1; then
			if TS_FETCH_MSG="$(wget -q -T "$max" -O "$out" "$url" 2>&1)"; then
				if [ -s "$out" ]; then
					TS_FETCH_ERROR=''
					return 0
				fi
				empty_seen=1
			fi
		else
			TS_FETCH_ERROR='no_client'
			return 2
		fi
		rm -f "$out"
		attempt=$((attempt + 1))
		if [ "$attempt" -le "$retry" ]; then
			sleep "$attempt"
		fi
	done
	if [ "$empty_seen" = "1" ]; then
		TS_FETCH_ERROR='empty_response'
	fi
	return 1
}

ts_fetch_log() {
	local msg
	case "$TS_FETCH_ERROR" in
		empty_response) ts_task_log "$1" fetch_fail 'empty response after retries' ;;
		no_client) ts_task_log "$1" fetch_fail 'no downloader is installed' ;;
		*)
			msg="$(printf '%s' "$TS_FETCH_MSG" | tail -n 1)"
			ts_task_log "$1" fetch_fail "$2${msg:+ $msg}"
			;;
	esac
}

ts_cached_fetch() {
	local cache="$1" url="$2" max="$3" ttl="$4" stamp now
	if [ -f "$cache" ]; then
		stamp="$(stat -c %Y "$cache" 2>/dev/null || printf '0')"
		now="$(date +%s)"
		if [ $((now - stamp)) -lt "$ttl" ]; then
			printf '%s' "$cache"
			return 0
		fi
	fi
	if ts_fetch "$url" "$cache.tmp" "$max"; then
		mv "$cache.tmp" "$cache"
		printf '%s' "$cache"
		return 0
	fi
	rm -f "$cache.tmp"
	if [ -f "$cache" ]; then
		printf '%s' "$cache"
		return 0
	fi
	return 1
}

ts_update_channel() {
	local channel
	channel="$(ts_uci_get update channel 'custom')"
	case "$channel" in
		custom|official) printf '%s' "$channel" ;;
		*) printf 'custom' ;;
	esac
}

ts_official_arch() {
	case "$(uname -m 2>/dev/null)" in
		x86_64|amd64) printf 'amd64' ;;
		i?86|x86) printf '386' ;;
		aarch64|arm64) printf 'arm64' ;;
		arm*|armv*) printf 'arm' ;;
		mips64el|mips64le) printf 'mips64le' ;;
		mips64) printf 'mips64' ;;
		mipsel*|mipsle) printf 'mipsle' ;;
		mips*) printf 'mips' ;;
		riscv64) printf 'riscv64' ;;
		geode) printf 'geode' ;;
		*) return 1 ;;
	esac
}

ts_official_manifest() {
	local dir ttl cache
	dir="$(ts_tmpdir)"
	ttl="$(ts_uci_get update cache_ttl "$TS_DEF_TTL")"
	cache="$dir/rel-official-tailscale.json"
	ts_cached_fetch "$cache" 'https://pkgs.tailscale.com/stable/?mode=json&os=linux' "$(ts_uci_get update timeout "$TS_DEF_TIMEOUT")" "$ttl"
}

ts_official_latest() {
	local manifest latest
	manifest="$(ts_official_manifest)" || return 1
	latest="$(grep -o '"TarballsVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
	case "$latest" in
		[0-9]*.[0-9]*.[0-9]*) printf '%s' "$latest" ;;
		*) return 1 ;;
	esac
}

ts_official_file() {
	local version="$1" arch="$2" manifest tarballs
	manifest="$(ts_official_manifest)" || return 1
	if [ -z "$version" ] || [ -z "$arch" ]; then return 1; fi
	tarballs="$(sed -n '/"Tarballs"[[:space:]]*:/,/^[[:space:]]*}/p' "$manifest")"
	printf '%s\n' "$tarballs" | grep -q '"'"$arch"'"[[:space:]]*:' || return 1
	printf 'tailscale_%s_%s.tgz' "$version" "$arch"
}

ts_path_bytes() {
	local path="$1" real size
	real="$(readlink -f "$path" 2>/dev/null)"
	[ -n "$real" ] || real="$path"
	[ -f "$real" ] || { printf '0'; return 0; }
	size="$(stat -c %s "$real" 2>/dev/null)"
	case "$size" in ''|*[!0-9]*) size="$(wc -c < "$real" 2>/dev/null | tr -d ' ')" ;; esac
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	printf '%s' "$size"
}

ts_free_bytes() {
	local path="$1" bytes
	while [ ! -e "$path" ] && [ "${path%/*}" != "$path" ]; do
		path="${path%/*}"
	done
	[ -n "$path" ] || path=/
	bytes="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 { printf "%.0f", $4 * 1024 }')"
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	printf '%s' "$bytes"
}

ts_remote_bytes() {
	local url="$1" bytes headers
	bytes=0
	if command -v curl >/dev/null 2>&1; then
		bytes="$(curl -fsSI -L --connect-timeout 8 --max-time 20 "$url" 2>/dev/null | awk 'BEGIN { IGNORECASE=1 } tolower($1)=="content-length:" { gsub("\r", "", $2); value=$2 } END { if (value ~ /^[0-9]+$/) print value; else print 0 }')"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		headers="$(uclient-fetch --timeout=20 --spider -O - -q "$url" 2>&1)"
		bytes="$(printf '%s\n' "$headers" | awk 'BEGIN { IGNORECASE=1 } tolower($1)=="content-length:" { gsub("\r", "", $2); value=$2 } END { if (value ~ /^[0-9]+$/) print value; else print 0 }')"
	elif command -v wget >/dev/null 2>&1; then
		headers="$(wget --spider --server-response -T 20 -O /dev/null "$url" 2>&1)"
		bytes="$(printf '%s\n' "$headers" | awk 'BEGIN { IGNORECASE=1 } tolower($1)=="content-length:" { gsub("\r", "", $2); value=$2 } END { if (value ~ /^[0-9]+$/) print value; else print 0 }')"
	fi
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	printf '%s' "$bytes"
}

ts_asset_bytes() {
	local blob="$1" file="$2" url="$3" bytes
	bytes="$(grep -A"$TS_DEF_GH_WINDOW" -F "\"name\": \"$file\"" "$blob" 2>/dev/null | grep -o -m1 '"size":[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
	case "$bytes" in ''|*[!0-9]*|0) bytes="$(ts_remote_bytes "$url")" ;; esac
	printf '%s' "$bytes"
}

ts_cache_dir() {
	local cache home
	home="${HOME:-/root}"
	cache="${XDG_CACHE_HOME:-$home/.cache}"
	[ -d "$cache" ] || cache="$home"
	printf '%s' "$cache"
}

ts_official_download_bytes() {
	ts_remote_bytes "$1"
}

ts_official_info() {
	local version="$1" arch="$2" file="$3" bin url cli_real daemon_real cli_bytes daemon_bytes installed_bytes cache_parent free_bin free_cache download_bytes
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	url="https://pkgs.tailscale.com/stable/$file"
	cli_real="$(readlink -f "$bin/tailscale" 2>/dev/null)"
	daemon_real="$(readlink -f "$bin/tailscaled" 2>/dev/null)"
	cli_bytes="$(ts_path_bytes "$bin/tailscale")"
	daemon_bytes="$(ts_path_bytes "$bin/tailscaled")"
	if [ -n "$cli_real" ] && [ "$cli_real" = "$daemon_real" ]; then
		installed_bytes="$daemon_bytes"
	else
		installed_bytes=$((cli_bytes + daemon_bytes))
	fi
	cache_parent="$(ts_cache_dir)"
	free_bin="$(ts_free_bytes "$bin")"
	free_cache="$(ts_free_bytes "$cache_parent")"
	download_bytes="$(ts_official_download_bytes "$url")"
	printf '{"version":"%s","arch":"%s","file":"%s","url":"%s","download_bytes":%s,"installed_bytes":%s,"free_bin_bytes":%s,"free_cache_bytes":%s}' "$version" "$arch" "$file" "$url" "$download_bytes" "$installed_bytes" "$free_bin" "$free_cache"
}

ts_custom_layout() {
	local bin target
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	[ -L "$bin/tailscale" ] || return 1
	target="$(readlink "$bin/tailscale" 2>/dev/null)"
	case "$target" in
		tailscaled|"$bin/tailscaled") return 0 ;;
		*) return 1 ;;
	esac
}

ts_official_list() {
	local version="${1:-}" arch file info
	[ -n "$version" ] || version="$(ts_official_latest)" || return 1
	arch="$(ts_official_arch)" || return 1
	file="$(ts_official_file "$version" "$arch")" || return 1
	info="$(ts_official_info "$version" "$arch" "$file")"
	printf '{"source":"official","tags":["%s"],"files":{"%s":["%s"]},"info":%s}' "$version" "$version" "$file" "$info"
}

ts_index() {
	local idx="$1.idx"
	[ -f "$1" ] || return 1
	if [ ! -s "$idx" ] || [ "$1" -nt "$idx" ]; then
		grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"\|https\?://[^"[:space:]\]*' "$1" | awk '
			/^"tag_name"/ { v = $0; sub(/^"tag_name"[[:space:]]*:[[:space:]]*"[vV ]*/, "", v); sub(/[-+[:space:]"].*/, "", v); next }
			v != "" {
				b = $0
				sub(/[?#].*/, "", b)
				n = split(b, p, "/")
				b = p[n]
				if (b ~ /[.]/ && b !~ /[{}]/ && !s[v SUBSEP b]++) print v, b, $0
			}
		' >"$idx.$$" && mv -f "$idx.$$" "$idx"
		rm -f "$idx.$$"
	fi
	[ -f "$idx" ] && printf '%s' "$idx"
}

ts_assets() {
	local idx
	idx="$(ts_index "$1")" || return 1
	awk -v re="$2" -v v="$3" '(v == "" || $1 == v) && $2 ~ re && !s[$2]++ { print $2 }' "$idx" | sort
}

ts_asset() {
	local idx
	idx="$(ts_index "$1")" || return 1
	awk -v f="$2" -v c="$3" '$2 == f { print $c; exit }' "$idx"
}

ts_versions() {
	local idx
	idx="$(ts_index "$1")" || return 1
	awk -v re="$2" '$2 ~ re { print $1 }' "$idx" | sort -Vru
}

ts_verify() {
	local got
	got="$(ts_sha256_file "$4")"
	[ -n "$got" ] && grep -qF "$got" "$2" && return 0
	if grep -q '[0-9a-f]\{64\}' "$2"; then
		ts_task_log "$1" hash_mismatch "$3"
		return 3
	fi
	ts_task_log "$1" no_hash "$3"
	return 2
}

ts_endian() {
	local probe
	probe="$(printf '\001\002' | od -An -tu2 2>/dev/null | tr -d ' \n')"
	if [ "$probe" = "258" ]; then
		printf 'big'
	else
		printf 'little'
	fi
}

ts_float() {
	if grep -qi -e fpu -e vfp -e neon -e 'hard.*float' /proc/cpuinfo 2>/dev/null; then
		printf 'hard'
	else
		printf 'soft'
	fi
}

ts_mips_base() {
	if [ "$(ts_endian)" = "big" ]; then
		printf 'mips'
	else
		printf 'mipsel'
	fi
}

ts_mips_tokens() {
	local base="$1" variant order
	if [ "$(ts_float)" = "hard" ]; then
		order='hardfloat softfloat'
	else
		order='softfloat hardfloat'
	fi
	for variant in $order; do
		printf '%s-%s ' "$base" "$variant"
	done
}

ts_arch_tokens() {
	local arch machine tokens
	arch="${TS_ARCH:-$(ts_uci_get update arch 'auto')}"
	if [ "$arch" != "auto" ]; then
		printf '%s' "$arch"
		return 0
	fi
	machine="$(uname -m)"
	case "$machine" in
	x86_64) tokens='x86_64' ;;
	i386|i486|i586|i686) tokens='i686' ;;
	aarch64|arm64) tokens='aarch64' ;;
	armv7*) tokens='armv7l armv6l armv5l' ;;
	armv6*) tokens='armv6l armv5l' ;;
	armv5*) tokens='armv5l' ;;
	arm*) tokens='armv7l armv6l armv5l' ;;
	riscv64*) tokens='riscv64' ;;
	loongarch64|loong64) tokens='loongarch64' ;;
	ppc64le|powerpc64le) tokens='powerpc64le' ;;
	mips64el*|mips64le*) tokens="$(ts_mips_tokens mips64el)" ;;
	mips64*) tokens="$(ts_mips_tokens mips64)" ;;
	mipsel*|mipsle*) tokens="$(ts_mips_tokens mipsel)" ;;
	mipseb*) tokens="$(ts_mips_tokens mips)" ;;
	mips*) tokens="$(ts_mips_tokens "$(ts_mips_base)")" ;;
	*) tokens='' ;;
	esac
	printf '%s' "$tokens"
}

ts_ver_norm() {
	printf '%s' "$1" | sed -e 's/^[vV ]*//' -e 's/[[:space:]].*//' -e 's/-.*//' -e 's/+.*//'
}

ts_ver_cmp() {
	local first
	if [ "$1" = "$2" ]; then
		printf '0'
		return 0
	fi
	first="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)"
	if [ "$first" = "$1" ]; then
		printf '%s' '-1'
	else
		printf '1'
	fi
}

ts_sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$1" | cut -d' ' -f2
	fi
}

ts_api_url() {
	local source="$1" proj="$2"
	case "$source" in
		gitlab) printf '%s' "https://gitlab.com/api/v4/projects/whzhni%2F${proj}/releases" ;;
		r2) printf '%s' "https://pub-8a57d35d70d5423aac22a3316867e7ce.r2.dev/${proj}/releases" ;;
		github) printf '%s' "https://api.github.com/repos/whzhni1/${proj}/releases" ;;
		*) return 1 ;;
	esac
}

ts_sources() {
	local order
	if [ -n "$1" ] && [ "$1" != "auto" ]; then
		printf '%s' "$1"
		return 0
	fi
	order="$(ts_uci_get update source_order "$TS_DEF_SOURCES")"
	if [ "$order" = 'gitlab r2 github' ]; then
		order="$TS_DEF_SOURCES"
	fi
	printf '%s' "$order"
}

ts_releases() {
	local dir ttl cache url
	dir="$(ts_tmpdir)"
	ttl="$(ts_uci_get update cache_ttl "$TS_DEF_TTL")"
	cache="$dir/rel-$2-$1.json"
	url="$(ts_api_url "$2" "$1")" || return 1
	ts_cached_fetch "$cache" "$url" '' "$ttl"
}

ts_url() {
	ts_asset "$1" "$2" 3
}

ts_latest_for() {
	local proj="$1" want="$2" src blob latest
	for src in $(ts_sources "$want"); do
		blob="$(ts_releases "$proj" "$src")" || continue
		latest="$(core_latest "$blob")"
		if [ -n "$latest" ]; then
			printf '%s' "$latest"
			return 0
		fi
	done
	return 1
}

ts_check_json() {
	local installed="$1" latest="$2" outdated
	outdated='true'
	if [ -n "$installed" ] && [ "$(ts_ver_cmp "$installed" "$latest")" != "-1" ]; then
		outdated='false'
	fi
	printf '{"ok":true,"installed":"%s","latest":"%s","outdated":%s}' "$installed" "$latest" "$outdated"
}

ts_install_loop() {
	local id="$1" proj="$2" version="$3" want="$4" wsrc="$5" resolve_fn="$6" attempt_fn="$7"
	local dir blob src file url fail attempted rc out
	dir="$(ts_tmpdir)"
	fail='fetch_fail'
	for src in $(ts_sources "$wsrc"); do
		blob="$(ts_releases "$proj" "$src")" || continue
		ts_task_step "$id" resolve 10 "$src"
		fail='no_match'
		attempted=0
		for file in $("$resolve_fn" "$blob" "$version" "$want"); do
			attempted=1
			url="$(ts_url "$blob" "$file")"
			if [ -z "$url" ]; then
				fail='no_url'
				ts_task_log "$id" no_url "$file"
				continue
			fi
			out="$("$attempt_fn" "$id" "$blob" "$file" "$url")"
			rc="$?"
			if [ "$rc" = "0" ]; then
				printf 'ok %s' "$out"
				return 0
			fi
			case "$rc" in
			1) fail='fetch_fail' ;;
			2) fail='no_hash' ;;
			3) fail='hash_mismatch' ;;
			4) fail='extract_fail' ;;
			5) fail='tryrun_fail' ;;
			6) fail='pkg_fail' ;;
			7) fail='space_insufficient'; printf '%s' "$fail"; return 1 ;;
			*) fail='install_fail' ;;
			esac
		done
		if [ "$attempted" = "0" ]; then
			ts_task_log "$id" no_match "$src"
		fi
	done
	printf '%s' "$fail"
	return 1
}

ts_running() {
	local state
	state="$(ts_uci_get main state_dir "$TS_DEF_STATE")"
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -f "(^|/)tailscaled --state=$state" >/dev/null 2>&1
	else
		pidof tailscaled >/dev/null 2>&1
	fi
}

ts_shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

core_member() {
	tar -tzf "$1" 2>/dev/null | grep -m1 '/tailscaled$'
}

core_member_bytes() {
	local bytes
	bytes="$(tar -tvzf "$1" "$2" 2>/dev/null | awk 'NR==1 { print $3; exit }')"
	case "$bytes" in ''|*[!0-9]*|0) bytes="$(tar -xzOf "$1" "$2" 2>/dev/null | wc -c | tr -d ' ')" ;; esac
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	printf '%s' "$bytes"
}

core_tryrun() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$TS_DEF_TRYRUN" "$1" -version >/dev/null 2>&1
	else
		"$1" -version >/dev/null 2>&1
	fi
}

core_installed_version() {
	local bin version
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	if [ ! -x "$bin/tailscale" ]; then
		return 1
	fi
	version="$("$bin/tailscale" version 2>/dev/null | head -n 1)"
	if [ -z "$version" ]; then
		return 1
	fi
	ts_ver_norm "$version"
}

ts_extract_version() {
	printf '%s' "$1" | grep -Eo -m1 '[0-9]+\.[0-9]+\.[0-9]+'
}

ts_version_matches() {
	local expected="$1" actual="$2"
	[ -z "$expected" ] || [ "$expected" = "latest" ] || [ "$(ts_ver_norm "$actual")" = "$(ts_ver_norm "$expected")" ]
}

core_binary_version_ok() {
	local bin="$1" expected="$2" cli_output daemon_output cli_version daemon_version
	[ -x "$bin/tailscale" ] && [ -x "$bin/tailscaled" ] || return 1
	cli_output="$("$bin/tailscale" version 2>/dev/null)" || return 1
	daemon_output="$("$bin/tailscaled" --version 2>&1)" || return 1
	cli_version="$(ts_extract_version "$cli_output")"
	daemon_version="$(ts_extract_version "$daemon_output")"
	[ -n "$cli_version" ] && [ -n "$daemon_version" ] || return 1
	ts_version_matches "$expected" "$cli_version" && ts_version_matches "$expected" "$daemon_version"
}

core_service_ready() {
	local bin="$1" expected="$2" socket="$3" output reported
	if command -v timeout >/dev/null 2>&1; then
		output="$(timeout 2 "$bin/tailscale" "--socket=$socket" status --json 2>/dev/null)" || return 1
	else
		output="$("$bin/tailscale" "--socket=$socket" status --json 2>/dev/null)" || return 1
	fi
	printf '%s' "$output" | grep -q '"BackendState"[[:space:]]*:' || return 1
	reported="$(printf '%s' "$output" | grep -Eo -m1 '"Version"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d '"' -f4)"
	if [ -n "$expected" ] && [ "$expected" != "latest" ] && [ -n "$reported" ]; then
		reported="$(ts_extract_version "$reported")"
		[ -n "$reported" ] && ts_version_matches "$expected" "$reported" || return 1
	fi
	return 0
}

ts_service_wait_seconds() {
	local value
	value="$(ts_uci_get update service_wait_seconds 180)"
	case "$value" in
		''|*[!0-9]*) value=180 ;;
	esac
	value="$(printf '%s' "$value" | sed 's/^0*//')"
	[ -n "$value" ] || value=0
	[ "$value" -ge 30 ] 2>/dev/null || value=30
	[ "$value" -le 600 ] 2>/dev/null || value=600
	printf '%s' "$value"
}

ts_wait_service() {
	local id="$1" bin="$2" expected="$3" socket="$4" start deadline now elapsed next_log remaining wait_seconds
	wait_seconds="$(ts_service_wait_seconds)"
	start="$(date +%s)"
	deadline=$((start + wait_seconds))
	next_log=$((start + 15))
	ts_task_step "$id" healthcheck 98 ''
	while :; do
		if core_service_ready "$bin" "$expected" "$socket"; then
			now="$(date +%s)"
			ts_task_log "$id" service_ready "$((now - start)) seconds"
			return 0
		fi
		now="$(date +%s)"
		[ "$now" -lt "$deadline" ] || break
		elapsed=$((now - start))
		if [ "$now" -ge "$next_log" ]; then
			ts_task_log "$id" service_wait "$elapsed/$wait_seconds seconds"
			next_log=$((now + 15))
		fi
		remaining=$((deadline - now))
		if [ "$remaining" -lt 1 ]; then sleep "$remaining"; else sleep 1; fi
	done
	return 1
}

core_resolve() {
	local blob="$1" version="$2" want="$3" files token
	if [ "$version" = "latest" ]; then
		version="$(core_latest "$blob")"
	else
		version="$(ts_ver_norm "$version")"
	fi
	if [ -z "$version" ]; then
		return 1
	fi
	files="$(core_files "$blob" "$version")"
	if [ -z "$files" ]; then
		return 1
	fi
	if [ "$want" = "all" ]; then
		printf '%s\n' "$files"
		return 0
	fi
	if [ "$want" != "auto" ]; then
		printf '%s\n' "$files" | grep -Fx "$want"
		return $?
	fi
	for token in $(ts_arch_tokens); do
		printf '%s\n' "$files" | grep -F -m1 "linux-$token.tar.gz"
	done | awk '!seen[$0]++'
}

core_attempt() {
	local id="$1" blob="$2" file="$3" url="$4" dir bin pkg got member new download_bytes actual_download_bytes free_tmp free_bin member_bytes stage_dir archive_dir need
	dir="$(ts_tmpdir)"
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	stage_dir="$bin/.tailscale-stage-$id"
	rm -rf "$stage_dir" 2>/dev/null
	if ! mkdir -p "$dir/dl" "$bin" "$stage_dir" 2>/dev/null; then
		ts_task_log "$id" space_insufficient 'unable to create a staging directory'
		return 7
	fi
	download_bytes="$(ts_asset_bytes "$blob" "$file" "$url")"
	free_tmp="$(ts_free_bytes "$dir/dl")"
	free_bin="$(ts_free_bytes "$bin")"
	if [ "$download_bytes" -gt 0 ]; then
		need=$((download_bytes + 1048576))
		if [ "$free_tmp" -ge "$need" ]; then
			archive_dir="$dir/dl"
		elif [ "$free_bin" -ge "$need" ]; then
			archive_dir="$stage_dir"
		else
			rm -rf "$stage_dir"
			ts_task_log "$id" space_insufficient 'not enough space for archive in temporary or installation directory'
			return 7
		fi
	else
		if [ "$free_tmp" -ge 1048576 ] && { [ "$free_bin" -lt 1048576 ] || [ "$free_tmp" -ge "$free_bin" ]; }; then
			archive_dir="$dir/dl"
		elif [ "$free_bin" -ge 1048576 ]; then
			archive_dir="$stage_dir"
		elif [ "$free_tmp" -ge 1048576 ]; then
			archive_dir="$dir/dl"
		else
			rm -rf "$stage_dir"
			ts_task_log "$id" space_insufficient 'temporary and installation directories are nearly full'
			return 7
		fi
	fi
	pkg="$archive_dir/$file"
	ts_task_step "$id" download 20 "$file"
	if ! ts_fetch "$url" "$pkg" "$(ts_uci_get update dl_timeout "$TS_DEF_DL")"; then
		rm -f "$pkg"
		rm -rf "$stage_dir"
		ts_fetch_log "$id" "$file"
		return 1
	fi
	actual_download_bytes="$(ts_path_bytes "$pkg")"
	if [ "$actual_download_bytes" -le 0 ]; then
		rm -f "$pkg"
		rm -rf "$stage_dir"
		ts_task_log "$id" fetch_fail 'downloaded archive is empty'
		return 1
	fi
	ts_task_log "$id" archive_bytes "$actual_download_bytes"
	if [ "$download_bytes" -gt 0 ] && [ "$download_bytes" != "$actual_download_bytes" ]; then
		ts_task_log "$id" content_length_mismatch "$download_bytes:$actual_download_bytes"
	fi
	ts_task_step "$id" download 60 "$file"
	ts_verify "$id" "$blob" "$file" "$pkg" || {
		got="$?"
		rm -f "$pkg"
		rm -rf "$stage_dir"
		return "$got"
	}
	ts_task_step "$id" verify 70 "$file"
	member="$(core_member "$pkg")"
	if [ -z "$member" ]; then
		rm -f "$pkg"
		rm -rf "$stage_dir"
		ts_task_log "$id" extract_fail "$file"
		return 4
	fi
	member_bytes="$(core_member_bytes "$pkg" "$member")"
	if [ "$member_bytes" -le 0 ]; then
		rm -f "$pkg"
		rm -rf "$stage_dir"
		ts_task_log "$id" extract_fail 'archive member size is unavailable'
		return 4
	fi
	free_bin="$(ts_free_bytes "$bin")"
	if [ "$free_bin" -lt "$((member_bytes + 1048576))" ]; then
		rm -f "$pkg"
		rm -rf "$stage_dir"
		ts_task_log "$id" space_insufficient 'not enough installation space for extracted daemon'
		return 7
	fi
	new="$stage_dir/tailscaled.new"
	if ! tar -xzOf "$pkg" "$member" >"$new" 2>/dev/null; then
		rm -f "$pkg" "$new"
		rm -rf "$stage_dir"
		ts_task_log "$id" extract_fail "$file"
		return 4
	fi
	ts_task_step "$id" extract 80 "$file"
	if ! chmod 755 "$new"; then
		rm -f "$pkg" "$new"
		rm -rf "$stage_dir"
		ts_task_log "$id" extract_fail "$file"
		return 4
	fi
	if ! core_tryrun "$new"; then
		rm -f "$pkg" "$new"
		rm -rf "$stage_dir"
		ts_task_log "$id" tryrun_fail "$file"
		return 5
	fi
	ts_task_step "$id" tryrun 85 "$file"
	rm -f "$pkg"
	printf '%s' "$new"
	return 0
}

core_finish() {
	local dir bin
	dir="$(ts_tmpdir)"
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	rm -rf "$bin/.tailscale-stage-$1" 2>/dev/null
	cp -f "$dir/task-$1.log" "$dir/last-core.log" 2>/dev/null
	ts_task_done "$1" "$2" "$3"
	ts_unlock "$dir/download"
}

core_cli_running() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x tailscale >/dev/null 2>&1
	else
		pidof tailscale >/dev/null 2>&1
	fi
}

core_stop_for_update() {
	local init="$1" timeout="${2:-30}" waited=0
	if ts_running; then
		TS_STOP_KEEP_CONFIG=1 TS_STOP_RELOAD_NETWORK=0 TS_STOP_SKIP_WORKER=1 "$init" stop >/dev/null 2>&1 || :
	fi
	while [ "$waited" -lt "$timeout" ]; do
		if ! ts_running && ! core_cli_running; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	if ts_running || core_cli_running; then
		return 1
	fi
	return 0
}

ts_abs_dir() {
	local dir="$1"
	while [ "$dir" != "/" ] && [ "${dir%/}" != "$dir" ]; do
		dir="${dir%/}"
	done
	case "$dir" in
		/|*/..|*/../*|*/.|*/./*) return 1 ;;
		/*) printf '%s' "$dir" ;;
		*) return 1 ;;
	esac
}

core_remove() {
	local dir bin init
	dir="$(ts_tmpdir)"
	if ! mkdir -p "$dir"; then
		printf 'delete_fail'
		return 1
	fi
	if ! ts_lock "$dir/download"; then
		printf 'busy'
		return 1
	fi
	if ! bin="$(ts_abs_dir "$(ts_uci_get main bin_dir "$TS_DEF_BIN")")"; then
		ts_unlock "$dir/download"
		printf 'invalid_bin_dir'
		return 1
	fi
	init="${TS_SELF_INIT:-/etc/init.d/tailscale}"
	if ! core_stop_for_update "$init" 30; then
		ts_unlock "$dir/download"
		printf 'service_stop_fail'
		return 1
	fi
	if ! rm -f "$bin/tailscaled" "$bin/tailscale"; then
		ts_unlock "$dir/download"
		printf 'delete_fail'
		return 1
	fi
	ts_unlock "$dir/download"
	printf 'removed'
	return 0
}

core_manual_cleanup() {
	local id="$1" dir="$(ts_tmpdir)" lock='/tmp/tailscale/manual-upload.lock' owner
	owner="$(cat "$lock/id" 2>/dev/null)"
	if [ "$owner" = "$id" ]; then
		rm -f "/tmp/tailscale/manual/$id.tailscaled" "/tmp/tailscale/manual/$id.tailscaled.old"
		rm -rf "$lock"
	fi
	rm -f "$dir/task-$id.manual.json" "$dir/task-$id.pid"
}

core_manual_install() {
	local id="$1" dir stage backup bin init result changed backup_ok was_running cli_removed free old_size i
	case "$id" in ''|*[!A-Za-z0-9_-]*) return 2 ;; esac
	dir="$(ts_tmpdir)"
	stage="/tmp/tailscale/manual/$id.tailscaled"
	backup="/tmp/tailscale/manual/$id.tailscaled.old"
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	init="${TS_SELF_INIT:-/etc/init.d/tailscale}"
	result=''
	changed=0
	backup_ok=0
	was_running=0
	ts_task_begin "$id"
	if ! ts_lock "$dir/download"; then
		ts_task_done "$id" busy
		core_manual_cleanup "$id"
		return 1
	fi
	ts_task_step "$id" verify 72 ""
	if [ ! -s "$stage" ] || ! chmod 755 "$stage" || ! core_tryrun "$stage"; then
		result='tryrun_fail'
	fi
	if [ -z "$result" ] && { ! mkdir -p "$bin" || [ ! -d "$bin" ] || [ ! -w "$bin" ]; }; then
		result='install_fail'
	fi
	if [ -z "$result" ] && [ -f "$bin/tailscaled" ]; then
		old_size="$(stat -c %s "$bin/tailscaled" 2>/dev/null)"
		free="$(df -Pk /tmp 2>/dev/null | awk 'NR==2 { printf "%.0f", $4 * 1024 }')"
		case "$old_size:$free" in *[!0-9:]*|:*) old_size=0; free=0 ;; esac
		if [ "$old_size" -gt 0 ] && [ "$free" -ge "$((old_size + 1048576))" ] && cp -p "$bin/tailscaled" "$backup" 2>/dev/null; then
			backup_ok=1
		fi
	fi
	if [ -z "$result" ] && ts_running; then
		was_running=1
		ts_task_step "$id" stop 78 ""
		if ! TS_STOP_KEEP_CONFIG=1 TS_STOP_RELOAD_NETWORK=0 TS_STOP_SKIP_WORKER=1 "$init" stop >/dev/null 2>&1; then
			result='service_stop_fail'
		else
			for i in 1 2 3 4 5 6 7 8 9 10; do
				if ! ts_running; then break; fi
				sleep 1
			done
			if ts_running; then result='service_stop_fail'; fi
		fi
	fi
	if [ -z "$result" ]; then
		rm -f "$bin/tailscale"
		cli_removed=1
		for i in 1 2 3 4 5 6 7 8 9 10; do
			if ! core_cli_running; then break; fi
			sleep 1
		done
		if core_cli_running; then result='service_stop_fail'; fi
	fi
	if [ -z "$result" ]; then
		ts_task_step "$id" install 84 ""
		changed=1
		if ! cat "$stage" > "$bin/tailscaled" || ! chmod 755 "$bin/tailscaled" || ! ln -sf tailscaled "$bin/tailscale"; then
			result='install_fail'
		fi
	fi
	if [ -z "$result" ]; then
		ts_task_step "$id" restart 92 ""
		TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
	fi
	if [ -n "$result" ] && [ "$changed" = 1 ] && [ "$backup_ok" = 1 ]; then
		if ! core_stop_for_update "$init" 30; then
			result='rollback_fail'
		elif cat "$backup" > "$bin/tailscaled" && chmod 755 "$bin/tailscaled" && ln -sf tailscaled "$bin/tailscale"; then
			result='rolled_back'
			TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
		else
			result='rollback_fail'
		fi
	fi
	if [ -n "$result" ] && [ "$cli_removed" = 1 ] && [ ! -e "$bin/tailscale" ] && [ ! -L "$bin/tailscale" ]; then
		ln -sf tailscaled "$bin/tailscale" || result='rollback_fail'
	fi
	if [ -n "$result" ] && [ "$changed" = 0 ] && [ "$was_running" = 1 ] && ! ts_running; then
		TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
	fi
	core_finish "$id" "$result"
	core_manual_cleanup "$id"
	[ -z "$result" ]
}

core_backup_bytes() {
	local bin="$1" total=0 size file
	for file in tailscaled tailscale; do
		if [ -f "$bin/$file" ] && { [ "$file" = "tailscaled" ] || [ ! -L "$bin/$file" ]; }; then
			size="$(ts_path_bytes "$bin/$file")"
			total=$((total + size))
		fi
	done
	printf '%s' "$total"
}

core_backup_destination() {
	local id="$1" bin="$2" dir="$3" install_need="$4" backup_bytes free_bin free_tmp
	backup_bytes="$(core_backup_bytes "$bin")"
	[ "$backup_bytes" -gt 0 ] || return 1
	free_bin="$(ts_free_bytes "$bin")"
	if [ "$free_bin" -ge "$((backup_bytes + install_need))" ]; then
		printf '%s' "$bin/.tailscale-update-$id"
		return 0
	fi
	free_tmp="$(ts_free_bytes "$dir")"
	if [ "$free_bin" -ge "$install_need" ] && [ "$free_tmp" -ge "$((backup_bytes + 1048576))" ]; then
		printf '%s' "$dir/rollback-$id"
		return 0
	fi
	return 1
}

core_backup_files() {
	local bin="$1" backup_dir="$2"
	[ -n "$backup_dir" ] || return 1
	rm -rf "$backup_dir"
	mkdir -p "$backup_dir" || return 1
	if [ -f "$bin/tailscaled" ] && ! cp -p "$bin/tailscaled" "$backup_dir/tailscaled"; then
		rm -rf "$backup_dir"
		return 1
	fi
	if [ -f "$bin/tailscale" ] && [ ! -L "$bin/tailscale" ] && ! cp -p "$bin/tailscale" "$backup_dir/tailscale"; then
		rm -rf "$backup_dir"
		return 1
	fi
	return 0
}

core_remove_backups() {
	[ -n "$1" ] || return 0
	rm -rf "$1"
}

core_restore_files() {
	local bin="$1" backup_dir="$2" had_daemon="$3" had_cli="$4" cli_link="$5" rc=0
	if [ "$had_daemon" = "1" ]; then
		if ! cp -p "$backup_dir/tailscaled" "$bin/tailscaled"; then rc=1; fi
	else
		rm -f "$bin/tailscaled" || rc=1
	fi
	if [ "$had_cli" = "1" ]; then
		if [ -n "$cli_link" ]; then
			rm -f "$bin/tailscale" || rc=1
			ln -s "$cli_link" "$bin/tailscale" || rc=1
		elif [ -f "$backup_dir/tailscale" ]; then
			cp -p "$backup_dir/tailscale" "$bin/tailscale" || rc=1
		else
			rc=1
		fi
	else
		rm -f "$bin/tailscale" || rc=1
	fi
	return "$rc"
}

core_rollback() {
	local id="$1" bin="$2" init="$3" backup_dir="$4" had_daemon="$5" had_cli="$6" cli_link="$7" was_running="$8" cause="$9" old_version="${10}" socket
	ts_task_log "$id" update_failed "$cause"
	if ! core_stop_for_update "$init" 30; then
		if [ "$was_running" = "1" ] && ! ts_running; then
			TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
		fi
		ts_task_log "$id" rollback_fail 'service did not stop before restoring binaries'
		core_finish "$id" rollback_fail
		return 1
	fi
	if ! core_restore_files "$bin" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link"; then
		ts_task_log "$id" rollback_fail 'binary restoration failed'
		core_finish "$id" rollback_fail
		return 1
	fi
	if [ -n "$old_version" ] && ! core_binary_version_ok "$bin" "$old_version"; then
		ts_task_log "$id" rollback_fail 'restored binaries did not pass the version check'
		core_finish "$id" rollback_fail
		return 1
	fi
	if [ "$was_running" = "1" ]; then
		socket="$(ts_uci_get main socket "$TS_DEF_SOCKET")"
		ts_task_step "$id" restart 99 ''
		TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
		if ! ts_wait_service "$id" "$bin" "$old_version" "$socket"; then
			ts_task_log "$id" rollback_fail 'service did not recover after restoration'
			core_finish "$id" rollback_fail
			return 1
		fi
	fi
	core_remove_backups "$backup_dir"
	ts_task_log "$id" rollback 'previous binary state restored'
	core_finish "$id" rolled_back
	return 1
}

core_update_failure() {
	local id="$1" bin="$2" init="$3" backup_dir="$4" had_daemon="$5" had_cli="$6" cli_link="$7" was_running="$8" cause="$9" old_version="${10}"
	if [ -n "$backup_dir" ]; then
		core_rollback "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" "$cause" "$old_version"
		return 1
	fi
	if [ "$was_running" = "1" ] && ! ts_running; then
		TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
	fi
	ts_task_log "$id" update_failed "$cause"
	core_finish "$id" update_fail_no_rollback
	return 1
}

core_install() {
	local id="$1" version="$2" want="$3" wsrc="$4" dir bin out new fail init had_daemon had_cli cli_link was_running rollback backup_dir warning new_bytes install_need free_bin expected_version old_version socket
	dir="$(ts_tmpdir)"
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	init="${TS_SELF_INIT:-/etc/init.d/tailscale}"
	mkdir -p "$bin" 2>/dev/null
	ts_task_begin "$id"
	if ! ts_lock "$dir/download"; then
		ts_task_done "$id" busy
		return 1
	fi
	out="$(ts_install_loop "$id" "$TS_PKG" "$version" "$want" "$wsrc" core_resolve core_attempt)" || {
		fail="$out"
		core_finish "$id" "$fail"
		return 1
	}
	new="${out#ok }"
	if [ ! -f "$new" ]; then
		core_finish "$id" install_fail
		return 1
	fi
	ts_task_step "$id" install 90 ""
	old_version="$(core_installed_version)" || old_version=''
	had_daemon=0
	[ -f "$bin/tailscaled" ] && had_daemon=1
	had_cli=0
	{ [ -e "$bin/tailscale" ] || [ -L "$bin/tailscale" ]; } && had_cli=1
	cli_link=''
	if [ -L "$bin/tailscale" ]; then cli_link="$(readlink "$bin/tailscale" 2>/dev/null)"; fi
	was_running=0
	ts_running && was_running=1
	rollback="$(ts_uci_get update auto_rollback '1')"
	backup_dir=''
	warning=''
	new_bytes="$(ts_path_bytes "$new")"
	if [ "$new" = "$bin/.tailscale-stage-$id/tailscaled.new" ]; then
		install_need=1048576
	else
		install_need=$((new_bytes + 1048576))
	fi
	free_bin="$(ts_free_bytes "$bin")"
	if [ "$new_bytes" -le 0 ] || [ "$free_bin" -lt "$install_need" ]; then
		rm -f "$new"
		core_finish "$id" space_insufficient
		return 1
	fi
	if [ "$rollback" = "1" ]; then
		backup_dir="$(core_backup_destination "$id" "$bin" "$dir" "$install_need")" || backup_dir=''
		if [ -n "$backup_dir" ] && core_backup_files "$bin" "$backup_dir"; then
			ts_task_log "$id" backup_created "$backup_dir"
		else
			backup_dir=''
			warning='backup_unavailable'
			ts_task_log "$id" backup_skipped 'space or filesystem constraints prevented a backup'
		fi
	fi
	free_bin="$(ts_free_bytes "$bin")"
	if [ "$free_bin" -lt "$install_need" ]; then
		core_remove_backups "$backup_dir"
		backup_dir=''
		rm -f "$new"
		core_finish "$id" space_insufficient
		return 1
	fi
	expected_version="$version"
	if [ "$expected_version" = "latest" ]; then
		expected_version="$(ts_extract_version "$("$new" --version 2>&1)")"
	fi
	if [ "$was_running" = "1" ]; then
		ts_task_step "$id" stop 92 ""
	fi
	if ! core_stop_for_update "$init" 30; then
		if [ "$was_running" = "1" ] && ! ts_running; then
			TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
		fi
		core_remove_backups "$backup_dir"
		core_finish "$id" service_stop_fail
		return 1
	fi
	if ! mv -f "$new" "$bin/tailscaled"; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$old_version"
		return 1
	fi
	if ! chmod 755 "$bin/tailscaled"; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$old_version"
		return 1
	fi
	if ! ln -sf tailscaled "$bin/tailscale" && ! cp -f "$bin/tailscaled" "$bin/tailscale"; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$old_version"
		return 1
	fi
	if [ -z "$expected_version" ]; then
		expected_version="$(core_installed_version)" || expected_version=''
	fi
	if ! core_binary_version_ok "$bin" "$expected_version"; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" version_check_fail "$old_version"
		return 1
	fi
	ts_task_step "$id" install 95 ""
	if [ "$was_running" = "1" ]; then
		ts_task_step "$id" restart 97 ""
		socket="$(ts_uci_get main socket "$TS_DEF_SOCKET")"
		TS_STOP_KEEP_CONFIG=1 "$init" restart >/dev/null 2>&1 &
		if ! ts_wait_service "$id" "$bin" "$expected_version" "$socket"; then
			core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" restart_fail "$old_version"
			return 1
		fi
	fi
	core_remove_backups "$backup_dir"
	core_finish "$id" "" "$warning"
	return 0
}

official_install() {
	local id="$1" version="$2" dir bin init latest installed comparison force rc line restart_failed had_daemon had_cli cli_link was_running rollback backup_dir warning old_version arch file info download_bytes installed_bytes install_bytes install_need cache_need free_bin free_cache backup_bytes cache expected_version socket
	dir="$(ts_tmpdir)"
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	init="${TS_SELF_INIT:-/etc/init.d/tailscale}"
	latest="$(ts_official_latest)" || {
		ts_task_begin "$id"
		ts_task_done "$id" fetch_fail
		return 1
	}
	if [ "$version" != "latest" ] && [ "$version" != "$latest" ]; then
		ts_task_begin "$id"
		ts_task_done "$id" unsupported_version
		return 1
	fi
	installed="$(core_installed_version)" || installed=""
	comparison="$(ts_ver_cmp "$installed" "$latest")"
	force=0
	if ts_custom_layout && [ "$installed" = "$latest" ]; then force=1; fi
	if ts_custom_layout && [ "$comparison" = "1" ]; then
		ts_task_begin "$id"
		ts_task_done "$id" version_ahead
		return 1
	fi
	if ! ts_lock "$dir/download"; then
		ts_task_begin "$id"
		ts_task_done "$id" busy
		return 1
	fi
	ts_task_begin "$id"
	if [ ! -x "$bin/tailscale" ]; then
		core_finish "$id" core_missing
		return 1
	fi
	arch="$(ts_official_arch)" || {
		core_finish "$id" unsupported_version
		return 1
	}
	file="$(ts_official_file "$latest" "$arch")" || {
		core_finish "$id" fetch_fail
		return 1
	}
	info="$(ts_official_info "$latest" "$arch" "$file")"
	download_bytes="$(printf '%s' "$info" | sed -n 's/.*"download_bytes":\([0-9][0-9]*\).*/\1/p')"
	installed_bytes="$(printf '%s' "$info" | sed -n 's/.*"installed_bytes":\([0-9][0-9]*\).*/\1/p')"
	case "$download_bytes" in ''|*[!0-9]*) download_bytes=0 ;; esac
	case "$installed_bytes" in ''|*[!0-9]*) installed_bytes=0 ;; esac
	backup_bytes="$(core_backup_bytes "$bin")"
	install_bytes="$installed_bytes"
	[ "$install_bytes" -ge "$backup_bytes" ] || install_bytes="$backup_bytes"
	[ "$install_bytes" -gt 0 ] || install_bytes=1048576
	install_need=$((install_bytes + 1048576))
	cache_need="$download_bytes"
	[ "$cache_need" -gt 0 ] || cache_need="$install_bytes"
	cache_need=$((cache_need + 1048576))
	expected_version="$latest"
	cache="$(ts_cache_dir)"
	free_bin="$(ts_free_bytes "$bin")"
	free_cache="$(ts_free_bytes "$cache")"
	if [ "$free_bin" -lt "$install_need" ] || [ "$free_cache" -lt "$cache_need" ]; then
		core_finish "$id" space_insufficient
		return 1
	fi
	had_daemon=0
	[ -f "$bin/tailscaled" ] && had_daemon=1
	had_cli=0
	{ [ -e "$bin/tailscale" ] || [ -L "$bin/tailscale" ]; } && had_cli=1
	cli_link=''
	if [ -L "$bin/tailscale" ]; then cli_link="$(readlink "$bin/tailscale" 2>/dev/null)"; fi
	old_version="$installed"
	was_running=0
	ts_running && was_running=1
	rollback="$(ts_uci_get update auto_rollback '1')"
	backup_dir=''
	warning=''
	if [ "$rollback" = "1" ]; then
		backup_dir="$(core_backup_destination "$id" "$bin" "$dir" "$install_need")" || backup_dir=''
		if [ -n "$backup_dir" ]; then
			if core_backup_files "$bin" "$backup_dir"; then
				free_bin="$(ts_free_bytes "$bin")"
				free_cache="$(ts_free_bytes "$cache")"
				if [ "$free_bin" -lt "$install_need" ] || [ "$free_cache" -lt "$cache_need" ]; then
					core_remove_backups "$backup_dir"
					backup_dir=''
				fi
			else
				backup_dir=''
			fi
		fi
		if [ -z "$backup_dir" ] && [ "$backup_bytes" -gt 0 ]; then
			free_bin="$(ts_free_bytes "$bin")"
			free_cache="$(ts_free_bytes "$cache")"
			free_tmp="$(ts_free_bytes "$dir")"
			if [ "$free_bin" -ge "$install_need" ] && [ "$free_cache" -ge "$cache_need" ] && [ "$free_tmp" -ge "$((backup_bytes + 1048576))" ]; then
				backup_dir="$dir/rollback-$id"
				if ! core_backup_files "$bin" "$backup_dir"; then backup_dir=''; fi
			fi
		fi
		if [ -n "$backup_dir" ]; then
			free_bin="$(ts_free_bytes "$bin")"
			free_cache="$(ts_free_bytes "$cache")"
			if [ "$free_bin" -lt "$install_need" ] || [ "$free_cache" -lt "$cache_need" ]; then
				core_remove_backups "$backup_dir"
				backup_dir=''
			fi
		fi
		if [ -n "$backup_dir" ]; then
			ts_task_log "$id" backup_created "$backup_dir"
		else
			warning='backup_unavailable'
			ts_task_log "$id" backup_skipped 'space or filesystem constraints prevented a backup'
		fi
	fi
	free_bin="$(ts_free_bytes "$bin")"
	free_cache="$(ts_free_bytes "$cache")"
	if [ "$free_bin" -lt "$install_need" ] || [ "$free_cache" -lt "$cache_need" ]; then
		core_remove_backups "$backup_dir"
		core_finish "$id" space_insufficient
		return 1
	fi
	ts_task_step "$id" resolve 10 "$latest"
	ts_task_step "$id" download 25 "official $latest"
	if [ "$force" = "1" ]; then
		TS_UPDATE_SKIP_VERSION_CHECK=1 "$bin/tailscale" update --yes >"$dir/task-$id.native.log" 2>&1
		rc=$?
	else
		"$bin/tailscale" update --yes >"$dir/task-$id.native.log" 2>&1
		rc=$?
	fi
	restart_failed=0
	if grep -Eiq 'failed to restart tailscaled|failed to restart' "$dir/task-$id.native.log" 2>/dev/null; then restart_failed=1; fi
	while IFS= read -r line || [ -n "$line" ]; do
		ts_task_log "$id" official "$line"
	done <"$dir/task-$id.native.log"
	rm -f "$dir/task-$id.native.log"
	if [ "$rc" != "0" ]; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" official_update_fail "$old_version"
		return 1
	fi
	if [ "$restart_failed" = "1" ]; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" restart_fail "$old_version"
		return 1
	fi
	if ! chmod 755 "$bin/tailscale" "$bin/tailscaled"; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$old_version"
		return 1
	fi
	if ts_custom_layout || [ ! -x "$bin/tailscale" ] || [ ! -x "$bin/tailscaled" ]; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" channel_switch_fail "$old_version"
		return 1
	fi
	if ! core_binary_version_ok "$bin" "$latest"; then
		core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" version_check_fail "$old_version"
		return 1
	fi
	if [ "$was_running" = "1" ]; then
		socket="$(ts_uci_get main socket "$TS_DEF_SOCKET")"
		if ! ts_wait_service "$id" "$bin" "$latest" "$socket"; then
			core_update_failure "$id" "$bin" "$init" "$backup_dir" "$had_daemon" "$had_cli" "$cli_link" "$was_running" restart_fail "$old_version"
			return 1
		fi
	fi
	ts_task_step "$id" install 95 "$latest"
	core_remove_backups "$backup_dir"
	core_finish "$id" "" "$warning"
	return 0
}

core_ensure() {
	local dir bin version file arch rc
	dir="$(ts_tmpdir)"
	if ! ts_lock "$dir/bootstrap"; then
		return 3
	fi
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	if [ -x "$bin/tailscaled" ]; then
		if [ ! -x "$bin/tailscale" ]; then
			ln -sf tailscaled "$bin/tailscale" || cp -f "$bin/tailscaled" "$bin/tailscale"
		fi
		if core_installed_version >/dev/null 2>&1; then
			ts_unlock "$dir/bootstrap"
			return 0
		fi
	fi
	version="$(ts_uci_get update version 'latest')"
	file="$(ts_uci_get update file 'auto')"
	arch="$(ts_uci_get update arch 'auto')"
	TS_ARCH="$arch" core_install bootstrap-core "$version" "$file" auto
	rc="$?"
	ts_unlock "$dir/bootstrap"
	return "$rc"
}


core_file_bytes() {
	local file="$2" blob url bytes
	blob="$(ts_releases "$TS_PKG" "$1")" || return 1
	if [ -z "$file" ] || [ "$file" = auto ]; then
		file="$(core_resolve "$blob" latest auto | head -n 1)"
		[ -n "$file" ] || return 1
	fi
	url="$(ts_url "$blob" "$file")"
	[ -n "$url" ] || return 1
	bytes="$(ts_asset_bytes "$blob" "$file" "$url")"
	[ "$bytes" -gt 0 ] || return 1
	printf '%s' "$bytes"
}

core_files() {
	ts_assets "$1" "$TS_RE_CORE" "$2"
}

core_versions() {
	ts_versions "$1" "$TS_RE_CORE"
}

core_latest() {
	core_versions "$1" | head -n 1
}

core_check() {
	local source="$1" latest="${2:-}" installed desired comparison outdated mismatch
	if [ "$source" = "official" ] || { [ "$source" = "auto" ] && [ "$(ts_update_channel)" = "official" ]; }; then
		desired=official
		if [ -z "$latest" ]; then
			latest="$(ts_official_latest)" || {
				printf '{"ok":false,"error":"fetch_fail"}'
				return 1
			}
		fi
	else
		desired=custom
		if [ -z "$latest" ]; then
			latest="$(ts_latest_for "$TS_PKG" "$source")" || {
				printf '{"ok":false,"error":"fetch_fail"}'
				return 1
			}
		fi
	fi
	installed="$(core_installed_version)" || installed=""
	comparison="$(ts_ver_cmp "$installed" "$latest")"
	outdated=false
	[ "$comparison" = "-1" ] && outdated=true
	mismatch=false
	if [ "$desired" = official ] && ts_custom_layout; then
		mismatch=true
	elif [ "$desired" = custom ] && ! ts_custom_layout; then
		mismatch=true
	fi
	if [ "$mismatch" = true ] && [ "$comparison" != "1" ]; then
		outdated=true
	fi
	printf '{"ok":true,"installed":"%s","latest":"%s","outdated":%s,"channel_mismatch":%s}' "$installed" "$latest" "$outdated" "$mismatch"
}

luci_mgr() {
	if [ -f /lib/apk/db/installed ]; then
		printf 'apk'
	else
		printf 'opkg'
	fi
}

luci_suf() {
	if [ "$(luci_mgr)" = "apk" ]; then
		printf 'apk'
	else
		printf 'ipk'
	fi
}

luci_files() {
	local all suf
	all="$(ts_assets "$1" "$TS_RE_LUCI" "$2")"
	suf="$(luci_suf)"
	printf '%s\n' "$all" | grep "[.]$suf\$"
	printf '%s\n' "$all" | grep -v "[.]$suf\$"
}

luci_filevers() {
	ts_versions "$1" "^${TS_PKG_LUCI}[_-][0-9].*[.]$(luci_suf)\$"
}

luci_resolve() {
	local blob="$1" version="$2" want="$3"
	if [ "$want" != "auto" ]; then
		ts_assets "$blob" "$TS_RE_LUCI" | grep -Fx "$want"
		return $?
	fi
	if [ "$version" = "latest" ]; then
		version="$(luci_filevers "$blob" | head -n 1)"
	else
		version="$(ts_ver_norm "$version")"
	fi
	[ -n "$version" ] || return 1
	luci_files "$blob" "$version" | grep .
}

luci_installed_version() {
	local mgr version
	mgr="$(luci_mgr)"
	if [ "$mgr" = "apk" ]; then
		version="$(apk list --installed --manifest 2>/dev/null | awk -v p="$TS_PKG_LUCI" '$1 == p { print $2; exit }')"
	else
		version="$(opkg list-installed "$TS_PKG_LUCI" 2>/dev/null | cut -d' ' -f3)"
	fi
	if [ -z "$version" ]; then
		return 1
	fi
	ts_ver_norm "$version"
}

luci_check() {
	local src blob latest installed fetched
	fetched=0
	for src in $(ts_sources "$1"); do
		blob="$(ts_releases "$TS_PKG_LUCI" "$src")" || continue
		fetched=1
		latest="$(luci_filevers "$blob" | head -n 1)"
		if [ -z "$latest" ]; then
			continue
		fi
		installed="$(luci_installed_version)" || installed=""
		ts_check_json "$installed" "$latest"
		return 0
	done
	if [ "$fetched" = "1" ]; then
		printf '{"ok":false,"error":"no_match"}'
	else
		printf '{"ok":false,"error":"fetch_fail"}'
	fi
	return 1
}

luci_attempt() {
	local id="$1" blob="$2" file="$3" url="$4" dir pkg got mgr pkg_out
	dir="$(ts_tmpdir)"
	pkg="$dir/dl/$file"
	mgr="$(luci_mgr)"
	ts_task_step "$id" download 20 "$file"
	if ! ts_fetch "$url" "$pkg" "$(ts_uci_get update dl_timeout "$TS_DEF_DL")"; then
		rm -f "$pkg"
		ts_fetch_log "$id" "$file"
		return 1
	fi
	ts_task_step "$id" download 60 "$file"
	ts_verify "$id" "$blob" "$file" "$pkg" || {
		got="$?"
		rm -f "$pkg"
		return "$got"
	}
	ts_task_step "$id" install 90 "$file"
	if [ "$mgr" = "apk" ]; then
		pkg_out="$(apk add --allow-untrusted "$pkg" 2>&1)" || {
			rm -f "$pkg"
			ts_task_log "$id" pkg_fail "$(printf '%s' "$pkg_out" | tail -n 1)"
			return 6
		}
	else
		pkg_out="$(opkg install "$pkg" 2>&1)" || {
			rm -f "$pkg"
			ts_task_log "$id" pkg_fail "$(printf '%s' "$pkg_out" | tail -n 1)"
			return 6
		}
	fi
	rm -f "$pkg"
	case "$file" in
		"$TS_PKG_LUCI"*) luci_i18n_install "$id" "$blob" "$file" >/dev/null ;;
	esac
	printf '%s' "$file"
	return 0
}

luci_i18n_install() {
	local lang file
	lang="$(ts_uci_get update lang '')"
	case "$lang" in
		''|*[!a-z0-9-]*) return 0 ;;
	esac
	file="$(ts_assets "$2" "^luci-i18n-tailscale-${lang}[_-][0-9].*[.]$(luci_suf)\$" "$(ts_asset "$2" "$3" 1)" | head -n 1)"
	[ -n "$file" ] || return 0
	luci_attempt "$1" "$2" "$file" "$(ts_url "$2" "$file")" || ts_task_log "$1" i18n_skip "$file"
}

luci_finish() {
	local dir
	dir="$(ts_tmpdir)"
	cp -f "$dir/task-$1.log" "$dir/last-luci.log" 2>/dev/null
	ts_task_done "$1" "$2"
	ts_unlock "$dir/download"
}

luci_install() {
	local id="$1" version="$2" want="$3" wsrc="$4" dir out file fail
	dir="$(ts_tmpdir)"
	ts_task_begin "$id"
	if ! ts_lock "$dir/download"; then
		ts_task_done "$id" busy
		return 1
	fi
	out="$(ts_install_loop "$id" "$TS_PKG_LUCI" "$version" "$want" "$wsrc" luci_resolve luci_attempt)" || {
		fail="$out"
		luci_finish "$id" "$fail"
		return 1
	}
	file="${out#ok }"
	ts_task_step "$id" install 95 "$file"
	if [ -x /etc/init.d/uhttpd ]; then
		ts_task_log "$id" restart uhttpd
		/etc/init.d/uhttpd restart >/dev/null 2>&1
	fi
	luci_finish "$id" ""
	return 0
}

update_task_error() {
	local dir
	dir="$(ts_tmpdir)"
	grep -o '"error":"[^"]*"' "$dir/task-$1.json" 2>/dev/null | cut -d'"' -f4
}

update_hist() {
	local dir
	dir="$(ts_tmpdir)"
	printf '%s %s %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$dir/update-history.log"
	tail -n "$TS_DEF_HIST" "$dir/update-history.log" >"$dir/update-history.tmp"
	mv "$dir/update-history.tmp" "$dir/update-history.log"
}

update_one() {
	local mode="$1" id="$2" version="$3" want="$4" out installed latest outdated err iv
	if [ "$mode" = "core" ]; then
		out="$(core_check auto)"
	else
		out="$(luci_check auto)"
	fi
	installed="$(printf '%s' "$out" | grep -o '"installed":"[^"]*"' | cut -d'"' -f4)"
	latest="$(printf '%s' "$out" | grep -o '"latest":"[^"]*"' | cut -d'"' -f4)"
	outdated="$(printf '%s' "$out" | grep -o '"outdated":[a-z]*' | cut -d: -f2)"
	if [ -z "$outdated" ]; then
		update_hist "$mode" "check-failed"
		return 0
	elif [ "$outdated" != "true" ]; then
		update_hist "$mode" "$installed->$latest current"
		return 0
	fi
	iv="$version"
	if [ "$version" = "latest" ]; then
		iv="$latest"
	fi
	if [ "$mode" = "core" ]; then
		if [ "$(ts_update_channel)" = "official" ]; then
			official_install "$id" "$iv"
		else
			core_install "$id" "$iv" "$want" auto
		fi
	else
		luci_install "$id" "$iv" "$want" auto
	fi
	if [ "$?" = "0" ]; then
		update_hist "$mode" "$installed->$latest updated"
	else
		err="$(update_task_error "$id")"
		update_hist "$mode" "$installed->$latest failed($err)"
	fi
	return 0
}

update_auto() {
	local version file
	version="$(ts_uci_get update version 'latest')"
	file="$(ts_uci_get update file 'auto')"
	update_one core auto-core "$version" "$file"
	if [ "$version" != "latest" ] || [ "$file" != "auto" ]; then
		update_hist luci "skipped version-pinned"
		return 0
	fi
	update_one luci auto-luci latest auto
	return 0
}

update_c2n() {
	local channel out installed latest outdated mismatch
	channel="$(ts_update_channel)"
	if [ "$channel" = "official" ]; then
		official_install c2n-official latest
		return $?
	fi
	out="$(core_check auto)" || {
		printf '%s\n' 'custom update check failed' >&2
		return 1
	}
	installed="$(printf '%s' "$out" | grep -o '"installed":"[^"]*"' | cut -d'"' -f4)"
	latest="$(printf '%s' "$out" | grep -o '"latest":"[^"]*"' | cut -d'"' -f4)"
	outdated="$(printf '%s' "$out" | grep -o '"outdated":[a-z]*' | cut -d: -f2)"
	mismatch="$(printf '%s' "$out" | grep -o '"channel_mismatch":[a-z]*' | cut -d: -f2)"
	if [ -z "$latest" ] || [ -z "$outdated" ]; then
		printf '%s\n' 'custom update check returned invalid data' >&2
		return 1
	fi
	if [ "$outdated" = "true" ]; then
		core_install c2n-custom "$latest" auto auto
		return $?
	fi
	if [ "$mismatch" = "true" ]; then
		printf 'custom build %s is older than installed %s; refusing automatic downgrade\n' "$latest" "$installed" >&2
		return 1
	fi
	printf 'already running custom build %s\n' "$installed"
	return 0
}


update_project_check() {
	case "$1" in
		tailscale) core_check "$2" ;;
		luci-app-tailscale) luci_check "$2" ;;
		*) return 2 ;;
	esac
}

update_list() {
	local proj="$1" source="$2" mode="${3:-full}" package blob versions version files first comma check installed result latest
	case "$proj" in
		tailscale) package="$TS_PKG" ;;
		luci-app-tailscale) package="$TS_PKG_LUCI" ;;
		*) return 2 ;;
	esac
	if [ "$proj" = tailscale ] && [ "$source" = official ]; then
		if [ "$mode" = tags ]; then
			version="$(ts_official_latest)" || return 1
			printf '{"source":"official","tags":["%s"]}' "$version"
			return 0
		fi
		if [ "$mode" = rpc ]; then
			latest="$(ts_official_latest)" || return 1
			result="$(ts_official_list "$latest")" || return 1
			check="$(core_check official "$latest" 2>/dev/null)"
			[ -n "$check" ] || check='null'
			printf '%s,"check":%s}' "${result%?}" "$check"
			return 0
		fi
		ts_official_list
		return $?
	fi
	case "$source" in
		gitlab|r2|github) ;;
		*) return 2 ;;
	esac
	blob="$(ts_releases "$package" "$source")" || return 1
	if [ "$proj" = "tailscale" ]; then
		versions="$(core_versions "$blob")"
	else
		versions="$(luci_filevers "$blob")"
	fi
	latest=''
	if [ "$mode" = rpc ] && [ "$proj" = tailscale ]; then latest="$(printf '%s\n' "$versions" | head -n 1)"; fi
	printf '{"source":"%s","tags":[' "$source"
	comma=''
	for version in $versions; do
		printf '%s"%s"' "$comma" "$version"
		comma=','
	done
	printf ']'
	if [ "$mode" = tags ]; then
		printf '}'
		return 0
	fi
	printf ',"files":{'
	comma=''
	for version in $versions; do
		if [ "$proj" = "tailscale" ]; then
			files="$(core_resolve "$blob" "$version" all)"
		else
			files="$(luci_resolve "$blob" "$version" auto)"
		fi
		printf '%s"%s":[' "$comma" "$version"
		first=''
		for file in $files; do
			printf '%s"%s"' "$first" "$file"
			first=','
		done
		printf ']'
		comma=','
		if [ "$mode" = rpc ]; then break; fi
	done
	printf '}'
	if [ "$mode" = rpc ]; then
		if [ "$proj" = tailscale ]; then
			check="$(core_check "$source" "$latest" 2>/dev/null)"
			[ -n "$check" ] || check='null'
			printf ',"check":%s' "$check"
		else
			installed="$(luci_installed_version 2>/dev/null)" || installed=''
			if [ -n "$installed" ]; then printf ',"installed_version":"%s"' "$installed"; fi
		fi
	fi
	printf '}'
}

update_version_files() {
	local proj="$1" source="$2" version="$3" package blob files file comma
	case "$proj" in
		tailscale) package="$TS_PKG" ;;
		luci-app-tailscale) package="$TS_PKG_LUCI" ;;
		*) return 2 ;;
	esac
	case "$source" in
		gitlab|r2|github) ;;
		*) return 2 ;;
	esac
	version="$(ts_ver_norm "$version")"
	[ -n "$version" ] || return 1
	blob="$(ts_releases "$package" "$source")" || return 1
	if [ "$proj" = tailscale ]; then
		files="$(core_resolve "$blob" "$version" all)" || return 1
	else
		files="$(luci_resolve "$blob" "$version" auto)" || return 1
	fi
	printf '{"source":"%s","version":"%s","files":[' "$source" "$version"
	comma=''
	for file in $files; do
		printf '%s"%s"' "$comma" "$file"
		comma=','
	done
	printf ']}'
}

update_resolve() {
	local proj="$1" blob="$2" version="$3" file="$4" arch="$5" wanted
	case "$proj" in
		tailscale)
			case "$blob" in
				*/rel-official-tailscale.json)
					[ "$version" = latest ] && version="$(ts_official_latest)"
					[ -z "$version" ] && return 1
					[ "$arch" = auto ] && arch="$(ts_official_arch)"
					wanted="$(ts_official_file "$version" "$arch")" || return 1
					if [ "$file" = auto ] || [ "$file" = "$wanted" ]; then printf '%s' "$wanted"; else return 1; fi
					;;
				*) TS_ARCH="$arch" core_resolve "$blob" "$version" "$file" ;;
			esac
			;;
		luci-app-tailscale) luci_resolve "$blob" "$version" "$file" ;;
		*) return 2 ;;
	esac
}

update_installed() {
	case "$1" in
		tailscale) core_installed_version ;;
		luci-app-tailscale) luci_installed_version ;;
		*) return 2 ;;
	esac
}

update_download() {
	local proj="$1" id="$2" version="$3" file="$4" source="$5" arch="$6"
	case "$proj" in
		tailscale)
			if [ "$source" = official ]; then
				official_install "$id" "$version"
			else
				TS_ARCH="$arch" core_install "$id" "$version" "$file" "$source"
			fi
			;;
		luci-app-tailscale) luci_install "$id" "$version" "$file" "$source" ;;
		*) return 2 ;;
	esac
}


pkg_upgrading() {
	local pid="$$" depth=0 args
	[ "$PKG_UPGRADE" = "1" ] && return 0
	case " $* " in
		*" upgrade "*) return 0 ;;
	esac
	while [ "$depth" -lt 16 ]; do
		case "$pid" in
			''|*[!0-9]*|0|1) return 1 ;;
		esac
		args="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
		case "${args%% *}" in
			opkg|*/opkg) case " $args " in *" install "*|*" upgrade "*) return 0 ;; esac ;;
			apk|*/apk) case " $args " in *" add "*|*" upgrade "*|*" fix "*) return 0 ;; esac ;;
		esac
		pid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)"
		depth=$((depth + 1))
	done
	return 1
}

pkg_foreign() {
	local list
	for list in /usr/lib/opkg/info/*.list /lib/apk/packages/*.list; do
		[ -f "$list" ] || continue
		[ "${list##*/}" = "$TS_PKG_LUCI.list" ] && continue
		awk -v f="$1" '$1 == f { found = 1; exit } END { exit !found }' "$list" && return 0
	done
	return 1
}

purge_paths() {
	local dir="$1" name
	shift
	[ -n "$dir" ] || return 0
	case "${dir##*/}" in
		*tailscale*) printf '%s\n' "$dir" ;;
		*) for name in "$@"; do printf '%s\n' "$dir"/$name; done ;;
	esac
}

state_paths() {
	purge_paths "$1" 'tailscaled.*' derpmap.cached.json
}

core_backup() {
	local tmp rel='' path
	for path in /etc/config/tailscale $(state_paths "$1"); do
		[ -e "$path" ] && rel="$rel ${path#/}"
	done
	[ -n "$rel" ] || return 0
	tmp="$(mktemp /tmp/tailscale-luci-app-backup.XXXXXX)" || return 1
	if tar czf "$tmp" -C / $rel 2>/dev/null; then
		mv -f "$tmp" "$TS_BACKUP_FILE"
	else
		rm -f "$tmp"
		return 1
	fi
}

core_restore() {
	local stage state
	[ -f "$TS_BACKUP_FILE" ] && [ -O "$TS_BACKUP_FILE" ] || return 0
	stage="$(mktemp -d /tmp/tailscale-luci-app-restore.XXXXXX)" || return 1
	if tar xzf "$TS_BACKUP_FILE" -C "$stage" 2>/dev/null && [ -f "$stage/etc/config/tailscale" ]; then
		cp -f "$stage/etc/config/tailscale" /etc/config/tailscale
		state="$(ts_abs_dir "$(ts_uci_get main state_dir "$TS_DEF_STATE")")"
		if [ -n "$state" ] && [ -d "$stage$state" ]; then
			mkdir -p "$state" && cp -a "$stage$state/." "$state/"
		fi
		rm -f "$TS_BACKUP_FILE"
	fi
	rm -rf "$stage"
}

purge_cron() {
	local cron="${TS_CRON_FILE:-/etc/crontabs/root}" lib="$1"
	grep -qE "^# tailscale-auto|$lib/" "$cron" 2>/dev/null || return 0
	sed -i -e '/^# tailscale-auto/d' -e "\\#$lib/#d" "$cron"
	"${TS_CRON_INIT:-/etc/init.d/cron}" restart >/dev/null 2>&1
}

core_uninstall() {
	local init="${TS_SELF_INIT:-/etc/init.d/tailscale}" lib="${TS_LIBDIR:-/usr/libexec/tailscale}" cli=/usr/bin/tailscale bin state socket file
	rm -f "$TS_PURGE_LIST"
	if pkg_upgrading "$@"; then
		: >"$TS_UPGRADE_MARKER"
		return 0
	fi
	rm -f "$TS_UPGRADE_MARKER"
	bin="$(ts_abs_dir "$(ts_uci_get main bin_dir "$TS_DEF_BIN")")"
	state="$(ts_abs_dir "$(ts_uci_get main state_dir "$TS_DEF_STATE")")"
	socket="$(ts_uci_get main socket "$TS_DEF_SOCKET")"
	TS_STOP_RELOAD_NETWORK=1 "$init" stop >/dev/null 2>&1
	"$init" disable >/dev/null 2>&1
	core_stop_for_update "$init" 15 || killall tailscaled tailscale >/dev/null 2>&1
	[ -n "$bin" ] && [ -x "$bin/tailscaled" ] && "$bin/tailscaled" --cleanup >/dev/null 2>&1
	core_backup "$state"
	purge_cron "$lib"
	{
		[ "$(readlink "$cli" 2>/dev/null)" = "$lib/cli-dispatch.sh" ] && printf '%s\n' "$cli"
		if [ -n "$bin" ] && ! pkg_foreign "$bin/tailscaled" && ! pkg_foreign "$bin/tailscale"; then
			printf '%s\n' "$bin/tailscaled" "$bin/tailscale" "$bin"/.tailscale-update-* "$bin"/.tailscale-stage-*
			state_paths "$state"
			purge_paths "$(ts_abs_dir "${socket%/*}")" "${socket##*/}"
			printf '%s\n' "$(ts_cache_dir)/tailscale-update"
		fi
		purge_paths "$(ts_abs_dir "$(ts_uci_get main tmp_dir "$TS_DEF_TMP")")"
		for file in /etc/config/tailscale /etc/config/tailscale-opkg /etc/config/tailscale.apk-new /tmp/.uci/tailscale; do
			pkg_foreign "$file" || printf '%s\n' "$file"
		done
	} >"$TS_PURGE_LIST"
}


case "${1:-}" in
	auto|--auto) update_auto ;;
	c2n-update) update_c2n ;;
	ensure-core) core_ensure ;;
	manual-install) core_manual_install "$2" ;;
	remove-core) core_remove ;;
	list) update_list "$2" "$3" "$4" ;;
	tags) update_list "$2" "$3" tags ;;
	files) update_version_files "$2" "$3" "$4" ;;
	check) update_project_check "$2" "$3" ;;
	resolve) update_resolve "$2" "$3" "$4" "$5" "$6" ;;
	download) update_download "$2" "$3" "$4" "$5" "$6" "$7" ;;
	url) ts_url "$2" "$3" | grep . ;;
	size) core_file_bytes "$2" "$3" ;;
	installed) update_installed "$2" ;;
	core-versions) core_versions "$2" ;;
	luci-filevers) luci_filevers "$2" ;;
	luci-mgr) luci_mgr ;;
	uninstall) shift; core_uninstall "$@" ;;
	restore) core_restore ;;
	*) printf 'usage: %s {auto|ensure-core|manual-install|remove-core|list|tags|files|check|resolve|download|url|size|installed}\n' "${0##*/}" >&2; exit 2 ;;
esac
