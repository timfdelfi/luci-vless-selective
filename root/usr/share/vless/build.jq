# build.jq — собирает конфиг sing-box (>= 1.12) из списка серверов и настроек.
#
#   jq -n -f build.jq --slurpfile servers servers.json --argjson s '{...}' \
#      --arg secret XXX --arg selected auto --arg logfile /var/run/vless/sing-box.log
#
# Параметры настроек ($s): remote_dns, bootstrap_dns, block_quic, bypass_ru,
# direct_domains[], tun_stack, mtu, log_level, api_port, mixed_port, dns_listen, tun_name,
# scope ("all" | "selected"), presets[], proxy_domains[]
#
# scope = "all"      — через VPN идёт всё (bypass_ru = «кроме российских сайтов»)
# scope = "selected" — через VPN идут только выбранные пресеты и proxy_domains, остальное напрямую
# zapret_udp = true  — UDP 19294-19344 и 50000-50100 (голос Discord) идёт напрямую, мимо туннеля

include "presets";

def ru_suffixes: [
  ".ru", ".su", ".xn--p1ai", ".xn--80asehdb", ".xn--80aswg",
  "yandex.net", "yandex.com", "yastatic.net", "ya.cc",
  "vk.com", "vk.me", "vkuser.net", "userapi.com", "vk-cdn.net", "vkontakte.ru",
  "sberbank.com", "mail.ru", "ok.ru", "mycdn.me", "tinkoff.ru", "kinopoisk.ru",
  "avito.st", "ozon.ru", "wb.ru", "wildberries.ru", "gosuslugi.ru", "mos.ru"
];


# без регулярных выражений: на роутерах jq часто собран без Oniguruma
def isdigits: length > 0 and (explode | all(. >= 48 and . <= 57));
def is_ip:
  (split("/")[0]) as $a
  | ((($a | split(".")) as $p | ($p | length) == 4 and ($p | all(isdigits)))
     or (($a | contains(":")) and ($a | explode | all((. >= 48 and . <= 58) or (. >= 65 and . <= 70) or (. >= 97 and . <= 102)))));
def is_domainlike: is_ip | not;
# Пользователь пишет «*.example.org». nft-часть уже снимала «*.», а здесь оставалось
# голое «*.example.org», из-за чего sing-box check падал и кнопка «Подключить»
# не работала вовсе. Приводим оба пути к одному виду: снять «*.», отбросить прочие «*».
def plain: ltrimstr("*.") | select(contains("*") | not);

