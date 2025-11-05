#!/bin/sh

# ==================== 全局配置 ====================
SCRIPT_VERSION="1.0.4"
LOG_FILE="/tmp/auto-update.log"
CONFIG_BACKUP_DIR="/tmp/config_Backup"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"

# 安装优先级：1=官方优先，其他=Gitee优先
INSTALL_PRIORITY=1

# Gitee 配置
GITEE_OWNERS="whzhni sirpdboy kiddin9"

# 脚本更新源（按优先级排序）
SCRIPT_URLS="https://raw.gitcode.com https://gitee.com"
SCRIPT_PATH="/whzhni/luci-app-tailscale/raw/main/auto-update.sh"

# 排除列表
EXCLUDE_PACKAGES="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky"

# ==================== 包管理器变量 ====================
PKG_EXT=""           # .ipk 或 .apk
PKG_INSTALL=""       # 安装命令
PKG_UPDATE=""        # 更新源命令
SYS_ARCH=""          # 系统架构

# ==================== 工具函数 ====================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    case "$1" in -*) ;; *) logger -t "auto-update" "$1" 2>/dev/null ;; esac
}

# ==================== 检测包管理器 ====================
detect_package_manager() {
    if which opkg >/dev/null 2>&1; then
        PKG_EXT=".ipk"
        PKG_INSTALL="opkg install"
        PKG_UPDATE="opkg update"
    else
        PKG_EXT=".apk"
        PKG_INSTALL="apk add --allow-untrusted"
        PKG_UPDATE="apk update"
    fi
    log "包管理器: $(echo $PKG_INSTALL | awk '{print $1}')"
    log "包格式: $PKG_EXT"
}

get_system_arch() {
    if [ -z "$SYS_ARCH" ]; then
        case "$(uname -m)" in
            aarch64)   SYS_ARCH="arm64" ;;
            armv7l)    SYS_ARCH="armv7" ;;
            armv6l)    SYS_ARCH="armv6" ;;
            armv5tel)  SYS_ARCH="armv5" ;;
            x86_64)    SYS_ARCH="x86_64" ;;
            i686|i386) SYS_ARCH="i386" ;;
            mips)      SYS_ARCH="mips" ;;
            mipsel)    SYS_ARCH="mipsle" ;;
            riscv64)   SYS_ARCH="riscv64" ;;
            *)         SYS_ARCH="unknown" ;;
        esac
        log "系统架构: $SYS_ARCH"
    fi
}

normalize_version() {
    echo "$1" | sed 's/^[vV]//' | sed 's/-r\?[0-9]\+$//'
}

compare_versions() {
    local v1=$(normalize_version "$1")
    local v2=$(normalize_version "$2")
    log "  [版本对比] $1 → $v1  vs  $2 → $v2"
    [ "$v1" = "$v2" ]
}

# ==================== 获取更新周期 ====================
get_update_schedule() {
    local cron_entry=$(crontab -l 2>/dev/null | grep "auto-update.sh" | grep -v "^#" | head -n1)
    
    [ -z "$cron_entry" ] && { echo "未设置"; return; }
    
    local minute=$(echo "$cron_entry" | awk '{print $1}')
    local hour=$(echo "$cron_entry" | awk '{print $2}')
    local day=$(echo "$cron_entry" | awk '{print $3}')
    local month=$(echo "$cron_entry" | awk '{print $4}')
    local weekday=$(echo "$cron_entry" | awk '{print $5}')
    
    local week_name=""
    case "$weekday" in
        0|7) week_name="日" ;;
        1) week_name="一" ;;
        2) week_name="二" ;;
        3) week_name="三" ;;
        4) week_name="四" ;;
        5) week_name="五" ;;
        6) week_name="六" ;;
    esac
    
    local hour_str=""
    if [ "$hour" != "*" ] && ! echo "$hour" | grep -q "/"; then
        hour_str=$(printf "%02d" "$hour")
    fi
    
    if [ "$weekday" != "*" ]; then
        if [ -n "$hour_str" ]; then
            echo "每周${week_name} ${hour_str}点"
        else
            echo "每周${week_name}"
        fi
    elif echo "$hour" | grep -q "^\*/"; then
        local h=$(echo "$hour" | sed 's/\*\///')
        echo "每${h}小时"
    elif echo "$day" | grep -q "^\*/"; then
        local d=$(echo "$day" | sed 's/\*\///')
        if [ -n "$hour_str" ]; then
            echo "每${d}天 ${hour_str}点"
        else
            echo "每${d}天"
        fi
    elif [ "$hour" != "*" ] && [ "$day" = "*" ]; then
        echo "每天${hour_str}点"
    elif [ "$hour" = "*" ] && echo "$minute" | grep -q "^\*/"; then
        local m=$(echo "$minute" | sed 's/\*\///')
        echo "每${m}分钟"
    elif [ "$hour" = "*" ] && [ "$minute" != "*" ]; then
        echo "每小时"
    else
        echo "$minute $hour $day $month $weekday"
    fi
}

