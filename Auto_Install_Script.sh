#!/bin/sh
API_NAME="$1"
[ -z "$API_NAME" ] && { echo "无法获取包名"; exit 1; }
API="https://gitlab.com/api/v4/projects/whzhni%2F${API_NAME}/releases"
echo "包名: $API_NAME"
if command -v opkg >/dev/null 2>&1; then
    MGR=opkg EXT=ipk
    ARCH=$(opkg print-architecture | awk '!/all|noarch/{a=$2}END{print a}')
elif command -v apk >/dev/null 2>&1; then
    MGR=apk EXT=apk
    ARCH=$(apk --print-arch)
else
    echo "✗ 未识别包管理器"; exit 1
fi
case "$ARCH" in
    aarch64*) ARCH_ALT=arm64;;
    arm_arm926*|arm_fa526|arm_xscale) ARCH_ALT=armv5;;
    arm_arm1176*|arm_mpcore) ARCH_ALT=armv6;;
    arm*) ARCH_ALT=armv7;;
    i386*) ARCH_ALT=i386;;
    mipsel*) ARCH_ALT=mipsle_hardfloat;;
    mips*) ARCH_ALT=mips_hardfloat;;
    *) ARCH_ALT=$ARCH;;
esac
echo "📦 包管理器: $MGR | 架构: $ARCH → $ARCH_ALT"
echo "⏳ 获取软件包列表..."
DATA=$(curl -sL "$API") || { echo "✗ API请求失败"; exit 1; }
FILES=$(echo "$DATA" | grep -o "\"[^\"]*\.${EXT}\"" | tr -d '"' | grep -v "/")
[ -z "$FILES" ] && { echo "✗ 未找到文件"; exit 1; }
echo "  共 $(echo "$FILES" | wc -l) 个文件"
TS_FILES=$(echo "$FILES" | grep "^${API_NAME}_" | sort -u)
BEST=$(echo "$TS_FILES" | grep "_${ARCH}\." | head -1)
[ -z "$BEST" ] && BEST=$(echo "$TS_FILES" | grep "_${ARCH_ALT}\." | head -1)
[ -z "$BEST" ] && BEST=$(echo "$TS_FILES" | grep "_generic\." | head -1)
echo ""
echo "=== $API_NAME 安装包 ==="
i=1; for f in $TS_FILES; do
    [ "$f" = "$BEST" ] && echo "$i. $f ★ 最佳匹配" || echo "$i. $f"
    i=$((i+1))
done
printf "选择安装 : "
read n < /dev/tty
[ -z "$n" ] && n=1
SEL=$(echo "$TS_FILES" | sed -n "${n}p")
[ -z "$SEL" ] && { echo "✗ 无效选择"; exit 1; }

install_pkg() {
    local file="$1" url
    url=$(echo "$DATA" | grep -o "https://[^\"]*/${file}\"" | tr -d '"' | head -1)
    [ -z "$url" ] && { echo "✗ 未找到: $file"; return 1; }
    echo "⬇️  下载: $file"
    curl -sL -o "/tmp/$file" "$url" || { echo "✗ 下载失败"; return 1; }
    echo "📦 安装: $file"
    case "$MGR" in
        opkg) opkg install "/tmp/$file" ;;
        apk)  apk add --allow-untrusted "/tmp/$file" ;;
    esac
    rm -f "/tmp/$file"
}
install_pkg "$SEL" || exit 1
LUCI=$(echo "$FILES" | grep "^luci-app-${API_NAME}" | head -1)
[ -n "$LUCI" ] && { echo ""; echo "📌 安装LuCI..."; install_pkg "$LUCI"; }
I18N_FILES=$(echo "$FILES" | grep "^luci-i18n-${API_NAME}" | sort -u)
if [ -n "$I18N_FILES" ]; then
    echo ""
    echo "=== 语言包 ==="
    i=1; for f in $I18N_FILES; do echo "$i. $f"; i=$((i+1)); done
    echo "0. 跳过"
    printf "选择语言包 : "
    read ln < /dev/tty
    [ -n "$ln" ] && [ "$ln" != "0" ] && {
        I18N_SEL=$(echo "$I18N_FILES" | sed -n "${ln}p")
        [ -n "$I18N_SEL" ] && install_pkg "$I18N_SEL"
    }
fi
echo ""
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart 2>/dev/null
echo "✅ 安装完成!"
