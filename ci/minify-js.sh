#!/bin/sh
# Минификация интерфейса (main.js) и контроль размера.
#   sh ci/minify-js.sh [ВЫХОДНОЙ_ФАЙЛ]     по умолчанию dist/main.min.js
#
# Что делает:
#   1. сверяет размер исходного main.js с бюджетом (JS_MAX_KB, по умолчанию 150 КБ);
#   2. сжимает через terser (качается npx, версия закреплена; нужен node и сеть);
#   3. проверяет результат: node --check, и что LuCI-директивы 'use strict' / 'require …'
#      остались в начале файла. terser по умолчанию выкидывает «нестандартные» директивы,
#      а без них LuCI не подтянет модули и страница не откроется — поэтому directives=false;
#   4. печатает размеры (как есть и gzip).
# Релизная сборка по умолчанию НЕ минифицирует: включается явно, MINIFY=1 sh build.sh.
set -e
cd "$(dirname "$0")/.."
SRC=htdocs/luci-static/resources/view/vless/main.js
OUT="${1:-dist/main.min.js}"
TERSER="${TERSER_VERSION:-5.31.0}"
MAX_KB="${JS_MAX_KB:-150}"

size() { wc -c < "$1" | tr -d ' '; }
gz()   { gzip -9 -c "$1" | wc -c | tr -d ' '; }

raw="$(size "$SRC")"
[ "$raw" -le $((MAX_KB * 1024)) ] || { echo "main.js: $raw байт — больше бюджета ${MAX_KB} КБ (JS_MAX_KB)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
# --format quote_style=1: одинарные кавычки, как в исходнике (так директивы выглядят привычно для загрузчика LuCI)
npx --yes "terser@$TERSER" "$SRC" \
	--parse bare_returns=true \
	--compress directives=false,passes=2 --mangle \
	--format quote_style=1,comments=false \
	-o "$OUT"

node --check "$OUT"

# директивы из исходника должны стоять в минифицированном файле в самом начале
head_min="$(head -c 600 "$OUT")"
grep -E "^'(use strict|require [^']+)';" "$SRC" | while IFS= read -r d; do
	d="${d%;}"
	case "$head_min" in
		*"$d"*) ;;
		*) echo "после минификации пропала директива $d — файл нельзя отдавать в LuCI" >&2; exit 1 ;;
	esac
done

min="$(size "$OUT")"
[ "$min" -gt 0 ] && [ "$min" -lt "$raw" ] || { echo "минифицированный файл подозрительного размера: $min" >&2; exit 1; }
printf 'main.js: %s Б → %s Б (-%s%%); gzip: %s Б → %s Б\n' "$raw" "$min" $(( (raw - min) * 100 / raw )) "$(gz "$SRC")" "$(gz "$OUT")"
