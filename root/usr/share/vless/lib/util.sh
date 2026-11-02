# shellcheck shell=sh disable=SC2154
# vless / util.sh — общие утилиты: cfg, api, атомарная запись, фоновые задачи, блокировка.
# Подключается из /usr/bin/vless (общие переменные и функции живут там и в других модулях); отдельно не запускается.

# ---------------------------------------------------------------- утилиты

cfg()  { local v; v="$(uci -q get vless.main."$1" 2>/dev/null)"; [ -n "$v" ] && echo "$v" || echo "$2"; }
cfgb() { [ "$(cfg "$1" "$2")" = "1" ]; }
# Kill Switch включён, если в UCI kill_switch=1 (по умолчанию выключен)
kill_switch_on() { cfgb kill_switch 0; }

json_err() { jq -n -c --arg e "$1" '{ok:false,error:$e}'; }

set_error() { printf '%s' "$1" > "$RUN/last_error"; }

pid_alive() {
	local p
	[ -f "$PIDFILE" ] || return 1
	p="$(cat "$PIDFILE" 2>/dev/null)"
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
is_running() { pid_alive; }
is_ready()   { is_running && [ -f "$RUN/up_since" ]; }

sb_version() { sing-box version 2>/dev/null | head -n1 | awk '{print $3}'; }

api() {
	# api METHOD PATH [BODY]
	# Секрет идёт в curl через stdin (-K -), а не через argv: иначе он виден в /proc/*/cmdline.
	local sec; sec="$(cat "$RUN/secret" 2>/dev/null)"
	if [ -n "$3" ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$sec" | curl -s -m "${T:-4}" -K - -X "$1" -H 'Content-Type: application/json' -d "$3" "http://127.0.0.1:$API_PORT$2"
	else
		printf 'header = "Authorization: Bearer %s"\n' "$sec" | curl -s -m "${T:-4}" -K - -X "$1" "http://127.0.0.1:$API_PORT$2"
	fi
}


# Записать вывод команды в FILE атомарно и только при успешном коде возврата.
# Важно: НЕ «jq … | write_atomic» — в конвейере доступен код возврата только
# последней команды (cat), и упавший jq молча затирал бы базу пустым файлом.
atomic_run() { # atomic_run FILE КОМАНДА [АРГУМЕНТЫ…]
	local f="$1"; shift
	( umask 077; "$@" > "$f.tmp" ) || { rm -f "$f.tmp"; return 1; }
	mv "$f.tmp" "$f"
}

atomic_text() { # atomic_text FILE ТЕКСТ
	local f="$1" t="$2"
	( umask 077; printf '%s' "$t" > "$f.tmp" ) || { rm -f "$f.tmp"; return 1; }
	mv "$f.tmp" "$f"
}

# Ограничение числа одновременно запущенных дочерних процессов: подписка на
# сотни серверов иначе поднимает тысячи процессов и роутер с 64 МБ уходит в OOM.
JOBS_MAX="${VLESS_JOBS_MAX:-8}"
pids=""

# join_jobs — дождаться фоновых задач, если их уже больше JOBS_MAX, и обнулить список.
# Вызывающий код накапливает pid'ы в $pids.
join_jobs() {
	[ "$(printf '%s' "$pids" | wc -w)" -gt "$JOBS_MAX" ] || return 0
	local p
	for p in $pids; do wait "$p" 2>/dev/null; done
	pids=""
}

# join_all — дождаться всех накопленных фоновых задач.
join_all() {
	local p
	for p in $pids; do wait "$p" 2>/dev/null; done
	pids=""
}

# Блокировка: команды, меняющие серверы/настройки, не должны выполняться одновременно
# (например, автообновление по cron и «Добавить» из веб-интерфейса).
LOCKDIR="$RUN/lock"
lock() {
	local i=0 p
	while ! mkdir "$LOCKDIR" 2>/dev/null; do
		p="$(cat "$LOCKDIR/pid" 2>/dev/null)"
		if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$LOCKDIR"; continue; fi
		i=$((i + 1)); [ $i -gt 100 ] && return 1
		sleep 1
	done
	echo $$ > "$LOCKDIR/pid"
}
unlock() { rm -rf "$LOCKDIR"; }
locked() { # locked КОМАНДА [АРГУМЕНТЫ…]
	lock || { json_err "Занято: выполняется другая операция. Повторите через минуту."; return 1; }
	trap unlock EXIT
	"$@"
}
