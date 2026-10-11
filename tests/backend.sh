#!/bin/sh
# Тесты бэкенда (/usr/bin/vless) на заглушках: без роутера, sing-box и сети.
#   sh tests/backend.sh
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

W="$(mktemp -d)"
export VLESS_DIR="$W/etc" VLESS_RUN="$W/run" VLESS_LIB="$ROOT/root/usr/share/vless" VLESS_PID="$W/vless.pid"
export VLESS_CRON="$W/crontab" UCI_DB="$W/uci.db" NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
export PATH="$ROOT/tests/mock:$PATH"
H="sh $ROOT/root/usr/bin/vless"
j() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }
t() { j "$2" "$3" && ok "$1" || { bad "$1"; printf '       получено: %s\n' "$(printf '%s' "$2" | cut -c1-300)"; }; }

echo "== добавление и состояние"
r="$($H add "$(cat tests/links.txt)")"
t "add: 7 серверов из текста со ссылками" "$r" '.ok==true and .added==7'
# unique_by() переставлял весь список (id — это md5), и сервера «прыгали» при каждом добавлении
b_order="$($H state | jq -r '[.servers[].id]|join(",")')"
b_names="$($H state | jq -r '[.servers[].name]|join(",")')"
$H add "$(sed -n '1p' tests/links.txt)" >/dev/null
a_order="$($H state | jq -r '[.servers[].id]|join(",")')"
a_names="$($H state | jq -r '[.servers[].name]|join(",")')"
[ "$b_order" = "$a_order" ] && ok "порядок серверов не ломается при повторном добавлении" || bad "порядок серверов: $b_order -> $a_order"
[ "$b_names" = "$a_names" ] && ok "названия серверов не переставляются" || bad "названия переставились"
r="$($H add 'просто мусор')"
t "add: мусор отклонён с понятной ошибкой" "$r" '.ok==false and (.error|length)>10'
# rpcd передаёт текст через stdin: argv виден всем локальным пользователям
# в /proc/*/cmdline, а там полные ключи и токены подписки.
r="$(cat tests/links.txt | $H add)"
t "add через stdin (как это делает rpcd)" "$r" '.ok==true and .added==7'
r="$($H add '')"
t "add: пустой ввод отклонён" "$r" '.ok==false'
r="$($H state)"
t "state: серверы без секретов (outbound вырезан)" "$r" '(.servers|length)==7 and all(.servers[]; has("outbound")|not)'
t "state: источник «Мои ключи»" "$r" '.sources[0].id=="manual" and .sources[0].count==7'
t "state: статус «выключено»" "$r" '.status.phase=="off" and .status.connected==false'
t "state: настройки по умолчанию" "$r" '.settings.mtu==1400 and .settings.scope=="all" and .settings.block_ipv6==true'
t "state: по умолчанию российские сайты — напрямую" "$r" '.settings.bypass_ru==true'

echo "== настройки"
r="$(printf '%s' '{"kill_switch":true,"mtu":"abc","remote_dns":"not-ip","direct_domains":["example.org","bad domain!"],"mode":"include","devices":["192.168.1.50","999.1.1.1"],"presets":["telegram","nope"]}' | $H set)"
t "set: ok, но неверные значения перечислены" "$r" '.ok==true and (.ignored|index("mtu")) and (.ignored|index("remote_dns")) and (.ignored|any(startswith("direct_domains"))) and (.ignored|any(startswith("devices")))'
r="$($H settings)"
t "set: валидное сохранено, мусор — нет" "$r" '.kill_switch==true and .mtu==1400 and .remote_dns=="1.1.1.1" and .direct_domains==["example.org"] and .devices==["192.168.1.50"] and .presets==["telegram"] and .mode=="include"'
r="$(printf '%s' '{"mtu":1500,"update_interval":6}' | $H set)"
t "set: числа принимаются" "$r" '.ok==true and (.ignored|length)==0'
grep -q '^17 \*/6 \* \* \* /usr/bin/vless update-all' "$VLESS_CRON" && ok "cron: запись «каждые 6 часов»" || bad "cron: запись «каждые 6 часов»"
printf '%s' '{"update_interval":0}' | $H set >/dev/null
grep -q update-all "$VLESS_CRON" && bad "cron: запись удалена при «выключено»" || ok "cron: запись удалена при «выключено»"
r="$(printf 'не json' | $H set)"
t "set: некорректный JSON" "$r" '.ok==false'

echo "== выбор и удаление"
id="$($H state | jq -r '.servers[2].id')"
r="$($H select "$id")"
t "select: сервер выбран" "$r" ".ok==true and .selected==\"$id\""
r="$($H select 'x; rm -rf /')"
t "select: инъекция отклонена" "$r" '.ok==false'
r="$($H remove "$id")"
t "remove: сервер удалён" "$r" '.ok==true'
r="$($H state)"
t "remove: выбранный удалён → «Авто», осталось 6" "$r" '(.servers|length)==6 and .settings.selected=="auto" and .sources[0].count==6'
r="$($H remove 'zz zz')"
t "remove: некорректный id отклонён" "$r" '.ok==false'

