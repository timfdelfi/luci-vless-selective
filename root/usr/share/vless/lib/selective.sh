# shellcheck shell=sh disable=SC2154
# vless / selective.sh — выборочная маршрутизация (режим «только выбранные»).
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- выборочная маршрутизация
# «Только выбранные сервисы»: весь трафик в туннель НЕ заворачиваем. nftables помечает только пакеты
# к адресам из набора vpn4 — его наполняет dnsmasq по доменам выбранных сервисов (nftset) и пресеты
# с подсетями. Помеченные пакеты уходят в туннель, остальные идут обычной маршрутизацией мимо sing-box.

SEL_MARK=0x64
SEL_SET="vpn4"

# selective_lists — строки «D домен» и «C подсеть» для выбранных пресетов и своих сайтов
selective_lists() {
	local keys pd
	keys="$(effective_settings | jq -c '.presets // []')"
	pd="$(effective_settings | jq -c '.proxy_domains // []')"
	jq -n -r -L "$LIB" --argjson keys "$keys" --argjson pd "$pd" '
		include "presets";
		def isdigits: length > 0 and (explode | all(. >= 48 and . <= 57));
		def is_ip: (split("/")[0]) as $a
			| ((($a | split(".")) | length) == 4 and (($a | split(".")) | all(isdigits)))
			  or ($a | contains(":"));
		def is_ip4: (split("/")[0]) as $a
			| ((($a | split(".")) | length) == 4 and (($a | split(".")) | all(isdigits)));
		( $keys[] as $k | (presets[$k].domains // [])[] | "D " + . ),
		( $keys[] as $k | (presets[$k].cidrs // [])[] | select(is_ip4) | "C " + . ),
		# Набор vpn4 объявлен как ipv4_addr, поэтому IPv6-подсети в него попасть не могут.
		# Раньше такая строка ломала nft add element целиком и отключала ВСЕ подсети разом.
		( $pd[] | ltrimstr("*.") | select(contains("*") | not)
			| if is_ip4 then "C " + . elif is_ip then empty else "D " + . end )
	' 2>/dev/null
}

# selective_nft_conf — правила nftables для режима «выбранные»
selective_nft_conf() {
	local csv="" d rule
	for d in $(uci -q get vless.main.devices 2>/dev/null); do
		valid_cidr "$d" && csv="${csv:+$csv, }$d"
	done
		case "$(eff mode)" in
			include)
				if [ -n "$csv" ]; then rule="ip saddr { $csv } ip daddr @$SEL_SET meta mark set $SEL_MARK"; else rule=""; fi ;;
			exclude)
				if [ -n "$csv" ]; then rule="ip saddr != { $csv } ip daddr @$SEL_SET meta mark set $SEL_MARK"
				else rule="ip daddr @$SEL_SET meta mark set $SEL_MARK"; fi ;;
			*)  rule="ip daddr @$SEL_SET meta mark set $SEL_MARK" ;;
		esac
	echo "table inet vless {"
	# Набор живёт до перезапуска службы: dnsmasq добавляет элементы без таймаута,
	# поэтому старые адреса сами не исчезают — зато переподключение всегда чистит набор.
	echo "  set $SEL_SET { type ipv4_addr; flags interval, timeout; auto-merge; }"
	echo "  chain pre { type filter hook prerouting priority -150; policy accept;"
	[ -n "$rule" ] && echo "    $rule"
	echo "  }"
	echo "}"
}

# selective_up — включить выборочный режим; при неудаче возвращает 1 (тогда работает обычный режим)
selective_up() {
	local lines c
	if ! dnsmasq --version 2>/dev/null | tr " \t" "\n" | grep -qx nftset; then
		logger -t vless "dnsmasq собран без nftset: выборочный режим недоступен, используется обычный (установите dnsmasq-full)" 2>/dev/null
		return 1
	fi
	lines="$(selective_lists)"
	printf '%s\n' "$lines" | awk -v s="$SEL_SET" '$1=="D"{print "nftset=/" $2 "/4#inet#vless#" s}' > "$RUN/nftset.conf"
	selective_nft_conf > "$RUN/nft.conf"
	if ! nft -f "$RUN/nft.conf" 2>"$RUN/nft.err"; then
		logger -t vless "nft: не удалось включить выборочный режим: $(head -c 200 "$RUN/nft.err" 2>/dev/null)" 2>/dev/null
		rm -f "$RUN/nftset.conf"; nft delete table inet vless 2>/dev/null
		return 1
	fi
	c="$(printf '%s\n' "$lines" | awk '$1=="C"{s = s (s ? "," : "") $2} END{print s}')"
	if [ -n "$c" ]; then
		# nft откатывает add element целиком, если хотя бы один элемент негодный.
		# Поэтому сначала пробуем всё сразу, а при отказе — по одному, чтобы потеря
		# одной кривой подсети не отключала все остальные.
		nft add element inet vless "$SEL_SET" "{ $c }" 2>/dev/null ||
			printf '%s\n' "$c" | tr ',' '\n' | while read -r one; do
				[ -n "$one" ] && nft add element inet vless "$SEL_SET" "{ $one }" 2>/dev/null
			done
	fi
	# Если в наборе пусто, маркировать нечего: трафик пойдёт мимо туннеля, но VPN
	# покажет себя подключённым. Честнее сообщить об этом, чем вернуть 0.
	if [ -z "$c" ] && ! printf '%s\n' "$lines" | grep -q '^D '; then
		logger -t vless "выборочный режим: нет ни доменов, ни подсетей — трафик в туннель не пойдёт (проверьте «Настройки → Маршрутизация»)" 2>/dev/null
		rm -f "$RUN/nftset.conf"; nft delete table inet vless 2>/dev/null
		return 1
	fi
	return 0
}

selective_down() {
	nft delete table inet vless 2>/dev/null
	rm -f "$RUN/nftset.conf" "$RUN/nft.conf"
}
