#!/bin/sh
# Сборка установочных пакетов без OpenWrt SDK.
#   sh build.sh   ->   dist/vless-vpn.zip (Windows), dist/vless-vpn.tar.gz и dist/luci-vless-selective_<версия>_all.ipk
set -e
cd "$(dirname "$0")"
VER="$(tr -d '\r\n' < VERSION)"
printf '%s\n' "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' || {
	echo "Некорректная версия в VERSION: $VER" >&2
	exit 1
}
command -v ar >/dev/null 2>&1 || {
	echo "Для сборки .ipk нужна команда ar (пакет binutils)." >&2
	exit 1
}
OUT="$PWD/dist"; W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"
rm -f "$OUT/vless-vpn.tar.gz" "$OUT/vless-vpn.zip" "$OUT/luci-vless-selective_${VER}_all.ipk"

# 1) универсальный установщик (opkg и apk)
mkdir -p "$W/vless-vpn"
cp -a root htdocs install.sh uninstall.sh INSTALL.bat "$W/vless-vpn/"
chmod 0755 "$W/vless-vpn/root/usr/bin/vless" "$W/vless-vpn/root/usr/libexec/rpcd/vless" \
	"$W/vless-vpn/root/etc/init.d/vless" "$W/vless-vpn/root/etc/uci-defaults/90-vless" \
	"$W/vless-vpn/install.sh" "$W/vless-vpn/uninstall.sh"
find "$W/vless-vpn" -type f ! -name INSTALL.bat -exec sed -i 's/\r$//' {} +
tar --owner=0 --group=0 --numeric-owner -C "$W" -czf "$OUT/vless-vpn.tar.gz" vless-vpn
# zip для Windows: распаковать и запустить INSTALL.bat
if command -v zip >/dev/null 2>&1; then ( cd "$W" && zip -qr "$OUT/vless-vpn.zip" vless-vpn ); else echo "zip не найден — vless-vpn.zip не создан"; fi

# 2) .ipk для opkg (OpenWrt 24.10 и старше)
mkdir -p "$W/data/www" "$W/ctl"
cp -a root/. "$W/data/"
chmod 0755 "$W/data/usr/bin/vless" "$W/data/usr/libexec/rpcd/vless" \
	"$W/data/etc/init.d/vless" "$W/data/etc/uci-defaults/90-vless"
cp -a htdocs/. "$W/data/www/"
find "$W/data" "$W/ctl" -type f -exec sed -i 's/\r$//' {} +
cat > "$W/ctl/control" <<C
Package: luci-vless-selective
Version: $VER
Depends: luci-base, rpcd, sing-box, kmod-tun, curl, jq, ca-bundle, ip-full
Section: luci
Architecture: all
Maintainer: $(sed -n 's/^PKG_MAINTAINER:=//p' Makefile)
Description: VPN для OpenWrt: вставил ссылку, нажал кнопку, работает
C
echo /etc/config/vless > "$W/ctl/conffiles"
cat > "$W/ctl/postinst" <<'C'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
[ -x /etc/uci-defaults/90-vless ] && { sh /etc/uci-defaults/90-vless; rm -f /etc/uci-defaults/90-vless; }
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
exit 0
C
cat > "$W/ctl/prerm" <<'C'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/vless stop >/dev/null 2>&1
/etc/init.d/vless disable >/dev/null 2>&1
exit 0
C
chmod 0755 "$W/ctl/postinst" "$W/ctl/prerm"
( cd "$W/ctl" && tar --owner=0 --group=0 --numeric-owner -czf "$W/control.tar.gz" . )
( cd "$W/data" && tar --owner=0 --group=0 --numeric-owner -czf "$W/data.tar.gz" . )
echo 2.0 > "$W/debian-binary"
( cd "$W" && ar -cr "$OUT/luci-vless-selective_${VER}_all.ipk" debian-binary data.tar.gz control.tar.gz )
ls -l "$OUT"