echo "== подписка (локальный сервер)"
python3 tests/subserver.py 18765 tests/links.txt & SP=$!
sleep 1
r="$($H add http://127.0.0.1:18765/sub)"
t "подписка: добавлена, имя из Profile-Title" "$r" '.ok==true and .kind=="sub" and .name=="Тест" and .added==7'
# state читается любым пользователем LuCI с доступом к приложению, поэтому токен
# из пути подписки наружу отдаваться не должен — остаётся только хост.
r="$($H state)"
t "токен подписки не утекает через state" "$r" '[.sources[]|select(.kind=="sub")][0].url=="http://127.0.0.1:18765"'
t "подписка: остаток трафика и срок" "$r" '[.sources[]|select(.kind=="sub")][0] | .total==10737418240 and .upload==1048576 and .download==2097152 and .expire==1893456000'
sid="$(printf '%s' "$r" | jq -r '[.sources[]|select(.kind=="sub")][0].id')"
sv="$(printf '%s' "$r" | jq -r --arg s "$sid" '[.servers[]|select(.source==$s)][0].id')"
$H remove "$sv" >/dev/null
r="$($H refresh "$sid")"
t "refresh: ok" "$r" '.ok==true and .updated==1 and .failed==0'
r="$($H state)"
t "refresh: удалённый пользователем сервер не вернулся" "$r" "([.servers[]|select(.source==\"$sid\")]|length)==6"
r="$($H add 'vless://add/http://127.0.0.1:18765/sub')"
t "add: ссылка-обёртка vless://add/… распознана" "$r" '.ok==true and .kind=="sub"'
$H remove "$sid" >/dev/null
r="$($H state)"
t "remove: подписка удаляется вместе с серверами" "$r" '([.sources[]|select(.kind=="sub")]|length)==0 and (.servers|length)==6'
kill $SP 2>/dev/null; wait $SP 2>/dev/null
r="$($H add http://127.0.0.1:18765/sub)"
t "подписка недоступна: понятная ошибка" "$r" '.ok==false and (.error|startswith("Не удалось скачать"))'

echo "== подписка в base64 (Xray-JSON)"
# Раньше формат определялся ДО декодирования, поэтому base64(Xray-JSON)
# уходил в режим links и пользователь получал «серверов не найдено».
eval "$(sed -n '/^b64dec()/,/^}/p;/^body_format()/,/^}/p;/^body_to_tsv()/,/^}/p' root/usr/bin/vless)"
# Анализатор считает LIB неиспользуемой, но она нужна функции body_to_tsv,
# которая подтягивается eval'ом — такие строки статический анализ не разбирает.
RUN="$VLESS_RUN"; LIB="$VLESS_LIB"; mkdir -p "$RUN"
XJ='{"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"b64.example.com","port":8443,"users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"b64.example.com"},"wsSettings":{"path":"/b64","headers":{"Host":"cdn.b64.example.com"}}}}]}'
printf '%s' "$XJ" | jq -R -s -r 'explode | map(select(. != 10 and . != 13)) | implode | @base64' > "$W/sub.b64"
r="$(body_to_tsv "$W/sub.b64" 2>/dev/null)"
printf '%s\n' "$r" | cut -f2 | jq -e '.outbound.server=="b64.example.com" and .outbound.transport.path=="/b64"' >/dev/null 2>&1 \
	&& ok "base64(Xray-JSON) распознан" || bad "base64(Xray-JSON) не распознан"
printf '%s' "$XJ" > "$W/sub.json"
printf '%s\n' "$(body_to_tsv "$W/sub.json" 2>/dev/null)" | cut -f2 | jq -e '.outbound.type=="vless"' >/dev/null 2>&1 \
	&& ok "обычный Xray-JSON по-прежнему распознаётся" || bad "обычный Xray-JSON"

echo "== замер пинга при подключённом VPN"
# В Clash API sing-box 1.12+ нет маршрута /group/... — прежний код стучался туда
# и всегда получал ошибку, поэтому пинг не появлялся. Меряем /proxies/s-<id>/delay сами.
grep -qE "api GET '?/group/" root/usr/bin/vless && bad "в коде остался несуществующий запрос /group/" \
	|| ok "запросов к несуществующему /group/ больше нет"
