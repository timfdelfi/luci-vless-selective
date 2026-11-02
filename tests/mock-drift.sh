#!/bin/sh
# Проверка, что рукописные заглушки (tests/mock/api/curl, tests/mock/uci) не разошлись с кодом:
# каждый запрос к Clash API и каждая подкоманда uci, которые использует бэкенд, должны быть в заглушке,
# а каждый маршрут заглушки — реально использоваться бэкендом. Нужен только sh, grep, sed (без jq).
#   sh tests/mock-drift.sh
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
SRC="root/usr/bin/vless root/usr/bin/vless-discord $(ls root/usr/share/vless/lib/*.sh | tr '\n' ' ')"
MOCK_CURL=tests/mock/api/curl
MOCK_UCI=tests/mock/uci

echo "== заглушки не разошлись с кодом"

# 1) маршруты Clash API: бэкенд -> заглушка
paths="$(grep -hoE "\bapi (GET|PUT|POST|DELETE|PATCH) [^ )|;\`]+" $SRC | awk '{print $3}' | tr -d "\"'" | sed 's/\$id/abc/g; s/\$PING_URL/u/g; s/\$[A-Za-z_]*/x/g' | sort -u)"
[ -n "$paths" ] || bad "не найдено ни одного вызова api в бэкенде (изменился формат?)"
for p in $paths; do
	out="$(sh "$MOCK_CURL" "http://127.0.0.1:9099$p")"
	if [ -z "$out" ] || [ "$out" = "{}" ]; then bad "заглушка curl не знает маршрут $p"; else ok "заглушка curl знает $p"; fi
done

# 2) маршруты заглушки -> бэкенд (кроме /group/: это защита от старой ошибки, в коде его быть не должно)
for seg in $(grep -oE '\*/[a-z]+' "$MOCK_CURL" | tr -d '*/' | sort -u); do
	[ "$seg" = group ] && continue
	printf '%s\n' "$paths" | grep -q "/$seg" || printf '%s\n' "$paths" | grep -q "$seg" \
		&& ok "маршрут /$seg из заглушки используется бэкендом" || bad "маршрут /$seg есть в заглушке, но бэкенд его не вызывает"
done

# 3) подкоманды uci: код -> заглушка
for c in $(grep -hoE "\buci( -q)? [a-z_]+" $SRC root/usr/libexec/rpcd/vless root/etc/init.d/vless root/etc/init.d/vless-discord | sed 's/ -q//' | awk '{print $2}' | sort -u); do
	grep -qE "^[[:space:]]*$c\)" "$MOCK_UCI" && ok "заглушка uci знает «$c»" || bad "заглушка uci не знает «$c»"
done

[ $fail -eq 0 ] && echo "заглушки актуальны" || echo "ЗАГЛУШКИ РАЗОШЛИСЬ С КОДОМ"
exit $fail
