# shellcheck shell=sh disable=SC2154
# vless / settings.sh — настройки: settings_json и cmd_set.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- настройки

settings_json() {
	local dd dev ifs pd pr
	dd="$(uci -q get vless.main.direct_domains 2>/dev/null)"
	dev="$(uci -q get vless.main.devices 2>/dev/null)"
	ifs="$(uci -q get vless.main.ifaces 2>/dev/null)"
	pd="$(uci -q get vless.main.proxy_domains 2>/dev/null)"
	pr="$(uci -q get vless.main.presets 2>/dev/null)"
	jq -n -c \
		--arg scope "$(cfg scope all)" --arg pd "$pd" --arg pr "$pr" \
		--arg mode "$(cfg mode all)" \
		--arg dns_mode "$(cfg dns_mode vpn)" \
		--arg remote_dns "$(cfg remote_dns 1.1.1.1)" \
		--arg direct_dns "$(cfg direct_dns 'tls://77.88.8.8')" \
		--arg bootstrap_dns "$(cfg bootstrap_dns 77.88.8.8)" \
		--arg kill_switch "$(cfg kill_switch 0)" \
		--arg block_quic "$(cfg block_quic 1)" \
		--arg block_ipv6 "$(cfg block_ipv6 1)" \
		--arg bypass_vpn "$(cfg bypass_vpn 1)" \
		--arg bypass_ru "$(cfg bypass_ru 1)" \
		--arg tun_stack "$(cfg tun_stack system)" \
		--arg mtu "$(cfg mtu 1400)" \
		--arg log_level "$(cfg log_level warn)" \
		--arg user_agent "$(cfg user_agent "$VLESS_UA_DEFAULT")" --arg hwid "$(get_hwid)" \
		--arg update_interval "$(cfg update_interval 24)" \
		--arg selected "$(cfg selected auto)" \
		--arg discord_mode "$(cfg discord_mode off)" --arg discord_offload "$(cfg discord_offload 1)" \
		--arg auto_interval "$(cfg auto_interval 3m)" \
		--arg auto_tolerance "$(cfg auto_tolerance 80)" \
		--arg auto_test_url "$(cfg auto_test_url 'https://www.gstatic.com/generate_204')" \
		--arg dd "$dd" --arg dev "$dev" --arg ifs "${ifs:-lan}" \
		'{ scope:$scope, presets:($pr|split(" ")|map(select(length>0))), proxy_domains:($pd|split(" ")|map(select(length>0))),
		   mode:$mode, dns_mode:$dns_mode, remote_dns:$remote_dns, direct_dns:$direct_dns, bootstrap_dns:$bootstrap_dns,
		   kill_switch:($kill_switch=="1"), block_quic:($block_quic=="1"), block_ipv6:($block_ipv6=="1"), bypass_vpn:($bypass_vpn=="1"),
		   bypass_ru:($bypass_ru=="1"), tun_stack:$tun_stack, mtu:(try ($mtu|tonumber) catch 1400), log_level:$log_level,
		   discord_mode:$discord_mode, discord_offload:($discord_offload=="1"),
		   user_agent:$user_agent, hwid:$hwid, update_interval:(try ($update_interval|tonumber) catch 24), selected:$selected,
		   auto_interval:$auto_interval, auto_tolerance:(try ($auto_tolerance|tonumber) catch 80), auto_test_url:$auto_test_url,
		   direct_domains:($dd|split(" ")|map(select(length>0))),
		   devices:($dev|split(" ")|map(select(length>0))),
		   ifaces:($ifs|split(" ")|map(select(length>0))),
		   api_port:'"$API_PORT"', mixed_port:'"$MIXED_PORT"', dns_listen:"'"$DNS_LISTEN"'", tun_name:"'"$TUN"'" }'
}