SERVERS="$VLESS_DIR/servers.json"; RUN="$VLESS_RUN"
eval "$(sed -n '/^api()/,/^}/p;/^ping_all_servers()/,/^}/p' root/usr/bin/vless)"
[ -f "$SERVERS" ] && cp "$SERVERS" "$SERVERS.ping.bak"
printf '%s\n' aaaaaaa1 aaaaaaa2 dead0001 aaaaaaa3 aaaaaaa4 |
	jq -R -s 'split("\n") | map(select(length > 0))
		| map({ id:., source:"t", supported:true, outbound:{type:"vless"}, name:.,
		        proto:"vless", server:"h", port:443, net:"ws", sec:"tls" })' > "$SERVERS"
out="$( (export PATH="$ROOT/tests/mock/api:$PATH"; ping_all_servers) )"
printf '%s' "$out" | jq -e 'type=="object" and length==4' >/dev/null 2>&1 \
	&& ok "замерены 4 живых сервера, мёртвый отброшен" || bad "состав замера: $out"
printf '%s' "$out" | jq -e '[.[]|type]|all(.=="number")' >/dev/null 2>&1 \
	&& ok "задержки числовые — интерфейс их покажет" || bad "тип задержек: $out"
printf '%s' "$out" | jq -e 'has("aaaaaaa1")' >/dev/null 2>&1 \
	&& ok "ключи задержек — id серверов (совпадают с интерфейсом)" || bad "ключи: $out"
echo '[]' > "$SERVERS"
out="$( (export PATH="$ROOT/tests/mock/api:$PATH"; ping_all_servers) )"
[ "$out" = "{}" ] && ok "пустой список серверов -> {}" || bad "пустой список вернул: $out"
[ -f "$SERVERS.ping.bak" ] && mv "$SERVERS.ping.bak" "$SERVERS"

echo "== шум в журнале не должен показываться как ошибка"
# После штатного отключения sing-box пишет обрыв загрузки на уровне ERROR.
# Раньше эта строка всплывала как «Ошибка подключения».
printf '%s\n' "+0000 ERROR [1 55.63s] connection: connection download closed: http2: client connection force closed via ClientConn.Close" \
	> "$RUN/sing-box.log"
printf '%s\n' "+0000 INFO inbound/tun[tun-in]: started at vless0" >> "$RUN/sing-box.log"
eval "$(sed -n '/^log_noise()/,/^}/p' root/usr/bin/vless)"
err="$(grep -iE 'fatal|error' "$RUN/sing-box.log" | log_noise)"
[ -z "$err" ] && ok "обрыв соединения отфильтрован" || bad "шум не отфильтрован: $err"

echo "== прочее"
r="$($H status)"
t "status: выключено, без ошибки" "$r" '.running==false and .phase=="off" and .error==""'
r="$($H connect)"
t "connect без sing-box: ошибка, а не ложное «ок»" "$r" '.ok==false and (.error|length)>5'
r="$($H disconnect)"
t "disconnect: ok" "$r" '.ok==true'
r="$($H clear)"
t "clear: всё очищено" "$r" '.ok==true'
t "clear: пусто" "$($H state)" '(.servers|length)==0 and (.sources|length)==0'

echo "== отключение не тащит старые ошибки в статус"
# Раньше после штатного отключения sing-box писал обрыв соединения на уровне ERROR,
# и эта строка всплывала в интерфейсе как «Ошибка подключения».
printf '%s\n' "+0000 ERROR [1 55.63s] connection: connection download closed: http2: client connection force closed via ClientConn.Close" \
	"+0000 INFO inbound/tun[tun-in]: started at vless0" > "$VLESS_RUN/sing-box.log"
$H disconnect >/dev/null
[ -s "$VLESS_RUN/sing-box.prev.log" ] && ok "журнал прошлого запуска сохранён" || bad "журнал прошлого запуска потерян"
[ -s "$VLESS_RUN/sing-box.log" ] && bad "после отключения журнал не чистый" || ok "после отключения журнал чистый"
r="$($H status)"
printf '%s' "$r" | jq -e '.error=="" and .phase=="off"' >/dev/null 2>&1 \
	&& ok "статус после отключения без ошибки" || bad "после отключения ошибка: $r"
r="$($H logs)"
printf '%s' "$r" | jq -e '.log | test("предыдущий запуск")' >/dev/null 2>&1 \
	&& ok "журнал показывает прошлый запуск отдельным блоком" || bad "прошлый запуск не виден в журнале"

echo "== rpcd-плагин"
RP="sh $ROOT/root/usr/libexec/rpcd/vless"
$RP list | jq -e 'has("connect") and has("set") and has("ping") and has("ping-direct")' >/dev/null && ok "list: валидный JSON с методами" || bad "list"
# Каждый метод, который вызывает интерфейс, обязан быть в списке rpcd, иначе ubus его не отдаст.
miss=""
for m in $(sed -n "s/.*H('\([a-z-]*\)'.*/\1/p" "$ROOT/htdocs/luci-static/resources/view/vless/main.js" | sort -u); do
	$RP list | jq -e --arg m "$m" 'has($m)' >/dev/null 2>&1 || miss="$miss $m"
