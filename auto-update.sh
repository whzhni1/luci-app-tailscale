#!/bin/sh

LOG_FILE="/tmp/auto-update-$(date +%Y%m%d-%H%M%S).log"
GITEE_OWNERS="whzhni sirpdboy kiddin9"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"

# 排除列表：不应该自动更新的包
EXCLUDE_PACKAGES="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    
    # 避免 logger 把分隔线当作选项
    case "$1" in
        -*)
            ;;
        *)
            logger -t "auto-update" "$1"
            ;;
    esac
}

# 版本号标准化（移除前缀 v 和后缀 -r）
normalize_version() {
    local ver="$1"
    
    # 移除前缀 v 或 V
    ver=$(echo "$ver" | sed 's/^[vV]//')
    
    # 移除 -r数字 或 -数字 后缀（如 -r1, -1, -r20251017, -20251017）
    ver=$(echo "$ver" | sed 's/-r\?[0-9]\+$//')
    
    echo "$ver"
}

# 智能版本比较
compare_versions() {
    local current="$1"
    local gitee="$2"
    
    # 标准化版本号
    local norm_current=$(normalize_version "$current")
    local norm_gitee=$(normalize_version "$gitee")
    
    log "  [版本对比] $current → $norm_current  vs  $gitee → $norm_gitee"
    
    # 比较标准化后的版本
    if [ "$norm_current" = "$norm_gitee" ]; then
        return 0  # 版本相同
    else
        return 1  # 版本不同
    fi
}

send_push() {
    local title="$1"
    local content="$2"
    
    if [ ! -f "/etc/config/wechatpush" ]; then
        log "⚠ wechatpush 未安装，跳过推送"
        return 1
    fi
    
    local enabled=$(uci get wechatpush.config.enable 2>/dev/null)
    if [ "$enabled" != "1" ]; then
        log "⚠ wechatpush 未启用，跳过推送"
        return 1
    fi
    
    # 智能检测推送方式
    local pushplus_token=$(uci get wechatpush.config.pushplus_token 2>/dev/null)
    local serverchan_key=$(uci get wechatpush.config.serverchan_key 2>/dev/null)
    local serverchan_3_key=$(uci get wechatpush.config.serverchan_3_key 2>/dev/null)
    
    local push_method=""
    local token_value=""
    local api_type=""
    
    if [ -n "$pushplus_token" ]; then
        push_method="PushPlus"
        token_value="$pushplus_token"
        api_type="pushplus"
    elif [ -n "$serverchan_3_key" ]; then
        push_method="Server酱3"
        token_value="$serverchan_3_key"
        api_type="serverchan3"
    elif [ -n "$serverchan_key" ]; then
        push_method="Server酱"
        token_value="$serverchan_key"
        api_type="serverchan"
    else
        log "⚠ 未配置任何推送方式，跳过推送"
        return 1
    fi
    
    log "发送推送通知 (方式: $push_method)..."
    
    local response=""
    local result=1
    
    case "$api_type" in
        pushplus)
            local content_escaped=$(echo "$content" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
            
            response=$(curl -s -X POST "http://www.pushplus.plus/send" \
                -H "Content-Type: application/json" \
                -d "{\"token\":\"$token_value\",\"title\":\"$title\",\"content\":\"$content_escaped\",\"template\":\"txt\"}")
            
            if echo "$response" | grep -q '"code":200'; then
                result=0
            fi
            ;;
        serverchan)
            response=$(curl -s -X POST "https://sc.ftqq.com/${token_value}.send" \
                -d "text=$title" \
                -d "desp=$content")
            
            if echo "$response" | grep -q '"errno":0\|"code":0'; then
                result=0
            fi
            ;;
        serverchan3)
            response=$(curl -s -X POST "https://sctapi.ftqq.com/${token_value}.send" \
                -d "text=$title" \
                -d "desp=$content")
            
            if echo "$response" | grep -q '"errno":0\|"code":0'; then
                result=0
            fi
            ;;
    esac
    
    if [ $result -eq 0 ]; then
        log "✓ 推送发送成功"
        return 0
    else
        log "✗ 推送发送失败: $response"
        return 1
    fi
}

