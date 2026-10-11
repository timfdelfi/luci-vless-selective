#!/bin/sh
# Проверка переводов строк: в репозитории везде LF, иначе `#!/bin/sh` на роутере
# не запустится. Исключения: INSTALL.bat (нужен CRLF) и бинарные файлы.
cd "$(dirname "$0")/.." || exit 1
CR="$(printf '\r')"
bad=$(find . -type f \
	-not -path './.git/*' -not -path './dist/*' -not -path './tests/ui/out/*' \
	-not -name '*.png' -not -name '*.ipk' -not -name '*.zip' -not -name '*.gz' \
	-not -name 'INSTALL.bat' -print | while IFS= read -r f; do
		grep -q "$CR" "$f" 2>/dev/null && echo "$f"
	done)
if [ -n "$bad" ]; then
	echo "Файлы с CRLF (нужен LF):"
	echo "$bad"
	exit 1
fi
echo "ok: все текстовые файлы в LF"
