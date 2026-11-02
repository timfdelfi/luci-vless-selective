# shellcheck shell=sh disable=SC2154
# vless / subscriptions.sh — подписки и серверы: add, remove, refresh, select, clear.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- подписки и серверы

# Постоянный идентификатор устройства (HWID): генерируется один раз и хранится на роутере.
# Панели с лимитом устройств считают по нему, поэтому он не должен меняться между обновлениями.
get_hwid() {
	local f="$DIR/hwid"
	# Создание идёт через временный файл с link(), иначе два параллельных вызова
	# (например, cmd_state без блокировки и скачивание подписки) оба увидели бы
	# пустой файл и записали разные HWID — панель увидела бы «новое устройство»
	# и лимит устройств у пользователя сбрасывался бы.
	if [ ! -s "$f" ]; then
		( umask 077; tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-16 > "$f.new" ) 2>/dev/null
		if [ -s "$f.new" ]; then
			[ -s "$f" ] || ln "$f.new" "$f" 2>/dev/null || mv "$f.new" "$f"
			rm -f "$f.new"
		fi
	fi
	cat "$f" 2>/dev/null
}

# sub_curl [аргументы curl] URL — curl с заголовками Happ для Android.
# Если пользователь задал свой User-Agent (не Happ), отправляется только он.
sub_curl() {
	local ua; ua="$(cfg user_agent "$VLESS_UA_DEFAULT")"
	case "$ua" in
		Happ/*|vless/*)
			curl -sSL -m 10 --connect-timeout 5 -A "$ua" \
				-H "X-Device-Os: Android" -H "X-Ver-Os: $VLESS_ANDROID_VER" \
				-H "X-Device-Model: $VLESS_DEVICE_MODEL" -H "X-Device-Locale: ru" \
				-H "X-Hwid: $(get_hwid)" "$@" ;;
		*)
			curl -sSL -m 10 --connect-timeout 5 -A "$ua" "$@" ;;
	esac
}

# fetch_url URL OUT HEADERS
fetch_url() {
	sub_curl -D "$3" -o "$2" "$1" 2>"$RUN/curl.err" && [ -s "$2" ] && return 0
	if is_ready; then
		sub_curl -m 8 -x "socks5h://127.0.0.1:$MIXED_PORT" -D "$3" -o "$2" "$1" 2>"$RUN/curl.err" && [ -s "$2" ] && return 0
	fi
	return 1
}

# is_stub — в только что разобранной подписке лежит заглушка вида
# «Ваш клиент VPN не поддерживается» (панель не узнала приложение)
is_stub() {
	[ "$1" -le 2 ] || return 1
	jq -r '.name // empty' "$RUN/new.jsonl" 2>/dev/null | tr 'A-Z' 'a-z' |
		grep -qE 'не поддерж|не подде|unsupported|not supported|update (your )?(app|client)|обновите|устарел'
}

# base64 без регулярных выражений: на многих роутерах jq собран без Oniguruma.
# Замена через split/join, а не explode: explode разворачивал подписку в массив из
# миллиона чисел, и на роутере с 64 МБ jq уходил в OOM на большой подписке.
b64dec() {
	jq -R -s -r 'split("\n") | join("") | split("\r") | join("")
		| split(" ") | join("") | split("\t") | join("")
		| split("-") | join("+") | split("_") | join("/")
		| split("=") | join("")
		| . + ("===="[0: ((4 - (length % 4)) % 4)]) | @base64d' 2>>"$RUN/parse.err"
}

# parse_err — последняя ошибка разбора (для сообщения пользователю)
parse_err() { grep -v 'base64' "$RUN/parse.err" 2>/dev/null | head -c 200 | tr '\n' ' '; }

# формат_body FILE -> json|links — по первому значащему символу
body_format() {
	case "$(head -c 400 "$1" | tr -d ' \t\r\n' | head -c 1)" in
		'[' | '{') echo json ;;
		*)        echo links ;;
	esac
}

# body_to_tsv FILE  -> TSV (ключ \t json) на stdout
body_to_tsv() {
	local fmt
	: > "$RUN/parse.err"
	if [ ! -s "$LIB/parse.jq" ]; then
		echo "нет файла $LIB/parse.jq (переустановите приложение)" >> "$RUN/parse.err"; return 1
	fi
	fmt="$(body_format "$1")"
	if [ "$fmt" = json ]; then
		jq -n -r --arg mode json -f "$LIB/parse.jq" < "$1" 2>>"$RUN/parse.err"
		return
	fi
	if grep -q '://' "$1"; then
		jq -R -n -r --arg mode links -f "$LIB/parse.jq" < "$1" 2>>"$RUN/parse.err"
		return
	fi
	# base64: внутри может быть и список ссылок, и JSON-конфиг Xray —
	# формат определяем уже по РАСШИФРОВАННОМУ тексту, иначе такой подписки
	# не распознать и пользователь получит «серверов не найдено».
	b64dec < "$1" > "$1.dec"
	fmt="$(body_format "$1.dec")"
	if [ "$fmt" = json ]; then
		jq -n -r --arg mode json -f "$LIB/parse.jq" < "$1.dec" 2>>"$RUN/parse.err"
	else
		jq -R -n -r --arg mode links -f "$LIB/parse.jq" < "$1.dec" 2>>"$RUN/parse.err"
	fi
	rm -f "$1.dec"
}

# ingest SOURCE_ID < TSV  -> $RUN/new.jsonl, печатает количество
ingest() {
	local id key rest n=0
	: > "$RUN/new.jsonl"
	while IFS="$TAB" read -r key rest; do
		[ -n "$rest" ] || continue
		id="$(printf '%s%s' "$1" "$key" | md5sum | cut -c1-8)"
		printf '{"id":"%s","source":"%s",%s\n' "$id" "$1" "${rest#\{}" >> "$RUN/new.jsonl"
		n=$((n + 1))
	done
	echo "$n"
}

merge_servers() { # merge_servers SRC MODE(replace|append)  — удалённые пользователем серверы не возвращаются
	local flt='map(select(.id as $i | ($hid | map(.id) | index($i)) | not))'
	# Дедупликация БЕЗ сортировки: unique_by() переставлял бы весь список,
	# потому что id — это md5, и сервера «прыгали» бы при каждом обновлении.
	local ud='def ud: reduce .[] as $x ([]; if any(.[]; .id == $x.id) then . else . + [$x] end); '
	if [ "$2" = "replace" ]; then
		atomic_run "$SERVERS" jq -c -s --arg src "$1" --slurpfile h "$HIDDEN" "$ud"'($h[0] // []) as $hid | ((.[0] | map(select(.source != $src))) + (.[1:] | ud)) | '"$flt" "$SERVERS" "$RUN/new.jsonl"
	else
		atomic_run "$SERVERS" jq -c -s --slurpfile h "$HIDDEN" "$ud"'($h[0] // []) as $hid | ((.[0] + .[1:]) | ud) | '"$flt" "$SERVERS" "$RUN/new.jsonl"
	fi
}

upsert_source() { # upsert_source JSON
	atomic_run "$SOURCES" jq -c --argjson o "$1" 'map(select(.id != $o.id)) + [$o]' "$SOURCES"
}

hdr() { # hdr FILE NAME
	grep -i "^$2:" "$1" 2>/dev/null | tail -n1 | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

add_sub() { # add_sub URL
	local url="$1" sid body hf title info n now
	sid="$(printf '%s' "$url" | md5sum | cut -c1-8)"
	body="$RUN/sub.body"; hf="$RUN/sub.hdr"
	if ! fetch_url "$url" "$body" "$hf"; then
		json_err "Не удалось скачать подписку. $(tr -d '\n' < "$RUN/curl.err" 2>/dev/null | sed -E 's#https?://[^ ]*#<ссылка>#g' | cut -c1-160)"
		rm -f "$body" "$hf"
		return 1
	fi
	n="$(body_to_tsv "$body" | ingest "$sid")"
	if [ "$n" -gt 0 ] && is_stub "$n"; then
		json_err "Панель подписки не признала клиент и вернула заглушку «не поддерживается». Проверьте User-Agent в «Настройки → DNS и сеть» (должен быть вида Happ/3.13.0) или лимит устройств в подписке (HWID роутера: $(get_hwid))."
		rm -f "$body" "$hf" "$RUN/new.jsonl"
		return 1
	fi
	if [ "$n" -eq 0 ]; then
		json_err "Подписка загружена, но в ней не найдено серверов. Проверьте ссылку.$(pe="$(parse_err)"; [ -n "$pe" ] && echo " Ошибка разбора: $pe")"
		return 1
	fi
	merge_servers "$sid" replace

	title="$(hdr "$hf" profile-title)"
	case "$title" in base64:*) title="$(printf '%s' "${title#base64:}" | b64dec)" ;; esac
	[ -n "$title" ] || title="$(printf '%s' "$url" | sed -E 's#^https?://([^/:]+).*#\1#')"
	info="$(hdr "$hf" subscription-userinfo)"
	now="$(date +%s)"

	upsert_source "$(jq -n -c --arg id "$sid" --arg url "$url" --arg name "$title" --arg info "$info" \
		--arg support "$(hdr "$hf" support-url)" --arg page "$(hdr "$hf" profile-web-page-url)" --argjson now "$now" --argjson n "$n" '
		def kv($k): ($info | split(";") | map(split("=") | { key: (.[0] | ltrimstr(" ")), value: (.[1] // "") })
			| map(select(.key == $k)) | (.[0].value // "") | (tonumber? // null));
		{ id:$id, kind:"sub", url:$url, name:$name, updated:$now, count:$n,
		  upload:(try kv("upload") catch null), download:(try kv("download") catch null),
		  total:(try kv("total") catch null), expire:(try kv("expire") catch null),
		  support:(if ($support|length)>0 then $support else null end), page:(if ($page|length)>0 then $page else null end) }')"
	rm -f "$body" "$hf"
	jq -n -c --arg id "$sid" --arg name "$title" --argjson n "$n" '{ok:true,kind:"sub",source:$id,name:$name,added:$n}'
}

add_links() { # add_links TEXT
	local text="$1" n total
	printf '%s\n' "$text" > "$RUN/links.in"
	if ! grep -q '://' "$RUN/links.in"; then
		b64dec < "$RUN/links.in" > "$RUN/links.dec" 2>/dev/null && mv "$RUN/links.dec" "$RUN/links.in"
	fi
	n="$(body_to_tsv "$RUN/links.in" | ingest manual)"
	rm -f "$RUN/links.in"
	if [ "$n" -eq 0 ]; then
		json_err "Не удалось распознать ссылку. Поддерживаются vless://, vmess://, trojan://, ss://, hysteria2:// и адреса подписок (https://…).$(pe="$(parse_err)"; [ -n "$pe" ] && echo " Ошибка разбора: $pe")"
		return 1
	fi
	merge_servers manual append
	total="$(jq '[.[]|select(.source=="manual")]|length' "$SERVERS")"
	upsert_source "$(jq -n -c --argjson n "$total" --argjson now "$(date +%s)" '{id:"manual",kind:"manual",name:"Мои ключи",updated:$now,count:$n}')"
	jq -n -c --argjson n "$n" '{ok:true,kind:"manual",source:"manual",name:"Мои ключи",added:$n}'
}

restart_if_running() {
	if is_running; then /etc/init.d/vless restart >/dev/null 2>&1; fi
}

# unwrap_link — ссылки-«обёртки» приложений (vless://add/URL, clash://install-config?url=URL …)
unwrap_link() {
	local u
	case "$1" in
		vless://add/http*|vless://import/http*) printf '%s' "${1#vless://*/}" ;;
		clash://install-config?url=*|sing-box://import-remote-profile?url=*)
			u="${1#*url=}"; u="${u%%&*}"
			printf '%s' "$u" | sed 's/%3A/:/Ig;s/%2F/\//Ig;s/%3F/?/Ig;s/%3D/=/Ig;s/%26/\&/Ig' ;;
		*) printf '%s' "$1" ;;
	esac
}

