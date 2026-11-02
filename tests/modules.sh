#!/bin/sh
# Статическая проверка разбиения бэкенда на модули (без jq и sing-box).
#   sh tests/modules.sh
cd "$(dirname "$0")/.." || exit 1
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
MAIN=root/usr/bin/vless
LIBDIR=root/usr/share/vless/lib

echo "== модули бэкенда"
listed="$(sed -n 's/^VLESS_MODULES="\(.*\)"/\1/p' "$MAIN")"
[ -n "$listed" ] || bad "в $MAIN нет списка VLESS_MODULES"

# 1) каждый модуль из списка существует и проходит sh -n
for m in $listed; do
	f="$LIBDIR/$m.sh"
	if [ ! -s "$f" ]; then bad "модуль $m: файл $f не найден"; continue; fi
	sh -n "$f" 2>/dev/null && ok "модуль $m: синтаксис" || bad "модуль $m: ошибка синтаксиса"
done

# 2) в lib/ нет файлов, которых не подключает главный скрипт
for f in "$LIBDIR"/*.sh; do
	m="$(basename "$f" .sh)"
	case " $listed " in *" $m "*) ;; *) bad "модуль $m лежит в lib/, но не подключён в VLESS_MODULES" ;; esac
done

# 3) функция определена ровно в одном месте
dups="$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$MAIN" "$LIBDIR"/*.sh | sort | uniq -d)"
[ -z "$dups" ] && ok "функции не определены дважды" || bad "функция определена несколько раз: $(echo $dups)"

# 4) главный скрипт не содержит функций (вся логика — в модулях)
n="$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{' "$MAIN")"
[ "$n" -eq 0 ] && ok "главный скрипт: только настройка, загрузка модулей и диспетчер" || bad "в $MAIN осталось функций: $n"

# 5) каждая команда диспетчера ведёт в существующую функцию
defs="$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$LIBDIR"/*.sh | tr -d '()')"
sed -n '/^case "\$1" in/,/^esac/p' "$MAIN" | sed -n 's/^[[:space:]]*[a-z-]*)[[:space:]]*\(.*\)/\1/p' | tr ';' '\n' \
	| sed 's/^[[:space:]]*//; s/^shift$//; s/^locked //' | awk 'NF{print $1}' | sort -u | while read -r fn; do
	case "$fn" in cmd_*|net_*|selective_*|sync_cron|effective_settings|settings_json) ;; *) continue ;; esac
	printf '%s\n' "$defs" | grep -qx "$fn" || echo "$fn"
done > /tmp/vless-modules.miss.$$
if [ -s /tmp/vless-modules.miss.$$ ]; then bad "диспетчер вызывает неопределённые функции: $(tr '\n' ' ' < /tmp/vless-modules.miss.$$)"; else ok "все команды диспетчера определены в модулях"; fi
rm -f /tmp/vless-modules.miss.$$

# 6) в пакете и в установщике перечислены те же модули
for m in $listed; do
	grep -q "/usr/share/vless/lib/$m.sh" install.sh && ok "install.sh проверяет модуль $m" || bad "install.sh не проверяет модуль $m"
done

[ $fail -eq 0 ] && echo "модули в порядке" || echo "ОШИБКИ В МОДУЛЯХ"
exit $fail