cmd_set() {
	# stdin: JSON с настройками (только известные ключи)
	local data k v t line bad rej="$RUN/set.rejected" prev_dm
	prev_dm="$(cfg discord_mode off)"
	data="$(cat)"
	: > "$rej"
	printf '%s\n' "$data" | jq -e 'type=="object"' >/dev/null 2>&1 || { json_err "Некорректные настройки"; return 1; }
	uci -q get vless.main >/dev/null 2>&1 || { uci set vless.main=vless; }

	# скаляры
	printf '%s\n' "$data" | jq -r '
		def b: if . == true then "1" elif . == false then "0" else . end;
		[ "scope","mode","dns_mode","remote_dns","direct_dns","bootstrap_dns","kill_switch","block_quic","block_ipv6","bypass_ru","bypass_vpn",
		  "tun_stack","mtu","log_level","user_agent","update_interval","selected",
		  "auto_interval","auto_tolerance","auto_test_url","discord_mode","discord_offload" ] as $keys
		| $keys[] as $k | select(has($k)) | "\($k)\t\(.[$k] | b | tostring)"' | tr -d '\r' |
	while IFS="$TAB" read -r k v; do
		bad=0
		case "$k" in
			scope)          case "$v" in all|selected) ;; *) bad=1 ;; esac ;;
			mode)           case "$v" in all|include|exclude) ;; *) bad=1 ;; esac ;;
			dns_mode)       case "$v" in vpn|system) ;; *) bad=1 ;; esac ;;
			tun_stack)      case "$v" in system|gvisor|mixed) ;; *) bad=1 ;; esac ;;
			log_level)      case "$v" in trace|debug|info|warn|error) ;; *) bad=1 ;; esac ;;
			remote_dns|direct_dns) valid_dns_server "$v" || bad=1 ;;
			bootstrap_dns)  valid_ip "$v" || bad=1 ;;
			kill_switch|block_quic|block_ipv6|bypass_ru|bypass_vpn|discord_offload) case "$v" in 0|1) ;; *) bad=1 ;; esac ;;
			discord_mode)   case "$v" in off|auto|zapret|vpn) ;; *) bad=1 ;; esac ;;
			mtu)            { echo "$v" | grep -qE '^[0-9]{4}$' && [ "$v" -ge 1000 ] && [ "$v" -le 9000 ]; } || bad=1 ;;
			update_interval) { echo "$v" | grep -qE '^[0-9]{1,3}$' && [ "$v" -le 720 ]; } || bad=1 ;;
			selected)       echo "$v" | grep -qE '^(auto|[0-9a-f]{8})$' || bad=1 ;;
			auto_interval)  echo "$v" | grep -qE '^[0-9]+(s|m|h)$' || bad=1 ;;
			auto_tolerance) { echo "$v" | grep -qE '^[0-9]{1,4}$' && [ "$v" -le 1000 ]; } || bad=1 ;;
			auto_test_url)  case "$v" in http://*|https://*) ;; *) bad=1 ;; esac ;;
			user_agent)     { [ ${#v} -le 80 ] && [ -n "$v" ]; } || bad=1 ;;
			# Значение с переводом строки разбивается на несколько строк при чтении,
			# и вторая строка стала бы произвольным ключом UCI. Неизвестный ключ — отказ.
			*)              bad=1 ;;
		esac
		if [ "$bad" = 1 ]; then echo "$k" >> "$rej"; continue; fi
		uci set "vless.main.$k=$v"
	done

	# списки. Значения сначала проверяются целиком и только потом перезаписывается список:
	# раньше uci delete шёл первым, и сбой на середине оставлял опцию пустой безвозвратно.
	for k in direct_domains proxy_domains presets devices ifaces; do
		printf '%s\n' "$data" | jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1 || continue
		# элемент с переводом строки разбился бы на несколько записей списка
		if ! printf '%s\n' "$data" | jq -e --arg k "$k" \
			'[.[$k][]? | tostring | select(contains("\n") or contains("\r"))] | length == 0' >/dev/null 2>&1; then
			echo "$k (значение с переводом строки)" >> "$rej"; continue
		fi
		: > "$RUN/list.ok"
		printf '%s\n' "$data" | jq -r --arg k "$k" '.[$k][]? | tostring' | tr -d '\r' | while IFS= read -r line; do
			[ -n "$line" ] || continue
			case "$k" in
				devices)  valid_cidr "$line" || { echo "$k: $line" >> "$rej"; continue; } ;;
				presets)  case " $PRESET_KEYS " in *" $line "*) ;; *) continue ;; esac ;;
				ifaces)   echo "$line" | grep -qE '^[A-Za-z0-9_]{1,15}$' || { echo "$k: $line" >> "$rej"; continue; } ;;
				*)
					[ "${#line}" -le 253 ] && valid_route_target "$line" ||
						{ echo "$k: $line" >> "$rej"; continue; }
					;;
			esac
			printf '%s\n' "$line" >> "$RUN/list.ok"
		done
		# пустой результат при непустом вводе = всё отброшено проверкой: старый список цел
		if [ ! -s "$RUN/list.ok" ] && [ "$(printf '%s\n' "$data" | jq -r --arg k "$k" '[.[$k][]?]|length')" -gt 0 ]; then
			continue
		fi
		uci -q delete "vless.main.$k"
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			uci add_list "vless.main.$k=$line"
		done < "$RUN/list.ok"
	done
	rm -f "$RUN/list.ok"
	uci commit vless

	if printf '%s\n' "$data" | jq -e 'has("autostart")' >/dev/null 2>&1; then
		if [ "$(printf '%s\n' "$data" | jq -r '.autostart')" = "true" ]; then
			/etc/init.d/vless enable
		else
			/etc/init.d/vless disable
		fi
	fi
	sync_cron
	# Режим Discord сменился — подключаем или отключаем zapret (в фоне: может скачивать файлы)
	if [ "$(cfg discord_mode off)" != "$prev_dm" ] && [ -x "$DISCORD_BIN" ] && [ -z "$DISCORD_NO_SERVICE" ]; then
		( "$DISCORD_BIN" apply >/dev/null 2>&1 & )
	fi
	jq -n -c --rawfile r "$rej" '{ok:true, ignored:($r | split("\n") | map(select(length > 0)))}'
}