cmd_add() {
	local text res
	# Текст можно передать аргументом (как раньше, для ручной отладки) или через stdin.
	# rpcd-плагин передаёт именно через stdin: argv виден всем локальным пользователям
	# в /proc/*/cmdline, а там — полные ключи и токены подписок.
	if [ -n "$1" ]; then
		text="$(printf '%s' "$1" | tr -d '\r')"
	else
		text="$(cat | tr -d '\r')"
	fi
	text="$(printf '%s' "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	# Ссылку-«обёртку» распаковываем только если вставлена ровно одна строка.
	# Проверяем через wc, а не шаблон case с переводом строки: результат command
	# substitution всегда обрезает хвостовые переводы строк, и такой шаблон
	# превратился бы в пустой — то есть совпал бы с любой строкой.
	if [ "$(printf '%s\n' "$text" | wc -l)" -eq 1 ]; then
		text="$(unwrap_link "$text")"
	fi
	[ -n "$text" ] || { json_err "Вставьте ссылку"; return 1; }
	if printf '%s' "$text" | grep -qE '^https?://[^[:space:]]+$'; then
		res="$(add_sub "$text")"
	else
		res="$(add_links "$text")"
	fi
	echo "$res"
	if [ "$(printf '%s\n' "$res" | jq -r '.ok')" = "true" ]; then
		restart_if_running
	fi
}

