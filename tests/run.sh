#!/bin/sh
# Тесты: разбор ссылок, сборка конфига, проверка конфига через sing-box (если установлен).
#   sh tests/run.sh
cd "$(dirname "$0")/.." || exit 1
LIB=root/usr/share/vless
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

echo "== разбор ссылок"
out="$(jq -R -n -r --arg mode links -f $LIB/parse.jq < tests/links.txt)"
[ "$(printf '%s\n' "$out" | wc -l)" -eq 7 ] && ok "7 серверов из 8 строк (мусор пропущен)" || bad "ожидалось 7 серверов"
rows="$(printf '%s\n' "$out" | cut -f2)"
chk() { printf '%s\n' "$rows" | jq -e -s "$2" >/dev/null 2>&1 && ok "$1" || bad "$1"; }
chk "Reality: pbk/sid/flow"          '.[0].outbound | .flow=="xtls-rprx-vision" and .tls.reality.public_key=="AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde" and .tls.reality.short_id=="ab12cd"'
chk "имя с эмодзи декодируется"      '.[0].name | endswith("Germany")'
chk "gRPC: serviceName с точками"    '.[1].outbound.transport | .type=="grpc" and .service_name=="sync.v2.ApiService"'
chk "WebSocket: host и path"         '.[2].outbound.transport | .type=="ws" and .path=="/ws" and .headers.Host=="cdn.example.com"'
chk "XHTTP помечен неподдерживаемым" '.[3].supported==false'
chk "Trojan: пароль декодирован"     '.[4].outbound.password=="pa$$word"'
chk "Shadowsocks: метод и пароль"    '.[5].outbound | .method=="aes-256-gcm" and .password=="password"'
chk "Hysteria2"                      '.[6].outbound | .type=="hysteria2" and .tls.insecure==true'

echo "== сборка конфига"
tmp="$(mktemp -d)"
printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r k f; do
	id="$(printf '%s' "$k" | md5sum | cut -c1-8)"
	printf '{"id":"%s","source":"t",%s\n' "$id" "${f#\{}"
done | jq -s -c . > "$tmp/servers.json"
S='{"remote_dns":"1.1.1.1","bootstrap_dns":"77.88.8.8","block_quic":true,"bypass_ru":true,"direct_domains":["example.org","10.1.2.0/24"],"tun_stack":"system","mtu":1400,"log_level":"warn","auto_interval":"3m","auto_tolerance":80}'
if jq -n -L $LIB -f $LIB/build.jq --slurpfile servers "$tmp/servers.json" --argjson s "$S" --arg secret x --arg selected auto --arg logfile /tmp/vless.log > "$tmp/config.json"; then
	ok "конфиг собран"
	jq -e '.outbounds | map(select(.type=="urltest")) | .[0] | .interval=="3m" and .tolerance==80' "$tmp/config.json" >/dev/null && ok "автовыбор: urltest с интервалом и порогом" || bad "urltest"
	if command -v sing-box >/dev/null 2>&1; then
		sing-box check -c "$tmp/config.json" && ok "sing-box check: конфиг валиден" || bad "sing-box check"
	else
		echo "  --   sing-box не найден, проверка конфига пропущена"
	fi
else
	bad "сборка конфига"
fi

echo "== пресеты (только выбранное)"
build() { jq -n -L $LIB -f $LIB/build.jq --slurpfile servers "$tmp/servers.json" --argjson s "$1" --arg secret x --arg selected auto --arg logfile /tmp/vless.log; }
B='"remote_dns":"1.1.1.1","bootstrap_dns":"77.88.8.8","block_quic":true,"tun_stack":"system","mtu":1400,"log_level":"warn"'
cj() { printf '%s' "$cfg" | jq -e "$2" >/dev/null 2>&1 && ok "$1" || bad "$1"; }

