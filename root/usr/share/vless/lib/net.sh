# shellcheck shell=sh disable=SC2154
# vless / net.sh — сеть: net_up/net_down, ip rule, nft, DNS (dnsmasq).
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# net_up_running — идёт ли ещё настройка сети; net_down обязан дождаться её.
net_up_running() {
	local p
	p="$(cat "$RUN/net_up.pid" 2>/dev/null)"
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

RULE_PREFS="$RUN/rule.prefs"

# note_pref — запомнить pref только что добавленного правила.
# Удалять будем ровно свои правила: срез «весь диапазон 9000–9199» сносил чужие
# правила других пакетов (mwan3, второй VPN и т.п.).
note_pref() { printf '%s\n' "$1" >> "$RULE_PREFS"; }

del_rules() { # del_rules [-6]
	# Свои правила: записанные pref + всё, что однозначно наше (наша таблица 100,
	# наш интерфейс vless0, наше unreachable-правило для IPv6).
	local p
	[ -f "$RULE_PREFS" ] || : > "$RULE_PREFS"
	for p in $(cat "$RULE_PREFS"; ip $1 rule show 2>/dev/null | awk -F: -v tbl "$TABLE" -v tun "$TUN" '
		$1+0>=9000 && $1+0<9200 && (index($0, "lookup " tbl) || index($0, tun) || (index($0, "unreachable") && index($0, "iif")))
		{print $1+0}' | sort -un); do
		while ip $1 rule del pref "$p" 2>/dev/null; do :; done
	done
	: > "$RULE_PREFS"
}

dnsmasq_dir() {
	# Настоящий каталог из dnsmasq.init: /tmp/dnsmasq${cfg:+.$cfg}.d, где cfg — имя секции.
	# У секции без имени cfg пуст, поэтому каталог называется просто /tmp/dnsmasq.d:
	# его не покрывает шаблон /tmp/dnsmasq.*.d (там обязателен непустой средний сегмент),
	# и не покрывает имя секции вида @dnsmasq[0].
	# Если несколько секций dnsmasq — берём первую, у которой есть каталог.
	local name d names
	names="$(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^=]*\)=dnsmasq$/\1/p')"
	for name in $names; do
		d="/tmp/dnsmasq${name:+.$name}.d"
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	[ -d /tmp/dnsmasq.d ] && { echo /tmp/dnsmasq.d; return 0; }
	# секцию могли переименовать — берём любой существующий каталог dnsmasq
	for d in /tmp/dnsmasq*.d; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	return 0
}

net_fail() { # net_fail СООБЩЕНИЕ — запомнить причину и остановить сервис (без перезапусков procd)
	set_error "$1"
	( /etc/init.d/vless stop >/dev/null 2>&1 & )
	exit 1
}

net_up() {
	local i=0 n p net st addr mask dev ip ifs
	# Пока идёт настройка, служба уже может быть остановлена — тогда продолжать нельзя,
	# иначе правила появятся после net_down.
	while [ $i -lt 40 ]; do
		net_up_running || return 0
		ip link show "$TUN" >/dev/null 2>&1 && break
		pid_alive || [ $i -lt 3 ] || return 0
		sleep 1; i=$((i + 1))
	done
	if ! ip link show "$TUN" >/dev/null 2>&1; then
		net_fail "Интерфейс $TUN не появился: $(grep -iE 'fatal|error' "$RUN/sing-box.log" 2>/dev/null | tail -n1 | cut -c1-200)"
	fi

	del_rules; del_rules -6
	ip route flush table $TABLE 2>/dev/null
	selective_down
	ip link set "$TUN" up
	# ответы приходят из туннеля с чужими адресами — строгий rp_filter их бы отбросил
	# на некоторых ядрах/контейнерах запись может не разрешаться — игнорируем ошибку
	sysctl -qw "net.ipv4.conf.$TUN.rp_filter=2" >/dev/null 2>&1 || true
	ip route replace default dev "$TUN" table $TABLE metric 100 || net_fail "Не удалось создать маршрут через $TUN (пакет ip-full установлен?)"
	kill_switch_on && ip route replace blackhole default table $TABLE metric 4096

	# локальные и служебные сети всегда идут мимо туннеля
	p=9000
	for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 224.0.0.0/4; do
		ip rule add to "$net" lookup main pref $p 2>/dev/null && note_pref $p
		p=$((p + 1))
	done

	# выборочный режим: метим только пакеты к адресам набора vpn4; при неудаче — обычный режим
	local sel=0
	if [ "$(eff scope)" = selected ]; then
		if selective_up; then
			sel=1
			ip rule add fwmark $SEL_MARK lookup $TABLE pref 9100 2>/dev/null && note_pref 9100
		elif [ -f "$RUN/discord.vpn_only" ]; then
			# Без выборочного режима «VPN только для Discord» превратился бы в VPN для всего.
			net_fail "Для запасного пути Discord через VPN нужен dnsmasq-full (поддержка nftset)"
		fi
	fi

	ifs="$(uci -q get vless.main.ifaces 2>/dev/null)"; [ -n "$ifs" ] || ifs="lan"
	local subnets="" devs=""
	for n in $ifs; do
		st="$(ubus call "network.interface.$n" status 2>/dev/null)" || continue
		addr="$(printf '%s\n' "$st" | jsonfilter -q -e '@["ipv4-address"][0].address')"
		mask="$(printf '%s\n' "$st" | jsonfilter -q -e '@["ipv4-address"][0].mask')"
		dev="$(printf '%s\n' "$st" | jsonfilter -q -e '@.l3_device')"
		[ -n "$addr" ] && [ -n "$mask" ] && subnets="$subnets $addr/$mask"
		[ -n "$dev" ] && devs="$devs $dev"
	done
	for net in $subnets; do ip rule add to "$net" lookup main pref 9020 2>/dev/null && note_pref 9020; done

	# Если ни один интерфейс не разрешился, то ни одного ip rule не будет: трафик уйдёт мимо
	# туннеля, а блокировка IPv6 (цикл ниже по $devs) не применится. Молчать здесь нельзя —
	# снаружи это выглядит как «подключилось, а VPN не работает».
	if [ -z "$subnets" ]; then
		logger -t vless "не удалось получить адреса интерфейсов: $ifs" 2>/dev/null
		net_fail "Не найдены адреса интерфейсов ($ifs). Проверьте «Интерфейсы» в настройках — обычно это lan."
	fi
	[ -n "$devs" ] || logger -t vless "не найден l3_device интерфейсов ($ifs) — IPv6 может утекать мимо VPN" 2>/dev/null

	# VPN-серверы подписки — мимо туннеля (VPN-клиенты на телефонах и компьютерах в сети)
	if cfgb bypass_vpn 1 && [ -s "$RUN/vpn_targets" ]; then
		local tp tport
		while read -r ip tp tport; do
			[ -n "$ip" ] && [ -n "$tport" ] || continue
			# BusyBox ip не умеет ipproto/dport, поэтому первый вариант обычно не проходит:
			# тогда весь трафик к IP VPN-сервера идёт мимо туннеля (а не только его трафик).
			ip rule add to "$ip" ipproto "$tp" dport "$tport" lookup main pref 9030 2>/dev/null ||
				ip rule add to "$ip" lookup main pref 9030 2>/dev/null
			note_pref 9030
		done < "$RUN/vpn_targets"
	fi

	if [ "$sel" = 0 ]; then
	case "$(cfg mode all)" in
		include)
			for ip in $(uci -q get vless.main.devices 2>/dev/null); do
				valid_cidr "$ip" && { ip rule add from "$ip" lookup $TABLE pref 9100 2>/dev/null && note_pref 9100; }
			done ;;
		exclude)
			for ip in $(uci -q get vless.main.devices 2>/dev/null); do
				valid_cidr "$ip" && { ip rule add from "$ip" lookup main pref 9050 2>/dev/null && note_pref 9050; }
			done
			for net in $subnets; do ip rule add from "$net" lookup $TABLE pref 9100 2>/dev/null && note_pref 9100; done ;;
		*)
			for net in $subnets; do ip rule add from "$net" lookup $TABLE pref 9100 2>/dev/null && note_pref 9100; done ;;
	esac
	fi

	# IPv6 в туннель не отправляем — закрываем во всех режимах, иначе он утечёт мимо VPN.
	# Ошибка здесь означает утечку IPv6, поэтому подтверждаем успех явно.
	if cfgb block_ipv6 1; then
		local v6ok=1
		for dev in $devs; do
			for net in fe80::/10 fc00::/7 ff00::/8; do
				ip -6 rule add iif "$dev" to "$net" lookup main pref 9090 2>/dev/null && note_pref 9090
			done
			if ip -6 rule add iif "$dev" unreachable pref 9100 2>/dev/null; then note_pref 9100; else v6ok=0; fi
		done
		[ "$v6ok" = 1 ] || logger -t vless "не удалось заблокировать IPv6 (нужен пакет ip-full): трафик IPv6 может идти мимо VPN" 2>/dev/null
	fi

	# DNS: dnsmasq спрашивает sing-box (через VPN); в выборочном режиме он же заполняет набор адресов
	local d; d="$(dnsmasq_dir)"
	if [ -n "$d" ]; then
		{
			if [ "$(cfg dns_mode vpn)" = "vpn" ]; then
				echo "server=$DNS_LISTEN"; echo "strict-order"; if kill_switch_on; then echo "no-resolv"; fi
			fi
			[ -s "$RUN/nftset.conf" ] && cat "$RUN/nftset.conf"
		} > "$d/vless.conf"
		chmod 644 "$d/vless.conf"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	else
		# Раньше этот случай проходил молча: VPN показывался подключённым, но DNS уходил
		# мимо туннеля, а набор адресов выборочного режима оставался пустым.
		logger -t vless "не найден каталог конфигурации dnsmasq: DNS через VPN и выборочная маршрутизация не настроены (проверьте, запущен ли dnsmasq)" 2>/dev/null
	fi
	date +%s > "$RUN/up_since"
	rm -f "$RUN/net_up.pid"
}

net_down() {
	local d f i=0 p
	# Дождаться, пока net_up закончит: иначе он добавит правила уже после их удаления.
	while net_up_running && [ $i -lt 45 ]; do sleep 1; i=$((i + 1)); done
	# Если net_up завис — убиваем принудительно, иначе stop висит вечно
	p="$(cat "$RUN/net_up.pid" 2>/dev/null)"
	if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
		kill -KILL "$p" 2>/dev/null
		logger -t vless "net_up завис (pid $p), убит принудительно" 2>/dev/null
	fi
	rm -f "$RUN/net_up.pid"
	del_rules; del_rules -6
	ip route flush table $TABLE 2>/dev/null
	selective_down
	d="$(dnsmasq_dir)"
	if [ -n "$d" ] && [ -f "$d/vless.conf" ]; then
		rm -f "$d/vless.conf"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi
	rm -f "$RUN/up_since" "$RUN/ip.json"
}
