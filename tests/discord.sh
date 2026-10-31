#!/bin/sh
# Тесты обхода Discord (vless-discord + интеграция в vless): без роутера, сети и настоящего nfqws.
#   sh tests/discord.sh
# Проверка Discord подменяется переменной DISCORD_FAKE_PROBE_OK (список id стратегий, при которых
# «Discord открывается»); управление службой и nft отключается DISCORD_NO_SERVICE=1.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

W="$(mktemp -d)"
mkdir -p "$W/bin" "$W/etc" "$W/run" "$W/dd/bin" "$W/dd/fake" "$W/dd/lists"
cat > "$W/bin/vless" <<EOF
#!/bin/sh
exec sh "$ROOT/root/usr/bin/vless" "\$@"
EOF
cat > "$W/bin/vless-discord" <<EOF
#!/bin/sh
exec sh "$ROOT/root/usr/bin/vless-discord" "\$@"
EOF
chmod +x "$W/bin/vless" "$W/bin/vless-discord"
export VLESS_DIR="$W/etc" VLESS_RUN="$W/run" VLESS_LIB="$ROOT/root/usr/share/vless" VLESS_PID="$W/vless.pid"
export VLESS_CRON="$W/crontab" UCI_DB="$W/uci.db" VLESS_DD="$W/dd" VLESS_BIN="$W/bin/vless" VLESS_DISCORD_BIN="$W/bin/vless-discord"
export DISCORD_NO_SERVICE=1 DISCORD_NO_SYNC=1 DISCORD_SETTLE=0
export PATH="$W/bin:$ROOT/tests/mock:$PATH"
H="vless"
D="vless-discord"
j() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }
t() { j "$2" "$3" && ok "$1" || { bad "$1"; printf '       получено: %s\n' "$(printf '%s' "$2" | cut -c1-300)"; }; }
setu() { uci set "vless.main.$1=$2"; }

echo "== стратегии"
ids="$(grep -v '^[[:space:]]*#' root/usr/share/vless/discord-strategies.conf | awk -F'|' 'NF==3{print $1}')"
[ "$(printf '%s\n' "$ids" | wc -l)" -ge 5 ] && ok "в файле стратегий не меньше пяти записей" || bad "мало стратегий"
[ "$(printf '%s\n' "$ids" | sort | uniq -d | wc -l)" -eq 0 ] && ok "id стратегий уникальны" || bad "повтор id стратегий"
[ "$(grep -v '^[[:space:]]*#' root/usr/share/vless/discord-strategies.conf | awk -F'|' 'NF!=3' | wc -l)" -eq 0 ] && ok "у каждой стратегии 3 поля" || bad "кривая строка в стратегиях"
a="$($D args s6)"
case "$a" in *--qnum=217*--filter-tcp=443*--hostlist=*--new*--filter-tcp=2053*--hostlist-domains=discord.media*--new*--filter-udp=19294-19344,50000-50100*--filter-l7=discord,stun*) ok "аргументы nfqws: TLS-, discord.media- и голосовой профили через --new" ;; *) bad "аргументы nfqws: $a" ;; esac
$D args s1 >/dev/null 2>&1 && bad "s1 без .bin должна быть недоступна" || ok "стратегия без нужного .bin пропускается"
echo x > "$W/dd/fake/tls_clienthello_www_google_com.bin"; echo x > "$W/dd/fake/quic_initial_www_google_com.bin"
echo x > "$W/dd/fake/quic_initial_dbankcloud_ru.bin"
$D args s1 | grep -q "seqovl-pattern=$W/dd/fake/tls_clienthello_www_google_com.bin" && ok "@F@ заменяется на каталог фейков" || bad "подстановка @F@"
$D nft-rules | grep -q 'queue num 217 bypass' && ok "nft: очередь с bypass (без nfqws трафик не пропадает)" || bad "nft: bypass"
$D nft-rules | grep -q 'oifname { "vless0", "lo" } return' && ok "nft: трафик в туннель VPN не трогаем" || bad "nft: vless0"

