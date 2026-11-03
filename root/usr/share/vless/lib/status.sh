# shellcheck shell=sh disable=SC2154
# vless / status.sh — state/status/devices/logs и selftest.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

cmd_status() {
	local running=false ready=false active="" up=0 down=0 speed_up=0 speed_down=0 since=0 err="" now
	is_running && running=true
	is_ready && ready=true
	now="$(date +%s)"
	if [ "$ready" = true ]; then
		local now_act
		now_act="$(api GET /proxies/proxy | jq -r '.now // empty' 2>/dev/null)"
		[ "$now_act" = "auto" ] && now_act="$(api GET /proxies/auto | jq -r '.now // empty' 2>/dev/null)"
		active="${now_act#s-}"
		api GET /connections > "$RUN/conn.json.tmp" 2>/dev/null && mv "$RUN/conn.json.tmp" "$RUN/conn.json"
		up="$(jq -r '.uploadTotal // 0' "$RUN/conn.json" 2>/dev/null)"
		down="$(jq -r '.downloadTotal // 0' "$RUN/conn.json" 2>/dev/null)"
		since="$(cat "$RUN/up_since" 2>/dev/null)"
		if [ -s "$RUN/traffic.prev" ]; then
			local prev_t prev_u prev_d dt
			read -r prev_t prev_u prev_d < "$RUN/traffic.prev" 2>/dev/null
			dt=$((now - ${prev_t:-0}))
			if [ "$dt" -ge 1 ] && [ "${up:-0}" -ge "${prev_u:-0}" ] && [ "${down:-0}" -ge "${prev_d:-0}" ]; then
				speed_up=$(( (${up:-0} - ${prev_u:-0}) / dt ))
				speed_down=$(( (${down:-0} - ${prev_d:-0}) / dt ))
			fi
		fi
		echo "$now ${up:-0} ${down:-0}" > "$RUN/traffic.prev"
	else
		rm -f "$RUN/traffic.prev"
	fi
	if [ "$ready" = false ]; then
		err="$(cat "$RUN/last_error" 2>/dev/null)"
		[ -n "$err" ] || err="$(grep -iE 'fatal|error' "$RUN/sing-box.log" 2>/dev/null | log_noise | tail -n1 | cut -c1-300)"
	fi
	local other=false mine="" p ipj=null
	[ -s "$RUN/ip.json" ] && ipj="$(cat "$RUN/ip.json")"
	mine="$(cat "$PIDFILE" 2>/dev/null)"
	for p in $(pgrep -x sing-box 2>/dev/null); do [ "$p" != "$mine" ] && other=true; done
	jq -n -c --argjson running "$running" --argjson ready "$ready" --arg active "$active" \
		--argjson up "${up:-0}" --argjson down "${down:-0}" \
		--argjson speed_up "${speed_up:-0}" --argjson speed_down "${speed_down:-0}" \
		--argjson since "${since:-0}" --argjson now "$now" \
		--arg err "$err" --argjson other "$other" --argjson ip "$ipj" '
		{ running:$running, connected:$ready, active:$active, up:$up, down:$down,
		  speed_up:$speed_up, speed_down:$speed_down,
		  uptime:(if $since>0 then ($now-$since) else 0 end), error:$err, other_singbox:$other, ip:$ip,
			  phase:(if $ready then "on" elif $running then (if ($err|length)>0 then "error" else "starting" end) else (if ($err|length)>0 then "error" else "off" end) end) }'
}

