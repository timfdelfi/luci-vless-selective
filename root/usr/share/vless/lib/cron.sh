# shellcheck shell=sh disable=SC2154
# vless / cron.sh — cron автообновления подписок и автозапуск.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# cron_spec ЧАСЫ — до 23 ч: «каждые N часов»; больше: раз в N/24 дней в 04:17
cron_spec() {
	if [ "$1" -le 23 ]; then echo "17 */$1 * * *"; else echo "17 4 */$(($1 / 24)) * *"; fi
}

sync_cron() {
	local n f="${VLESS_CRON:-/etc/crontabs/root}"
	n="$(cfg update_interval 24)"
	mkdir -p "$(dirname "$f")"
	[ -f "$f" ] || { touch "$f"; chmod 600 "$f" 2>/dev/null; }
	# grep -v отнимает 1 и когда строк просто не осталось (в crontab была только наша
	# запись) — это норма. Код 2 означает настоящую ошибку: при ней $f.tmp пуст,
	# и все чужие задания cron были бы стёрты. Поэтому проверяем код, а не пустой файл.
	grep -v -F '/usr/bin/vless update-all' "$f" > "$f.tmp" 2>/dev/null
	grc=$?
	if [ "$grc" -gt 1 ]; then
		rm -f "$f.tmp"
		logger -t vless "не удалось обновить crontab: $f недоступен для чтения" 2>/dev/null
		return 1
	fi
	if [ "$n" -gt 0 ] 2>/dev/null; then
		echo "$(cron_spec "$n") /usr/bin/vless update-all >/dev/null 2>&1" >> "$f.tmp"
	fi
	if ! cmp -s "$f" "$f.tmp"; then
		# Права OpenWrt на /etc/crontabs/root — 0600; после mv они не должны меняться.
		chmod --reference="$f" "$f.tmp" 2>/dev/null || chmod 600 "$f.tmp" 2>/dev/null
		mv "$f.tmp" "$f"
		[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1
	else
		rm -f "$f.tmp"
	fi
}

autostart_on() { ls /etc/rc.d/S*vless >/dev/null 2>&1; }
