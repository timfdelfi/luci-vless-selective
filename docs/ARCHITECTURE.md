# Архитектура

Как устроено приложение, из чего оно состоит и как части общаются друг с другом.
Если нужно добавить функцию, начните отсюда, а потом откройте [CONTRIBUTING.md](../CONTRIBUTING.md).

## Общая схема

```
 браузер (LuCI)                      роутер OpenWrt
┌──────────────┐  ubus/JSON-RPC  ┌────────────────────┐
│  main.js     │ ──────────────▶ │ rpcd-плагин        │  /usr/libexec/rpcd/vless
│  (JS-view)   │ ◀────────────── │ (мост + ACL)       │
└──────────────┘                 └─────────┬──────────┘
                                           │ вызывает, JSON на stdout
                                           ▼
                                 ┌────────────────────┐   jq: parse.jq, build.jq, presets.jq
                                 │ /usr/bin/vless     │──▶ UCI: /etc/config/vless
                                 │ (бэкенд, sh)       │──▶ база: /etc/vless/*.json
                                 │ + lib/*.sh         │──▶ состояние: /var/run/vless/
                                 └───┬────────┬───────┘
              procd (init.d/vless)   │        │ ip rule / ip route / nft / dnsmasq
                                     ▼        ▼
                           ┌────────────┐  ┌────────────────────────────┐
                           │ sing-box   │  │ сетевой стек роутера       │
                           │ TUN vless0 │◀─│ таблица 100, набор vpn4    │
                           │ Clash API  │  └────────────────────────────┘
                           └────────────┘
                                     ▲
              cron: update-all       │  /usr/bin/vless-discord ──▶ nfqws (отдельно, только Discord)
```

Принципы:

- **Бэкенд — это CLI.** Каждая команда `vless <команда>` печатает JSON; веб-интерфейс ничего не знает о внутренностях и
  только вызывает методы. Ту же команду можно выполнить руками по ssh.
- **Ничего не зависит от LuCI-версии, кроме `main.js`.** Всё остальное работает без веб-интерфейса.
- **Свой экземпляр sing-box.** Приложение не трогает `/etc/sing-box` и чужие `ip rule`/nft-правила.

## Компоненты

| Компонент | Файл | Задача |
| --- | --- | --- |
| Интерфейс | `htdocs/luci-static/resources/view/vless/main.js` | Страница «Службы → VPN». Только вызывает rpc-методы и рисует состояние |
| Меню и права | `root/usr/share/luci/menu.d/…json`, `root/usr/share/rpcd/acl.d/…json` | Пункт меню и список ubus-методов, доступных вошедшему в LuCI |
| rpcd-плагин | `root/usr/libexec/rpcd/vless` | `list` / `call`: проверяет метод, вызывает `/usr/bin/vless`, гарантирует JSON-ответ даже при сбое бэкенда |
| Бэкенд | `root/usr/bin/vless` + `root/usr/share/vless/lib/*.sh` | Подписки, сборка конфига, запуск, сеть, DNS, диагностика |
| jq-программы | `root/usr/share/vless/{parse,build,presets}.jq` | Разбор ссылок/подписок в серверы; сборка конфига sing-box; домены и подсети пресетов |
| Служба | `root/etc/init.d/vless` | procd: `vless prepare`, затем `vless run` (внутри `exec sing-box`); `stop` → `vless net-down` |
| Discord | `root/usr/bin/vless-discord`, `root/etc/init.d/vless-discord`, `discord-strategies.conf` | Отдельный обход Discord через nfqws; сам с VPN связан только настройками и запасным путём |
| Установка | `install.sh`, `uninstall.sh`, `INSTALL.bat`, `build.sh`, `Makefile` | Установка на роутер, сборка `.ipk`/`.tar.gz`/`.zip` |

## Модули бэкенда

`/usr/bin/vless` сам почти ничего не делает: задаёт пути и константы, создаёт каталоги, подключает модули
(`VLESS_MODULES`) и разбирает команду. Вся логика лежит в `root/usr/share/vless/lib/`:

