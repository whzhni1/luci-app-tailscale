## 📥 安装说明
## 终端执行以下命令，自动下载安装自动识别架构
  ```bash
  curl -fsSL "https://gitlab.com/whzhni/tailscale/-/raw/main/Auto_Install_Script.sh" | sh -s luci-app-tailscale
  ```
  ## 或
  ```bash
  wget -q -O - "https://gitlab.com/whzhni/tailscale/-/raw/main/Auto_Install_Script.sh" | sh -s luci-app-tailscale
  ```
## 😉手动安装

  ⚠️ **重要：必须先安装 Tailscale，再安装 LuCI**
  
  ### 1. 安装 Tailscale（必需）
  
  根据你的架构选择对应的文件：
  
  **APK (OpenWrt 主线):**
  ```bash
  apk add --allow-untrusted tailscale-*.apk
  ```
  
  **IPK (OpenWrt 24.10):**
  ```bash
  opkg install tailscale_*_架构.ipk
  ```
  
  ### 2. 安装 LuCI 界面（可选）
  
  **APK:**
  ```bash
  apk add --allow-untrusted luci-app-tailscale-*.apk
  apk add --allow-untrusted luci-i18n-tailscale-zh-cn-*.apk  # 中文
  ```
  
  **IPK:**
  ```bash
  opkg install luci-app-tailscale_*_all.ipk
  opkg install luci-i18n-tailscale-zh-cn_*_all.ipk  # 中文
  ```
  
  ### 3. 刷新 LuCI（必需）
  
  ```bash
  rm -f /tmp/luci-indexcache
  /etc/init.d/uhttpd restart
  ```
  
  然后访问 **服务 → Tailscale** 即可。
  
  ## 📋 支持的架构
  
  - **ARM:** arm_cortex-a7, arm_cortex-a9, arm_cortex-a15, 等 14 个变体
  - **ARM64:** aarch64_cortex-a53, aarch64_cortex-a72, aarch64_generic, 等
  - **MIPS:** mips_24kc, mips_mips32, 等
  - **MIPS64:** mips64_mips64r2, mips64_octeonplus
  - **x86:** i386_pentium-mmx, i386_pentium4, i386_geode
  - **x86_64:** x86_64
  
  **查看设备架构：**
  ```bash
  opkg print-architecture
  ```
  
  ## 🔧 配置说明
  
  - **二进制文件：** `/usr/sbin/tailscaled` (主程序) + `/usr/bin/tailscaled` (软链接)
  - **服务脚本：** `/etc/init.d/tailscale` (LuCI 官方版本，自动同步)
  
  **特性：**
  - ✅ **LuCI 完美支持**（显示 + 控制）
  - ✅ 固件升级保留配置
  - ✅ 重新安装保留数据
  - ✅ UPX 压缩减小体积 50-70%
  - ✅ 无文件冲突
  
  ## 🆚 与其他构建对比
  
  | 特性 | IMM 官方包 | GuNanOvO 包 | 本构建 |
  |------|-----------|------------|--------|
  | 二进制位置 | /usr/sbin | /usr/bin | ✅ /usr/sbin |
  | init.d 来源 | IMM 官方 | GuNanOvO | ✅ LuCI 官方 |
  | LuCI 显示 | ✅ 正常 | ❌ 异常 | ✅ 正常 |
  | LuCI 控制 | ⚠️ 需配合 LuCI 包 | ❌ 不可用 | ✅ 完美 |
  | UPX 压缩 | ❌ 未压缩 | ✅ 已压缩 | ✅ 已压缩 |
  | 包大小 | ~20MB | ~5-10MB | ~5-10MB |
  | 自动更新 init.d | ❌ | ❌ | ✅ 跟随 LuCI |
  
  ---
  
  **上游项目：**
  - [tailscale/tailscale](https://github.com/tailscale/tailscale)
  - [immortalwrt/packages](https://github.com/immortalwrt/packages)
  - [asvow/luci-app-tailscale](https://github.com/asvow/luci-app-tailscale)
