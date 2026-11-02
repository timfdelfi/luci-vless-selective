# shellcheck shell=sh disable=SC2154
# vless / lifecycle.sh — prepare, connect, disconnect, run.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- запуск и остановка

# Адреса VPN-серверов подписки (ip proto port в $RUN/vpn_targets).
# Трафик устройств к этим серверам пускаем мимо туннеля: иначе VPN-клиент на телефоне или
# компьютере (с теми же серверами) оказывается «внутри» VPN роутера и перестаёт работать.
resolve_vpn_targets() {
	local out="$RUN/vpn_targets" bs host typ port proto ip to=""
	bs="$(cfg bootstrap_dns 77.88.8.8)"
	command -v timeout >/dev/null 2>&1 && to="timeout 5"
	rm -rf "$RUN/res"; mkdir -p "$RUN/res"; : > "$out.tmp"
	jq -r '.[] | select(.supported==true and .outbound!=null) | [.server, (.outbound.type // "x"), (.port|tostring)] | @tsv' "$SERVERS" 2>/dev/null | sort -u > "$RUN/vpn_hosts.tsv"
	pids=""
	while IFS="$TAB" read -r host typ port; do
		[ -n "$host" ] && [ -n "$port" ] || continue
		proto=tcp; case "$typ" in hysteria2|hysteria|tuic|wireguard) proto=udp ;; esac
		if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
			echo "$host $proto $port" >> "$out.tmp"
		else
			( $to nslookup "$host" "$bs" 2>/dev/null | awk '/^Name:/{f=1;next} f&&/^Address/{print}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
				while read -r ip; do echo "$ip $proto $port"; done > "$RUN/res/$(printf '%s' "$host$port" | md5sum | cut -c1-12)" ) &
			pids="$pids $!"
			join_jobs
		fi
	done < "$RUN/vpn_hosts.tsv"
	join_all
	cat "$RUN"/res/* >> "$out.tmp" 2>/dev/null
	sort -u "$out.tmp" > "$out"; rm -rf "$out.tmp" "$RUN/res" "$RUN/vpn_hosts.tsv"
}

cmd_prepare() {
	local ver major minor secret out
	: > "$RUN/last_error"
	command -v sing-box >/dev/null 2>&1 || { set_error "Не установлен sing-box. Установите: opkg update && opkg install sing-box (или apk add sing-box)"; return 1; }
	ver="$(sb_version)"; major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
	if [ "${major:-0}" -lt 1 ] || { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -lt 12 ]; }; then
		set_error "Версия sing-box ($ver) слишком старая, нужна 1.12 или новее"; return 1
	fi
	[ -c /dev/net/tun ] || { modprobe tun 2>/dev/null; sleep 1; }
	[ -c /dev/net/tun ] || { set_error "Нет устройства /dev/net/tun. Установите: opkg install kmod-tun"; return 1; }
	secret="$(cat /proc/sys/kernel/random/uuid)"
	printf '%s' "$secret" > "$RUN/secret"; chmod 600 "$RUN/secret"
	if ! out="$(jq -n -L "$LIB" -f "$LIB/build.jq" --slurpfile servers "$SERVERS" --argjson s "$(effective_settings)" \
			--arg secret "$secret" --arg selected "$(cfg selected auto)" --arg logfile "$RUN/sing-box.log" 2>&1 > "$CONFIG.tmp")"; then
		set_error "$(echo "$out" | head -n3 | tr '\n' ' ')"; rm -f "$CONFIG.tmp"; return 1
	fi
	# Сначала проверяем временный файл и только потом заменяем рабочий: иначе
	# невалидный конфиг оставался бы на месте и ломал бы следующий запуск.
	if ! out="$(sing-box check -c "$CONFIG.tmp" 2>&1)"; then
		set_error "Конфиг не прошёл проверку: $(echo "$out" | head -n3 | tr '\n' ' ')"; rm -f "$CONFIG.tmp"; return 1
	fi
	mv "$CONFIG.tmp" "$CONFIG"; chmod 600 "$CONFIG"
	: > "$RUN/sing-box.log"
	rm -f "$RUN/up_since" "$RUN/ip.json"
	if cfgb bypass_vpn 1; then resolve_vpn_targets; else rm -f "$RUN/vpn_targets"; fi
	return 0
}

# connect — (пере)запустить службу и сразу сказать, получилось ли поднять sing-box.
# Готовность туннеля интерфейс узнаёт сам, опрашивая status.
cmd_connect() {
	local i=0
	rm -f "$RUN/discord.vpn_only"   # пользователь включил VPN сам — это уже полноценный VPN
	: > "$RUN/last_error"
	# Старый экземпляр должен освободить vless0 до старта нового. procd не ждёт
	# полного завершения, поэтому новый sing-box не мог создать туннель, подключение
	# падало с ошибкой, и приходилось нажимать кнопку второй раз.
	/etc/init.d/vless stop >/dev/null 2>&1
	i=0
	while [ $i -lt 10 ] && is_running; do sleep 1; i=$((i + 1)); done
	i=0
	while [ $i -lt 5 ] && ip link show "$TUN" >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
	/etc/init.d/vless start >/dev/null 2>&1
	i=0
	while [ $i -lt 20 ]; do
		is_running && break
		[ -s "$RUN/last_error" ] && break
		sleep 1; i=$((i + 1))
	done
	if ! is_running; then
		json_err "$(cat "$RUN/last_error" 2>/dev/null | grep . || echo 'Не удалось запустить sing-box. Смотрите вкладку «Журнал».')"
		return 1
	fi
	jq -n -c '{ok:true,starting:true}'
}

cmd_disconnect() {
	rm -f "$RUN/discord.vpn_only"
	/etc/init.d/vless stop >/dev/null 2>&1
	# Журнал прошлой сессии убираем в сторону и начинаем чистый. Иначе ошибки,
	# случившиеся во время работы, всплывают потом как «Ошибка подключения»
	# уже после того, как пользователь отключился штатно.
	if [ -s "$RUN/sing-box.log" ]; then
		tail -n 400 "$RUN/sing-box.log" > "$RUN/sing-box.prev.log" 2>/dev/null
	fi
	: > "$RUN/sing-box.log"
	rm -f "$RUN/up_since" "$RUN/ip.json"
	: > "$RUN/last_error"
	jq -n -c '{ok:true}'
}

rotate_log() { # если лог больше 5 МБ — обрезаем, оставляя последние 200 строк
	local f="$RUN/sing-box.log"
	[ -f "$f" ] || return 0
	local size
	size="$(wc -c < "$f" 2>/dev/null || echo 0)"
	[ "$size" -gt 5242880 ] 2>/dev/null || return 0
	tail -n 200 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

cmd_run() {
	rm -f "$RUN/up_since" "$RUN/ip.json"
	rotate_log
	# Если предыдущий net_up ещё работает от прошлого запуска — убиваем его
	local old_p; old_p="$(cat "$RUN/net_up.pid" 2>/dev/null)"
	# pid из файла мог устареть (ранний выход net_up его не стирает) и достаться чужому
	# процессу — убиваем, только если это действительно наш скрипт и не мы сами.
	if [ -n "$old_p" ] && [ "$old_p" != "$$" ] && kill -0 "$old_p" 2>/dev/null \
		&& tr '\0' ' ' < "/proc/$old_p/cmdline" 2>/dev/null | grep -q 'vless'; then
		kill -9 "$old_p" 2>/dev/null
	fi
	# net_up ждёт появления туннеля до 40 с, поэтому его pid запоминаем: иначе
	# «Отключить» в этот момент удалял бы ещё не созданные правила, а net_up затем
	# добавил бы их после остановки службы, уведя трафик в мёртвый туннель.
	( net_up ) >/dev/null 2>&1 &
	printf '%s\n' "$!" > "$RUN/net_up.pid"
	exec sing-box run -D "$RUN" -c "$CONFIG"
}
