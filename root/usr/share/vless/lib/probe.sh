# shellcheck shell=sh disable=SC2154
# vless / probe.sh — диагностика: check, ping, ping-direct.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- диагностика

# Шум при штатном отключении. sing-box пишет обрыв загрузки на уровне ERROR,
# хотя соединение закрыл сам пользователь кнопкой «Отключить». Такие строки
# не должны показываться как «Ошибка подключения».
log_noise() {
	grep -viE 'connection download closed|ClientConn\.Close|force closed|context canceled|use of closed network connection|operation was canceled'
}

ip_lookup() { # через локальный proxy sing-box
	local u r why=""
	for u in "https://ipwho.is/" "https://api.ip.sb/geoip" "https://api.myip.com"; do
		r="$(curl -s -m 7 -x "socks5h://127.0.0.1:$MIXED_PORT" "$u" 2>/dev/null)" || { why="$why ${u#https://}:недоступен"; continue; }
		printf '%s\n' "$r" | jq -e '.ip' >/dev/null 2>&1 || { why="$why ${u#https://}:нет поля ip"; continue; }
		[ -n "$why" ] && logger -t vless "ip: ответил ${u#https://} ($why)" 2>/dev/null
		printf '%s\n' "$r" | jq -c '{ip:.ip, country:(.country // ""), code:((.country_code // .cc // "")|ascii_uppercase)}'
		return 0
	done
	logger -t vless "ip: не удалось определить адрес ($why)" 2>/dev/null
	return 1
}

cmd_check() {
	local r d ipj
	is_ready || { jq -n -c '{ok:false,error:"VPN не запущен"}'; return 0; }
	# T должен быть больше timeout в URL (7с), иначе curl обрубит запрос раньше sing-box
	r="$(T=12 api GET '/proxies/proxy/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=7000')"
	d="$(printf '%s\n' "$r" | jq -r '.delay // empty' 2>/dev/null)"
	if [ -z "$d" ]; then
		jq -n -c --arg m "$(printf '%s\n' "$r" | jq -r '.message // "нет ответа"' 2>/dev/null)" '{ok:false,error:("Сервер не отвечает: "+$m)}'
		return 0
	fi
	ipj="$(ip_lookup)"
	[ -n "$ipj" ] && echo "$ipj" > "$RUN/ip.json"
	jq -n -c --argjson d "$d" --argjson ip "${ipj:-null}" '{ok:true,delay:$d,ip:$ip}'
}

PING_URL="https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"

# Задержки всех серверов: по одному запросу /proxies/s-<id>/delay на сервер, параллельно.
# Раньше использовался /group/auto/delay — такого эндпоинта в Clash API sing-box 1.12+
# просто нет (маршруты /configs, /proxies, /rules, /connections, /dns, /profile, /cache,
# /providers, /script, /ui), поэтому «Пинг всех» при подключённом VPN всегда заканчивался
# ошибкой и цифры не появлялись. Меряем сами, ограничивая число одновременных запросов,
# чтобы роутер не захлебнулся.
ping_all_servers() { # -> {"id":мс,…}
	local ids id d p n=0 pids="" dir="$RUN/delay.$$" f
	rm -rf "$dir"; mkdir -p "$dir"
	ids="$(jq -r '.[] | select(.supported==true and .outbound!=null) | .id' "$SERVERS" 2>/dev/null | tr -d '\r')"
	if [ -z "$ids" ]; then echo '{}'; return 0; fi
	for id in $ids; do
		(
			d="$(T=8 api GET "/proxies/s-$id/delay?url=$PING_URL&timeout=5000" 2>/dev/null |
				jq -r 'if (.delay|type)=="number" then .delay else empty end' 2>/dev/null)"
			[ -n "$d" ] && printf '%s' "$d" > "$dir/$id"
		) &
		pids="$pids $!"; n=$((n + 1))
		if [ "$n" -ge 8 ]; then
			for p in $pids; do wait "$p" 2>/dev/null; done
			pids=""; n=0
		fi
	done
	for p in $pids; do wait "$p" 2>/dev/null; done
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		printf '%s\t%s\n' "${f##*/}" "$(cat "$f" 2>/dev/null)"
	done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t"))
		| map({ key: .[0], value: (.[1] | tonumber?) }) | map(select(.value != null)) | from_entries' 2>/dev/null
	rm -rf "$dir"
}

