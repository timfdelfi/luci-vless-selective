#!/bin/sh
# Удаление VPN (luci-vless-selective).  sh uninstall.sh [--purge]  (--purge удаляет и список серверов)
/etc/init.d/vless stop 2>/dev/null
/etc/init.d/vless disable 2>/dev/null
/usr/bin/vless net-down 2>/dev/null
grep -v '/usr/bin/vless update-all' /etc/crontabs/root > /tmp/cron.vless 2>/dev/null && mv /tmp/cron.vless /etc/crontabs/root
rm -f /usr/bin/vless /etc/init.d/vless /usr/libexec/rpcd/vless /etc/config/vless \
      /usr/share/rpcd/acl.d/luci-vless-selective.json /usr/share/luci/menu.d/luci-vless-selective.json \
      /usr/share/nftables.d/chain-pre/input/20-vless.nft /usr/share/nftables.d/chain-pre/forward/20-vless.nft
rm -rf /usr/share/vless /www/luci-static/resources/view/vless /var/run/vless
[ "$1" = "--purge" ] && rm -rf /etc/vless
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/cron restart >/dev/null 2>&1
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
echo "VPN удалён."
