#!/bin/sh
[ $# -eq 0 ] && { echo "用法: $0 <包名> ..."; exit 1; }

if command -v opkg >/dev/null 2>&1; then
    MGR=opkg EXT=ipk
    ARCH=$(opkg print-architecture | awk '!/all|noarch/{a=$2}END{print a}')
elif command -v apk >/dev/null 2>&1; then
    MGR=apk EXT=apk
    ARCH=$(apk --print-arch)
else
    echo "✗ 未识别包管理器"; exit 1
fi

ensure_cmd() {
    cmd="$1"
    shift
    command -v "$cmd" >/dev/null 2>&1 || {
        $MGR update >/dev/null 2>&1
        echo "⚙️  安装 $cmd ..."
        case "$MGR" in opkg) opkg install "$cmd";; apk) apk add "$cmd";; esac
    }
    [ $# -gt 0 ] && "$cmd" "$@"
}

ARCH_KEY=$(echo "$ARCH" | cut -d'_' -f1)
case "$ARCH_KEY" in
    aarch64) ARCH_ALT=arm64;;
    arm) ARCH_ALT=armv7;;
    i386) ARCH_ALT=x86;;
    x86_64) ARCH_ALT=amd64;;
    mipsel) ARCH_ALT=mipsle;;
    mips) ARCH_ALT=mips;;
    *) ARCH_ALT=$ARCH_KEY;;
esac
echo "📦 包管理器：$MGR | 架构：$ARCH → $ARCH_KEY → $ARCH_ALT"

install_pkg() {
    local file="$1" url
    url=$(echo "$DATA" | grep -o "https://[^\"]*/${file}" | head -1)
    [ -z "$url" ] && { echo "✗ 未找到: $file"; return 1; }
    echo "⬇️  $file"
    curl -sL -o "/tmp/$file" "$url" || { echo "✗ 下载失败"; return 1; }
    case "$MGR" in opkg) opkg install "/tmp/$file";; apk) apk add --allow-untrusted "/tmp/$file";; esac
    rm -f "/tmp/$file"
}

menu_install() {
    [ -z "$2" ] && return 0
    echo ""; echo "=== $1 ==="
    local i=1 f; for f in $2; do [ "$f" = "$3" ] && echo "$i. $f ★ 最佳匹配" || echo "$i. $f"; i=$((i+1)); done
    [ "$4" = "1" ] && echo "0. 跳过"
    while true; do
        printf "选择: "; read n < /dev/tty
        [ -z "$n" ] && n=1
        [ "$n" = "0" ] && return 0
        f=$(echo "$2" | sed -n "${n}p")
        [ -n "$f" ] && break
        echo "✗ 无效选择，请重新输入"
    done
    install_pkg "$f"
}

for API_NAME in "$@"; do
    echo ""; echo "═══════ $API_NAME ═══════"
    DATA=$(ensure_cmd curl -sL "https://gitlab.com/api/v4/projects/whzhni%2F${API_NAME}/releases") || { echo "✗ API失败"; continue; }
    FILES=$(echo "$DATA" | grep -o '"[^"]*\.'"${EXT}"'"' | tr -d '"' | grep -v "/" | sort -u)
    [ -z "$FILES" ] && { echo "✗ 无文件"; continue; }
    
    MAIN=$(echo "$FILES" | grep -v "^luci-")
    if [ -n "$MAIN" ]; then
        BEST=""
        for p in "$ARCH" "$ARCH_KEY" "$ARCH_ALT" "generic"; do
            BEST=$(echo "$MAIN" | grep "$p" | head -1)
            [ -n "$BEST" ] && break
        done
        menu_install "主程序" "$MAIN" "$BEST" 0
    fi
    
    LUCI=$(echo "$FILES" | grep "^luci-app-" | head -1)
    [ -n "$LUCI" ] && { echo ""; echo "📌 LuCI"; install_pkg "$LUCI"; }
    
    I18N=$(echo "$FILES" | grep "^luci-i18n-")
    menu_install "语言包" "$I18N" "" 1
done

rm -f /tmp/luci-indexcache; /etc/init.d/uhttpd restart 2>/dev/null
echo ""; echo "✅ 完成!"
