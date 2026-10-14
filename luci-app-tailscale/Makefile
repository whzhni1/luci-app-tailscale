include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=whzhni1

LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

LUCI_TITLE:=LuCI app for Tailscale
LUCI_DESCRIPTION:=Tailscale management UI with an ucode rpcd backend and a self contained kernel updater
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-html

define Package/luci-app-tailscale/conffiles
/etc/config/tailscale
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
INITD=/etc/init.d
$${INITD}/tailscale enable
( setsid "$${INITD}/tailscale" start </dev/null >/dev/null 2>&1 & )
$${INITD}/rpcd reload >/dev/null 2>&1 || true
rm -rf /tmp/luci-*

exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

INITD=/etc/init.d

$${INITD}/tailscale stop >/dev/null 2>&1 || true

rm -rf /tmp/luci-*

exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