cfg="$(build "{$B,\"scope\":\"selected\",\"presets\":[\"telegram\",\"youtube\"],\"proxy_domains\":[\"example.net\",\"203.0.113.7\"],\"direct_domains\":[\"youtube.com\"]}")"
cj "остальное — напрямую (final=direct)"        '.route.final=="direct"'
cj "DNS по умолчанию — прямой"                  '.dns.final=="dns-direct"'
cj "YouTube и свой домен идут через прокси"     '.route.rules | any(.outbound=="proxy" and (.domain_suffix|index("googlevideo.com")) and (.domain_suffix|index("example.net")))'
cj "Telegram и свой IP — по подсетям"           '.route.rules | any(.outbound=="proxy" and (.ip_cidr|index("149.154.160.0/20")) and (.ip_cidr|index("203.0.113.7")))'
cj "DNS выбранных сайтов — через VPN"           '.dns.rules | any(.server=="dns-remote" and (.domain_suffix|index("t.me")))'
cj "QUIC режется только у выбранных"            '[.route.rules[] | select(.action=="reject")] | length>0 and all(has("domain_suffix") or has("ip_cidr"))'
cj "исключение пользователя раньше прокси-правил" '([.route.rules[]|.outbound=="direct" and has("domain_suffix")]|index(true)) < ([.route.rules[]|.outbound=="proxy" and has("domain_suffix")]|index(true))'
cfg="$(build "{$B,\"scope\":\"selected\",\"presets\":[\"nope\"]}")"
cj "неизвестный пресет игнорируется"            '.route.final=="direct" and ([.route.rules[]|select(.outbound=="proxy")]|length)==0'
# Пользователь пишет «*.example.org». nft-часть снимала «*.», а sing-box-конфиг
# оставлял «*.example.org», и sing-box check падал — кнопка «Подключить» не работала.
cfg="$(build "{$B,\"scope\":\"selected\",\"proxy_domains\":[\"*.foo.org\",\"example.net\"],\"direct_domains\":[\"*.direct.org\"]}")"
cj "«*.» снимается и в sing-box-конфиге"        '[.route.rules[] | (.domain_suffix // [])[]] | (index("*.foo.org")|not) and (index("foo.org")!=null)'
cj "«*.» снимается и в исключениях"             '.route.rules | any(.outbound=="direct" and (.domain_suffix|index("*.direct.org")|not) and (.domain_suffix|index("direct.org")))'
cfg="$(build "{$B,\"scope\":\"all\",\"bypass_ru\":true,\"presets\":[\"telegram\"]}")"
cj "режим «всё»: пресеты не влияют, final=proxy" '.route.final=="proxy" and .dns.final=="dns-remote" and ([.route.rules[]|select(.outbound=="proxy")]|length)==0'
cj "режим «всё, кроме РФ»: .ru напрямую"        '.route.rules | any(.outbound=="direct" and (.domain_suffix|index(".ru")))'
cfg="$(build "{$B,\"scope\":\"all\",\"bypass_ru\":true,\"direct_domains\":[\"example.org\"]}")"
cj "QUIC режется после правил «напрямую»"       '([.route.rules[]|.action=="reject"]|index(true)) > ([.route.rules[]|.outbound=="direct" and has("domain_suffix")]|index(true))'
cj "reject-правило QUIC присутствует"           '[.route.rules[]|select(.action=="reject" and .port==443)]|length==1'

