#!/bin/sh
# -*- coding: utf-8 -*-

# ==================== 全局配置 ====================
SCRIPT_VERSION="1.0.2"
LOG_FILE="/tmp/auto-update-$(date +%Y%m%d-%H%M%S).log"
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

# ==================== 工具函数 ====================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    case "$1" in -*) ;; *) logger -t "auto-update" "$1" 2>/dev/null ;; esac
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

get_system_arch() {
    case "$(uname -m)" in
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        armv6l)  echo "armv6" ;;
        x86_64)  echo "x86_64" ;;
        i686|i386) echo "i386" ;;
        *) echo "unknown" ;;
    esac
}

# ==================== 包管理函数 ====================
is_package_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for pattern in $EXCLUDE_PACKAGES; do
        case "$1" in $pattern*) return 0 ;; esac
    done
    return 1
}

opkg_check() {
    opkg "$@" 2>/dev/null | grep -q "^$2 "
}

get_package_version() {
    opkg "$1" | grep "^$2 " | awk '{print $3}'
}

install_language_package() {
    local pkg="$1" lang_pkg=""
    case "$pkg" in
        luci-app-*)   lang_pkg="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang_pkg="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return 0 ;;
    esac
    
    opkg_check list "$lang_pkg" || return 0
    
    local action="安装"
    opkg_check list-installed "$lang_pkg" && action="升级"
    
    log "    ${action}语言包 $lang_pkg..."
    if opkg ${action} "$lang_pkg" >>"$LOG_FILE" 2>&1; then
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

is_arch_match() {
    case "$1" in
        *_$2.ipk|*_$2_*.ipk|*_all.ipk) return 0 ;;
        *) return 1 ;;
    esac
}

is_better_binary() {
    [ -z "$1" ] && return 0
    case "$2" in
        *_wanji.ipk)
            case "$1" in
                *_wanji.ipk) [ "$2" \> "$1" ] ;;
                *) return 0 ;;
            esac ;;
        *)
            case "$1" in
                *_wanji.ipk) return 1 ;;
                *) [ "$2" \> "$1" ] ;;
            esac ;;
    esac
}

update_from_gitee() {
    local pkg="$1" repo="$2"
    local app_name="${pkg#luci-app-}" app_name="${app_name#luci-theme-}"
    
    log "  从 Gitee 更新 $pkg (仓库: $repo)"
    backup_config
    
    local arch=$(get_system_arch)
    local json=$(curl -s "https://gitee.com/api/v5/repos/${repo}/releases/latest")
    
    [ -z "$json" ] && { log "  ✗ API 请求失败"; cleanup_backup; return 1; }
    
    local version=$(echo "$json" | grep -o '"tag_name":"[^"]*"' | head -n1 | cut -d'"' -f4)
    [ -z "$version" ] && { log "  ✗ 无法获取版本"; cleanup_backup; return 1; }
    
    log "  Gitee 最新版本: $version"
    
    local files=$(echo "$json" | grep -o '"browser_download_url":"[^"]*\.ipk"' | cut -d'"' -f4 | xargs -n1 basename)
    [ -z "$files" ] && { log "  ✗ 未找到 ipk 文件"; cleanup_backup; return 1; }
    
    # 智能分类 ipk 文件
    local main="" luci="" i18n=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            *luci-i18n-*${app_name}*zh-cn*.ipk) [ -z "$i18n" ] && i18n="$f" ;;
            luci-app-${app_name}_*.ipk|luci-theme-${app_name}_*.ipk) [ -z "$luci" ] && luci="$f" ;;
            *${app_name}*.ipk)
                case "$f" in
                    luci-*|*-luci-*) ;;
                    *) is_arch_match "$f" "$arch" && is_better_binary "$main" "$f" && main="$f" ;;
                esac ;;
        esac
    done <<EOF