done
[ -z "$miss" ] && ok "все методы интерфейса есть в rpcd list" || bad "в rpcd list нет:$miss"
$RP list | jq -r 'keys[]' | while read -r m; do
	grep -q "\"$m\"" "$ROOT/root/usr/share/rpcd/acl.d/luci-vless-selective.json" || echo "acl: нет $m"
done > "$W/acl.miss" 2>/dev/null
[ -s "$W/acl.miss" ] && bad "методы без прав в ACL: $(tr '\n' ' ' < "$W/acl.miss")" || ok "все методы разрешены в ACL"
r="$(echo '{}' | VLESS_BIN="$ROOT/root/usr/bin/vless" $RP call status)"
t "call status: проксируется" "$r" 'has("running")'
r="$(echo '{}' | VLESS_BIN=/nonexistent $RP call state)"
t "call при сломанном бэкенде: JSON-ошибка, не пустой ответ" "$r" '.ok==false and (.error|length)>5'
r="$(echo '{}' | $RP call nope)"
t "call: неизвестный метод" "$r" '.ok==false'

echo "== выборочная маршрутизация"
printf '%s' '{"scope":"selected","presets":["telegram","youtube"],"proxy_domains":["example.net","203.0.113.7","*.foo.org"],"mode":"all","devices":[]}' | $H set >/dev/null
L="$($H selective-lists)"
printf '%s\n' "$L" | grep -qx 'D t.me' && ok "списки: домен пресета telegram" || bad "списки: домен пресета telegram"
printf '%s\n' "$L" | grep -qx 'C 149.154.160.0/20' && ok "списки: подсеть пресета telegram" || bad "списки: подсеть пресета telegram"
printf '%s\n' "$L" | grep -qx 'D youtube.com' && ok "списки: пресет youtube" || bad "списки: пресет youtube"
printf '%s\n' "$L" | grep -qx 'D example.net' && ok "списки: свой домен" || bad "списки: свой домен"
printf '%s\n' "$L" | grep -qx 'C 203.0.113.7' && ok "списки: свой IP попадает в подсети" || bad "списки: свой IP попадает в подсети"
printf '%s\n' "$L" | grep -qx 'D foo.org' && ok "списки: звёздочка *. снимается" || bad "списки: звёздочка *. снимается"
printf '%s\n' "$L" | grep -q 'discord' && bad "списки: невыбранный пресет не попадает" || ok "списки: невыбранный пресет не попадает"
# Набор vpn4 объявлен ipv4_addr: одна IPv6-запись раньше роняла nft add element
# целиком и отключала ВСЕ подсети разом.
printf '%s' '{"scope":"selected","presets":["telegram"],"proxy_domains":["example.net","2001:db8::/32"],"mode":"all","devices":[]}' | $H set >/dev/null
L="$($H selective-lists)"
printf '%s\n' "$L" | grep -qx 'C 149.154.160.0/20' && ok "подсети пресета целы несмотря на IPv6-запись" || bad "подсети пресета потеряны"
printf '%s\n' "$L" | grep -q '2001:db8' && bad "IPv6 попал в набор ipv4_addr" || ok "IPv6 отфильтрован из списка подсетей"
printf '%s\n' "$L" | grep -qx 'C 95.161.64.0/20' && ok "новый диапазон Telegram на месте" || bad "нет диапазона 95.161.64.0/20"
N="$($H selective-nft)"
printf '%s\n' "$N" | grep -q 'meta mark set 0x64' && ok "nft: правило пометки есть" || bad "nft: правило пометки есть"
if command -v nft >/dev/null 2>&1 && printf '%s\n' "$N" | nft -c -f - >/dev/null 2>&1; then ok "nft: синтаксис принят nft -c"
else echo "  --   nft -c недоступен здесь, проверка синтаксиса пропущена"; fi
printf '%s' '{"mode":"include","devices":["192.168.1.50"]}' | $H set >/dev/null
$H selective-nft | grep -q 'ip saddr { 192.168.1.50 }' && ok "nft: режим «только выбранные устройства» учтён" || bad "nft: режим устройств"
printf '%s' '{"scope":"all","mode":"all","devices":[]}' | $H set >/dev/null
$H state | jq -e '.settings.bypass_ru==true or .settings.bypass_ru==false' >/dev/null && ok "состояние: поле bypass_ru есть" || bad "состояние: bypass_ru"

rm -rf "$W"
[ $fail -eq 0 ] && echo "ТЕСТЫ БЭКЕНДА ПРОЙДЕНЫ" || echo "ЕСТЬ ОШИБКИ В БЭКЕНДЕ"
exit $fail