echo "== функции бэкенда"
eval "$(sed -n '/^valid_ip()/,/^}/p;/^valid_cidr()/,/^}/p;/^cron_spec()/,/^}/p' root/usr/bin/vless)"
valid_ip 192.168.1.1 && ok "valid_ip: 192.168.1.1" || bad "valid_ip: 192.168.1.1"
valid_ip 999.1.1.1 && bad "valid_ip: 999.1.1.1 отклонён" || ok "valid_ip: 999.1.1.1 отклонён"
valid_ip 1.2.3 && bad "valid_ip: 1.2.3 отклонён" || ok "valid_ip: 1.2.3 отклонён"
valid_cidr 10.0.0.0/8 && ok "valid_cidr: 10.0.0.0/8" || bad "valid_cidr: 10.0.0.0/8"
valid_cidr 10.0.0.0/33 && bad "valid_cidr: /33 отклонён" || ok "valid_cidr: /33 отклонён"
valid_cidr 10.0.0.1/ && bad "valid_cidr: пустая маска отклонена" || ok "valid_cidr: пустая маска отклонена"
[ "$(cron_spec 6)" = "17 */6 * * *" ] && ok "cron: каждые 6 часов" || bad "cron: каждые 6 часов"
[ "$(cron_spec 72)" = "17 4 */3 * *" ] && ok "cron: раз в 3 дня" || bad "cron: раз в 3 дня"
[ "$(cron_spec 168)" = "17 4 */7 * *" ] && ok "cron: раз в неделю" || bad "cron: раз в неделю"

echo "== прямой пинг (ping_one_direct)"
eval "$(sed -n '/^ping_one_direct()/,/^}/p' root/usr/bin/vless)"
pdir="$(mktemp -d)"
# Заглушка curl: поведение задаётся переменными FAKE_OUT и FAKE_RC (вывод -w и код выхода).
cat > "$pdir/curl" <<'FAKE'
#!/bin/sh
printf '%s' "$FAKE_OUT"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$pdir/curl"
pp() { ( PATH="$pdir:$PATH"; FAKE_OUT="$1"; FAKE_RC="$2"; export FAKE_OUT FAKE_RC; ping_one_direct "${3:-example.com}" "${4:-443}" ); }
[ "$(pp '404 0.045000 0.120000' 0)" = "45" ]   && ok "пинг: ответ 404 (маскировка Reality) — сервер жив" || bad "пинг: ответ 404 (маскировка Reality)"
[ "$(pp '000 0.050000 0.130000' 52)" = "50" ]  && ok "пинг: пустой ответ после TLS (curl 52) — сервер жив" || bad "пинг: пустой ответ после TLS (curl 52)"
[ "$(pp '000 0.050000 0.130000' 56)" = "50" ]  && ok "пинг: обрыв после TLS (curl 56) — сервер жив" || bad "пинг: обрыв после TLS (curl 56)"
[ -z "$(pp '000 0.050000 0.000000' 35)" ]      && ok "пинг: сброс до конца TLS (DPI) — недоступен" || bad "пинг: сброс до конца TLS (DPI)"
[ -z "$(pp '000 0.000000 0.000000' 28)" ]      && ok "пинг: нет TCP connect — недоступен" || bad "пинг: нет TCP connect"
[ -z "$(pp '000 0.040000 0.000000' 52 example.com 80)" ] && ok "пинг: порт 80 без HTTP-ответа — недоступен" || bad "пинг: порт 80 без HTTP-ответа"
[ "$(pp '200 0.012000 0.000000' 0 example.com 80)" = "12" ] && ok "пинг: порт 80, ответ 200" || bad "пинг: порт 80, ответ 200"
[ -z "$(pp '' 7)" ]                            && ok "пинг: curl ничего не вывел — недоступен" || bad "пинг: curl ничего не вывел"
# IPv6-адрес должен попасть в URL в квадратных скобках
cat > "$pdir/curl" <<'FAKE'
#!/bin/sh
for a in "$@"; do last="$a"; done
printf '%s' "$last" > "$FAKE_URLFILE"
printf '200 0.010000 0.020000'
FAKE
( PATH="$pdir:$PATH"; FAKE_URLFILE="$pdir/url"; export FAKE_URLFILE; ping_one_direct 2001:db8::1 8443 >/dev/null )
[ "$(cat "$pdir/url")" = "https://[2001:db8::1]:8443" ] && ok "пинг: IPv6 в URL в скобках" || bad "пинг: IPv6 в URL в скобках"
rm -rf "$pdir"

rm -rf "$tmp"

echo
sh tests/backend.sh || fail=1
echo
[ $fail -eq 0 ] && echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ" || echo "ЕСТЬ ОШИБКИ"
exit $fail