# ---------------------------------------------------------------- экспорт и импорт

cmd_export() {
	local srv src hid st
	[ -s "$SERVERS" ] && srv="$(cat "$SERVERS")" || srv='[]'
	[ -s "$SOURCES" ] && src="$(cat "$SOURCES")" || src='[]'
	[ -s "$HIDDEN" ] && hid="$(cat "$HIDDEN")" || hid='[]'
	st="$(settings_json)"
	jq -n -c \
		--argjson v 1 \
		--argjson now "$(date +%s)" \
		--argjson settings "$st" \
		--argjson sources "$src" \
		--argjson servers "$srv" \
		--argjson hidden "$hid" \
		'{ok:true,version:$v,created:$now,settings:$settings,sources:$sources,servers:$servers,hidden:$hidden}'
}

cmd_import() {
	local in data srv src hid
	in="$(cat)"
	if printf '%s' "$in" | jq -e '.backup and (.backup | type=="object")' >/dev/null 2>&1; then
		data="$(printf '%s' "$in" | jq -c '.backup')"
	elif printf '%s' "$in" | jq -e '.backup and (.backup | type=="string")' >/dev/null 2>&1; then
		data="$(printf '%s' "$in" | jq -r '.backup' | jq -c . 2>/dev/null)"
	else
		data="$in"
	fi
	printf '%s' "$data" | jq -e 'type=="object" and (has("servers") or has("settings"))' >/dev/null 2>&1 || {
		json_err "Некорректный файл резервной копии"
		return 1
	}

	if printf '%s' "$data" | jq -e '.servers | type=="array"' >/dev/null 2>&1; then
		srv="$(printf '%s' "$data" | jq -c '.servers')"
		atomic_text "$SERVERS" "$srv" || { json_err "Не удалось восстановить серверы"; return 1; }
	fi

	if printf '%s' "$data" | jq -e '.sources | type=="array"' >/dev/null 2>&1; then
		src="$(printf '%s' "$data" | jq -c '.sources')"
		atomic_text "$SOURCES" "$src" || { json_err "Не удалось восстановить подписки"; return 1; }
	fi

	if printf '%s' "$data" | jq -e '.hidden | type=="array"' >/dev/null 2>&1; then
		hid="$(printf '%s' "$data" | jq -c '.hidden')"
		atomic_text "$HIDDEN" "$hid" || true
	fi

	if printf '%s' "$data" | jq -e '.settings | type=="object"' >/dev/null 2>&1; then
		printf '%s' "$data" | jq -c '.settings' | cmd_set >/dev/null 2>&1
	fi

	restart_if_running
	jq -n -c '{ok:true}'
}