# ==================== 状态推送函数 ====================
send_status_push() {
    : > "$LOG_FILE"
    
    log "======================================"
    log "发送状态推送"
    log "======================================"
    
    local schedule=$(get_update_schedule)
    
    local message="自动更新已打开\n\n"
    message="${message}**脚本版本**: $SCRIPT_VERSION\n"
    message="${message}**自动更新时间**: $schedule\n\n"
    message="${message}---\n"
    message="${message}设备: $DEVICE_MODEL\n"
    message="${message}时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    log "推送内容:"
    log "  版本: $SCRIPT_VERSION"
    log "  计划: $schedule"
    log ""
    
    send_push "$PUSH_TITLE" "$message"
    
    log "======================================"
    log "状态推送完成"
    log "======================================"
}

# ==================== 包管理函数 ====================
is_package_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for pattern in $EXCLUDE_PACKAGES; do
        case "$1" in $pattern*) return 0 ;; esac
    done
    return 1
}

is_installed() {
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg list-installed | grep -q "^$1 "
    else
        apk info -e "$1" >/dev/null 2>&1
    fi
}

get_package_version() {
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg "$1" | grep "^$2 " | awk '{print $3}'
    else
        case "$1" in
            list-installed)
                apk info "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
                ;;
            list)
                apk search "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut-d'-' -f1
                ;;
        esac
    fi
}

install_language_package() {
    local pkg="$1" lang_pkg=""
    case "$pkg" in
        luci-app-*)   lang_pkg="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang_pkg="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return 0 ;;
    esac
    
    # 检查语言包是否存在于软件源
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg list 2>/dev/null | grep -q "^$lang_pkg " || return 0
    else
        apk search "$lang_pkg" 2>/dev/null | grep -q "^$lang_pkg" || return 0
    fi
    
    # 检查是否已安装
    local action="安装"
    is_installed "$lang_pkg" && action="升级"
    
    log "    ${action}语言包 $lang_pkg..."
    if $PKG_INSTALL "$lang_pkg" >>"$LOG_FILE" 2>&1; then
        log "    ✓ $lang_pkg ${action}成功"
    else
        log "    ⚠ $lang_pkg ${action}失败（不影响主程序）"
    fi
}