cmd_refresh() { # refresh [ID]
	local ids id url res ok=0 fail=0 before after last=""
	before="$(md5sum < "$SERVERS")"
	if [ -n "$1" ] && [ "$1" != "all" ]; then
		# id проверяем и не разворачиваем: без кавычек значение превращалось
		# в список файлов и в несколько id через пробелы.
		echo "$1" | grep -qE '^[0-9a-z]{4,8}$' || { json_err "Некорректный id"; return 1; }
		ids="$1"
	else
		ids="$(jq -r '.[]|select(.kind=="sub")|.id' "$SOURCES")"
	fi
	# for, а не printf | while: конвейер выполняет цикл в подоболочке, и счётчики ok/fail
	# терялись бы (refresh всегда сообщал 0 обновлённых и ok:true даже при ошибках).
	# id — md5 без пробелов, поэтому разбиение по словам безопасно.
	for id in $ids; do
		url="$(jq -r --arg id "$id" '.[]|select(.id==$id and .kind=="sub")|.url' "$SOURCES")"
		[ -n "$url" ] || continue
		res="$(add_sub "$url")"
		if [ "$(printf '%s\n' "$res" | jq -r '.ok')" = "true" ]; then ok=$((ok + 1)); else fail=$((fail + 1)); last="$(printf '%s\n' "$res" | jq -r '.error')"; fi
	done
	after="$(md5sum < "$SERVERS")"
	# выбранный сервер мог исчезнуть
	local sel; sel="$(cfg selected auto)"
	if [ "$sel" != "auto" ] && [ "$(jq --arg s "$sel" '[.[]|select(.id==$s)]|length' "$SERVERS")" = "0" ]; then
		uci set vless.main.selected=auto; uci commit vless
	fi
	[ "$before" != "$after" ] && restart_if_running
	jq -n -c --argjson ok "$ok" --argjson fail "$fail" --arg e "${last:-}" '{ok:($fail==0),updated:$ok,failed:$fail,error:$e}'
}