$files
EOF
    
    local order="$main $luci $i18n"
    [ -z "$(echo $order | tr -d ' ')" ] && { log "  ✗ 未找到匹配包"; cleanup_backup; return 1; }
    
    log "  安装计划: $order"
    
    local count=0
    for file in $order; do
        [ -z "$file" ] && continue
        local url=$(echo "$json" | grep -o "\"browser_download_url\":\"[^\"]*${file}\"" | cut -d'"' -f4)
        [ -z "$url" ] && { log "  ⚠ 未找到 $file 下载链接"; continue; }
        
        log "  下载: $file"
        curl -fsSL -o "/tmp/$file" "$url" || { log "  ✗ 下载失败"; rm -f /tmp/*${app_name}*.ipk; restore_config; return 1; }
        
        log "  安装 $file..."
        if ! opkg install --force-reinstall "/tmp/$file" >>"$LOG_FILE" 2>&1; then
            log "  ✗ 首次安装失败，尝试卸载重装..."
            local name=$(echo "$file" | sed 's/_.*\.ipk$//')
            opkg remove "$name" >>"$LOG_FILE" 2>&1
            opkg install "/tmp/$file" >>"$LOG_FILE" 2>&1 || \
                { log "  ✗ 重装失败"; rm -f /tmp/*${app_name}*.ipk; restore_config; return 1; }
        fi
        log "  ✓ $file 安装成功"
        count=$((count + 1))
    done
    
    rm -f /tmp/*${app_name}*.ipk 2>/dev/null
    restore_config
    log "  ✓ $pkg 更新完成 (版本: $version, 共 $count 个包)"
    return 0
}

# ==================== 官方源更新 ====================
update_official_packages() {
    log "======================================"
    log "步骤: 更新官方源中的包"
    log "======================================"
    
    log "更新软件源..."
    opkg update >>"$LOG_FILE" 2>&1 || { log "✗ 软件源更新失败"; return 1; }
    log "✓ 软件源更新成功"
    
    OFFICIAL_UPDATED=0 OFFICIAL_SKIPPED=0 OFFICIAL_EXCLUDED=0 
    OFFICIAL_FAILED=0 OFFICIAL_NOT_IN_REPO=0
    UPDATED_PACKAGES="" FAILED_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    
    local pkgs=$(opkg list-installed | awk '{print $1}' | grep -v "^luci-i18n-")
    log "检测到 $(echo "$pkgs" | wc -l) 个已安装包（已排除语言包）"
    log "--------------------------------------"
    
    for pkg in $pkgs; do
        if is_package_excluded "$pkg"; then
            OFFICIAL_EXCLUDED=$((OFFICIAL_EXCLUDED + 1))
            continue
        fi
        
        if opkg info "$pkg" 2>/dev/null | grep -q "^Description:"; then
            local cur=$(get_package_version list-installed "$pkg")
            local new=$(get_package_version list "$pkg")
            
            if [ "$cur" != "$new" ]; then
                log "↻ $pkg: $cur → $new"
                log "  正在升级..."
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
                log "○ $pkg: $cur (已是最新)"
                OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED + 1))
            fi
        else
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            log "⊗ $pkg: 不在官方源"
            OFFICIAL_NOT_IN_REPO=$((OFFICIAL_NOT_IN_REPO + 1))
        fi
    done
    
    log "--------------------------------------"
    log "官方源检查完成:"
    log "  ✓ 升级: $OFFICIAL_UPDATED 个"
    log "  ○ 已是最新: $OFFICIAL_SKIPPED 个"
    log "  ⊗ 不在官方源: $OFFICIAL_NOT_IN_REPO 个"
    log "  ⊝ 排除: $OFFICIAL_EXCLUDED 个"
    log "  ✗ 失败: $OFFICIAL_FAILED 个"
    return 0
}

# ==================== Gitee 源更新 ====================
update_gitee_packages() {
    log "======================================"
    log "步骤: 检查并更新 Gitee 源的包"
    log "======================================"
    
    GITEE_UPDATED=0 GITEE_SAME=0 GITEE_NOTFOUND=0 GITEE_FAILED=0
    GITEE_UPDATED_LIST="" GITEE_NOTFOUND_LIST="" GITEE_FAILED_LIST=""
    
    local check_list=""
    for pkg in $NON_OFFICIAL_PACKAGES; do
        case "$pkg" in
            luci-app-*|luci-theme-*|lucky) check_list="$check_list $pkg" ;;
        esac
    done
    
    [ -z "$check_list" ] && { log "没有需要从 Gitee 检查的插件"; return 0; }
    
    log "需要从 Gitee 检查的插件: $(echo $check_list | wc -w) 个"
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
    local report="插件更新报告 版本$SCRIPT_VERSION \n"
    report="${report}======================================\n"
    report="${report}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report="${report}设备: $DEVICE_MODEL\n\n"
    
    report="${report}官方源检查完成:\n"
    report="${report}  ✓ 升级: $OFFICIAL_UPDATED 个\n"
    [ -n "$UPDATED_PACKAGES" ] && report="${report}$UPDATED_PACKAGES\n"
    report="${report}  ○ 已是最新: $OFFICIAL_SKIPPED 个\n"
    report="${report}  ⊗ 不在官方源: $OFFICIAL_NOT_IN_REPO 个\n"
    report="${report}  ⊝ 排除: $OFFICIAL_EXCLUDED 个\n"
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
    report="${report}详细日志: /tmp/auto-update-latest.log"
    
    echo "$report"
}

# ==================== 主函数 ====================
run_update() {
    log "======================================"
    log "OpenWrt 自动更新脚本 v${SCRIPT_VERSION}"
    log "开始执行 (PID: $$)"
    log "日志文件: $LOG_FILE"
    log "安装优先级: $([ "$INSTALL_PRIORITY" = "1" ] && echo "官方源优先" || echo "Gitee 优先")"
    log "======================================"
    log ""
    
    check_script_update
    
    # 根据优先级决定执行顺序
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
    
    cp "$LOG_FILE" "/tmp/auto-update-latest.log" 2>/dev/null
    log "日志已保存到: /tmp/auto-update-latest.log"
}

# 执行更新
run_update