echo "== стратегии из .bat-файлов Flowseal"
mkdir -p "$W/bats"
mkbat() { # mkbat ФАЙЛ [строка-комментарий]
	printf '%s\r\n' '@echo off' ":: ${2:-65001 - UTF-8}" 'set "BIN=%~dp0bin\"' '' \
	'start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp=443,19294-19344,50000-50100,%GameFilterUDP% ^' \
	'--filter-udp=443 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^' \
	'--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-fake-stun="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-repeats=6 --new ^' \
	'--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=fake,multisplit --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new ^' \
	'--filter-tcp=80 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --new ^' \
	'--filter-tcp=443 --hostlist="%LISTS%list-general.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --dpi-desync=fake,multisplit --new ^' \
	'--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --dpi-desync=fake --dpi-desync-any-protocol=1' > "$1"
}
mkbat "$W/bats/general.bat"; mkbat "$W/bats/general (ALT10).bat"; mkbat "$W/bats/general (ALT2).bat"
mkbat "$W/bats/general (ALT5).bat" "NOT RECOMMENDED"; mkbat "$W/bats/general (FAKE TLS AUTO).bat"; echo svc > "$W/bats/service.bat"
p="$($D bat2profiles "$W/bats/general.bat")"
case "$p" in *--filter-udp=19294-19344,50000-50100*dbankcloud_ru.bin*--new*discord.media*--new*--filter-tcp=443*--hostlist=@L@*) ok "bat → nfqws: голос, discord.media и TLS сохранены" ;; *) bad "bat → nfqws: $p" ;; esac
case "$p" in *winws*|*--wf-*|*GameFilter*|*ipset*|*list-general*|*%BIN%*|*'"'*) bad "bat → nfqws: остатки Windows/списков Flowseal: $p" ;; *) ok "bat → nfqws: пути Windows, --wf-*, игровой фильтр и списки Flowseal убраны" ;; esac
case "$p" in *--filter-udp=443*|*--filter-tcp=80*) bad "bat → nfqws: лишние профили (QUIC/порт 80)" ;; *) ok "bat → nfqws: QUIC и порт 80 отброшены (Discord их не использует)" ;; esac
n="$($D build-strategies "$W/bats")"
[ "$n" = 5 ] && ok "собрано 5 стратегий (service.bat пропущен)" || bad "собрано стратегий: $n"
ord="$(cut -d'|' -f1 "$W/dd/strategies.flowseal.conf" | tr '\n' ' ')"
[ "$ord" = "f-general f-alt2 f-alt10 f-fake-tls-auto f-alt5 " ] && ok "порядок: general, ALT2, ALT10 (числом, не строкой), прочие, «NOT RECOMMENDED» в конце" || bad "порядок стратегий: $ord"
$D strategies | head -n1 | grep -q '^f-general$' && ok "стратегии Flowseal идут раньше встроенных" || bad "порядок источников"
$D strategies | grep -q '^s1$' && ok "встроенные остаются запасными" || bad "встроенные пропали"
rm -f "$W/dd/strategies.flowseal.conf"

echo "== эффективные настройки (поправка на Discord)"
setu scope all; setu discord_mode auto; uci set vless.main.presets=discord
echo zapret > "$W/run/discord.active"
r="$($H effective)"
t "zapret: домены Discord идут напрямую" "$r" '.direct_domains | index("discord.com") != null and index("discord.media") != null'
t "zapret: Discord убран из пресетов VPN" "$r" '(.presets | index("discord")) == null'
t "zapret: голосовой UDP идёт напрямую" "$r" '.zapret_udp == true'
t "zapret: сохранённые настройки не затронуты" "$($H settings)" '.presets == ["discord"] and (.direct_domains | length) == 0'
echo vpn > "$W/run/discord.active"
r="$($H effective)"
t "vpn: Discord добавлен в пресеты" "$r" '.presets | index("discord") != null'
t "vpn: прямых исключений не добавляется" "$r" '(.direct_domains | length) == 0 and (.zapret_udp // false) == false'
setu discord_mode off; echo zapret > "$W/run/discord.active"
t "режим «off»: настройки как есть, активное состояние игнорируется" "$($H effective)" '.presets == ["discord"] and (.direct_domains | length) == 0'
setu discord_mode auto; echo vpn > "$W/run/discord.active"; : > "$W/run/discord.vpn_only"
r="$($H effective)"
t "VPN только ради Discord: «выбранное», один пресет, все устройства" "$r" '.scope=="selected" and .presets==["discord"] and .mode=="all" and (.proxy_domains|length)==0'
rm -f "$W/run/discord.vpn_only"