| Модуль | Ответственность | Ключевые функции |
| --- | --- | --- |
| `util.sh` | общее | `cfg`, `api` (Clash API), `atomic_run`/`atomic_text`, `join_jobs`, `lock`/`locked` |
| `validate.sh` | входные данные | `valid_ip`, `valid_cidr`, `valid_ipv6`, `valid_domain`, `valid_route_target` |
| `settings.sh` | настройки | `settings_json`, `cmd_set` |
| `discord.sh` | связка с Discord | `effective_settings` (поправка настроек под Discord), `cmd_discord_sync` |
| `cron.sh` | расписание | `cron_spec`, `sync_cron`, `autostart_on` |
| `subscriptions.sh` | подписки и серверы | `cmd_add`, `cmd_refresh`, `cmd_remove`, `cmd_select`, разбор тела подписки |
| `lifecycle.sh` | запуск | `cmd_prepare`, `cmd_connect`, `cmd_disconnect`, `cmd_run` |
| `net.sh` | сеть и DNS | `net_up`, `net_down`, `del_rules`, `dnsmasq_dir` |
| `selective.sh` | режим «только выбранные» | `selective_lists`, `selective_nft_conf`, `selective_up`/`selective_down` |
| `probe.sh` | диагностика | `cmd_check`, `cmd_ping`, `cmd_ping_direct`, `ping_one_direct` |
| `status.sh` | состояние для UI | `cmd_state`, `cmd_status`, `cmd_devices`, `cmd_logs`, `cmd_selftest` |

Правила модулей:

- Модуль только объявляет функции и переменные; ничего не выполняет при подключении.
- Порядок подключения не важен. Модуль вправе вызывать функции любого другого модуля.
- Одна функция — в одном модуле (проверяет `tests/modules.sh`).
- Общие переменные (`DIR`, `RUN`, `LIB`, `SERVERS`, `TUN`, …) задаются в `/usr/bin/vless`.

## Данные и состояние

| Где | Что | Права |
| --- | --- | --- |
| `/etc/config/vless` (UCI) | настройки пользователя: режим, DNS, интерфейсы, `selected` и т. д. | как у UCI |
| `/etc/vless/servers.json` | все серверы (разобранные ссылки, готовые outbound) | `0600` |
| `/etc/vless/sources.json` | подписки и «Мои ключи» (в т. ч. токены подписок) | `0600` |
| `/etc/vless/hidden.json` | серверы подписок, удалённые пользователем (чтобы не вернулись при обновлении) | `0600` |
| `/var/run/vless/` (tmpfs) | `config.json` sing-box, `secret` API, `last_error`, `up_since`, `rule.prefs`, `vpn_targets`, `nftset.conf`, журнал, замок `lock/` | каталог `0700` |
| `/etc/vless-discord/` | nfqws, фейки, списки, найденная стратегия (без секретов — nfqws читает не от root) | `0755` |

Все записи в базу идут через `atomic_run`/`atomic_text`: пишем во временный файл с `umask 077` и только при успехе
переименовываем. Упавший `jq` не может затереть базу пустым файлом.

## Жизненный цикл

1. **Добавление** (`vless add`, текст приходит со stdin): `parse.jq` превращает ссылки и подписки в серверы,
   `merge_servers` сливает их с базой, не возвращая удалённые пользователем.
2. **Подключение** (`vless connect` → `/etc/init.d/vless start`):
   - `vless prepare`: проверка sing-box ≥ 1.12 и `/dev/net/tun`, новый секрет API, сборка `config.json` через
     `build.jq`, `sing-box check` на временном файле и только потом замена рабочего, разрешение адресов серверов подписки;
   - procd запускает `vless run`: он в фоне запускает `net_up` и делает `exec sing-box`.