# 检查包是否在排除列表中
is_package_excluded() {
    local pkg="$1"
    
    # 排除语言包（会随主包自动更新）
    case "$pkg" in
        luci-i18n-*)
            return 0
            ;;
    esac
    
    # 排除系统核心包
    for pattern in $EXCLUDE_PACKAGES; do
        case "$pkg" in
            $pattern*)
                return 0
                ;;
        esac
    done
    
    return 1
}

# 检查包是否已安装
is_package_installed() {
    opkg list-installed | grep -q "^$1 "
}

# 检查包是否存在于源
check_package_exists() {
    opkg list | grep -q "^$1 "
}

# 获取所有已安装的包（排除语言包和系统包）
get_installed_packages() {
    opkg list-installed | awk '{print $1}' | grep -v "^luci-i18n-"
}

# 获取 luci 相关包（排除语言包）
get_luci_packages() {
    opkg list-installed | grep -E "^(luci-app-|luci-theme-)" | awk '{print $1}'
}

get_system_arch() {
    local arch=$(uname -m)
    case "$arch" in
        aarch64)   echo "arm64" ;;
        armv7l)    echo "armv7" ;;
        armv6l)    echo "armv6" ;;
        x86_64)    echo "x86_64" ;;
        i686|i386) echo "i386" ;;
        *)         echo "unknown" ;;
    esac
}

check_package_in_repo() {
    local pkg="$1"
    
    # 检查包信息是否有 Description 字段
    # 源内包有此字段，手动安装的包没有
    if opkg info "$pkg" 2>/dev/null | grep -q "^Description:"; then
        return 0  # 在源中
    else
        return 1  # 手动安装
    fi
}

get_installed_version() {
    opkg list-installed | grep "^$1 " | awk '{print $3}'
}

get_repo_version() {
    opkg list | grep "^$1 " | awk '{print $3}'
}

# 智能安装语言包（升级主包后）
install_language_package() {
    local pkg="$1"
    local lang_pkg=""
    
    case "$pkg" in
        luci-app-*)
            lang_pkg="luci-i18n-${pkg#luci-app-}-zh-cn"
            ;;
        luci-theme-*)
            lang_pkg="luci-i18n-theme-${pkg#luci-theme-}-zh-cn"
            ;;
        *)
            return 0
            ;;
    esac
    
    # 检查语言包是否存在于源
    if check_package_exists "$lang_pkg"; then
        if is_package_installed "$lang_pkg"; then
            # 已安装，升级
            log "    升级语言包 $lang_pkg..."
            if opkg upgrade "$lang_pkg" >>"$LOG_FILE" 2>&1; then
                log "    ✓ $lang_pkg 升级成功"
            else
                log "    ⚠ $lang_pkg 升级失败（不影响主程序）"
            fi
        else
            # 未安装，安装
            log "    安装语言包 $lang_pkg..."
            if opkg install "$lang_pkg" >>"$LOG_FILE" 2>&1; then
                log "    ✓ $lang_pkg 安装成功"
            else
                log "    ⚠ $lang_pkg 安装失败（不影响主程序）"
            fi
        fi
    fi
    
    return 0
}

# 包名到 Gitee 仓库名的映射
get_gitee_repo_name() {
    local pkg="$1"
    
    # 特殊映射（包名 -> 仓库名）
    case "$pkg" in
        lucky)
            echo "luci-app-lucky"
            return 0
            ;;
        *)
            # 默认使用包名作为仓库名
            echo "$pkg"
            return 0
            ;;
    esac
}

find_gitee_repo() {
    local pkg="$1"
    
    # 获取对应的仓库名
    local repo_name=$(get_gitee_repo_name "$pkg")
    
    for owner in $GITEE_OWNERS; do
        local repo="${owner}/${repo_name}"
        local api_url="https://gitee.com/api/v5/repos/${repo}/releases/latest"
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$api_url")
        
        if [ "$http_code" = "200" ]; then
            echo "$repo"
            return 0
        fi
    done
    
    return 1
}

