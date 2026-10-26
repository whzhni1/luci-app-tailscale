include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale
PKG_VERSION:=2.0.4
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=whzhni1

LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

LUCI_TITLE:=LuCI app for Tailscale
LUCI_DESCRIPTION:=Tailscale management UI with an ucode rpcd backend and a self contained kernel updater
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-html +curl

define Package/luci-app-tailscale/conffiles
/etc/config/tailscale
endef

define Build/Prepare/$(PKG_NAME)
	$(SED) "s/^const ASSET_VERSION = '[^']*';/const ASSET_VERSION = '$(PKG_VERSION)-r$(PKG_RELEASE)';/" $(PKG_BUILD_DIR)/htdocs/luci-static/resources/tailscale/common.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
INITD=/etc/init.d
UPGRADE_MARKER=/tmp/tailscale-luci-app-upgrade
if [ "$${PKG_UPGRADE}" = "1" ] || [ -e "$${UPGRADE_MARKER}" ]; then
	rm -f "$${UPGRADE_MARKER}"
else
	/usr/libexec/tailscale/update.sh restore >/dev/null 2>&1 || true
	$${INITD}/tailscale enable
	( setsid "$${INITD}/tailscale" start </dev/null >/dev/null 2>&1 & )
fi
$${INITD}/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*

exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/tailscale/update.sh uninstall "$$@" >/dev/null 2>&1 || true
rm -rf /tmp/luci-*

exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
PURGE_LIST=/tmp/tailscale-luci-app-purge
[ -f "$${PURGE_LIST}" ] || exit 0
while IFS= read -r path; do
	case "$${path}" in
		/?*)
			tries=0
			while [ -d "$${path}/fw-worker/lock" ] && [ "$${tries}" -lt 30 ]; do
				sleep 1
				tries=$$((tries + 1))
			done
			rm -rf "$${path}"
			;;
	esac
done <"$${PURGE_LIST}"
rm -f "$${PURGE_LIST}"
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*

exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))