cmd_ping() { # ping [ID] — без ID меряет все серверы, с ID — только один (через VPN, точнее)
	local r id="$1" d
	is_ready || { jq -n -c '{ok:false,error:"VPN не подключён — используйте кнопку «Пинг всех» для прямого измерения"}'; return 0; }
	[ -s "$RUN/delays.json" ] || echo '{}' > "$RUN/delays.json"
	if [ -n "$id" ]; then
		echo "$id" | grep -qE '^[0-9a-f]{8}$' || { json_err "Некорректный id"; return 0; }
		r="$(T=12 api GET "/proxies/s-$id/delay?url=$PING_URL&timeout=8000")"
		d="$(printf '%s\n' "$r" | jq -r 'if (.delay|type)=="number" then .delay else empty end' 2>/dev/null)"
		if [ -n "$d" ]; then
			jq -c --arg id "$id" --argjson d "$d" '. + {($id):$d}' "$RUN/delays.json" > "$RUN/delays.tmp" && mv "$RUN/delays.tmp" "$RUN/delays.json"
			jq -n -c --slurpfile all "$RUN/delays.json" --argjson d "$d" '{ok:true,ms:$d,delays:$all[0]}'
		else
			jq -c --arg id "$id" 'del(.[$id])' "$RUN/delays.json" > "$RUN/delays.tmp" && mv "$RUN/delays.tmp" "$RUN/delays.json"
			jq -n -c --slurpfile all "$RUN/delays.json" '{ok:false,error:"Сервер не ответил за 8 секунд",delays:$all[0]}'
		fi
		return 0
	fi
	r="$(ping_all_servers)"
	printf '%s' "$r" | jq -e 'type=="object"' >/dev/null 2>&1 || r='{}'
	atomic_text "$RUN/delays.json" "$r"
	# Если не ответил ни один сервер — это честная неудача, а не «обновилось»
	jq -n -c --slurpfile d "$RUN/delays.json" \
		'($d[0] | length) as $n
		 | if $n == 0 then {ok:false,error:"Ни один сервер не ответил",delays:{}}
		   else {ok:true,delays:$d[0],count:$n} end'
}

# ping_direct [ID] — прямой пинг до сервера без VPN
# Меряет время установления TCP-соединения до server:port — хороший прокси для «как далеко сервер».
# curl печатает %{time_connect} даже при неудаче, поэтому код возврата проверяется явно:
# иначе недоступный сервер получал бы правдоподобный «пинг».
ping_one_direct() { # ping_one_direct HOST PORT [PROTO] [SEC] -> мс (время RTT) или ""
	local host="$1" port="$2" proto="$3" sec="$4" out rc code tc ta u url
	# Для UDP-протоколов (Hysteria2, WireGuard) прямой пинг замеряется через ICMP к хосту
	if [ "$proto" = "hysteria2" ] || [ "$proto" = "hy2" ] || [ "$proto" = "wireguard" ]; then
		local p_out
		p_out="$(ping -c 1 -W 2 "$host" 2>/dev/null || ping -c 1 -w 2 "$host" 2>/dev/null)"
		echo "$p_out" | awk -F'/' '/rtt|round-trip/{printf "%d", $5; exit}' | grep -E '^[0-9]+$' && return 0
		echo "$p_out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -n1 | awk '{printf "%d", $1}' | grep -E '^[0-9]+$' && return 0
		return 0
	fi
	# IPv6-адрес в URL должен быть в квадратных скобках
	u="$host"
	case "$host" in *:*) u="[$host]" ;; esac
	# Для чистого Shadowsocks без TLS (sec=none) подключаемся по http, чтобы не ждать TLS handshake
	if [ "$proto" = "ss" ] && [ "$sec" = "none" ]; then
		url="http://$u:$port"
	else
		case "$port" in
			80) url="http://$u" ;;
			*)  url="https://$u:$port" ;;
		esac
	fi
	# -k: у Reality отдаётся сертификат сайта-маскировки, он не совпадает с адресом сервера.
	# Код выхода curl не отбрасывает результат: сервер VLESS/Trojan без fallback закрывает
	# соединение на HTTP-запрос (curl 52/56), хотя TCP и TLS уже прошли — он живой.
	# Недоступным считаем сервер, у которого не было TCP connect, а для https — и тот,
	# что сбросил соединение ещё до конца TLS-рукопожатия (так выглядит блокировка DPI).
	out="$(curl --noproxy '*' -k -so /dev/null -m 6 -w '%{http_code} %{time_connect} %{time_appconnect}' "$url" 2>/dev/null)"; rc=$?
	set -- $out
	code="$1"; tc="$2"; ta="$3"
	printf '%s' "$tc" | grep -qE '^[0-9]+\.[0-9]+$' || return 0
	awk -v t="$tc" 'BEGIN{exit !(t>0)}' || return 0
	# Для Shadowsocks без TLS достаточно успешного TCP connect
	if [ "$proto" = "ss" ] && [ "$sec" = "none" ]; then
		case "$rc" in 0|52|56) awk -v t="$tc" 'BEGIN{printf "%d", t*1000}'; return 0 ;; *) return 0 ;; esac
	fi
	case "$code" in
		[1-5][0-9][0-9]) ;;
		*)
			# ответа нет: годится только «закрыл после рукопожатия» (52/56) на https
			[ "$port" != 80 ] || return 0
			case "$rc" in 52|56) ;; *) return 0 ;; esac
			printf '%s' "$ta" | grep -qE '^[0-9]+\.[0-9]+$' || return 0
			awk -v t="$ta" 'BEGIN{exit !(t>0)}' || return 0
			;;
	esac
	awk -v t="$tc" 'BEGIN{printf "%d", t*1000}'
}

