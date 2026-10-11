include $(TOPDIR)/rules.mk

PKG_NAME:=luci-vless-selective
PKG_VERSION:=$(shell sed 's/-[^-]*$$//' $(CURDIR)/VERSION)
PKG_RELEASE:=$(shell sed 's/^.*-//' $(CURDIR)/VERSION)
# Контакт виден в `opkg info luci-vless-selective`
PKG_MAINTAINER:=timfdelfi <https://github.com/timfdelfi/luci-vless-selective/issues>
PKG_LICENSE:=MIT

LUCI_TITLE:=VPN для OpenWrt: вставил ссылку, нажал кнопку, работает
LUCI_DESCRIPTION:=Простой VPN-клиент для OpenWrt (sing-box, TUN). Подписки, VLESS/VMess/Trojan/SS/Hysteria2, автовыбор сервера.
LUCI_DEPENDS:=+luci-base +sing-box +kmod-tun +curl +jq +ca-bundle +ip-full +nftables
LUCI_PKGARCH:=all

PKG_FILE_MODES:=/usr/bin/vless:root:root:0755 \
	/usr/libexec/rpcd/vless:root:root:0755 \
	/etc/init.d/vless:root:root:0755 \
	/etc/uci-defaults/90-vless:root:root:0755

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