echo "== сборка конфига sing-box"
# build.jq требует хотя бы один поддерживаемый сервер
printf '%s\n' '[{"id":"aaaaaaaa","supported":true,"server":"example.com","outbound":{"type":"vless","server":"example.com","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000"}}]' > "$W/servers.json"
echo zapret > "$W/run/discord.active"; S="$($H effective)"
cfg="$(jq -n -L "$VLESS_LIB" -f "$VLESS_LIB/build.jq" --slurpfile servers "$W/servers.json" --argjson s "$S" --arg secret x --arg selected auto --arg logfile /tmp/v.log)"
t "UDP голоса Discord: правило по портам → direct" "$cfg" '.route.rules | any(.network=="udp" and (.port_range|index("50000:50100")) and .outbound=="direct")'
t "домены Discord → direct" "$cfg" '.route.rules | any(.outbound=="direct" and (.domain_suffix // [] | index("discord.com")))'
cfg="$(jq -n -L "$VLESS_LIB" -f "$VLESS_LIB/build.jq" --slurpfile servers "$W/servers.json" --argjson s '{}' --arg secret x --arg selected auto --arg logfile /tmp/v.log)"
t "без zapret правила по портам нет" "$cfg" '[.route.rules[] | select(has("port_range"))] | length == 0'

echo "== настройки: discord_mode"
r="$(printf '%s' '{"discord_mode":"bogus"}' | $H set)"
t "set: неизвестный режим отклонён" "$r" '.ok==true and (.ignored|index("discord_mode"))'
r="$(printf '%s' '{"discord_mode":"zapret","discord_offload":false}' | $H set)"
t "set: режим zapret принят" "$r" '.ok==true and (.ignored|length)==0'
t "settings: режим и offload видны интерфейсу" "$($H settings)" '.discord_mode=="zapret" and .discord_offload==false'
printf '%s' '{"discord_mode":"off","discord_offload":true}' | $H set >/dev/null

echo "== автомат: перебор стратегий и запасной путь"
# «nfqws» — заглушка, принимающая любые аргументы (--dry-run)
printf '#!/bin/sh\nexit 0\n' > "$W/dd/bin/nfqws"; chmod +x "$W/dd/bin/nfqws"
echo discord.com > "$W/dd/lists/discord.txt"
printf '%s\n' '[{"id":"aaaaaaaa","name":"t","supported":true,"outbound":{"type":"vless"}}]' > "$W/etc/servers.json"
rm -f "$W/run/discord.active" "$W/run/discord.json"
setu discord_mode auto
export DISCORD_FAKE_PROBE_OK="s3"
r="$($D auto force)"
t "подбор: нашлась s3, Discord идёт через zapret" "$r" '.active=="zapret" and .strategy=="s3"'
t "подбор: в результатах первые две не подошли, третья да" "$r" '(.results|map(select(.skipped|not))|map(.ok)) | .[0:3] == [false,false,true]'
[ "$(cat "$W/dd/chosen")" = s3 ] && ok "рабочая стратегия запомнена" || bad "chosen"
export DISCORD_FAKE_PROBE_OK="none"
r="$($D auto)"
t "один сбой проверки не переключает маршрут" "$r" '.active=="zapret" and .fails==1'
r="$($D auto)"
t "второй подряд — перебор не помог, Discord уходит на VPN" "$r" '.active=="vpn" and (.reason|length)>0'
export DISCORD_FAKE_PROBE_OK="s1"
r="$($D auto)"
t "на VPN: до истечения паузы возврат на zapret не пробуем" "$r" '.active=="vpn"'
r="$($D auto force)"
t "принудительная проверка возвращает zapret" "$r" '.active=="zapret" and .strategy=="s1"'