3. **Сеть** (`net_up`, ждёт появления `vless0` до 40 с):
   - таблица 100: `default dev vless0`; при Kill Switch ещё `blackhole default` с большой метрикой;
   - `ip rule` с префами: `9000…` локальные сети идут мимо туннеля (таблица `main`), `9020` трафик к подсетям LAN, `9030` адреса
     VPN-серверов подписки (мимо туннеля, чтобы VPN на телефонах продолжал работать), `9050` исключённые устройства,
     `9100` трафик в таблицу 100 (по источнику или по метке `0x64` в выборочном режиме);
   - IPv6 клиентов закрывается `unreachable`-правилом (если не отключено);
   - DNS: в каталог dnsmasq кладётся `vless.conf` (`server=127.0.0.77`, в выборочном режиме ещё `nftset`) и dnsmasq
     перезапускается.
   Свои правила запоминаются в `rule.prefs`, и `net_down` удаляет ровно их.
4. **Остановка** (`net_down`): ждёт `net_up`, убивает его при зависании, удаляет свои правила, nft-таблицу `inet vless`,
   `vless.conf`, перезапускает dnsmasq.

### Режимы маршрутизации

- **Весь трафик / всё, кроме РФ.** Весь трафик LAN уходит в таблицу 100, а решение «через VPN или напрямую» принимает
  sing-box по правилам из `build.jq` (`route.final=proxy`, российские домены — `direct`).
- **Только выбранные.** В туннель не заворачивается ничего, кроме адресов набора `vpn4`. Набор в nftables наполняет
  dnsmasq по доменам выбранных пресетов (`nftset`), подсети пресетов (Telegram) добавляются сразу. Пакеты к адресам из
  набора получают метку `0x64` и уходят в таблицу 100. Если dnsmasq собран без `nftset`, приложение откатывается на
  обычный режим и пишет причину в журнал.

### Автовыбор и пинг

`build.jq` собирает группу `urltest` (`auto`); выбранный вручную сервер — outbound `proxy`. Пинг через VPN идёт через
Clash API sing-box (`127.0.0.1:9099`, `Authorization: Bearer <secret>`, секрет передаётся curl через stdin).
Прямой пинг без VPN (`ping-direct`) — это время TCP connect, измеренное `curl` с таймаутом.

## Параллельность и блокировки

- Команды, меняющие серверы или настройки (`add`, `remove`, `refresh`, `select`, `set`, `clear`, `connect`,
  `disconnect`, `discord-sync`), идут через `locked`: замок — каталог `$RUN/lock` с pid владельца, мёртвый владелец снимается.
- `prepare` замок не берёт, поэтому `connect` → `start` → `prepare` не уходит в дедлок.
- Фоновые задачи (пинг, разрешение адресов) ограничены `JOBS_MAX` (8), чтобы роутер с 64 МБ не ушёл в OOM.

## Безопасность

- Ключи и токены подписок живут только в `/etc/vless` (`0700`/`0600`) и в `/var/run/vless`.
- Тексты со ссылками идут в бэкенд через stdin, секрет Clash API — в curl через stdin (`-K -`): в `argv` секретов нет,
  `/proc/*/cmdline` их не покажет.
- `state` не возвращает токены подписок (есть тест).
- Модуль Discord скачивает nfqws и релиз Flowseal с GitHub и проверяет sha256 из ответа GitHub API.
  Это защита от битой загрузки, но не от подмены самого релиза.

## Тесты и что они покрывают

| Тест | Что проверяет |
| --- | --- |
| `tests/run.sh` | разбор ссылок, сборка конфига, `sing-box check`, валидаторы, прямой пинг; запускает остальное |
| `tests/backend.sh` | бэкенд целиком на заглушках: добавление/удаление/обновление, настройки, rpcd, ACL, выборочные списки |
| `tests/discord.sh` | модуль Discord |
| `tests/modules.sh` | состав модулей, дубли функций, диспетчер, список в `install.sh` (jq не нужен) |
| `tests/mock-drift.sh` | что заглушки `curl` и `uci` знают всё, что вызывает код (jq не нужен) |
| `tests/ui/shot.js` | интерфейс в headless Chromium, скриншоты для README |
| `ci/*.sh` | LF, jq без регулярных выражений, размер и минификация `main.js` |
