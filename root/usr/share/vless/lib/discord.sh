# shellcheck shell=sh disable=SC2154
# vless / discord.sh — связка с vless-discord: «эффективные» настройки и синхронизация.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- Discord через zapret
# Обход Discord делает отдельный скрипт vless-discord (nfqws). Он решает, куда идёт Discord:
#   zapret — напрямую, через nfqws: Discord вырезается из маршрутов VPN, чтобы не ходил через туннель;
#   vpn    — через VPN (запасной путь, если ни одна стратегия zapret не подошла);
#   off    — Discord не трогаем.
# Здесь — только то, что касается самого VPN: «эффективные» настройки для sing-box.

DISCORD_BIN="${VLESS_DISCORD_BIN:-/usr/bin/vless-discord}"

discord_active() { cat "$RUN/discord.active" 2>/dev/null || echo off; }

# effective_settings — настройки пользователя с поправкой на Discord.
# Сохранённые настройки не меняются: поправка действует только при сборке маршрутов.
#   zapret   → домены Discord идут напрямую (и в «всё», и в «выбранное»), UDP голоса — напрямую.
#   vpn      → в режиме «выбранное» к пресетам добавляется Discord.
#   vpn_only → VPN запущен только ради Discord (сам пользователь VPN не включал):
#              «выбранное» с единственным пресетом, для всех устройств.
effective_settings() {
	local act only=false
	act="$(discord_active)"
	[ -f "$RUN/discord.vpn_only" ] && only=true
	settings_json | jq -c --arg act "$act" --argjson only "$only" \
		--argjson dom "$(jq -n -c -L "$LIB" 'include "presets"; presets.discord.domains')" '
		if $only then (.scope = "selected" | .mode = "all" | .devices = [] | .presets = ["discord"] | .proxy_domains = [])
		elif (.discord_mode // "off") == "off" then .
		elif $act == "zapret" then
			(.direct_domains = ((.direct_domains + $dom) | unique) | .presets = (.presets - ["discord"]) | .zapret_udp = true)
		elif $act == "vpn" then (.presets = ((.presets + ["discord"]) | unique))
		else . end'
}
eff() { effective_settings | jq -r --arg k "$1" '.[$k] | if type == "array" then join(" ") else tostring end'; }

# discord-sync: vless-discord сообщает, что Discord перешёл на другой путь.
# VPN работает — перечитываем маршруты; не работает, а Discord ушёл на VPN — поднимаем VPN
# только ради Discord; Discord вернулся на zapret, а VPN поднимали мы — гасим.
cmd_discord_sync() {
	local act
	act="$(discord_active)"
	if is_running; then
		if [ "$act" != vpn ] && [ -f "$RUN/discord.vpn_only" ]; then
			rm -f "$RUN/discord.vpn_only"
			/etc/init.d/vless stop >/dev/null 2>&1
		else
			/etc/init.d/vless restart >/dev/null 2>&1
		fi
		return 0
	fi
	if [ "$act" = vpn ] && [ "$(jq 'length' "$SERVERS" 2>/dev/null || echo 0)" -gt 0 ]; then
		: > "$RUN/discord.vpn_only"
		/etc/init.d/vless start >/dev/null 2>&1
	fi
	return 0
}
