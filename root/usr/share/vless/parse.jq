# parse.jq — преобразует ссылки (vless://, vmess://, trojan://, ss://, hysteria2://)
# и Xray-JSON подписки в серверы формата sing-box.
#
#   jq -R -n -r --arg mode links -f parse.jq < список_ссылок.txt
#   jq    -n -r --arg mode json  -f parse.jq < подписка.json
#
# На выходе по одной строке на сервер:  <ключ>\t<json сервера>
# Ключ нужен оболочке, чтобы получить стабильный id (md5 от ключа).

# ======================================================================
# Помощники БЕЗ регулярных выражений.
# На многих роутерах jq собран без библиотеки Oniguruma: test/match/capture/sub/gsub
# там падают, а разбор ссылок «молча» возвращает пустой список. Поэтому здесь
# используются только split/explode/startswith и т.п.
# ======================================================================

def isws: . == 32 or . == 9 or . == 10 or . == 13;
def strip: explode | until(length == 0 or (.[0] | isws | not); .[1:]) | until(length == 0 or (.[-1] | isws | not); .[:-1]) | implode;
def nows: explode | map(select(isws | not)) | implode;
def isdigits: length > 0 and (explode | all(. >= 48 and . <= 57));

# разрезать по первому / последнему разделителю: [до, после|null]
def cut1($sep): split($sep) as $p | if ($p | length) > 1 then [$p[0], ($p[1:] | join($sep))] else [$p[0], null] end;
def cutlast($sep): split($sep) as $p | if ($p | length) > 1 then [($p[:-1] | join($sep)), $p[-1]] else [null, $p[0]] end;

def hexv:
  if . >= 48 and . <= 57 then . - 48
  elif . >= 65 and . <= 70 then . - 55
  elif . >= 97 and . <= 102 then . - 87
  else null end;

# массив байт UTF-8 -> массив кодовых точек
def b2c:
  . as $b | ($b | length) as $n
  | { i: 0, out: [] }
  | until(.i >= $n;
      $b[.i] as $c
      | if $c < 128 then .out += [$c] | .i += 1
        elif $c >= 240 and (.i + 3) < $n then
          .out += [($c - 240) * 262144 + ($b[.i+1] - 128) * 4096 + ($b[.i+2] - 128) * 64 + ($b[.i+3] - 128)] | .i += 4
        elif $c >= 224 and $c < 240 and (.i + 2) < $n then
          .out += [($c - 224) * 4096 + ($b[.i+1] - 128) * 64 + ($b[.i+2] - 128)] | .i += 3
        elif $c >= 192 and $c < 224 and (.i + 1) < $n then
          .out += [($c - 192) * 64 + ($b[.i+1] - 128)] | .i += 2
        else .out += [65533] | .i += 1 end)
  | .out;

# %XX -> символы (с учётом UTF-8)
def pct:
  if type != "string" then .
  elif contains("%") | not then .
  else
    explode as $e | ($e | length) as $n
    | { i: 0, out: [], buf: [] }
    | until(.i >= $n;
        $e[.i] as $c
        | if $c == 37 and (.i + 2) < $n
             and (($e[.i+1] | hexv) != null) and (($e[.i+2] | hexv) != null)
          then .buf += [($e[.i+1] | hexv) * 16 + ($e[.i+2] | hexv)] | .i += 3
          else .out += (.buf | b2c) | .buf = [] | .out += [$c] | .i += 1 end)
    | (.out + (.buf | b2c)) | implode
  end;

# base64 (обычный и url-safe, с паддингом и без, с переводами строк)
def b64:
  explode
  | map(if . == 45 then 43 elif . == 95 then 47 else . end)
  | map(select(. != 61 and (isws | not)))
  | implode
  | . + ("===="[0: ((4 - (length % 4)) % 4)])
  | @base64d;
def b64safe: try b64 catch "";