echo "== без запасного VPN и в режиме «только zapret»"
export DISCORD_FAKE_PROBE_OK="none"
printf '%s\n' '[]' > "$W/etc/servers.json"
rm -f "$W/run/discord.active"
r="$($D auto force)"
t "auto без серверов VPN: ошибка, а не молчаливое «VPN»" "$r" '.active=="error" and (.reason|contains("нет серверов"))'
printf '%s\n' '[{"id":"aaaaaaaa","name":"t","supported":true,"outbound":{"type":"vless"}}]' > "$W/etc/servers.json"
setu discord_mode zapret; rm -f "$W/run/discord.active"
r="$($D auto force)"
t "zapret-only: при неудаче на VPN не уходим" "$r" '.active=="error"'
setu discord_mode vpn
r="$($D auto force)"
t "режим «только VPN»" "$r" '.active=="vpn"'
setu discord_mode off
r="$($D auto force)"
t "режим «выключено»" "$r" '.active=="off"'

echo "== cron"
setu discord_mode auto; $D sync-cron
grep -q '^\*/10 \* \* \* \* /usr/bin/vless-discord auto' "$VLESS_CRON" && ok "cron: проверка раз в 10 минут" || bad "cron: проверка"
grep -q 'vless-discord update' "$VLESS_CRON" && ok "cron: еженедельное обновление" || bad "cron: обновление"
setu discord_mode off; $D sync-cron
grep -q vless-discord "$VLESS_CRON" && bad "cron: записи убраны при «off»" || ok "cron: записи убраны при «off»"

echo "== очистка при fallback и режиме VPN"
eval "$(sed -n '/^fallback() {/,/^}/p;/^cmd_apply() {/,/^}/p' root/usr/bin/vless-discord)"
TEST_DISCORD_MODE=auto
DISCORD_ACTIONS="$W/actions"
cfg() { echo "$TEST_DISCORD_MODE"; }
vpn_servers() { echo 1; }
svc_stop() { echo stop >> "$DISCORD_ACTIONS"; }
nft_down() { echo nft-down >> "$DISCORD_ACTIONS"; }
offload_restore() { echo offload-restore >> "$DISCORD_ACTIONS"; }
set_active() { echo "active:$1" >> "$DISCORD_ACTIONS"; }
cmd_status() { :; }
sync_cron() { :; }
fallback "тестовая ошибка"
grep -q '^stop$' "$DISCORD_ACTIONS" && ok "fallback: nfqws останавливается" || bad "fallback: nfqws не остановлен"
grep -q '^nft-down$' "$DISCORD_ACTIONS" && ok "fallback: правила nft очищаются" || bad "fallback: nft не очищен"
grep -q '^offload-restore$' "$DISCORD_ACTIONS" && ok "fallback: flow offloading восстанавливается" || bad "fallback: offloading не восстановлен"
grep -q '^active:vpn$' "$DISCORD_ACTIONS" && ok "fallback: активируется резервный VPN" || bad "fallback: не выбран VPN"
: > "$DISCORD_ACTIONS"
TEST_DISCORD_MODE=vpn
cmd_apply
grep -q '^offload-restore$' "$DISCORD_ACTIONS" && ok "режим VPN: flow offloading восстанавливается" || bad "режим VPN: offloading не восстановлен"

rm -rf "$W"
echo
[ $fail -eq 0 ] && echo "ТЕСТЫ DISCORD ПРОЙДЕНЫ" || echo "ЕСТЬ ОШИБКИ (Discord)"
exit $fail
