#!/bin/sh
# Установка VPN (luci-vless-selective) на роутер OpenWrt.
# Запускать на роутере:  sh install.sh
cd "$(dirname "$0")" || exit 1

say()  { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

[ -f /etc/openwrt_release ] || { echo "Это не OpenWrt — установка остановлена."; exit 1; }
[ "$(id -u)" = "0" ] || { echo "Запустите от root."; exit 1; }

if command -v apk >/dev/null 2>&1; then PM=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg
else echo "Не найден менеджер пакетов (opkg/apk)."; exit 1; fi

free_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$free_kb" ] && [ "$free_kb" -lt 20000 ] && warn "Свободного места мало (${free_kb} КБ). sing-box занимает около 15–20 МБ."

say "Устанавливаю зависимости ($PM)"
DEPS="sing-box kmod-tun curl jq ca-bundle ip-full"
if [ "$PM" = apk ]; then
	apk update >/dev/null 2>&1
	for p in $DEPS; do apk info -e "$p" >/dev/null 2>&1 || apk add "$p" || warn "Не удалось установить $p"; done
else
	opkg update >/dev/null 2>&1
	for p in $DEPS; do opkg list-installed 2>/dev/null | grep -q "^$p " || opkg install "$p" || warn "Не удалось установить $p"; done
fi

command -v sing-box >/dev/null 2>&1 || { echo "sing-box не установлен — без него VPN не заработает. Освободите место и повторите."; exit 1; }
ver="$(sing-box version 2>/dev/null | head -n1 | awk '{print $3}')"
major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
if [ "${major:-0}" -lt 1 ] || { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -lt 12 ]; }; then
	warn "Установлен sing-box $ver — нужна версия 1.12 или новее. Обновите пакет sing-box."
fi

say "Копирую файлы"
[ -f /etc/config/vless ] && cp /etc/config/vless /tmp/vless.config.keep
cp -a root/. /
cp -a htdocs/. /www/
[ -f /tmp/vless.config.keep ] && { cp /tmp/vless.config.keep /etc/config/vless; rm -f /tmp/vless.config.keep; }
chmod 0755 /usr/bin/vless /usr/libexec/rpcd/vless /etc/init.d/vless /etc/uci-defaults/90-vless 2>/dev/null

say "Применяю настройки"
[ -x /etc/uci-defaults/90-vless ] && { sh /etc/uci-defaults/90-vless; rm -f /etc/uci-defaults/90-vless; }
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null

pgrep -x sing-box >/dev/null 2>&1 && warn "Уже запущен другой sing-box (возможно, Podkop). Перед подключением остановите его — два VPN одновременно мешают друг другу."

say "Самопроверка"
/usr/bin/vless selftest

say "Готово!"
echo "Откройте веб-интерфейс роутера → Службы → VPN"
echo "(если пункта нет — обновите страницу через Ctrl+F5 или перелогиньтесь)."
