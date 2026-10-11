#!/bin/sh
# Проверка jq-скриптов: компилируемость и отсутствие регулярных выражений.
#   sh ci/check-jq.sh
# Регулярные выражения — отдельная причина: на роутерах jq часто собран без
# Oniguruma, и test/match/capture молча возвращают пустой результат, а панель
# показывает «серверов не найдено». Поэтому используются только split/explode.
set -e
cd "$(dirname "$0")/.." || exit 1
L=root/usr/share/vless
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo '[]' > "$TMP/servers.json"

fail=0
compile() { # compile ОПИСАНИЕ КОМАНДА...
	desc="$1"; shift
	err="$("$@" 2>&1 >/dev/null || true)"
	case "$err" in
		*"compile error"*|*"syntax error"*)
			printf '  FAIL %s\n' "$desc"
			printf '%s\n' "$err" | head -n3 | sed 's/^/       /'
			fail=1 ;;
		*) printf '  ok   %s\n' "$desc" ;;
	esac
}

compile "parse.jq компилируется" \
	jq -n -L "$L" -f "$L/parse.jq" --arg mode links
compile "build.jq компилируется" \
	jq -n -L "$L" -f "$L/build.jq" --slurpfile servers "$TMP/servers.json" \
		--argjson s '{}' --arg secret x --arg selected auto --arg logfile /tmp/v.log
# presets.jq состоит только из определений, поэтому проверяем его через include:
# заодно это подтверждает, что build.jq его находит по -L.
compile "presets.jq компилируется и находится через include" \
	jq -n -L "$L" 'include "presets"; .'

for f in "$L"/*.jq; do
	if grep -nE '(^|[^_a-zA-Z])(test|match|capture|gsub|splits|scan|scanl)[[:space:]]*\(' "$f" \
		| grep -v '^[[:space:]]*#' | grep -q .; then
		printf '  FAIL %s: регулярные выражения не поддержаны jq без Oniguruma\n' "$f"
		fail=1
	else
		printf '  ok   %s: без регулярных выражений\n' "$f"
	fi
done

[ "$fail" = 0 ] || { echo "ЕСТЬ ОШИБКИ"; exit 1; }
echo "JQ-СКРИПТЫ В ПОРЯДКЕ"