# Обновление по cron: наружу не отдаём ничего, но неудачу пишем в системный журнал.
# Раньше ошибка просто терялась вместе с stdout, и сломанная подписка выглядела
# как «давно не обновлялось» без всяких признаков.
cmd_update_all() {
	local r
	r="$(cmd_refresh all)"
	[ "$(printf '%s' "$r" | jq -r '.ok')" = "true" ] && return 0
	logger -t vless "автообновление: не удалось обновить $(
		printf '%s' "$r" | jq -r '.failed' 2>/dev/null) подписок(и). $(
		printf '%s' "$r" | jq -r '.error' 2>/dev/null | cut -c1-160)" 2>/dev/null
	return 0
}

remove_rollback() {
	local tx="$1" f failed=0
	for f in servers sources hidden; do
		cp -p "$tx/$f" "$DIR/$f.json.rollback.$$" &&
			mv "$DIR/$f.json.rollback.$$" "$DIR/$f.json" || failed=1
	done
	rm -rf "$tx"
	if [ "$failed" = 1 ]; then
		logger -t vless "ошибка: не удалось полностью отменить удаление серверов" 2>/dev/null
		return 1
	fi
	return 0
}

remove_abort() {
	local tx="$1" message="$2"
	remove_rollback "$tx" || message="$message (не удалось полностью восстановить базу — проверьте файлы в $DIR)"
	json_err "$message"
	return 1
}