def qparse:
  if . == null or . == "" then {}
  else split("&") | map(select(length > 0) | cut1("=") | { key: .[0], value: ((.[1] // "") | pct) })
       | from_entries end;

# scheme://[user@]host[:port][/path][?query][#fragment]
def urlparse:
  cut1("://") as $s
  | if $s[1] == null then error("не ссылка") else . end
  | ($s[1] | cut1("#")) as $f
  | ($f[0] | cut1("?")) as $q
  | ($q[0] | split("/")[0]) as $auth
  | ($auth | cutlast("@")) as $ua
  | ($ua[1]) as $hp
  | (if ($hp | startswith("["))
     then ($hp[1:] | cut1("]")) as $b | [$b[0], (($b[1] // "") | ltrimstr(":"))]
     else ($hp | cut1(":")) | [.[0], (.[1] // "")] end) as $h
  | { scheme: ($s[0] | ascii_downcase),
      user: ($ua[0] | if . == null then null else pct end),
      userraw: $ua[0],
      host: $h[0],
      port: (if ($h[1] | isdigits) then ($h[1] | tonumber) else null end),
      query: ($q[1] | qparse),
      frag: (($f[1] // "") | pct) };

def islink: startswith("vless://") or startswith("vmess://") or startswith("trojan://") or startswith("ss://") or startswith("hysteria2://") or startswith("hy2://");

def truthy: . == "1" or . == "true" or . == true;
def nonempty: if . == null or . == "" then null else . end;

# ---- транспорт ----
def transport($net; $host; $path; $svc; $htype):
  ($net // "tcp") as $n
  | if   $n == "ws" then
      { type: "ws", path: ($path // "/"), headers: (if $host then { Host: $host } else null end) }
    elif $n == "grpc" or $n == "gun" then
      { type: "grpc", service_name: ($svc // "") }
    elif $n == "h2" or $n == "http" then
      { type: "http", host: (if $host then ($host | split(",")) else null end), path: ($path // "/") }
    elif $n == "httpupgrade" then
      { type: "httpupgrade", host: $host, path: ($path // "/") }
    elif ($n == "tcp" or $n == "raw" or $n == "") and ($htype != "http") then null
    else { unsupported: ("транспорт " + $n + " не поддерживается") } end;

def tlsobj($sec; $q; $net):
  if $sec == "tls" or $sec == "reality" then
    { enabled: true,
      server_name: (($q.sni | nonempty) // ($q.peer | nonempty) // (if $net == "ws" or $net == "httpupgrade" then ($q.host | nonempty) else null end)),
      insecure: (if ($q.allowInsecure | truthy) or ($q.insecure | truthy) then true else null end),
      alpn: (($q.alpn | nonempty) | if . then split(",") else null end),
      utls: (if $sec == "reality" or ($q.fp | nonempty) then { enabled: true, fingerprint: (($q.fp | nonempty) // "chrome") } else null end),
      reality: (if $sec == "reality" then { enabled: true, public_key: ($q.pbk // ""), short_id: ($q.sid // "") } else null end) }
  else null end;

def clean:
  walk(if type == "object" then with_entries(select(.value != null and .value != "")) else . end);

def mk($proto; $name; $host; $port; $net; $sec; $ob):
  ($ob | clean) as $o
  | ($o.transport.unsupported // $o.unsupported) as $bad
  | { name: ($name | nonempty // ($host + ":" + ($port | tostring))),
      proto: $proto, server: $host, port: $port, net: ($net // "tcp"), sec: ($sec // "none"),
      supported: ($bad == null), reason: $bad,
      outbound: (if $bad then null else $o end) };

# ---- vless ----
def vless($u):
  $u.query as $q
  | ($q.type // "tcp") as $net
  | ($q.security // "none") as $sec
  | transport($net; ($q.host | nonempty); ($q.path | nonempty); (($q.serviceName // $q.service_name) | nonempty); ($q.headerType | nonempty)) as $tr
  | if ($q.encryption // "none") != "none" then
      mk("vless"; $u.frag; $u.host; $u.port; $net; $sec; { unsupported: "VLESS encryption не поддерживается" })
    else
      mk("vless"; $u.frag; $u.host; $u.port; $net; $sec; {
        type: "vless", server: $u.host, server_port: $u.port, uuid: $u.user,
        flow: ($q.flow | nonempty), packet_encoding: "xudp",
        tls: tlsobj($sec; $q; $net), transport: $tr })
    end;

# ---- trojan ----
def trojan($u):
  $u.query as $q
  | ($q.type // "tcp") as $net
  | ($q.security // "tls") as $sec
  | transport($net; ($q.host | nonempty); ($q.path | nonempty); (($q.serviceName // $q.service_name) | nonempty); ($q.headerType | nonempty)) as $tr
  | mk("trojan"; $u.frag; $u.host; $u.port; $net; $sec; {
      type: "trojan", server: $u.host, server_port: $u.port, password: $u.user,
      tls: tlsobj($sec; $q; $net), transport: $tr });

# ---- vmess ----
def vmess($line):
  ($line[8:] | split("#")[0] | b64 | fromjson) as $j
  | ($j.net // "tcp") as $net
  | (if ($j.tls // "") == "tls" then "tls" else "none" end) as $sec
  | { sni: $j.sni, host: $j.host, alpn: $j.alpn, fp: $j.fp, allowInsecure: (if ($j.allowInsecure | truthy) then "1" else null end) } as $q
  | transport($net; ($j.host | nonempty); ($j.path | nonempty); (($j.serviceName | nonempty) // ($j.path | nonempty)); ($j.type | nonempty)) as $tr
  | mk("vmess"; ($j.ps // ""); $j.add; ($j.port | tonumber); $net; $sec; {
      type: "vmess", server: $j.add, server_port: ($j.port | tonumber), uuid: $j.id,
      security: ($j.scy // "auto"), alter_id: (($j.aid // 0) | tonumber),
      tls: tlsobj($sec; $q; $net), transport: $tr });

# ---- shadowsocks ----
def ss($line):
  ($line | urlparse) as $u
  | (if $u.user != null and $u.user != "" and ($u.user | contains(":")) then
      { m: ($u.user | split(":")[0]), p: ($u.user | split(":")[1:] | join(":")), h: $u.host, port: $u.port, plugin: $u.query.plugin }
    elif $u.userraw != null and $u.userraw != "" then
      ($u.userraw | pct | b64 | split(":")) as $mp
      | { m: $mp[0], p: ($mp[1:] | join(":")), h: $u.host, port: $u.port, plugin: $u.query.plugin }
    else
      ($line[5:] | split("#")[0] | split("?")[0] | b64) as $d
      | ($d | cutlast("@")) as $ua
      | ($ua[1] | cutlast(":")) as $hp
      | ($ua[0] | cut1(":")) as $mp
      | { m: $mp[0], p: ($mp[1] // ""), h: $hp[0], port: ($hp[1] | tonumber), plugin: null }
    end) as $s
  | mk("ss"; $u.frag; $s.h; $s.port; "tcp"; "none";
      if ($s.plugin | nonempty) then { unsupported: "плагин Shadowsocks не поддерживается" }
      else { type: "shadowsocks", server: $s.h, server_port: $s.port, method: $s.m, password: $s.p } end);

# ---- hysteria2 ----
def hy2($u):
  $u.query as $q
  | mk("hysteria2"; $u.frag; $u.host; ($u.port // 443); "udp"; "tls"; {
      type: "hysteria2", server: $u.host, server_port: ($u.port // 443), password: $u.user,
      obfs: (if ($q.obfs | nonempty) then { type: $q.obfs, password: ($q["obfs-password"] // "") } else null end),
      tls: { enabled: true, server_name: ($q.sni | nonempty), insecure: (if ($q.insecure | truthy) then true else null end),
             alpn: (($q.alpn | nonempty) | if . then split(",") else null end) } });

def link2server:
  strip as $l
  | if ($l | startswith("vless://")) then vless($l | urlparse)
    elif ($l | startswith("trojan://")) then trojan($l | urlparse)
    elif ($l | startswith("vmess://")) then vmess($l)
    elif ($l | startswith("ss://")) then ss($l)
    elif ($l | startswith("hysteria2://") or startswith("hy2://")) then hy2($l | urlparse)
    else empty end;

def safe(f): try f catch empty;

# ---- Xray-JSON подписка (формат, который отдают Happ/Remnawave по User-Agent Happ) ----
def xray2server($remarks):
  (.outbounds // [])
  | map(select(.protocol == "vless" or .protocol == "vmess" or .protocol == "trojan" or .protocol == "shadowsocks"))
  | first // empty
  | . as $o
  | ($o.streamSettings // {}) as $ss
  | ($ss.network // "tcp") as $net
  | ($ss.security // "none") as $sec
  | ($ss.realitySettings // $ss.tlsSettings // {}) as $ts
  | { sni: $ts.serverName, fp: $ts.fingerprint, pbk: $ts.publicKey, sid: $ts.shortId,
      alpn: (($ts.alpn // []) | join(",")), allowInsecure: ($ts.allowInsecure | if . == true then "1" else null end),
      host: ($ss.wsSettings.headers.Host // $ss.httpupgradeSettings.host // null) } as $q
  | ($ss.wsSettings.path // $ss.httpupgradeSettings.path // $ss.httpSettings.path // null) as $path
  | ($ss.grpcSettings.serviceName // null) as $svc
  | transport($net; ($q.host | nonempty); ($path | nonempty); ($svc | nonempty); null) as $tr
  | ($o.settings.vnext[0] // $o.settings.servers[0] // $o.settings) as $v
  | ($v.users[0] // $v) as $usr
  | ($v.address // $o.settings.address) as $addr
  | ($v.port // $o.settings.port) as $port
  | if $o.protocol == "vless" then
      mk("vless"; $remarks; $addr; $port; $net; $sec; {
        type: "vless", server: $addr, server_port: $port, uuid: $usr.id,
        flow: ($usr.flow | nonempty), packet_encoding: "xudp",
        tls: tlsobj($sec; $q; $net), transport: $tr })
    elif $o.protocol == "vmess" then
      mk("vmess"; $remarks; $addr; $port; $net; $sec; {
        type: "vmess", server: $addr, server_port: $port, uuid: $usr.id, security: ($usr.security // "auto"),
        tls: tlsobj($sec; $q; $net), transport: $tr })
    elif $o.protocol == "trojan" then
      mk("trojan"; $remarks; $addr; $port; $net; $sec; {
        type: "trojan", server: $addr, server_port: $port, password: $usr.password,
        tls: tlsobj($sec; $q; $net), transport: $tr })
    else
      mk("ss"; $remarks; $addr; $port; "tcp"; "none"; {
        type: "shadowsocks", server: $addr, server_port: $port, method: $usr.method, password: $usr.password })
    end;

def json2servers:
  (if type == "array" then .[] else . end)
  | . as $cfg
  | safe($cfg | xray2server($cfg.remarks // $cfg.ps // ""));

def emit: [((.outbound // del(.name)) | tojson), tojson] | join("\t");

# ---- точка входа ----
if $mode == "json" then (inputs | json2servers | emit)
else (inputs | safe(link2server) | emit) end
