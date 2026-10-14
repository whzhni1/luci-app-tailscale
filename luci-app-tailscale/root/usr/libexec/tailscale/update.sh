#!/bin/sh
TS_PKG=tailscale
TS_DEF_TMP=/tmp/tailscale
TS_DEF_BIN=/usr/sbin
TS_DEF_SOURCES='gitlab r2 github'
TS_DEF_TIMEOUT=20
TS_DEF_RETRY=2
TS_DEF_TTL=3600
TS_DEF_JITTER=600
TS_DEF_DL=600
TS_DEF_KEEP=1
TS_DEF_TRYRUN=10
TS_DEF_GH_WINDOW=40
TS_PKG_LUCI=luci-app-tailscale
TS_DEF_STATE=/etc/tailscale
TS_DEF_SOCKET=/var/run/tailscale/tailscaled.sock
TS_DEF_TUN=tailscale0
TS_DEF_HIST=50
TS_DEF_LAN=lan
TS_DEF_WAN=wan
TS_DEF_UPWAIT=5
TS_DEF_BOOTWAIT=30
TS_DEF_UPTIMEOUT=600

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
	local dir
	dir="$(ts_tmpdir)"
	if [ -z "$2" ]; then
		printf '{"step":"done","percent":100,"msg":"","done":true,"error":""}' >"$dir/task-$1.json"
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
	local url="$1" out="$2" max="$3" timeout retry attempt
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
	while [ "$attempt" -le "$retry" ]; do
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --connect-timeout "$timeout" --max-time "$max" -o "$out" "$url" && return 0
		elif command -v uclient-fetch >/dev/null 2>&1; then
			uclient-fetch --timeout="$max" -O "$out" "$url" && return 0
		elif command -v wget >/dev/null 2>&1; then
			wget -q -T "$max" -O "$out" "$url" && return 0
		else
			return 2
		fi
		attempt=$((attempt + 1))
		sleep "$attempt"
	done
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
	local dir ttl cache stamp now
	dir="$(ts_tmpdir)"
	ttl="$(ts_uci_get update cache_ttl "$TS_DEF_TTL")"
	cache="$dir/rel-official-tailscale.json"
	if [ -f "$cache" ]; then
		stamp="$(stat -c %Y "$cache" 2>/dev/null || printf '0')"
		now="$(date +%s)"
		if [ $((now - stamp)) -lt "$ttl" ]; then
			printf '%s' "$cache"
			return 0
		fi
	fi
	if ts_fetch 'https://pkgs.tailscale.com/stable/?mode=json&os=linux' "$cache.tmp" "$(ts_uci_get update timeout "$TS_DEF_TIMEOUT")"; then
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
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	printf '%s' "$size"
}

ts_free_bytes() {
	local path="$1" bytes
	bytes="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 { printf "%.0f", $4 * 1024 }')"
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	printf '%s' "$bytes"
}

ts_update_required_bytes() {
	local channel="$1" rollback
	rollback="$(ts_uci_get update auto_rollback '1')"
	case "$channel:$rollback" in
		custom:1) printf '%s' $((30 * 1048576)) ;;
		custom:*) printf '%s' $((10 * 1048576)) ;;
		official:1) printf '%s' $((200 * 1048576)) ;;
		official:*) printf '%s' $((130 * 1048576)) ;;
		*) printf '0' ;;
	esac
}

ts_update_free_bytes() {
	local channel="$1" bin tmp cache_home cache_parent free_bin free_tmp free_cache minimum
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	tmp="$(ts_tmpdir)"
	free_bin="$(ts_free_bytes "$bin")"
	free_tmp="$(ts_free_bytes "$tmp")"
	minimum="$free_bin"
	[ "$free_tmp" -ge "$minimum" ] || minimum="$free_tmp"
	if [ "$channel" = "official" ]; then
		cache_home="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}"
		cache_parent="$cache_home"
		[ -d "$cache_parent" ] || cache_parent="${HOME:-/root}"
		free_cache="$(ts_free_bytes "$cache_parent")"
		[ "$free_cache" -ge "$minimum" ] || minimum="$free_cache"
	fi
	printf '%s' "$minimum"
}

ts_update_space_check() {
	local channel="$1" available required
	available="$(ts_update_free_bytes "$channel")"
	required="$(ts_update_required_bytes "$channel")"
	[ "$required" -gt 0 ] && [ "$available" -ge "$required" ]
}

