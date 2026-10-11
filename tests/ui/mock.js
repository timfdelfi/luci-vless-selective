/* Поддельный бэкенд для стенда интерфейса. Сценарии: connected | off | empty | error | sub */
module.exports = function (scenario) {
  return `(function(){
  var sc = ${JSON.stringify(scenario)};
  var names = ['🇩🇪 Мост — Германия','🇳🇱 Мост — Нидерланды','🇸🇪 Мост — Швеция','🇬🇧 Мост — Великобритания','FI | Финляндия 1','Мост — Польша 1','Мост — Чехия 1','US New York 3','node-x-12 (xhttp)'];
  var servers = sc === 'empty' ? [] : names.map(function (n, i) { return { id: ('a000000' + i), source: i < 7 ? 'sub1' : 'manual', name: n, proto: 'vless', server: 'h' + i + '.example.com', port: 443, net: i === 4 ? 'tcp' : 'grpc', sec: i === 4 ? 'reality' : 'tls', supported: i !== 8, reason: i === 8 ? 'транспорт xhttp не поддерживается' : null }; });
  var sources = sc === 'empty' ? [] : [
    { id: 'sub1', kind: 'sub', name: 'Мосты', count: 7, upload: 3e9, download: 12e9, total: 100e9, expire: 1798000000 },
    { id: 'manual', kind: 'manual', name: 'Мои ключи', count: 2 }];
  var delays = {}; servers.forEach(function (s, i) { if (s.supported) delays[s.id] = [62, 48, 71, 96, 41, 88, 57, 310, 0][i]; });
  var on = sc === 'connected' || sc === 'sub';
  var st = { running: on, connected: on, active: 'a0000004', up: 184e5, down: 2.4e9, uptime: 754, error: sc === 'error' ? 'Интерфейс vless0 не появился: FATAL start service: start inbound/tun[tun-in]: configure tun interface: operation not permitted' : '', other_singbox: false, ip: { ip: '203.0.113.42', country: 'Finland', code: 'FI' }, phase: on ? 'on' : (sc === 'error' ? 'error' : 'off') };
  var settings = { scope: 'all', presets: ['telegram', 'youtube'], proxy_domains: [], mode: 'all', dns_mode: 'vpn', remote_dns: '1.1.1.1', bootstrap_dns: '77.88.8.8', kill_switch: false, block_quic: true, block_ipv6: true, bypass_vpn: true, bypass_ru: false, tun_stack: 'system', mtu: 1400, log_level: 'warn', user_agent: 'Happ/3.13.0', hwid: '9f3a1c7be2d84a05', update_interval: 24, selected: 'auto', auto_interval: '3m', auto_tolerance: 80, auto_test_url: 'https://www.gstatic.com/generate_204', direct_domains: ['bank.ru'], devices: [], ifaces: ['lan'], autostart: true };
  function state() { return { servers: servers, sources: sources, settings: settings, status: st, delays: delays, singbox: '1.12.25', tun: true }; }
  window.MOCK = {
    state: function () { return JSON.parse(JSON.stringify(state())); },
    status: function () { return JSON.parse(JSON.stringify(st)); },
    connect: function () { if (sc === 'fail') return { ok: false, error: 'Не установлен sing-box. Установите: opkg install sing-box' };
      /* Сценарий 'restart' повторяет реальность cmd_connect: он сначала рвёт туннель,
         и status какое-то время отвечает phase:'off'. Раньше интерфейс через 4 секунды
         объявлял это ошибкой, хотя туннель штатно поднимался. */
      if (sc === 'restart') { st.running = false; st.connected = false; st.phase = 'off';
        setTimeout(function () { st.running = true; st.phase = 'starting'; }, 7000);
        setTimeout(function () { st.connected = true; st.phase = 'on'; st.uptime = 0; st.error = ''; }, 9000); return { ok: true, starting: true }; }
      st.running = true; st.phase = 'starting'; setTimeout(function () { st.connected = true; st.phase = 'on'; st.uptime = 0; st.error = ''; }, 2500); return { ok: true, starting: true }; },
    disconnect: function () { st.running = false; st.connected = false; st.phase = 'off'; return { ok: true }; },
    add: function (t) { return t.indexOf('bad') >= 0 ? { ok: false, error: 'Не удалось распознать ссылку.' } : { ok: true, kind: 'sub', name: 'Тест', added: 5 }; },
    remove: function () { return { ok: true }; }, refresh: function () { return { ok: true, updated: 1, failed: 0 }; },
    select: function (id) { settings.selected = id; return { ok: true }; },
    set: function (s) { Object.assign(settings, s); return { ok: true, ignored: s.mtu === 1234 ? ['mtu'] : [] }; },
    check: function () { return { ok: true, delay: 41, ip: st.ip }; },
    ping: function (id) { return id ? { ok: true, ms: 55, delays: delays } : { ok: true, delays: delays }; },
    'ping-direct': function (id) { return id ? { ok: true, ms: 47, delays: delays, direct: true } : { ok: true, delays: delays, direct: true }; },
    devices: function () { return { devices: [{ ip: '192.168.1.20', mac: 'aa', name: 'iPhone-Anna' }, { ip: '192.168.1.31', mac: 'bb', name: 'DESKTOP-PC' }, { ip: '192.168.1.44', mac: 'cc', name: '' }] }; },
    logs: function () { return { log: '== sing-box ==\\n+0300 2026-10-09 21:40:01 INFO inbound/tun[tun-in]: started at vless0\\n+0300 2026-10-09 21:40:09 WARN outbound/vless[s-a0000002]: connection timeout\\n+0300 2026-10-09 21:40:12 ERROR dns: exchange failed\\n\\n== system ==\\nOct  9 21:40:00 router vless: net-up ok\\n' }; },
    clear: function () { return { ok: true }; }, clearlog: function () { return { ok: true }; }
  };
  })();`;
};
