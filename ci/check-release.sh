#!/bin/sh
# Согласованность релиза: VERSION, CHANGELOG и шаблоны issue говорят об одной версии.
#   sh ci/check-release.sh
cd "$(dirname "$0")/.." || exit 1
fail=0
bad() { echo "  FAIL $1"; fail=1; }
ok()  { echo "  ok   $1"; }

VER="$(tr -d '\r\n' < VERSION)"
BASE="${VER%-*}"
printf '%s\n' "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' && ok "VERSION=$VER" || bad "VERSION некорректен: $VER"

grep -q "^## \[$BASE\]" CHANGELOG.md && ok "CHANGELOG: есть раздел [$BASE]" || bad "в CHANGELOG.md нет раздела [$BASE]"
grep -q '^## \[Не выпущено\]' CHANGELOG.md && ok "CHANGELOG: есть раздел «Не выпущено»" || bad "в CHANGELOG.md нет раздела «Не выпущено»"
grep -q "$VER" .github/ISSUE_TEMPLATE/bug_report.yml && ok "шаблон bug_report знает версию" || bad "bug_report.yml: пример версии не $VER"

# Установщик не должен тянуть ничего с ветки main и не должен ставить непроверенный архив.
grep -q 'raw.githubusercontent.com/.*/main/' install.sh && bad "install.sh загружает файлы с ветки main" || ok "install.sh не берёт файлы с main"
grep -q 'sha256_check' install.sh && ok "install.sh проверяет sha256" || bad "в install.sh нет проверки sha256"

# В репозитории нет CRLF в скриптах (INSTALL.bat — исключение).
sh ci/check-lf.sh >/dev/null 2>&1 && ok "переводы строк LF" || bad "ci/check-lf.sh не прошёл"

[ $fail -eq 0 ] && echo "релиз согласован" || echo "РЕЛИЗ НЕСОГЛАСОВАН"
exit $fail