cmd_remove() { # remove ID (источник или одиночный сервер)
	local id="$1" sel tx="$RUN/remove.$$" ssrc f source_count server_count
	echo "$id" | grep -qE '^[0-9a-z]{4,8}$' || { json_err "Некорректный id"; return 1; }
	source_count="$(jq --arg id "$id" '[.[]|select(.id==$id)]|length' "$SOURCES")" ||
		{ json_err "Не удалось прочитать список подписок"; return 1; }
	server_count="$(jq --arg id "$id" '[.[]|select(.id==$id)]|length' "$SERVERS")" ||
		{ json_err "Не удалось прочитать список серверов"; return 1; }
	[ "$source_count" != "0" ] || [ "$server_count" != "0" ] ||
		{ json_err "Сервер или подписка не найдены"; return 1; }
	mkdir "$tx" 2>/dev/null || { json_err "Не удалось подготовить удаление"; return 1; }
	for f in servers sources hidden; do
		cp -p "$DIR/$f.json" "$tx/$f" 2>/dev/null || {
			rm -rf "$tx"
			json_err "Не удалось подготовить резервную копию базы серверов"
			return 1
		}
	done
	if [ "$source_count" != "0" ]; then
		atomic_run "$SOURCES" jq -c --arg id "$id" 'map(select(.id != $id))' "$SOURCES" ||
			{ remove_abort "$tx" "Не удалось сохранить список подписок"; return 1; }
		atomic_run "$SERVERS" jq -c --arg id "$id" 'map(select(.source != $id))' "$SERVERS" ||
			{ remove_abort "$tx" "Не удалось сохранить список серверов"; return 1; }
		# вместе с подпиской забываем и список удалённых из неё серверов
		atomic_run "$HIDDEN" jq -c --arg id "$id" 'map(select(.source != $id))' "$HIDDEN" ||
			{ remove_abort "$tx" "Не удалось сохранить список исключённых серверов"; return 1; }
	else
		# удалённый сервер подписки запоминаем, чтобы он не вернулся при обновлении
		ssrc="$(jq -r --arg id "$id" '[.[]|select(.id==$id)][0].source // empty' "$SERVERS")" ||
			{ remove_abort "$tx" "Не удалось прочитать источник сервера"; return 1; }
		if [ -n "$ssrc" ] && [ "$ssrc" != "manual" ]; then
			atomic_run "$HIDDEN" jq -c --arg id "$id" --arg src "$ssrc" '(map(select(.id != $id)) + [{id:$id,source:$src}])' "$HIDDEN" ||
				{ remove_abort "$tx" "Не удалось сохранить список исключённых серверов"; return 1; }
		fi
		atomic_run "$SERVERS" jq -c --arg id "$id" 'map(select(.id != $id))' "$SERVERS" ||
			{ remove_abort "$tx" "Не удалось сохранить список серверов"; return 1; }
		# обновить счётчик «Мои ключи»
		atomic_run "$SOURCES" jq -c --argjson n "$(jq '[.[]|select(.source=="manual")]|length' "$SERVERS")" \
			'map(if .id=="manual" then .count=$n else . end) | map(select(.id!="manual" or .count>0))' "$SOURCES" ||
			{ remove_abort "$tx" "Не удалось обновить список источников"; return 1; }
	fi
	rm -rf "$tx"
	sel="$(cfg selected auto)"
	if [ "$sel" != "auto" ] && [ "$(jq --arg s "$sel" '[.[]|select(.id==$s)]|length' "$SERVERS")" = "0" ]; then
		uci set vless.main.selected=auto; uci commit vless
	fi
	if [ "$(jq 'length' "$SERVERS")" = "0" ] && is_running; then
		/etc/init.d/vless stop >/dev/null 2>&1
	else
		restart_if_running
	fi
	jq -n -c '{ok:true}'
}

cmd_clear() {
	atomic_text "$SERVERS" '[]'; atomic_text "$SOURCES" '[]'; atomic_text "$HIDDEN" '[]'
	uci set vless.main.selected=auto; uci commit vless
	is_running && /etc/init.d/vless stop >/dev/null 2>&1
	jq -n -c '{ok:true}'
}

cmd_select() { # select ID|auto
	local id="$1"
	echo "$id" | grep -qE '^(auto|[0-9a-f]{8})$' || { json_err "Некорректный id"; return 1; }
	uci set vless.main.selected="$id"; uci commit vless
	if is_ready; then
		if [ "$id" = "auto" ]; then api PUT /proxies/proxy '{"name":"auto"}' >/dev/null
		else api PUT /proxies/proxy "{\"name\":\"s-$id\"}" >/dev/null; fi
		rm -f "$RUN/ip.json"
	fi
	jq -n -c --arg id "$id" '{ok:true,selected:$id}'
}