ts_official_download_bytes() {
	local url="$1" bytes
	if command -v curl >/dev/null 2>&1; then
		bytes="$(curl -fsSI -L --connect-timeout 8 --max-time 20 "$url" 2>/dev/null | awk 'BEGIN { IGNORECASE=1 } tolower($1)=="content-length:" { gsub("\\r", "", $2); value=$2 } END { if (value ~ /^[0-9]+$/) print value; else print 0 }')"
	else
		bytes=0
	fi
	case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
	printf '%s' "$bytes"
}

ts_official_info() {
	local version="$1" arch="$2" file="$3" bin url cli_real daemon_real cli_bytes daemon_bytes installed_bytes cache_home cache_parent free_bin free_cache download_bytes
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
	cache_home="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}"
	cache_parent="$cache_home"
	[ -d "$cache_parent" ] || cache_parent="${HOME:-/root}"
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
	local version arch file info
	version="$(ts_official_latest)" || return 1
	arch="$(ts_official_arch)" || return 1
	file="$(ts_official_file "$version" "$arch")" || return 1
	info="$(ts_official_info "$version" "$arch" "$file")"
	printf '{"source":"official","tags":["%s"],"files":{"%s":["%s"]},"info":%s}' "$version" "$version" "$file" "$info"
}

ts_match_files() {
	local icase=""
	if [ "$4" = "i" ]; then icase="-i"; fi
	grep $icase -o "$2[A-Za-z0-9._-]*$3" "$1" | grep -vi 'sha256' | sort -u
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
	printf '%s' "$order"
}

