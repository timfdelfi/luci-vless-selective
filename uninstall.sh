#!/bin/sh
# Удаление VPN (luci-vless-selective).  sh uninstall.sh [--purge]
# По умолчанию сохраняются серверы и подписки (/etc/vless), чтобы после
# переустановки не вводить всё заново. С --purge удаляется и база с ключами.
PURGE="$1"

say()  { printf '%s\n' "$*"; }

say "Останавливаю VPN"
/etc/init.d/vless stop 2>/dev/null
/etc/init.d/vless disable 2>/dev/null
/usr/bin/vless net-down 2>/dev/null

say "Убираю задачу автообновления"
# grep -v отнимает 1 и когда строк не осталось; код 2 означает настоящую ошибку.
if [ -f /etc/crontabs/root ]; then
	grep -v -F '/usr/bin/vless update-all' /etc/crontabs/root > /tmp/cron.vless 2>/dev/null
	[ $? -le 1 ] && mv /tmp/cron.vless /etc/crontabs/root || rm -f /tmp/cron.vless
fi

say "Удаляю файлы"
rm -f /usr/bin/vless /etc/init.d/vless /usr/libexec/rpcd/vless /etc/config/vless \
      /usr/share/rpcd/acl.d/luci-vless-selective.json /usr/share/luci/menu.d/luci-vless-selective.json \
      /usr/share/nftables.d/chain-pre/input/20-vless.nft /usr/share/nftables.d/chain-pre/forward/20-vless.nft \
      /etc/uci-defaults/90-vless
rm -rf /usr/share/vless /www/luci-static/resources/view/vless /var/run/vless

if [ "$PURGE" = "--purge" ]; then
	# Здесь лежат UUID, пароли и токены подписок. Без --purge они остаются.
	# Не удаляем, если это symlink/mount — удалим только содержимое
	if [ -L /etc/vless ] || mountpoint -q /etc/vless 2>/dev/null; then
		rm -f /etc/vless/* /etc/vless/.* 2>/dev/null || true
	else
		rm -rf /etc/vless
	fi
	say "База серверов и подписок удалена (/etc/vless)."
else
	say "Серверы и подписки сохранены в /etc/vless (удалить: sh uninstall.sh --purge)."
fi

/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
/etc/init.d/cron restart >/dev/null 2>&1
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
say "VPN удалён."