# ==================== 配置备份 ====================
backup_config() {
    log "  备份配置到 $CONFIG_BACKUP_DIR ..."
    rm -rf "$CONFIG_BACKUP_DIR" 2>/dev/null
    mkdir -p "$CONFIG_BACKUP_DIR"
    cp -r /etc/config/* "$CONFIG_BACKUP_DIR/" 2>/dev/null && \
        log "  ✓ 配置备份成功" || log "  ⚠ 配置备份失败"
}

restore_config() {
    [ ! -d "$CONFIG_BACKUP_DIR" ] && return 1
    log "  恢复配置..."
    if cp -r "$CONFIG_BACKUP_DIR"/* /etc/config/ 2>/dev/null; then
        log "  ✓ 配置恢复成功"
        rm -rf "$CONFIG_BACKUP_DIR"
    else
        log "  ✗ 配置恢复失败"
        return 1
    fi
}

cleanup_backup() {
    rm -rf "$CONFIG_BACKUP_DIR" 2>/dev/null
}

# ==================== 推送函数 ====================
send_push() {
    [ ! -f "/etc/config/wechatpush" ] && { log "⚠ wechatpush 未安装"; return 1; }
    [ "$(uci get wechatpush.config.enable 2>/dev/null)" != "1" ] && { log "⚠ wechatpush 未启用"; return 1; }
    
    local token=$(uci get wechatpush.config.pushplus_token 2>/dev/null)
    local api="pushplus" url="http://www.pushplus.plus/send"
    
    if [ -z "$token" ]; then
        token=$(uci get wechatpush.config.serverchan_3_key 2>/dev/null)
        api="serverchan3" url="https://sctapi.ftqq.com/${token}.send"
    fi
    
    if [ -z "$token" ]; then
        token=$(uci get wechatpush.config.serverchan_key 2>/dev/null)
        api="serverchan" url="https://sc.ftqq.com/${token}.send"
    fi
    
    [ -z "$token" ] && { log "⚠ 未配置推送"; return 1; }
    
    log "发送推送 ($api)..."
    
    local response=""
    if [ "$api" = "pushplus" ]; then
        local content=$(echo "$2" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        response=$(curl -s -X POST "$url" -H "Content-Type: application/json" \
            -d "{\"token\":\"$token\",\"title\":\"$1\",\"content\":\"$content\",\"template\":\"txt\"}")
        echo "$response" | grep -q '"code":200' && { log "✓ 推送成功"; return 0; }
    else
        response=$(curl -s -X POST "$url" -d "text=$1" -d "desp=$2")
        echo "$response" | grep -q '"errno":0\|"code":0' && { log "✓ 推送成功"; return 0; }
    fi
    
    log "✗ 推送失败: $response"
    return 1
}

# ==================== 包分类函数 ====================
classify_packages() {
    log "======================================"
    log "步骤: 分类已安装的包"
    log "======================================"
    
    log "更新软件源..."
    if ! $PKG_UPDATE >>"$LOG_FILE" 2>&1; then
        log "✗ 软件源更新失败"
        return 1
    fi
    log "✓ 软件源更新成功"
    
    OFFICIAL_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    EXCLUDED_COUNT=0
    
    local pkgs=""
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        pkgs=$(opkg list-installed | awk '{print $1}' | grep -v "^luci-i18n-")
    else
        pkgs=$(apk info 2>/dev/null | grep -v "^luci-i18n-")
    fi
    
    local total=$(echo "$pkgs" | wc -l)
    
    log "检测到 $total 个已安装包（已排除语言包）"
    log "分类中..."
    
    for pkg in $pkgs; do
        if is_package_excluded "$pkg"; then
            EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
        elif echo "$PKG_INSTALL" | grep -q "opkg"; then
            if opkg info "$pkg" 2>/dev/null | grep -q "^Description:"; then
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            else
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            fi
        else
            # apk 简单判断：有仓库来源的算官方
            if apk info "$pkg" 2>/dev/null | grep -q "^origin:"; then
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            else
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            fi
        fi
    done
    
    local official_count=$(echo $OFFICIAL_PACKAGES | wc -w)
    local non_official_count=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
    
    log "--------------------------------------"
    log "包分类完成:"
    log "  ✓ 官方源: $official_count 个"
    log "  ⊗ 非官方源: $non_official_count 个"
    log "  ⊝ 排除: $EXCLUDED_COUNT 个"
    log ""
    
    return 0
}

# ==================== Gitee 函数 ====================
find_gitee_repo() {
    for owner in $GITEE_OWNERS; do
        local repo="${owner}/$1"
        [ "$(curl -s -o /dev/null -w "%{http_code}" "https://gitee.com/api/v5/repos/${repo}/releases/latest")" = "200" ] && \
            { echo "$repo"; return 0; }
    done
    return 1
}

get_gitee_version() {
    local json=$(curl -s "https://gitee.com/api/v5/repos/$1/releases/latest")
    [ -z "$json" ] && return 1
    echo "$json" | grep -o '"tag_name":"[^"]*"' | head -n1 | cut -d'"' -f4
}

# ==================== Gitee 更新函数 ====================
update_from_gitee() {
    local pkg="$1" repo="$2"
    local app_name="${pkg#luci-app-}"
    app_name="${app_name#luci-theme-}"
    
    log "  从 Gitee 更新 $pkg (仓库: $repo)"
    backup_config
    
    local json=$(curl -s "https://gitee.com/api/v5/repos/${repo}/releases/latest")
    
    [ -z "$json" ] && { log "  ✗ API 请求失败"; cleanup_backup; return 1; }
    
    local version=$(echo "$json" | grep -o '"tag_name":"[^"]*"' | head -n1 | cut -d'"' -f4)
    [ -z "$version" ] && { log "  ✗ 无法获取版本"; cleanup_backup; return 1; }
    
    log "  版本: $version"
    
    # 获取所有包文件（完整URL）
    local all_files=$(echo "$json" | grep -o "\"browser_download_url\":\"[^\"]*\\${PKG_EXT}\"" | cut -d'"' -f4)
    [ -z "$all_files" ] && { log "  ✗ 未找到 ${PKG_EXT} 文件"; cleanup_backup; return 1; }
    
    log "  ====== 可用文件 ======"
    echo "$all_files" | while read url; do 
        [ -n "$url" ] && log "    $(basename "$url")"
    done
    log "  ====================="
    
    # 定义关键字组合（用 | 分隔关键字）
    local search_rules="
$SYS_ARCH
luci-app|$app_name
luci-theme|$app_name
luci-i18n|$app_name|zh-cn
"
    
    # 搜索匹配的文件
    local matched_files=""
    local old_IFS="$IFS"
    IFS=$'\n'
    
    for rule in $search_rules; do
        [ -z "$rule" ] && continue
        
        IFS='|'
        set -- $rule
        local keywords="$*"
        IFS=$'\n'
        
        for file_url in $all_files; do
            local filename=$(basename "$file_url")
            
            # 跳过已匹配的
            case " $matched_files " in *" $file_url "*) continue ;; esac
            
            # 检查所有关键字是否都匹配
            local all_match=1
            IFS='|'
            for kw in $rule; do
                [ -z "$kw" ] && continue
                echo "$filename" | grep -qi "$kw" || { all_match=0; break; }
            done
            IFS=$'\n'
            
            # 主程序排除 luci- 开头
            if ! echo "$rule" | grep -q "luci-"; then
                echo "$filename" | grep -q "^luci-" && all_match=0
            fi
            
            if [ $all_match -eq 1 ]; then
                matched_files="$matched_files $file_url"
                log "  [匹配] [$keywords] -> $filename"
                break
            fi
        done
    done
    
    IFS="$old_IFS"
    
    [ -z "$matched_files" ] && { log "  ✗ 未找到匹配文件"; cleanup_backup; return 1; }
    
    log "  ====== 安装计划 ======"
    for url in $matched_files; do
        log "    $(basename "$url")"
    done
    log "  ====================="
    
    # 下载并安装
    local count=0
    for file_url in $matched_files; do
        local filename=$(basename "$file_url")
        
        log "  "
        log "  ------ 处理文件 ------"
        log "  文件名: $filename"
        log "  下载地址: $file_url"
        
        if ! curl -fsSL -o "/tmp/$filename" "$file_url"; then
            log "  ✗ 下载失败"
            rm -f /tmp/*${app_name}*${PKG_EXT} 2>/dev/null
            restore_config
            return 1
        fi
        log "  ✓ 下载完成"
        
        log "  开始安装..."
        if echo "$PKG_INSTALL" | grep -q "opkg"; then
            if opkg install --force-reinstall "/tmp/$filename" >>"$LOG_FILE" 2>&1; then
                log "  ✓ 安装成功"
                count=$((count + 1))
            else
                log "  ⚠ 强制重装失败，尝试卸载后安装..."
                local pkg_name=$(echo "$filename" | sed "s/_.*\\${PKG_EXT}$//")
                opkg remove "$pkg_name" >>"$LOG_FILE" 2>&1
                if opkg install "/tmp/$filename" >>"$LOG_FILE" 2>&1; then
                    log "  ✓ 安装成功"
                    count=$((count + 1))
                else
                    log "  ✗ 安装失败"
                    rm -f /tmp/*${app_name}*${PKG_EXT} 2>/dev/null
                    restore_config
                    return 1
                fi
            fi
        else
            if $PKG_INSTALL "/tmp/$filename" >>"$LOG_FILE" 2>&1; then
                log "  ✓ 安装成功"
                count=$((count + 1))
            else
                log "  ✗ 安装失败"
                rm -f /tmp/*${app_name}*${PKG_EXT} 2>/dev/null
                restore_config
                return 1
            fi
        fi
        log "  ----------------------"
    done
    
    rm -f /tmp/*${app_name}*${PKG_EXT} 2>/dev/null
    restore_config
    
    log "  "
    log "  =============================="
    log "  ✓ $pkg 更新完成 (v$version, $count 个包)"
    log "  =============================="
    return 0
}

# ==================== 官方源更新 ====================
update_official_packages() {
    log "======================================"
    log "步骤: 更新官方源中的包"
    log "======================================"
    
    OFFICIAL_UPDATED=0 OFFICIAL_SKIPPED=0 OFFICIAL_FAILED=0
    UPDATED_PACKAGES="" FAILED_PACKAGES=""
    
    local count=$(echo $OFFICIAL_PACKAGES | wc -w)
    log "需要检查的官方源包: $count 个"
    log "--------------------------------------"
    
    for pkg in $OFFICIAL_PACKAGES; do
        local cur=$(get_package_version list-installed "$pkg")
        local new=$(get_package_version list "$pkg")
        
        if [ "$cur" != "$new" ] && [ -n "$new" ]; then
            log "↻ $pkg: $cur → $new"
            log "  正在升级..."
            
            if echo "$PKG_INSTALL" | grep -q "opkg"; then
                if opkg upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                    install_language_package "$pkg"
                else
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
            else
                if apk upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                else
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
            fi
        else
            log "○ $pkg: $cur (已是最新)"
            OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED + 1))
        fi
    done
    
    log "--------------------------------------"
    log "官方源检查完成:"
    log "  ✓ 升级: $OFFICIAL_UPDATED 个"
    log "  ○ 已是最新: $OFFICIAL_SKIPPED 个"
    log "  ✗ 失败: $OFFICIAL_FAILED 个"
    log ""
    
    return 0
}

# ==================== Gitee 源更新 ====================
update_gitee_packages() {
    log "======================================"
    log "步骤: 检查并更新 Gitee 源的包"
    log "======================================"
    
    GITEE_UPDATED=0 GITEE_SAME=0 GITEE_NOTFOUND=0 GITEE_FAILED=0
    GITEE_UPDATED_LIST="" GITEE_NOTFOUND_LIST="" GITEE_FAILED_LIST=""
    
    # 筛选需要检查的包
    local check_list=""
    for pkg in $NON_OFFICIAL_PACKAGES; do
        case "$pkg" in
            luci-app-*|luci-theme-*|lucky) check_list="$check_list $pkg" ;;
        esac
    done
    
    local count=$(echo $check_list | wc -w)
    [ $count -eq 0 ] && { log "没有需要从 Gitee 检查的插件"; log ""; return 0; }
    
    log "需要从 Gitee 检查的插件: $count 个"
    log "--------------------------------------"
    
    for pkg in $check_list; do
        local cur=$(get_package_version list-installed "$pkg")
        log "🔍 检查 $pkg (当前版本: $cur)"
        
        local repo=$(find_gitee_repo "$pkg")
        if [ $? -ne 0 ]; then
            log "  ⊗ 未找到 Gitee 仓库 (已尝试: $GITEE_OWNERS)"
            GITEE_NOTFOUND_LIST="${GITEE_NOTFOUND_LIST}\n    - $pkg"
            GITEE_NOTFOUND=$((GITEE_NOTFOUND + 1))
            log ""
            continue
        fi
        
        log "  ✓ 找到仓库: $repo"
        
        local ver=$(get_gitee_version "$repo")
        if [ -z "$ver" ]; then
            log "  ✗ 无法获取版本信息"
            GITEE_FAILED_LIST="${GITEE_FAILED_LIST}\n    - $pkg (无法获取版本)"
            GITEE_FAILED=$((GITEE_FAILED + 1))
            log ""
            continue
        fi
        
        log "  当前版本: $cur"
        log "  Gitee 版本: $ver"
        
        if compare_versions "$cur" "$ver"; then
            log "  ○ 版本相同，无需更新"
            GITEE_SAME=$((GITEE_SAME + 1))
        else
            log "  ↻ 版本不同，开始更新..."
            if update_from_gitee "$pkg" "$repo"; then
                GITEE_UPDATED_LIST="${GITEE_UPDATED_LIST}\n    - $pkg: $cur → $ver"
                GITEE_UPDATED=$((GITEE_UPDATED + 1))
            else
                GITEE_FAILED_LIST="${GITEE_FAILED_LIST}\n    - $pkg (更新失败)"
                GITEE_FAILED=$((GITEE_FAILED + 1))
            fi
        fi
        log ""
    done
    
    log "--------------------------------------"
    log "Gitee 检查完成:"
    log "  ✓ 已更新: $GITEE_UPDATED 个"
    log "  ○ 已是最新: $GITEE_SAME 个"
    log "  ⊗ 未找到仓库: $GITEE_NOTFOUND 个"
    log "  ✗ 失败: $GITEE_FAILED 个"
    log ""
    
    return 0
}

# ==================== 脚本自更新 ====================
check_script_update() {
    log "======================================"
    log "检查脚本更新"
    log "======================================"
    log "当前脚本版本: $SCRIPT_VERSION"
    
    local temp="/tmp/auto-update-new.sh"
    local url="" ver=""
    
    for base in $SCRIPT_URLS; do
        local full="${base}${SCRIPT_PATH}"
        local domain=$(echo "$base" | sed 's|https://||' | sed 's|/.*||')
        
        log "尝试从 $domain 获取脚本..."
        
        if curl -fsSL --connect-timeout 10 --max-time 30 "$full" -o "$temp" 2>/dev/null; then
            if [ -f "$temp" ] && [ -s "$temp" ] && head -n1 "$temp" | grep -q "^#!/"; then
                ver=$(grep -o 'SCRIPT_VERSION="[^"]*"' "$temp" | head -n1 | cut -d'"' -f2)
                [ -n "$ver" ] && { url="$full"; log "✓ 从 $domain 获取成功"; break; }
            fi
        fi
        log "✗ $domain 访问失败"
        rm -f "$temp"
    done
    
    [ -z "$ver" ] && { log "✗ 无法获取脚本"; rm -f "$temp"; log ""; return 1; }
    
    log "远程脚本版本: $ver"
    
    if [ "$SCRIPT_VERSION" = "$ver" ]; then
        log "○ 脚本已是最新版本"
        rm -f "$temp"
        log ""
        return 0
    fi
    
    log "↻ 发现新版本: $SCRIPT_VERSION → $ver"
    log "开始更新脚本..."
    
    local path=$(readlink -f "$0")
    
    # 保留用户配置
    local current_priority=$(grep "^INSTALL_PRIORITY=" "$path" | head -n1 | cut -d'=' -f2)
    if [ -n "$current_priority" ]; then
        log "保留用户配置: INSTALL_PRIORITY=$current_priority"
        sed -i "s/^INSTALL_PRIORITY=[0-9]\+$/INSTALL_PRIORITY=$current_priority/" "$temp"
    fi
    
    if mv "$temp" "$path"; then
        chmod +x "$path"
        log "✓ 脚本更新成功！"
        log "版本: $SCRIPT_VERSION → $ver"
        log "来源: $url"
        log ""
        log "======================================"
        log "脚本已更新，重新启动新版本..."
        log "======================================"
        log ""
        exec "$path"
    else
        log "✗ 脚本更新失败"
        rm -f "$temp"
        log ""
        return 1
    fi
}

# ==================== 报告生成 ====================
generate_report() {
    local updates=$((OFFICIAL_UPDATED + GITEE_UPDATED))
    local strategy="官方源优先"
    [ "$INSTALL_PRIORITY" != "1" ] && strategy="Gitee 优先"
    
    local non_official_count=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
    
    local report="脚本版本: $SCRIPT_VERSION\n"
    report="${report}======================================\n"
    report="${report}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report="${report}设备: $DEVICE_MODEL\n"
    report="${report}策略: $strategy\n\n"
    
    report="${report}官方源检查完成:\n"
    report="${report}  ✓ 升级: $OFFICIAL_UPDATED 个\n"
    [ -n "$UPDATED_PACKAGES" ] && report="${report}$UPDATED_PACKAGES\n"
    report="${report}  ○ 已是最新: $OFFICIAL_SKIPPED 个\n"
    report="${report}  ⊗ 不在官方源: $non_official_count 个\n"
    report="${report}  ⊝ 排除: $EXCLUDED_COUNT 个\n"
    report="${report}  ✗ 失败: $OFFICIAL_FAILED 个\n"
    [ -n "$FAILED_PACKAGES" ] && report="${report}$FAILED_PACKAGES\n"
    report="${report}\n"
    
    report="${report}Gitee 检查完成:\n"
    report="${report}  ✓ 已更新: $GITEE_UPDATED 个\n"
    [ -n "$GITEE_UPDATED_LIST" ] && report="${report}$GITEE_UPDATED_LIST\n"
    report="${report}  ○ 已是最新: $GITEE_SAME 个\n"
    report="${report}  ⊗ 未找到仓库: $GITEE_NOTFOUND 个\n"
    [ -n "$GITEE_NOTFOUND_LIST" ] && report="${report}$GITEE_NOTFOUND_LIST\n"
    report="${report}  ✗ 失败: $GITEE_FAILED 个\n"
    [ -n "$GITEE_FAILED_LIST" ] && report="${report}$GITEE_FAILED_LIST\n"
    report="${report}\n"
    
    [ $updates -eq 0 ] && report="${report}[提示] 所有软件包均为最新版本\n\n"
    
    report="${report}======================================\n"
    report="${report}详细日志: $LOG_FILE"
    
    echo "$report"
}

# ==================== 主函数 ====================
run_update() {
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"
    
    log "======================================"
    log "OpenWrt 自动更新脚本 v${SCRIPT_VERSION}"
    log "开始执行 (PID: $$)"
    log "日志文件: $LOG_FILE"
    log "======================================"
    log ""
    
    # 检测包管理器
    detect_package_manager
    
    # 获取系统架构
    get_system_arch
    
    log "安装优先级: $([ "$INSTALL_PRIORITY" = "1" ] && echo "官方源优先" || echo "Gitee 优先")"
    log ""
    
    check_script_update
    
    # 先分类所有包
    classify_packages || return 1
    
    # 根据优先级决定更新顺序
    if [ "$INSTALL_PRIORITY" = "1" ]; then
        log "[策略] 官方源优先，Gitee 补充"
        log ""
        update_official_packages
        update_gitee_packages
    else
        log "[策略] Gitee 优先，官方源补充"
        log ""
        update_gitee_packages
        update_official_packages
    fi
    
    log "======================================"
    log "✓ 更新流程完成"
    log "======================================"
    
    local report=$(generate_report)
    log "$report"
    
    send_push "$PUSH_TITLE" "$report"
}

# ==================== 参数处理 ====================
if [ "$1" = "ts" ]; then
    send_status_push
    exit 0
fi

# 执行更新
run_update