# 获取 Gitee 仓库的最新版本
get_gitee_version() {
    local repo="$1"
    local api_url="https://gitee.com/api/v5/repos/${repo}/releases/latest"
    local release_json=$(curl -s "$api_url")
    
    if [ -z "$release_json" ]; then
        return 1
    fi
    
    local latest_version=$(echo "$release_json" | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
    
    if [ -n "$latest_version" ]; then
        echo "$latest_version"
        return 0
    fi
    
    return 1
}

is_arch_match() {
    local filename="$1"
    local sys_arch="$2"
    
    case "$filename" in
        *_${sys_arch}.ipk|*_${sys_arch}_*.ipk|*_all.ipk)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 比较主程序包优先级
is_better_binary() {
    local current="$1"
    local new="$2"
    
    [ -z "$current" ] && return 0
    
    case "$new" in
        *_wanji.ipk)
            case "$current" in
                *_wanji.ipk)
                    [ "$new" \> "$current" ] && return 0
                    return 1
                    ;;
                *)
                    return 0
                    ;;
            esac
            ;;
        *)
            case "$current" in
                *_wanji.ipk)
                    return 1
                    ;;
                *)
                    [ "$new" \> "$current" ] && return 0
                    return 1
                    ;;
            esac
            ;;
    esac
}

# Gitee 更新
update_from_gitee() {
    local main_pkg="$1"
    local repo="$2"
    
    local app_name=""
    case "$main_pkg" in
        luci-app-*)   app_name="${main_pkg#luci-app-}" ;;
        luci-theme-*) app_name="${main_pkg#luci-theme-}" ;;
        *)            app_name="$main_pkg" ;;
    esac
    
    log "  从 Gitee 更新 $main_pkg (仓库: $repo)"
    
    local sys_arch=$(get_system_arch)
    local api_url="https://gitee.com/api/v5/repos/${repo}/releases/latest"
    local release_json=$(curl -s "$api_url")
    
    if [ -z "$release_json" ]; then
        log "  ✗ API 请求失败"
        return 1
    fi
    
    local latest_version=$(echo "$release_json" | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$latest_version" ]; then
        log "  ✗ 未能获取最新版本"
        return 1
    fi
    
    log "  Gitee 最新版本: $latest_version"
    
    local all_files=$(echo "$release_json" | grep -o '"browser_download_url":"[^"]*\.ipk"' | cut -d'"' -f4 | xargs -n1 basename)
    
    if [ -z "$all_files" ]; then
        log "  ✗ 未找到任何 ipk 文件"
        return 1
    fi
    
    # 智能分类
    local main_binary="" luci_pkg="" i18n_pkg=""
    
    while IFS= read -r filename; do
        [ -z "$filename" ] && continue
        
        case "$filename" in
            *luci-i18n-*${app_name}*zh-cn*.ipk)
                [ -z "$i18n_pkg" ] && i18n_pkg="$filename"
                continue
                ;;
            luci-app-${app_name}_*.ipk|luci-theme-${app_name}_*.ipk)
                [ -z "$luci_pkg" ] && luci_pkg="$filename"
                continue
                ;;
            *${app_name}*.ipk)
                case "$filename" in
                    luci-*|*-luci-*) ;;
                    *)
                        if is_arch_match "$filename" "$sys_arch"; then
                            if is_better_binary "$main_binary" "$filename"; then
                                main_binary="$filename"
                            fi
                        fi
                        ;;
                esac
                ;;
        esac
    done <<EOF