cmd_state() {
	local delays='{}'
	# Битый delays.json не должен ломать весь ответ интерфейса.
	[ -s "$RUN/delays.json" ] && jq -e 'type=="object"' "$RUN/delays.json" >/dev/null 2>&1 && delays="$(cat "$RUN/delays.json")"
	# URL подписки содержит токен доступа. Метод state доступен на чтение любому
	# пользователю LuCI с доступом к приложению, поэтому наружу отдаём только хост:
	# интерфейс всё равно URL не показывает, а ключи всех подписок хранятся в пути.
	# Разбор без регулярных выражений — jq на роутерах часто без Oniguruma.
	jq -n -c \
		--argjson servers "$(jq -c 'map(del(.outbound))' "$SERVERS")" \
		--argjson sources "$(jq -c 'map(if .url then .url = ((.url | split("://")) as $p
			| if ($p|length) > 1 then ($p[0] + "://" + ($p[1] | split("/")[0])) else "<скрыто>" end)
			else . end)' "$SOURCES")" \
		--argjson settings "$(settings_json)" \
		--argjson status "$(cmd_status)" \
		--argjson delays "$delays" \
		--argjson discord "$(d="$("$DISCORD_BIN" status 2>/dev/null)"; printf '%s' "$d" | jq -e 'type=="object"' >/dev/null 2>&1 && printf '%s' "$d" || echo null)" \
		--arg version "$(sb_version)" \
		--argjson autostart "$(autostart_on && echo true || echo false)" \
		--argjson tun "$([ -c /dev/net/tun ] && echo true || echo false)" \
		'{servers:$servers,sources:$sources,settings:($settings + {autostart:$autostart}),status:$status,delays:$delays,discord:$discord,singbox:$version,tun:$tun}'
}

cmd_devices() {
	[ -s /tmp/dhcp.leases ] || { echo '{"devices":[]}'; return; }
	jq -R -n -c '{devices:[inputs | split(" ") | select(length>=4) | {mac:.[1], ip:.[2], name:(if .[3]=="*" then "" else .[3] end)}] | sort_by(.ip | split(".") | map(tonumber? // 0))}' < /tmp/dhcp.leases
}

cmd_logs() {
	{
		echo "== sing-box =="
		[ -s "$RUN/sing-box.prev.log" ] && { echo "— предыдущий запуск —"; tail -n 60 "$RUN/sing-box.prev.log" 2>/dev/null; echo; }
		tail -n 60 "$RUN/sing-box.log" 2>/dev/null
		echo; echo "== system =="; logread -e vless 2>/dev/null | tail -n 30
	} | jq -R -s -c '{log:.}'
}

cmd_clearlog() {
	: > "$RUN/sing-box.log"
	: > "$RUN/sing-box.prev.log"
	jq -n -c '{ok:true}'
}

# ---------------------------------------------------------------- самопроверка

cmd_selftest() {
	local t n
	t='vless://00000000-0000-0000-0000-000000000000@example.com:443?type=grpc&security=tls&sni=example.com&serviceName=x#test'
	echo "jq:       $(jq --version 2>&1)"
	echo "curl:     $(command -v curl >/dev/null 2>&1 && echo ok || echo 'НЕ УСТАНОВЛЕН')"
	echo "sing-box: $(command -v sing-box >/dev/null 2>&1 && sb_version || echo 'НЕ УСТАНОВЛЕН')  (нужно 1.12+)"
	echo "User-Agent: $(cfg user_agent "$VLESS_UA_DEFAULT")   HWID: $(get_hwid)"
	echo "tun:      $([ -c /dev/net/tun ] && echo ok || echo 'НЕТ /dev/net/tun (kmod-tun)')"
	echo "parse.jq: $([ -s "$LIB/parse.jq" ] && echo ok || echo 'ФАЙЛ НЕ НАЙДЕН — переустановите')"
	echo "build.jq: $([ -s "$LIB/build.jq" ] && echo ok || echo 'ФАЙЛ НЕ НАЙДЕН — переустановите')"
	echo "dnsmasq nftset (для «Только выбранные»): $(dnsmasq --version 2>/dev/null | tr " " "\n" | grep -qx nftset && echo ok || echo 'НЕТ — установите dnsmasq-full')"
	n="$(printf '%s\n' "$t" | jq -R -n -r --arg mode links -f "$LIB/parse.jq" 2>&1 | head -c 120)"
	case "$n" in
		*server_port*) echo "разбор тестовой ссылки: ok" ;;
		*) echo "разбор тестовой ссылки: ОШИБКА: $n" ;;
	esac
	# Проверка версии jq (walk нужен в build.jq clean)
	jq --version 2>/dev/null | awk -F- '{print $2}' | awk -F. '{if ($1<1 || ($1==1 && $2<6)) print "ПРЕДУПРЕЖЕНИЕ: jq " $0 " — walk() может не работать, обновите jq"}'
	# Быстрая проверка доступности интернета (через gstatic)
	curl -s -m 3 "https://www.gstatic.com/generate_204" >/dev/null 2>&1 && echo "интернет: ok" || echo "интернет: НЕДОСТУПЕН (проверьте WAN)"
}
