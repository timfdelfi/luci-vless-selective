# Как внести вклад

Спасибо, что смотрите в код. Здесь коротко: как собрать окружение, что проверить до PR и по каким правилам написан код.
Устройство проекта описано в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Быстрый старт

Нужны: Linux (или WSL), `sh`, `jq` (1.6+), `python3`, `md5sum`, `curl`. По желанию: `sing-box` (проверка конфига),
`shellcheck`, `node` (интерфейс), `zip` и `ar` из binutils (сборка).

```
git clone https://github.com/timfdelfi/luci-vless-selective
cd luci-vless-selective
sh tests/run.sh            # всё, кроме интерфейса
```

Тестам не нужен роутер: бэкенд гоняется на заглушках из `tests/mock/`.

## Что запускать перед PR

То же, что гоняет CI:

```
sh ci/check-lf.sh          # везде LF (кроме INSTALL.bat)
sh ci/check-jq.sh          # jq-скрипты компилируются и не используют регулярные выражения
shellcheck -s sh -S warning -e SC3043,SC2034 \
    $(git ls-files '*.sh') root/usr/bin/vless root/usr/bin/vless-discord \
    root/etc/init.d/vless root/etc/init.d/vless-discord root/usr/libexec/rpcd/vless tests/mock/*
sh tests/run.sh            # включает tests/modules.sh и tests/mock-drift.sh
node --check htdocs/luci-static/resources/view/vless/main.js
node tests/ui/shot.js      # если трогали интерфейс (нужен playwright, см. README)
sh ci/minify-js.sh         # если трогали main.js: бюджет размера и проверка минификации
sh build.sh                # пакеты собираются
```

## Правила кода

**Shell.** Целевой интерпретатор — BusyBox `ash`, а не bash.

- Никаких bash-измов: `[[ ]]`, массивов, `$'…'`, `<(…)`, `${var//a/b}`. `local` можно (есть в ash).
- Отступы — табуляция, комментарии — по-русски, и объясняют **почему**, а не что.
- Пустой вывод и код возврата — не одно и то же: не пишите `jq … | write_atomic`, используйте `atomic_run FILE jq …`.
- Все команды бэкенда печатают JSON; ошибка — `json_err "текст"`. Причину сбоя службы запоминает `set_error`.
- Секреты (ключи, токены, секрет API) не кладём в `argv`: `curl -K -` / stdin.
- Любой пользовательский ввод проверяйте функциями из `validate.sh` до того, как он попадёт в `ip rule`, nft или конфиг.
- Команда, меняющая серверы или настройки, идёт через `locked` в диспетчере `/usr/bin/vless`.

**jq.** На роутерах jq часто собран без Oniguruma, поэтому **регулярные выражения запрещены** (`test`, `match`,
`sub`, `gsub`, `capture`, `scan`…). `ci/check-jq.sh` это проверяет.

**Интерфейс (`main.js`).** ES5-стиль, как в остальном LuCI. Новые данные в разметку — через DOM-функции (`E()`),
а не через `innerHTML` с пользовательскими строками. Метод, который вызывает интерфейс, должен быть в `rpcd list` и в ACL
(`tests/backend.sh` это проверяет). Директивы `'require …'` в начале файла не трогайте: на них держится загрузка модулей в LuCI.

## Как добавить…

**Новую команду бэкенда.** Функция `cmd_<имя>` в подходящем модуле `lib/`; строка в `case` диспетчера
`/usr/bin/vless`; для вызова из интерфейса — метод в `rpcd/vless` (`list` и `call`) и в ACL
`root/usr/share/rpcd/acl.d/luci-vless-selective.json`; тест в `tests/backend.sh`.

**Новый модуль.** Файл `root/usr/share/vless/lib/<имя>.sh` с первыми строками
`# shellcheck shell=sh disable=SC2154` и описанием, имя — в `VLESS_MODULES` в `/usr/bin/vless` и в список проверки
файлов в `install.sh`. `sh tests/modules.sh` подскажет, если что-то забыли.

**Пресет маршрутизации.** Ключ нужно прописать в трёх местах, и они должны совпадать:

1. `root/usr/share/vless/presets.jq` — домены и подсети;
2. `root/usr/bin/vless` — переменная `PRESET_KEYS`;
3. `htdocs/luci-static/resources/view/vless/main.js` — массив `PRESETS`.

**Протокол или транспорт.** Разбор — в `root/usr/share/vless/parse.jq`, сборка outbound — в `build.jq`. Добавьте
ссылку в `tests/links.txt` и проверку в `tests/run.sh`. `sing-box check` в CI поймает невалидный конфиг.

**Заглушки.** Если код начал вызывать новый маршрут Clash API или новую подкоманду `uci`, научите этому
`tests/mock/api/curl` / `tests/mock/uci`. Иначе `tests/mock-drift.sh` упадёт.

## Pull request

1. Ветка от `main`, одна тема на PR.
2. Тесты на то, что чините или добавляете. Исправление ошибки без теста, который до исправления падал, — неполное.
3. Запись в [CHANGELOG.md](CHANGELOG.md) в разделе «Не выпущено».
4. Версию (`VERSION`) меняет мейнтейнер при выпуске.
5. Заполните шаблон PR. Если трогали сеть, DNS или модуль Discord, напишите, на какой версии OpenWrt проверяли.

Не прикладывайте к issue и PR свои ссылки, ключи и токены подписок.

## Релиз (для мейнтейнера)

Обновить `VERSION`, перенести записи из «Не выпущено» в новый раздел `CHANGELOG.md`, затем
`git tag v<версия> && git push --tags`. CI соберёт `vless-vpn.zip`, `vless-vpn.tar.gz`, `.ipk` и `.sha256`
и приложит их к релизу. Тег должен совпадать с `VERSION`.