ts_releases() {
	local dir ttl cache url stamp now
	dir="$(ts_tmpdir)"
	ttl="$(ts_uci_get update cache_ttl "$TS_DEF_TTL")"
	cache="$dir/rel-$2-$1.json"
	url="$(ts_api_url "$2" "$1")" || return 1
	if [ -f "$cache" ]; then
		stamp="$(stat -c %Y "$cache" 2>/dev/null || printf '0')"
		now="$(date +%s)"
		if [ $((now - stamp)) -lt "$ttl" ]; then
			printf '%s' "$cache"
			return 0
		fi
	fi
	if ts_fetch "$url" "$cache.tmp"; then
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

ts_versions() {
	grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" | cut -d'"' -f4 | while IFS= read -r tag; do
		ts_ver_norm "$tag"
		printf '\n'
	done | sort -Vru
}

ts_latest() {
	ts_versions "$1" | head -n 1
}

ts_url() {
	grep -o 'https\?://[^" ]*' "$1" | grep -F -m1 "$2"
}

ts_hash() {
	local esc hash
	esc="$(printf '%s' "$2" | sed 's/\./\\./g')"
	hash="$(grep -o "${esc}\\\\nsha256:[0-9a-f]\\{64\\}" "$1" | head -n 1 | grep -o '[0-9a-f]\{64\}$')"
	if [ -n "$hash" ]; then
		printf '%s' "$hash"
		return 0
	fi
	grep -A"$TS_DEF_GH_WINDOW" -F "\"name\": \"$2\"" "$1" | grep -o -m1 'sha256:[0-9a-f]\{64\}' | cut -d: -f2
}

ts_latest_for() {
	local proj="$1" want="$2" src blob latest
	for src in $(ts_sources "$want"); do
		blob="$(ts_releases "$proj" "$src")" || continue
		latest="$(ts_latest "$blob")"
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

core_resolve() {
	local blob="$1" version="$2" want="$3" files token
	if [ "$version" = "latest" ]; then
		version="$(ts_latest "$blob")"
	else
		version="$(ts_ver_norm "$version")"
	fi
	if [ -z "$version" ]; then
		return 1
	fi
	files="$(ts_match_files "$blob" 'tailscale' '\.tar\.gz' | grep -F "_${version}_")"
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
	local id="$1" blob="$2" file="$3" url="$4" dir pkg expect got member new
	dir="$(ts_tmpdir)"
	pkg="$dir/dl/$file"
	ts_task_step "$id" download 20 "$file"
	if ! ts_fetch "$url" "$pkg" "$(ts_uci_get update dl_timeout "$TS_DEF_DL")"; then
		rm -f "$pkg"
		ts_task_log "$id" fetch_fail "$file"
		return 1
	fi
	ts_task_step "$id" download 60 "$file"
	expect="$(ts_hash "$blob" "$file")"
	if [ -z "$expect" ]; then
		rm -f "$pkg"
		ts_task_log "$id" no_hash "$file"
		return 2
	fi
	got="$(ts_sha256_file "$pkg")"
	if [ "$got" != "$expect" ]; then
		rm -f "$pkg"
		ts_task_log "$id" hash_mismatch "$file"
		return 3
	fi
	ts_task_step "$id" verify 70 "$file"
	member="$(core_member "$pkg")"
	if [ -z "$member" ]; then
		rm -f "$pkg"
		ts_task_log "$id" extract_fail "$file"
		return 4
	fi
	new="$dir/dl/tailscaled.new"
	if ! tar -xzOf "$pkg" "$member" >"$new" 2>/dev/null; then
		rm -f "$pkg" "$new"
		ts_task_log "$id" extract_fail "$file"
		return 4
	fi
	ts_task_step "$id" extract 80 "$file"
	chmod 755 "$new"
	if ! core_tryrun "$new"; then
		rm -f "$pkg" "$new"
		ts_task_log "$id" tryrun_fail "$file"
		return 5
	fi
	ts_task_step "$id" tryrun 85 "$file"
	rm -f "$pkg"
	printf '%s' "$new"
	return 0
}

core_finish() {
	local dir
	dir="$(ts_tmpdir)"
	cp -f "$dir/task-$1.log" "$dir/last-core.log" 2>/dev/null
	ts_task_done "$1" "$2"
	ts_unlock "$dir/download"
}

core_cli_running() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x tailscale >/dev/null 2>&1
	else
		pidof tailscale >/dev/null 2>&1
	fi
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
		if ! "$init" stop >/dev/null 2>&1; then
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
		"$init" restart >/dev/null 2>&1 &
	fi
	if [ -n "$result" ] && [ "$changed" = 1 ] && [ "$backup_ok" = 1 ]; then
		if ts_running; then "$init" stop >/dev/null 2>&1; fi
		if cat "$backup" > "$bin/tailscaled" && chmod 755 "$bin/tailscaled" && ln -sf tailscaled "$bin/tailscale"; then
			result='rolled_back'
			"$init" restart >/dev/null 2>&1 &
		else
			result='rollback_fail'
		fi
	fi
	if [ -n "$result" ] && [ "$cli_removed" = 1 ] && [ ! -e "$bin/tailscale" ] && [ ! -L "$bin/tailscale" ]; then
		ln -sf tailscaled "$bin/tailscale" || result='rollback_fail'
	fi
	if [ -n "$result" ] && [ "$changed" = 0 ] && [ "$was_running" = 1 ] && ! ts_running; then
		"$init" restart >/dev/null 2>&1 &
	fi
	core_finish "$id" "$result"
	core_manual_cleanup "$id"
	[ -z "$result" ]
}

core_backup_files() {
	local bin="$1"
	rm -f "$bin/tailscale.bak.new" "$bin/tailscaled.bak.new"
	if [ -f "$bin/tailscaled" ] && ! cp -p "$bin/tailscaled" "$bin/tailscaled.bak.new"; then
		rm -f "$bin/tailscale.bak.new" "$bin/tailscaled.bak.new"
		return 1
	fi
	if [ -f "$bin/tailscale" ] && [ ! -L "$bin/tailscale" ] && ! cp -p "$bin/tailscale" "$bin/tailscale.bak.new"; then
		rm -f "$bin/tailscale.bak.new" "$bin/tailscaled.bak.new"
		return 1
	fi
	if [ -f "$bin/tailscaled.bak.new" ]; then
		mv -f "$bin/tailscaled.bak.new" "$bin/tailscaled.bak" || return 1
	else
		rm -f "$bin/tailscaled.bak" || return 1
	fi
	if [ -f "$bin/tailscale.bak.new" ]; then
		mv -f "$bin/tailscale.bak.new" "$bin/tailscale.bak" || return 1
	else
		rm -f "$bin/tailscale.bak" || return 1
	fi
	return 0
}

core_remove_backups() {
	rm -f "$1/tailscale.bak" "$1/tailscaled.bak" "$1/tailscale.bak.new" "$1/tailscaled.bak.new"
}

core_restore_files() {
	local bin="$1" had_daemon="$2" had_cli="$3" cli_link="$4" rc=0
	if [ "$had_daemon" = "1" ]; then
		if ! cp -p "$bin/tailscaled.bak" "$bin/tailscaled"; then rc=1; fi
	else
		rm -f "$bin/tailscaled" || rc=1
	fi
	if [ "$had_cli" = "1" ]; then
		if [ -n "$cli_link" ]; then
			rm -f "$bin/tailscale" || rc=1
			ln -s "$cli_link" "$bin/tailscale" || rc=1
		elif [ -f "$bin/tailscale.bak" ]; then
			cp -p "$bin/tailscale.bak" "$bin/tailscale" || rc=1
		else
			rc=1
		fi
	else
		rm -f "$bin/tailscale" || rc=1
	fi
	return "$rc"
}

core_rollback() {
	local id="$1" bin="$2" init="$3" had_daemon="$4" had_cli="$5" cli_link="$6" was_running="$7" cause="$8"
	ts_task_log "$id" update_failed "$cause"
	if ! core_restore_files "$bin" "$had_daemon" "$had_cli" "$cli_link"; then
		ts_task_log "$id" rollback_fail 'binary restoration failed'
		core_finish "$id" rollback_fail
		return 1
	fi
	if [ "$was_running" = "1" ] && ! "$init" restart >/dev/null 2>&1; then
		ts_task_log "$id" rollback_fail 'service restart after restoration failed'
		core_finish "$id" rollback_fail
		return 1
	fi
	core_remove_backups "$bin"
	ts_task_log "$id" rollback 'previous binary state restored'
	core_finish "$id" rolled_back
	return 1
}

core_update_failure() {
	local id="$1" bin="$2" init="$3" had_daemon="$4" had_cli="$5" cli_link="$6" was_running="$7" cause="$8" rollback="${9:-1}"
	if [ "$rollback" = "1" ]; then
		core_rollback "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" "$cause"
		return 1
	fi
	ts_task_log "$id" update_failed "$cause"
	core_finish "$id" update_fail_no_rollback
	return 1
}

core_install() {
	local id="$1" version="$2" want="$3" wsrc="$4" dir bin out new fail init had_daemon had_cli cli_link was_running rollback
	dir="$(ts_tmpdir)"
	bin="$(ts_uci_get main bin_dir "$TS_DEF_BIN")"
	init="${TS_SELF_INIT:-/etc/init.d/tailscale}"
	mkdir -p "$bin" 2>/dev/null
	ts_task_begin "$id"
	if ! ts_update_space_check custom; then
		ts_task_done "$id" space_insufficient
		return 1
	fi
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
	had_daemon=0
	[ -f "$bin/tailscaled" ] && had_daemon=1
	had_cli=0
	{ [ -e "$bin/tailscale" ] || [ -L "$bin/tailscale" ]; } && had_cli=1
	cli_link=''
	if [ -L "$bin/tailscale" ]; then cli_link="$(readlink "$bin/tailscale" 2>/dev/null)"; fi
	was_running=0
	ts_running && was_running=1
	rollback="$(ts_uci_get update auto_rollback '1')"
	if [ "$rollback" = "1" ] && ! core_backup_files "$bin"; then
		ts_task_log "$id" backup_fail ''
		core_finish "$id" backup_fail
		return 1
	fi
	if ! mv -f "$new" "$bin/tailscaled"; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$rollback"
		return 1
	fi
	if ! chmod 755 "$bin/tailscaled"; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$rollback"
		return 1
	fi
	if ! ln -sf tailscaled "$bin/tailscale" && ! cp -f "$bin/tailscaled" "$bin/tailscale"; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$rollback"
		return 1
	fi
	if [ ! -x "$bin/tailscale" ] || [ ! -x "$bin/tailscaled" ]; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$rollback"
		return 1
	fi
	ts_task_step "$id" install 95 ""
	if [ "$was_running" = "1" ]; then
		ts_task_step "$id" restart 98 ""
		if ! "$init" restart >/dev/null 2>&1; then
			core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" restart_fail "$rollback"
			return 1
		fi
	fi
	core_remove_backups "$bin"
	core_finish "$id" ""
	return 0
}

official_install() {
	local id="$1" version="$2" dir bin init latest installed comparison force rc line restart_failed had_daemon had_cli cli_link was_running rollback
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
	had_daemon=0
	[ -f "$bin/tailscaled" ] && had_daemon=1
	had_cli=0
	{ [ -e "$bin/tailscale" ] || [ -L "$bin/tailscale" ]; } && had_cli=1
	cli_link=''
	if [ -L "$bin/tailscale" ]; then cli_link="$(readlink "$bin/tailscale" 2>/dev/null)"; fi
	was_running=0
	ts_running && was_running=1
	if ! ts_update_space_check official; then
		core_finish "$id" space_insufficient
		return 1
	fi
	rollback="$(ts_uci_get update auto_rollback '1')"
	if [ "$rollback" = "1" ] && ! core_backup_files "$bin"; then
		ts_task_log "$id" backup_fail ''
		core_finish "$id" backup_fail
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
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" official_update_fail "$rollback"
		return 1
	fi
	if [ "$restart_failed" = "1" ]; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" restart_fail "$rollback"
		return 1
	fi
	if ! chmod 755 "$bin/tailscale" "$bin/tailscaled"; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" install_fail "$rollback"
		return 1
	fi
	if ts_custom_layout || [ ! -x "$bin/tailscale" ] || [ ! -x "$bin/tailscaled" ]; then
		core_update_failure "$id" "$bin" "$init" "$had_daemon" "$had_cli" "$cli_link" "$was_running" channel_switch_fail "$rollback"
		return 1
	fi
	ts_task_step "$id" install 95 "$latest"
	core_remove_backups "$bin"
	core_finish "$id" ""
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

core_urlhash() {
	local blob="$1" file="$2" url hash
	url="$(ts_url "$blob" "$file")"
	hash="$(ts_hash "$blob" "$file")"
	printf '{"url":"%s","sha256":"%s"}' "$url" "$hash"
	if [ -n "$url" ] && [ -n "$hash" ]; then
		return 0
	fi
	return 1
}

core_versions() {
	ts_versions "$1"
}

core_check() {
	local source="$1" latest installed desired comparison outdated mismatch
	if [ "$source" = "official" ] || { [ "$source" = "auto" ] && [ "$(ts_update_channel)" = "official" ]; }; then
		desired=official
		latest="$(ts_official_latest)" || {
			printf '{"ok":false,"error":"fetch_fail"}'
			return 1
		}
	else
		desired=custom
		latest="$(ts_latest_for "$TS_PKG" "$source")" || {
			printf '{"ok":false,"error":"fetch_fail"}'
			return 1
		}
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

luci_file_version() {
	local rest
	rest="${1#luci-app-tailscale}"
	rest="${rest#[_-]}"
	rest="${rest%.ipk}"
	rest="${rest%.apk}"
	printf '%s' "$rest" | grep -o '^[0-9][0-9A-Za-z.+-]*' | head -n 1
}

luci_sort_ver() {
	local f v
	while IFS= read -r f; do
		if [ -n "$f" ]; then
			v="$(luci_file_version "$f")"
			printf '%s|%s\n' "$v" "$f"
		fi
	done | sort -Vr | cut -d'|' -f2-
}

luci_files() {
	local all mgr suf first rest
	all="$(ts_match_files "$1" 'luci-app-tailscale' '\.\(ipk\|apk\)' i)"
	mgr="$(luci_mgr)"
	suf='ipk'
	if [ "$mgr" = "apk" ]; then
		suf='apk'
	fi
	first="$(printf '%s\n' "$all" | grep -F ".$suf")"
	rest="$(printf '%s\n' "$all" | grep -Fv ".$suf")"
	{
		printf '%s\n' "$first" | luci_sort_ver
		printf '%s\n' "$rest" | luci_sort_ver
	} | awk 'NF && !seen[$0]++'
}

luci_filevers() {
	local mgr suf files f v
	mgr="$(luci_mgr)"
	suf='ipk'
	if [ "$mgr" = "apk" ]; then
		suf='apk'
	fi
	files="$(luci_files "$1" | grep -F ".$suf")"
	for f in $files; do
		v="$(ts_ver_norm "$(luci_file_version "$f")")"
		if [ -n "$v" ]; then
			printf '%s\n' "$v"
		fi
	done | sort -Vru
}

luci_resolve() {
	local blob="$1" version="$2" want="$3" files f v pin
	if [ "$want" != "auto" ]; then
		files="$(ts_match_files "$blob" 'luci-app-tailscale' '\.\(ipk\|apk\)' i)"
		printf '%s\n' "$files" | grep -Fx "$want"
		return $?
	fi
	files="$(luci_files "$blob")"
	if [ -z "$files" ]; then
		return 1
	fi
	if [ "$version" = "latest" ]; then
		printf '%s\n' "$files"
		return 0
	fi
	pin="$(ts_ver_norm "$version")"
	for f in $files; do
		v="$(ts_ver_norm "$(luci_file_version "$f")")"
		if [ "$v" = "$pin" ]; then
			printf '%s\n' "$f"
		fi
	done
}

luci_installed_version() {
	local mgr version
	mgr="$(luci_mgr)"
	if [ "$mgr" = "apk" ]; then
		version="$(apk info -v "$TS_PKG_LUCI" 2>/dev/null | head -n 1 | sed "s/^$TS_PKG_LUCI-//")"
	else
		version="$(opkg list-installed "$TS_PKG_LUCI" 2>/dev/null | cut -d' ' -f3)"
	fi
	if [ -z "$version" ]; then
		return 1
	fi
	ts_ver_norm "$version"
}

luci_check() {
	local src blob files first latest installed fetched
	fetched=0
	for src in $(ts_sources "$1"); do
		blob="$(ts_releases "$TS_PKG_LUCI" "$src")" || continue
		fetched=1
		files="$(luci_files "$blob")"
		if [ -z "$files" ]; then
			continue
		fi
		first="$(printf '%s\n' "$files" | head -n 1)"
		latest="$(ts_ver_norm "$(luci_file_version "$first")")"
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
	local id="$1" blob="$2" file="$3" url="$4" dir pkg expect got mgr pkg_out
	dir="$(ts_tmpdir)"
	pkg="$dir/dl/$file"
	mgr="$(luci_mgr)"
	ts_task_step "$id" download 20 "$file"
	if ! ts_fetch "$url" "$pkg" "$(ts_uci_get update dl_timeout "$TS_DEF_DL")"; then
		rm -f "$pkg"
		ts_task_log "$id" fetch_fail "$file"
		return 1
	fi
	ts_task_step "$id" download 60 "$file"
	expect="$(ts_hash "$blob" "$file")"
	if [ -z "$expect" ]; then
		rm -f "$pkg"
		ts_task_log "$id" no_hash "$file"
		return 2
	fi
	got="$(ts_sha256_file "$pkg")"
	if [ "$got" != "$expect" ]; then
		rm -f "$pkg"
		ts_task_log "$id" hash_mismatch "$file"
		return 3
	fi
	ts_task_step "$id" install 90 "$file"
	if [ "$mgr" = "apk" ]; then
		pkg_out="$(apk add --allow-untrusted "$pkg" 2>&1)" || {
			rm -f "$pkg"
			ts_task_log "$id" pkg_fail "$(printf '%s' "$pkg_out" | tail -n 1)"
			return 6
		}
	else
		pkg_out="$(opkg install --force-reinstall --force-downgrade "$pkg" 2>&1)" || {
			rm -f "$pkg"
			ts_task_log "$id" pkg_fail "$(printf '%s' "$pkg_out" | tail -n 1)"
			return 6
		}
	fi
	rm -f "$pkg"
	printf '%s' "$file"
	return 0
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
	local proj="$1" source="$2" package blob versions version files first comma
	case "$proj" in
		tailscale) package="$TS_PKG" ;;
		luci-app-tailscale) package="$TS_PKG_LUCI" ;;
		*) return 2 ;;
	esac
	if [ "$proj" = tailscale ] && [ "$source" = official ]; then
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
	printf '{"source":"%s","tags":[' "$source"
	comma=''
	for version in $versions; do
		printf '%s"%s"' "$comma" "$version"
		comma=','
	done
	printf '],"files":{'
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
	done
	printf '}}'
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


case "${1:-}" in
	auto|--auto) update_auto ;;
	c2n-update) update_c2n ;;
	ensure-core) core_ensure ;;
	manual-install) core_manual_install "$2" ;;
	list) update_list "$2" "$3" ;;
	check) update_project_check "$2" "$3" ;;
	resolve) update_resolve "$2" "$3" "$4" "$5" "$6" ;;
	download) update_download "$2" "$3" "$4" "$5" "$6" "$7" ;;
	urlhash) core_urlhash "$2" "$3" ;;
	installed) update_installed "$2" ;;
	core-versions) core_versions "$2" ;;
	luci-filevers) luci_filevers "$2" ;;
	luci-mgr) luci_mgr ;;
	"") printf 'usage: %s {auto|ensure-core|manual-install|list|check|resolve|download|urlhash|installed}\n' "${0##*/}" >&2; exit 2 ;;
	*) printf 'usage: %s {auto|ensure-core|manual-install|list|check|resolve|download|urlhash|installed}\n' "${0##*/}" >&2; exit 2 ;;
esac