def parse_dns($val; $default_type; $default_srv):
  ($val // "") as $v
  | if $v == "" then { type: $default_type, server: $default_srv }
    elif ($v | startswith("tls://")) then
      ($v | ltrimstr("tls://")) as $raw
      | ($raw | split(":")[0]) as $host
      | ($raw | split(":")[1]) as $port
      | { type: "tls", server: $host } + (if $port then { server_port: ($port | tonumber) } else {} end)
    elif ($v | startswith("https://")) then
      ($v | ltrimstr("https://")) as $raw
      | ($raw | split("/")[0]) as $hp
      | ($raw | split("/") | if length > 1 then .[1:] | "/" + join("/") else "/dns-query" end) as $path
      | ($hp | split(":")[0]) as $host
      | ($hp | split(":")[1]) as $port
      | { type: "https", server: $host, path: $path }
        + (if $port then { server_port: ($port | tonumber) } else {} end)
    elif ($v | startswith("udp://")) then
      ($v | ltrimstr("udp://")) as $raw
      | ($raw | split(":")[0]) as $host
      | ($raw | split(":")[1]) as $port
      | { type: "udp", server: $host } + (if $port then { server_port: ($port | tonumber) } else {} end)
    else
      { type: $default_type, server: $v }
    end;

($servers[0] // []) as $all
| ($all | map(select(.supported == true and .outbound != null))) as $list
| if ($list | length) == 0 then error("Нет ни одного поддерживаемого сервера") else . end
| ($list | map("s-" + .id)) as $tags
| (if $selected != "auto" and ($tags | index("s-" + $selected)) != null then "s-" + $selected else "auto" end) as $default
| ($list | map(.server) | unique | map(select(is_domainlike))) as $vpn_hosts

# исключения пользователя (всегда напрямую)
| ($s.direct_domains // [] | map(select(type == "string" and length > 0)) | map(plain)) as $dd
| ($dd | map(select(is_domainlike))) as $dd_domains
| ($dd | map(select(is_ip))) as $dd_ips

# режим «только выбранное»
| (($s.scope // "all") == "selected") as $sel
| presets as $PS
| ($s.presets // [] | map(select(type == "string"))) as $keys
| ($s.proxy_domains // [] | map(select(type == "string" and length > 0)) | map(plain)) as $pd
| ([ $keys[] as $k | ($PS[$k].domains // [])[] ] + ($pd | map(select(is_domainlike))) | unique) as $sel_domains
| ([ $keys[] as $k | ($PS[$k].cidrs // [])[] ] + ($pd | map(select(is_ip))) | unique) as $sel_cidrs
| ($s.block_quic != false) as $quic

| {
    log: { level: ($s.log_level // "warn"), timestamp: true, output: $logfile },

    dns: {
      servers: [
        (parse_dns($s.remote_dns; "tls"; "1.1.1.1") + { tag: "dns-remote", detour: "proxy" }),
        (parse_dns($s.direct_dns; "udp"; ($s.bootstrap_dns // "77.88.8.8")) + { tag: "dns-direct" }),
        { tag: "dns-bootstrap", type: "udp", server: ($s.bootstrap_dns // "77.88.8.8") }
      ],
      rules: (
        (parse_dns($s.direct_dns; "udp"; ($s.bootstrap_dns // "77.88.8.8")).server as $dh
         | if ($dh | is_domainlike) then [{ domain: [$dh], server: "dns-bootstrap" }] else [] end)
        + (if ($vpn_hosts | length) > 0 then [{ domain: $vpn_hosts, server: "dns-direct" }] else [] end)
        + (if ($dd_domains | length) > 0 then [{ domain_suffix: $dd_domains, server: "dns-direct" }] else [] end)
        + (if $sel then
             # выбранные сайты резолвим через VPN, остальные — напрямую
             (if ($sel_domains | length) > 0 then [{ domain_suffix: $sel_domains, server: "dns-remote" }] else [] end)
           else
             (if ($s.bypass_ru == true) then [{ domain_suffix: ru_suffixes, server: "dns-direct" }] else [] end)
           end)
      ),
      final: (if $sel then "dns-direct" else "dns-remote" end),
      strategy: "ipv4_only"
    },

    inbounds: [
      { type: "tun", tag: "tun-in", interface_name: ($s.tun_name // "vless0"),
        address: ["172.19.0.1/30"], mtu: ($s.mtu // 1400),
        auto_route: false, stack: ($s.tun_stack // "system") },
      { type: "direct", tag: "dns-in", listen: ($s.dns_listen // "127.0.0.77"), listen_port: 53 },
      { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: ($s.mixed_port // 2080) }
    ],

    outbounds: (
      [ { type: "selector", tag: "proxy", outbounds: (["auto"] + $tags), default: $default },
        { type: "urltest", tag: "auto", outbounds: $tags,
          url: ($s.auto_test_url // "https://www.gstatic.com/generate_204"),
          interval: ($s.auto_interval // "3m"), tolerance: ($s.auto_tolerance // 80) } ]
      + ($list | map(.outbound + { tag: ("s-" + .id) }))
      + [ { type: "direct", tag: "direct" } ]
    ),

    route: {
      rules: (
        [ { inbound: ["dns-in"], action: "hijack-dns" },
          { action: "sniff" },
          { protocol: "dns", action: "hijack-dns" },
          { ip_is_private: true, outbound: "direct" } ]
        + (if ($dd_ips | length) > 0 then [{ ip_cidr: $dd_ips, outbound: "direct" }] else [] end)
        + (if ($dd_domains | length) > 0 then [{ domain_suffix: $dd_domains, outbound: "direct" }] else [] end)
        # Discord идёт через zapret (nfqws): голос и демонстрация экрана — UDP на этих портах, домена у них нет,
        # поэтому без правила по портам они ушли бы в VPN вместе со всем остальным.
        + (if ($s.zapret_udp == true) then [{ network: "udp", port_range: ["19294:19344", "50000:50100"], outbound: "direct" }] else [] end)
        + (if $sel then
             # режем QUIC только у тех, кто идёт через VPN; остальной трафик не трогаем
             (if $quic and ($sel_domains | length) > 0 then [{ network: "udp", port: 443, domain_suffix: $sel_domains, action: "reject" }] else [] end)
             + (if $quic and ($sel_cidrs | length) > 0 then [{ network: "udp", port: 443, ip_cidr: $sel_cidrs, action: "reject" }] else [] end)
             + (if ($sel_domains | length) > 0 then [{ domain_suffix: $sel_domains, outbound: "proxy" }] else [] end)
             + (if ($sel_cidrs | length) > 0 then [{ ip_cidr: $sel_cidrs, outbound: "proxy" }] else [] end)
           else
             (if ($s.bypass_ru == true) then [{ domain_suffix: ru_suffixes, outbound: "direct" }] else [] end)
           end)
        # QUIC (UDP/443) режем, чтобы браузеры уходили на TCP — через прокси UDP работает не везде.
        # Правило стоит после «напрямую»: исключения и российские сайты QUIC не теряют.
        + (if $quic and ($sel | not) then [{ network: "udp", port: 443, action: "reject" }] else [] end)
      ),
      final: (if $sel then "direct" else "proxy" end),
      default_domain_resolver: "dns-direct"
    },

    experimental: {
      clash_api: { external_controller: ("127.0.0.1:" + (($s.api_port // 9099) | tostring)), secret: $secret }
    }
  }