cmd_ping_direct() { # ping_direct [ID] — прямой пинг без VPN
	local id="$1" d
	[ -s "$RUN/delays.json" ] || echo '{}' > "$RUN/delays.json"
	if [ -n "$id" ]; then
		echo "$id" | grep -qE '^[0-9a-f]{8}$' || { json_err "Некорректный id"; return 0; }
		d="$(jq -r --arg id "$id" '.[]|select(.id==$id)|[.server,(.port|tostring),(.proto // ""),(.sec // "")]|@tsv' "$SERVERS" 2>/dev/null)"
		[ -n "$d" ] || { json_err "Сервер не найден"; return 0; }
		local host port proto sec ms
		host="$(printf '%s' "$d" | cut -f1)"
		port="$(printf '%s' "$d" | cut -f2)"
		proto="$(printf '%s' "$d" | cut -f3)"
		sec="$(printf '%s' "$d" | cut -f4)"
		ms="$(ping_one_direct "$host" "$port" "$proto" "$sec")"
		if [ -n "$ms" ]; then
			jq -c --arg id "$id" --argjson d "$ms" '. + {($id):$d}' "$RUN/delays.json" > "$RUN/delays.tmp" && mv "$RUN/delays.tmp" "$RUN/delays.json"
			jq -n -c --slurpfile all "$RUN/delays.json" --argjson d "$ms" '{ok:true,ms:$d,delays:$all[0],direct:true}'
		else
			jq -c --arg id "$id" 'del(.[$id])' "$RUN/delays.json" > "$RUN/delays.tmp" && mv "$RUN/delays.tmp" "$RUN/delays.json"
			jq -n -c --slurpfile all "$RUN/delays.json" '{ok:false,error:"Сервер не ответил (возможно, недоступен напрямую)",delays:$all[0]}'
		fi
		return 0
	fi
	# параллельный пинг всех серверов (через файлы: <(...) не работает в sh)
	jq -r '.[]|[.id,.server,(.port|tostring),(.proto // ""),(.sec // "")]|@tsv' "$SERVERS" 2>/dev/null | tr -d '\r' > "$RUN/pingtab"
	local result="{}" n=0 p
	pids=""
	while IFS="$TAB" read -r id host port proto sec; do
		[ -n "$id" ] && [ -n "$host" ] && [ -n "$port" ] || continue
		( ms="$(ping_one_direct "$host" "$port" "$proto" "$sec")"; printf '%s\t%s\n' "$id" "${ms:-FAIL}" > "$RUN/pingd.$id" ) &
		pids="$pids $!"
		join_jobs
	done < "$RUN/pingtab"
	rm -f "$RUN/pingtab"
	join_all
	cat "$RUN"/pingd.* 2>/dev/null > "$RUN/pingres"
	while IFS="$TAB" read -r id ms; do
		[ -n "$id" ] || continue
		if [ "$ms" = "FAIL" ] || [ -z "$ms" ]; then
			result="$(printf '%s' "$result" | jq -c --arg id "$id" 'del(.[$id])')"
		else
			result="$(printf '%s' "$result" | jq -c --arg id "$id" --argjson d "$ms" '. + {($id):$d}')"
		fi
	done < "$RUN/pingres"
	rm -f "$RUN/pingres"
	rm -f "$RUN"/pingd.*
	atomic_text "$RUN/delays.json" "$result"
	# Как и в cmd_ping: если не ответил никто — это честная неудача, а не «обновилось».
	n="$(printf '%s' "$result" | jq -r 'length')"
	jq -n -c --slurpfile d "$RUN/delays.json" --argjson n "$n" \
		'(if $n == 0 then {ok:false,error:"Ни один сервер не ответил напрямую (проверьте подключение к интернету)"}
		  else {ok:true,delays:$d[0],count:$n} end) + {direct:true}'
}