$all_files
EOF
    
    # 构建安装顺序
    local install_order=""
    [ -n "$main_binary" ] && install_order="$main_binary"
    [ -n "$luci_pkg" ] && install_order="$install_order $luci_pkg"
    [ -n "$i18n_pkg" ] && install_order="$install_order $i18n_pkg"
    
    if [ -z "$install_order" ]; then
        log "  ✗ 未找到匹配的包"
        return 1
    fi
    
    log "  安装计划: $install_order"
    
    # 下载并安装
    local success_count=0
    for filename in $install_order; do
        filename=$(echo "$filename" | xargs)
        [ -z "$filename" ] && continue
        
        local download_url=$(echo "$release_json" | grep -o "\"browser_download_url\":\"[^\"]*${filename}\"" | cut -d'"' -f4)
        
        if [ -z "$download_url" ]; then
            log "  ⚠ 未找到 $filename 的下载链接"
            continue
        fi
        
        log "  下载: $filename"
        if ! curl -fsSL -o "/tmp/$filename" "$download_url"; then
            log "  ✗ 下载失败"
            rm -f /tmp/*${app_name}*.ipk 2>/dev/null
            return 1
        fi
        
        log "  安装 $filename..."
        if ! opkg install --force-reinstall "/tmp/$filename" >>"$LOG_FILE" 2>&1; then
            log "  ✗ 安装失败"
            rm -f /tmp/*${app_name}*.ipk 2>/dev/null
            return 1
        fi
        
        log "  ✓ $filename 安装成功"
        success_count=$((success_count + 1))
    done
    
    rm -f /tmp/*${app_name}*.ipk 2>/dev/null
    log "  ✓ $main_pkg 更新完成 (版本: $latest_version, 共安装 $success_count 个包)"
    
    return 0
}

update_official_packages() {
    log "======================================"
    log "步骤1: 更新官方源中的包"
    log "======================================"
    
    log "更新软件源..."
    if ! opkg update >>"$LOG_FILE" 2>&1; then
        log "✗ 软件源更新失败"
        return 1
    fi
    log "✓ 软件源更新成功"
    
    OFFICIAL_UPDATED=0
    OFFICIAL_SKIPPED=0
    OFFICIAL_EXCLUDED=0
    OFFICIAL_FAILED=0
    OFFICIAL_NOT_IN_REPO=0
    
    OFFICIAL_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    UPDATED_PACKAGES=""
    FAILED_PACKAGES=""
    
    local installed_pkgs=$(get_installed_packages)
    local total=$(echo "$installed_pkgs" | wc -l)
    
    log "检测到 $total 个已安装的软件包（已排除语言包）"
    log "--------------------------------------"
    
    for pkg in $installed_pkgs; do
        # 检查是否在排除列表
        if is_package_excluded "$pkg"; then
            OFFICIAL_EXCLUDED=$((OFFICIAL_EXCLUDED + 1))
            continue
        fi
        
        # 检查是否在官方源
        if check_package_in_repo "$pkg"; then
            OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            
            local current_ver=$(get_installed_version "$pkg")
            local repo_ver=$(get_repo_version "$pkg")
            
            if [ "$current_ver" != "$repo_ver" ]; then
                log "↻ $pkg: 当前 $current_ver → 仓库 $repo_ver"
                log "  正在升级..."
                
                if opkg upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="$UPDATED_PACKAGES\n    - $pkg: $current_ver → $repo_ver"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                    
                    # 智能安装/升级语言包
                    install_language_package "$pkg"
                else
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="$FAILED_PACKAGES\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
            else
                # 版本相同，记录到日志
                log "○ $pkg: $current_ver (已是最新)"
                OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED + 1))
            fi
        else
            # 不在官方源的包
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

update_gitee_packages() {
    log "======================================"
    log "步骤2: 检查并更新 Gitee 源的包"
    log "======================================"
    
    GITEE_UPDATED=0
    GITEE_SAME=0
    GITEE_NOTFOUND=0
    GITEE_FAILED=0
    
    GITEE_UPDATED_LIST=""
    GITEE_NOTFOUND_LIST=""
    GITEE_FAILED_LIST=""
    
    # 获取不在官方源的包，包括 luci-app、luci-theme 和其他需要检查的包（如 lucky）
    local check_list=""
    for pkg in $NON_OFFICIAL_PACKAGES; do
        case "$pkg" in
            luci-app-*|luci-theme-*|lucky)
                check_list="$check_list $pkg"
                ;;
        esac
    done
    
    if [ -z "$check_list" ]; then
        log "没有需要从 Gitee 检查的插件"
        return 0
    fi
    
    local total=$(echo "$check_list" | wc -w)
    log "需要从 Gitee 检查的插件: $total 个"
    log "--------------------------------------"
    
    for pkg in $check_list; do
        local current_ver=$(get_installed_version "$pkg")
        
        log "🔍 检查 $pkg (当前版本: $current_ver)"
        
        # 查找 Gitee 仓库
        local repo=$(find_gitee_repo "$pkg")
        
        if [ $? -ne 0 ] || [ -z "$repo" ]; then
            log "  ⊗ 未找到 Gitee 仓库 (已尝试: $GITEE_OWNERS)"
            GITEE_NOTFOUND_LIST="$GITEE_NOTFOUND_LIST\n    - $pkg"
            GITEE_NOTFOUND=$((GITEE_NOTFOUND + 1))
            log ""
            continue
        fi
        
        log "  ✓ 找到仓库: $repo"
        
        # 获取 Gitee 版本
        local gitee_ver=$(get_gitee_version "$repo")
        
        if [ -z "$gitee_ver" ]; then
            log "  ✗ 无法获取 Gitee 版本信息"
            GITEE_FAILED_LIST="$GITEE_FAILED_LIST\n    - $pkg (无法获取版本)"
            GITEE_FAILED=$((GITEE_FAILED + 1))
            log ""
            continue
        fi
        
        log "  当前版本: $current_ver"
        log "  Gitee 版本: $gitee_ver"
        
        # 使用智能版本比较
        if compare_versions "$current_ver" "$gitee_ver"; then
            log "  ○ 版本相同（标准化后），无需更新"
            GITEE_SAME=$((GITEE_SAME + 1))
        else
            log "  ↻ 版本不同，开始更新..."
            
            if update_from_gitee "$pkg" "$repo"; then
                GITEE_UPDATED_LIST="$GITEE_UPDATED_LIST\n    - $pkg: $current_ver → $gitee_ver"
                GITEE_UPDATED=$((GITEE_UPDATED + 1))
            else
                GITEE_FAILED_LIST="$GITEE_FAILED_LIST\n    - $pkg (更新失败)"
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

generate_report() {
    local has_updates=0
    
    # 检查是否有更新
    if [ $OFFICIAL_UPDATED -gt 0 ] || [ $GITEE_UPDATED -gt 0 ]; then
        has_updates=1
    fi
    
    # 生成报告内容
    local report=""
    report="${report}OpenWrt 系统更新报告\n"
    report="${report}======================================\n"
    report="${report}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report="${report}设备: $DEVICE_MODEL\n"
    report="${report}\n"
    
    # 官方源检查结果
    report="${report}官方源检查完成:\n"
    report="${report}  ✓ 升级: $OFFICIAL_UPDATED 个\n"
    if [ -n "$UPDATED_PACKAGES" ]; then
        report="${report}$UPDATED_PACKAGES\n"
    fi
    report="${report}  ○ 已是最新: $OFFICIAL_SKIPPED 个\n"
    report="${report}  ⊗ 不在官方源: $OFFICIAL_NOT_IN_REPO 个\n"
    report="${report}  ⊝ 排除: $OFFICIAL_EXCLUDED 个\n"
    report="${report}  ✗ 失败: $OFFICIAL_FAILED 个\n"
    if [ -n "$FAILED_PACKAGES" ]; then
        report="${report}$FAILED_PACKAGES\n"
    fi
    report="${report}\n"
    
    # Gitee 检查结果
    report="${report}Gitee 检查完成:\n"
    report="${report}  ✓ 已更新: $GITEE_UPDATED 个\n"
    if [ -n "$GITEE_UPDATED_LIST" ]; then
        report="${report}$GITEE_UPDATED_LIST\n"
    fi
    report="${report}  ○ 已是最新: $GITEE_SAME 个\n"
    report="${report}  ⊗ 未找到仓库: $GITEE_NOTFOUND 个\n"
    if [ -n "$GITEE_NOTFOUND_LIST" ]; then
        report="${report}$GITEE_NOTFOUND_LIST\n"
    fi
    report="${report}  ✗ 失败: $GITEE_FAILED 个\n"
    if [ -n "$GITEE_FAILED_LIST" ]; then
        report="${report}$GITEE_FAILED_LIST\n"
    fi
    report="${report}\n"
    
    # 总结
    if [ $has_updates -eq 0 ]; then
        report="${report}[提示] 所有软件包均为最新版本，无需更新\n"
        report="${report}\n"
    fi
    
    report="${report}======================================\n"
    report="${report}详细日志: /tmp/auto-update-latest.log"
    
    echo "$report"
}

run_update() {
    log "======================================"
    log "开始自动更新系统 (PID: $$)"
    log "日志文件: $LOG_FILE"
    log "======================================"
    
    update_official_packages
    update_gitee_packages
    
    log "======================================"
    log "✓ 更新流程完成"
    log "======================================"
    
    local report=$(generate_report)
    log "$report"
    
    send_push "$PUSH_TITLE" "$report"
    
    cp "$LOG_FILE" "/tmp/auto-update-latest.log" 2>/dev/null
    log "日志已保存到: /tmp/auto-update-latest.log"
    
    return 0
}

# 直接执行更新
run_update
