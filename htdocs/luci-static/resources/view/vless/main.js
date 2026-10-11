'use strict';
'require view';
'require rpc';
'require ui';

/* ───────────────────────── RPC ───────────────────────── */

var H = function (method, params) {
	return rpc.declare({ object: 'vless', method: method, params: params || [] });
};
var rState      = H('state');
var rStatus     = H('status');
var rConnect    = H('connect');
var rDisconnect = H('disconnect');
var rAdd        = H('add', ['text']);
var rRemove     = H('remove', ['id']);
var rRefresh    = H('refresh', ['id']);
var rSelect     = H('select', ['id']);
var rSet        = H('set', ['settings']);
var rCheck      = H('check');
var rPing       = H('ping');
var rPingDirect = H('ping-direct');
var rPingOne    = H('ping', ['id']);
var rPingOneDirect = H('ping-direct', ['id']);
var rDevices    = H('devices');
var rLogs       = H('logs');
var rClear      = H('clear');
var rClearLog   = H('clearlog');

/* Ретраи для сетевых запросов с экспоненциальной задержкой */
var MAX_RETRIES = 3;
var RETRY_DELAY = 1000;

function withRetry(fn, retries) {
	retries = retries || 0;
	return fn().catch(function (err) {
		if (retries < MAX_RETRIES) {
			return new Promise(function (resolve) {
				setTimeout(function () { resolve(withRetry(fn, retries + 1)); }, RETRY_DELAY * Math.pow(2, retries));
			});
		}
		throw err;
	});
}

var CONNECT_TIMEOUT = 45000;   /* сколько ждём подъёма туннеля, мс */

/* ───────────────────────── стили ───────────────────────── */

var CSS = [
/* Оформление — сдержанное и «инструментальное»: плоские поверхности, тонкие рамки,
   один спокойный акцентный цвет, плотная сетка. Никаких градиентов, свечений и
   пульсаций — интерфейс должен читаться как часть LuCI, а не как витрина. */

/* токены */
'.hv{--bg:#f4f6f8;--card:#fff;--card2:#f7f8fa;--line:#dde1e6;--tx:#1e242c;--tx2:#68727f;--ac:#2d6cb5;--acs:#e9f1f9;--ok:#18794e;--oks:#e7f5ee;--bad:#c0392b;--bads:#fbeceb;--warn:#a86400;--warns:#fdf3e2;--sh:0 1px 2px rgba(20,25,35,.05);--r:6px;',
'  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;color:var(--tx);width:100%;max-width:100%;margin:0;padding:0 0 20px;line-height:1.45;box-sizing:border-box;overflow-x:hidden;font-size:14px}',
'.hv[data-theme=dark]{--bg:#14171b;--card:#1b1f25;--card2:#22272e;--line:#2e343d;--tx:#e4e8ee;--tx2:#98a2b0;--acs:#1b2b3d;--ok:#3fb27f;--oks:#16281f;--bad:#e0655a;--bads:#2b1d1c;--warn:#d9a13c;--warns:#2b2318;--sh:0 1px 2px rgba(0,0,0,.3)}',
'.hv *,.hv *:before,.hv *:after{box-sizing:border-box}',
'.hv svg{width:1em;height:1em;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;display:block}',
'.hv i{font-style:normal;display:inline-flex;align-items:center;justify-content:center}',
'.hv button{font-family:inherit}',
'.hv :focus-visible{outline:2px solid var(--ac);outline-offset:2px}',

/* шапка */
'.hv-top{display:flex;align-items:center;justify-content:space-between;gap:10px 14px;margin:0 0 14px;flex-wrap:wrap}',
'.hv-logo{display:flex;align-items:center;gap:10px;min-width:0}',
'.hv-logo>i{width:30px;height:30px;border-radius:5px;background:var(--ac);color:#fff;font-size:16px;flex:none}',
'.hv-logo b{display:block;font-size:17px;font-weight:650;letter-spacing:-.01em;line-height:1.2}',
'.hv-logo small{display:block;font-size:12px;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
'.hv-topr{display:flex;align-items:center;gap:8px;flex-wrap:wrap;min-width:0}',
'.hv-pill{display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 10px;border-radius:var(--r);background:var(--card);border:1px solid var(--line);font-size:12px;font-weight:600;color:var(--tx2);white-space:nowrap}',
'.hv-pill:before{content:"";width:6px;height:6px;border-radius:50%;background:var(--tx2);opacity:.7}',
'.hv-pill.on{color:var(--ok);background:var(--oks);border-color:transparent}.hv-pill.on:before{background:var(--ok);opacity:1}',
'.hv-pill.busy{color:var(--ac)}.hv-pill.busy:before{background:var(--ac);opacity:1;animation:hvblink 1.1s infinite}',
'.hv-pill.err{color:var(--bad);background:var(--bads);border-color:transparent}.hv-pill.err:before{background:var(--bad);opacity:1}',
'.hv-tabs{display:flex;background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:2px;flex:none}',
'.hv-tabs button{border:0;background:none;color:var(--tx2);font-size:13px;font-weight:550;padding:6px 12px;border-radius:4px;cursor:pointer;display:flex;align-items:center;gap:6px;white-space:nowrap;transition:.12s}',
'.hv-tabs button:hover{color:var(--tx)}',
'.hv-tabs button.on{background:var(--acs);color:var(--ac)}',
'.hv[data-theme=dark] .hv-tabs button.on{color:#7fb4e8}',

/* сетка главной */
'.hv-grid{display:grid;grid-template-columns:minmax(0,1fr) minmax(290px,360px);gap:14px;align-items:start;width:100%;min-width:0}',
'.hv-side{position:sticky;top:10px;min-width:0}',

/* карточки */
'.hv-card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--sh);padding:14px;min-width:0}',
'.hv-h{display:flex;align-items:center;justify-content:space-between;gap:8px;margin:0 0 10px;min-width:0}',
'.hv-h b{font-size:14px;font-weight:650;display:flex;align-items:center;gap:7px;min-width:0}',
'.hv-h b em{font-style:normal;font-size:11px;font-weight:600;color:var(--tx2);background:var(--card2);border:1px solid var(--line);border-radius:3px;padding:0 6px}',
'.hv-h .acts{display:flex;gap:5px}',

/* кнопки */
'.hv-ibtn{border:1px solid var(--line);background:var(--card);color:var(--tx2);width:30px;height:30px;border-radius:var(--r);display:inline-flex;align-items:center;justify-content:center;cursor:pointer;font-size:15px;padding:0;transition:.12s;flex:none}',
'.hv-ibtn:hover{color:var(--ac);border-color:var(--ac);background:var(--acs)}',
'.hv-ibtn.sm{width:26px;height:26px;border-radius:4px;font-size:14px}',
'.hv-ibtn.flat{background:none;border-color:transparent}',
'.hv-ibtn.flat:hover{background:var(--card2);border-color:var(--line);color:var(--ac)}',
'.hv-ibtn.dng:hover{color:var(--bad);border-color:var(--bad);background:var(--bads)}',
'.hv-ibtn.spin svg,.hv-btn.spin>i svg{animation:hvspin 1s linear infinite}',
'.hv-btn{border:1px solid var(--ac);background:var(--ac);color:#fff;font-weight:600;font-size:13px;padding:0 14px;height:34px;border-radius:var(--r);cursor:pointer;transition:.12s;white-space:nowrap;flex:none;display:inline-flex;align-items:center;justify-content:center;gap:6px}',
'.hv-btn:hover{filter:brightness(1.08)}.hv-btn:active{transform:translateY(1px)}.hv-btn[disabled]{opacity:.45;cursor:default;filter:none;transform:none}',
'.hv-btn>i{font-size:14px}',
'.hv-btn.ghost{background:var(--card);color:var(--tx);border-color:var(--line)}',
'.hv-btn.ghost:hover{border-color:var(--ac);color:var(--ac);background:var(--acs);filter:none}',
'.hv-btn.dng{background:var(--card);color:var(--bad);border-color:rgba(192,57,43,.4)}',
'.hv-btn.dng:hover{background:var(--bad);color:#fff;border-color:var(--bad);filter:none}',
'.hv-btn.sm{height:30px;font-size:12.5px;padding:0 11px;border-radius:4px}',

/* добавление + поиск */
'.hv-add{display:flex;gap:8px;align-items:flex-start;margin-bottom:10px;min-width:0}',
'.hv .hv-in,.hv .hv-sel,.hv .hv-ta,.hv .hv-add textarea,.hv .hv-search input{width:100%;border:1px solid var(--line);background:var(--card);color:var(--tx);font:inherit;font-size:13px;border-radius:var(--r);padding:8px 10px;outline:none;transition:border-color .12s,box-shadow .12s;resize:none;min-width:0;margin:0;box-shadow:none;max-width:100%}',
'.hv .hv-add textarea{min-height:34px;height:34px;max-height:110px;padding-top:8px;line-height:17px;overflow:hidden}',
'.hv .hv-in:focus,.hv .hv-sel:focus,.hv .hv-ta:focus,.hv .hv-add textarea:focus,.hv .hv-search input:focus{border-color:var(--ac);box-shadow:0 0 0 2px var(--acs)}',
'.hv .hv-in,.hv .hv-sel{height:34px;padding:0 9px}',
'.hv .hv-sel{appearance:none;-webkit-appearance:none;padding-right:28px;cursor:pointer;background-image:url("data:image/svg+xml;utf8,<svg xmlns=\'http://www.w3.org/2000/svg\' width=\'12\' height=\'12\' viewBox=\'0 0 24 24\' fill=\'none\' stroke=\'%23868f9c\' stroke-width=\'3\' stroke-linecap=\'round\' stroke-linejoin=\'round\'><polyline points=\'6 9 12 15 18 9\'/></svg>");background-repeat:no-repeat;background-position:right 9px center}',
'.hv .hv-ta{min-height:80px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;line-height:1.5;resize:vertical}',
'.hv .hv-in.bad,.hv .hv-sel.bad,.hv .hv-ta.bad{border-color:var(--bad);box-shadow:0 0 0 2px var(--bads)}',
'.hv-tool{display:flex;gap:8px;align-items:center;margin-bottom:8px;min-width:0}',
'.hv-search{position:relative;flex:1;min-width:0}',
'.hv .hv-search input{height:34px;padding:0 10px 0 32px}',
'.hv-search>i{position:absolute;left:10px;top:9px;color:var(--tx2);font-size:15px;pointer-events:none}',

/* список серверов */
'.hv-list{max-height:min(540px,calc(100vh - 300px));min-height:110px;overflow-y:auto;overflow-x:hidden;margin:0 -4px;padding:0 4px;min-width:0}',
'.hv-list::-webkit-scrollbar{width:6px}.hv-list::-webkit-scrollbar-thumb{background:var(--line);border-radius:6px}',
'.hv-grp{display:flex;align-items:center;gap:6px;padding:12px 4px 4px;min-width:0}',
'.hv-grp b{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--tx2)}',
'.hv-grp em{font-style:normal;font-size:11px;color:var(--tx2);font-weight:600}',
'.hv-usage{font-size:11.5px;color:var(--tx2);padding:0 4px 6px}',
'.hv-bar{height:4px;border-radius:4px;background:var(--line);overflow:hidden;margin-top:5px}',
'.hv-bar span{display:block;height:100%;background:var(--ac);border-radius:4px;transition:width .4s}',
'.hv-bar.warn span{background:var(--warn)}.hv-bar.crit span{background:var(--bad)}',
'.hv-bar.inf span{width:100%;background:var(--line)}',
'.hv-row{display:flex;align-items:center;gap:10px;padding:8px 9px;border-radius:var(--r);cursor:pointer;border:1px solid transparent;transition:background .1s,border-color .1s;min-width:0;position:relative}',
'.hv-row:after{content:"";position:absolute;left:8px;right:8px;bottom:0;height:1px;background:var(--line);opacity:.8;pointer-events:none}',
'.hv-row:hover{background:var(--card2)}',
'.hv-row.sel{background:var(--acs);border-color:rgba(45,108,181,.3)}',
'.hv-row.sel:after,.hv-row.off:after{opacity:0}',
'.hv-row.off{opacity:.5;cursor:not-allowed}',
'.hv-fl{width:30px;height:22px;border-radius:3px;flex:none;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;letter-spacing:.03em;background:var(--card2);color:var(--tx2);border:1px solid var(--line)}',
'.hv-fl.auto{background:var(--acs);color:var(--ac);border-color:transparent;font-size:14px}',
'.hv-nm{flex:1;min-width:0;overflow:hidden}',
'.hv-nm b{display:block;font-size:13.5px;font-weight:550;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
'.hv-nm span{display:block;font-size:11px;color:var(--tx2);letter-spacing:.01em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:1px}',
/* Значение пинга занимает фиксированную ширину всегда — иначе цифры «приезжают»
   не с начала строки, а с середины, когда у части серверов замер ещё не готов. */
'.hv-ms{font-size:11.5px;font-weight:600;padding:1px 7px;border-radius:3px;background:var(--card2);color:var(--tx2);flex:none;font-variant-numeric:tabular-nums;min-width:58px;height:19px;display:flex;align-items:center;justify-content:center}',
'.hv-ms.g{color:var(--ok);background:var(--oks)}.hv-ms.y{color:var(--warn);background:var(--warns)}.hv-ms.r{color:var(--bad);background:var(--bads)}',
'.hv-ms.none{background:none}',
'.hv-ms.wait{background:none;position:relative;color:transparent}',
'.hv-ms.wait:after{content:"";position:absolute;left:50%;top:50%;width:11px;height:11px;margin:-5.5px 0 0 -5.5px;border:1.5px solid var(--line);border-top-color:var(--ac);border-radius:50%;animation:hvspin .7s linear infinite}',
/* Кнопки пинга и удаления видны всегда: наводить мышь ради второго действия не нужно */
'.hv-x{flex:none}',
'.hv-empty{text-align:center;padding:26px 10px;color:var(--tx2);font-size:13px}',
'.hv-hero{text-align:center;padding:22px 10px 10px}',
'.hv-hero>i{width:40px;height:40px;border-radius:var(--r);background:var(--card2);color:var(--tx2);font-size:20px;margin:0 auto 10px;border:1px solid var(--line)}',
'.hv-hero h2{margin:0 0 4px;font-size:16px;font-weight:650;border:0;padding:0}',
'.hv-hero p{margin:0 auto 12px;color:var(--tx2);max-width:380px;font-size:13px}',
'.hv-steps{display:flex;gap:6px 14px;justify-content:center;flex-wrap:wrap;color:var(--tx2);font-size:12.5px}',
'.hv-steps span{display:flex;align-items:center;gap:6px}',
'.hv-steps em{font-style:normal;width:19px;height:19px;border-radius:50%;background:var(--card2);color:var(--tx2);font-weight:700;font-size:10.5px;display:flex;align-items:center;justify-content:center;border:1px solid var(--line)}',
'.hv-skel{height:38px;border-radius:var(--r);margin-bottom:5px;background:var(--card2);border:1px solid var(--line)}',

/* правая панель */
'.hv-right{display:flex;flex-direction:column;align-items:center;padding:18px 14px 14px}',
'.hv-power{display:flex;flex-direction:column;align-items:center;width:100%}',
'.hv-pw{display:flex;align-items:center;justify-content:center;margin:0 0 12px}',
'.hv-pb{width:92px;height:92px;border-radius:50%;border:1px solid var(--line);cursor:pointer;background:var(--card2);color:var(--tx2);font-size:36px;display:flex;align-items:center;justify-content:center;transition:.15s;padding:0}',
'.hv-pb:hover{color:var(--ac);border-color:var(--ac)}',
'.hv-pb:active{transform:scale(.98)}',
'.hv-power.on .hv-pb{background:var(--ac);border-color:var(--ac);color:#fff}',
'.hv-power.on .hv-pb:hover{filter:brightness(1.08);color:#fff}',
'.hv-power.busy .hv-pb{color:var(--ac);border-color:var(--ac)}',
'.hv-power.err .hv-pb{color:var(--bad);border-color:var(--bad)}',
'.hv-st{font-size:16px;font-weight:650;letter-spacing:-.01em;text-align:center}',
'.hv-st.on{color:var(--ok)}.hv-st.err{color:var(--bad)}',
'.hv-sub{color:var(--tx2);font-size:12.5px;margin-top:2px;text-align:center;min-height:18px}',
'.hv-timer{font-size:14px;font-weight:600;color:var(--tx2);margin-top:2px;font-variant-numeric:tabular-nums;min-height:20px}',
'.hv-cur{display:flex;align-items:center;gap:10px;margin:14px 0 0;padding:9px 11px;background:var(--card2);border:1px solid var(--line);border-radius:var(--r);width:100%;min-width:0}',
'.hv-stats{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:8px;width:100%}',
'.hv-stat{background:var(--card2);border:1px solid var(--line);border-radius:var(--r);padding:7px 10px;min-width:0}',
'.hv-stat span{display:flex;align-items:center;gap:5px;font-size:10px;color:var(--tx2);font-weight:700;letter-spacing:.04em;text-transform:uppercase}',
'.hv-stat b{display:block;font-size:14px;margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-variant-numeric:tabular-nums}',
'.hv-stat small{display:block;font-size:10.5px;color:var(--tx2);font-weight:500;min-height:14px}',
'.hv-actions{display:flex;gap:8px;margin-top:8px;width:100%}',
'.hv-actions .hv-btn{flex:1}',
'.hv-err{margin-top:12px;padding:9px 11px;border-radius:var(--r);background:var(--bads);color:var(--bad);font-size:12.5px;word-break:break-word;width:100%;text-align:left;border:1px solid rgba(192,57,43,.25)}',

/* баннеры */
'.hv-banner{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;border-radius:var(--r);margin-bottom:10px;font-size:13px;border:1px solid;min-width:0}',
'.hv-banner.bad{background:var(--bads);border-color:rgba(192,57,43,.3)}',
'.hv-banner.warn{background:var(--warns);border-color:rgba(168,100,0,.3)}',
'.hv-banner>i{font-size:17px;flex:none;margin-top:1px}',
'.hv-banner.bad>i{color:var(--bad)}.hv-banner.warn>i{color:var(--warn)}',
'.hv-banner .b{flex:1;min-width:0;word-break:break-word}',
'.hv-banner .b b{display:block;margin-bottom:1px;font-weight:650}',
'.hv-banner .hv-btn{align-self:center}',

/* настройки */
'.hv-set{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;align-items:start;width:100%;min-width:0}',
'.hv-colm{display:flex;flex-direction:column;gap:14px;min-width:0}',
'.hv-sec h3{margin:0 0 2px;font-size:14.5px;font-weight:650;border:0;padding:0;display:flex;align-items:center;gap:8px}',
'.hv-sec h3>i{width:22px;height:22px;border-radius:4px;background:var(--acs);color:var(--ac);font-size:13px}',
'.hv-sec>p{margin:0 0 4px;color:var(--tx2);font-size:12.5px}',
'.hv-opt{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:9px 0;border-top:1px solid var(--line);min-width:0}',
'.hv-opt.first{border-top:0}',
'.hv-opt .t{flex:1;min-width:0}.hv-opt .t b{display:block;font-size:13.5px;font-weight:550}.hv-opt .t span{display:block;font-size:12px;color:var(--tx2);margin-top:1px}',
'.hv-opt .c{flex:none;width:min(200px,44%)}',
'.hv-opt.col{display:block}',
'.hv-opt.col .c{width:auto;margin-top:7px}',
'.hv-hint{font-size:12px;color:var(--tx2);margin-top:7px;line-height:1.5}',
'.hv-sw{position:relative;width:40px;height:22px;flex:none;display:block;cursor:pointer}',
'.hv-sw input{position:absolute;opacity:0;inset:0;margin:0;cursor:pointer;z-index:1;width:100%;height:100%}',
'.hv-sw i{position:absolute;inset:0;border-radius:22px;background:var(--line);transition:.15s;display:block}',
'.hv-sw i:after{content:"";position:absolute;left:2px;top:2px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.2);transition:.15s}',
'.hv-sw input:checked+i{background:var(--ac)}.hv-sw input:checked+i:after{transform:translateX(18px)}',
'.hv-sw input:focus-visible+i{outline:2px solid var(--ac);outline-offset:2px}',
'.hv-seg{display:flex;background:var(--card2);border:1px solid var(--line);border-radius:var(--r);padding:2px;width:100%}',
'.hv-seg button{flex:1;border:0;background:none;color:var(--tx2);font-size:12.5px;font-weight:550;padding:7px 5px;border-radius:4px;cursor:pointer;transition:.12s;line-height:1.25;min-width:0}',
'.hv-seg button:hover{color:var(--tx)}',
'.hv-seg button.on{background:var(--card);color:var(--ac);box-shadow:var(--sh);border:1px solid var(--line)}',
'.hv[data-theme=dark] .hv-seg button.on{color:#7fb4e8}',
'.hv-devs{max-height:200px;overflow:auto;border:1px solid var(--line);border-radius:var(--r);background:var(--card2)}',
'.hv-dev{display:flex;align-items:center;gap:9px;padding:7px 10px;font-size:12.5px;cursor:pointer;border-top:1px solid var(--line);min-width:0;margin:0}',
'.hv-dev:first-child{border-top:0}.hv-dev:hover{background:var(--acs)}',
'.hv-dev input{width:15px;height:15px;accent-color:var(--ac);margin:0;flex:none}',
'.hv-dev div{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
'.hv-dev span{color:var(--tx2);flex:none;font-variant-numeric:tabular-nums}',
'.hv-chips{display:flex;flex-wrap:wrap;gap:6px}',
'.hv-chip{position:relative;display:flex;align-items:center;gap:6px;padding:6px 12px;border:1px solid var(--line);background:var(--card);border-radius:var(--r);font-size:12.5px;font-weight:550;cursor:pointer;user-select:none;transition:.1s;margin:0}',
'.hv-chip input{position:absolute;opacity:0;inset:0;margin:0;cursor:pointer;width:100%;height:100%}',
'.hv-chip:hover{border-color:var(--ac)}',
'.hv-chip.on{background:var(--acs);border-color:var(--ac);color:var(--ac)}',
'.hv[data-theme=dark] .hv-chip.on{color:#7fb4e8}',
'.hv-label{font-size:13.5px;font-weight:600;margin:12px 0 5px}',
'.hv-label span{display:block;font-size:12px;font-weight:400;color:var(--tx2);margin-top:1px}',
'.hv-hwid{display:flex;gap:6px;align-items:center}',
'.hv-hwid code{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;background:var(--card2);border:1px solid var(--line);border-radius:4px;padding:6px 9px;user-select:all;color:var(--tx)}',
'.hv-save{position:sticky;bottom:8px;margin-top:14px;z-index:5}',
'.hv-save .in{display:flex;align-items:center;gap:10px;padding:8px 8px 8px 14px;background:var(--card);border:1px solid var(--line);border-radius:var(--r);box-shadow:0 2px 10px rgba(20,25,35,.12)}',
'.hv-save .msg{flex:1;font-size:13px;color:var(--tx2);min-width:0}',
'.hv-save.dirty .msg{color:var(--warn);font-weight:600}',
'.hv-danger{margin-top:14px;display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;border-color:rgba(192,57,43,.3)}',
'.hv-danger .t b{display:block;font-size:14px}.hv-danger .t span{font-size:12.5px;color:var(--tx2)}',

/* журнал */
'.hv-log{white-space:pre-wrap;word-break:break-all;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px;line-height:1.55;background:var(--card2);border:1px solid var(--line);border-radius:var(--r);padding:10px;height:min(540px,calc(100vh - 260px));min-height:190px;overflow:auto;margin:0;color:var(--tx)}',
'.hv-log .h{display:block;margin:10px 0 4px;color:var(--ac);font-weight:700}.hv-log .h:first-child{margin-top:0}',
'.hv-log .e{color:var(--bad)}.hv-log .w{color:var(--warn)}',
'.hv-auto{display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--tx2);margin:0 4px 0 0}',

'.hv-foot{margin-top:14px;text-align:center;font-size:11.5px;color:var(--tx2)}',
'.hv-toast{position:fixed;left:50%;bottom:22px;transform:translate(-50%,20px);background:#20242b;color:#fff;padding:10px 16px;border-radius:var(--r);font-size:13px;font-weight:600;opacity:0;pointer-events:none;transition:.2s;z-index:9999;max-width:min(90vw,520px);box-shadow:0 4px 16px rgba(0,0,0,.25);text-align:center}',
'.hv-toast.show{opacity:1;transform:translate(-50%,0)}.hv-toast.bad{background:#8f2b21}.hv-toast.warn{background:#8a5300}',

/* адаптив */
'@media (max-width:900px){.hv-grid{grid-template-columns:1fr}.hv-side{position:static;order:-1}.hv-set{grid-template-columns:1fr}.hv-list{max-height:none}}',
'@media (max-width:560px){.hv-top{flex-direction:column;align-items:stretch}.hv-topr{justify-content:space-between}.hv-tabs{flex:1}.hv-tabs button{flex:1;justify-content:center;padding:7px 5px}.hv-tabs button span{display:none}.hv-tabs button.on span{display:inline}',
' .hv-pill{display:none}.hv-card{padding:12px}.hv-add{flex-direction:column}.hv-add .hv-btn{width:100%}.hv-opt .c{width:min(170px,46%)}.hv-save .in{flex-wrap:wrap}.hv-save .msg{flex-basis:100%}.hv-save .hv-btn{flex:1}}',
'@media (prefers-reduced-motion:reduce){.hv *{animation:none!important;transition:none!important}}',
'@keyframes hvspin{to{transform:rotate(360deg)}}',
'@keyframes hvblink{50%{opacity:.25}}'
].join('\n');

/* ───────────────────────── иконки ───────────────────────── */

var ICON = {
	bolt: '<svg viewBox="0 0 24 24"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>',
	globe: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>',
	gear: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
	doc: '<svg viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M16 13H8M16 17H8M10 9H8"/></svg>',
	power: '<svg viewBox="0 0 24 24"><path d="M18.36 6.64a9 9 0 1 1-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>',
	plus: '<svg viewBox="0 0 24 24"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>',
	refresh: '<svg viewBox="0 0 24 24"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>',
	trash: '<svg viewBox="0 0 24 24"><path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>',
	search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>',
	check: '<svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"/></svg>',
	zap: '<svg viewBox="0 0 24 24"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>',
	warn: '<svg viewBox="0 0 24 24"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
	down: '<svg viewBox="0 0 24 24"><line x1="12" y1="5" x2="12" y2="19"/><polyline points="19 12 12 19 5 12"/></svg>',
	up: '<svg viewBox="0 0 24 24"><line x1="12" y1="19" x2="12" y2="5"/><polyline points="5 12 12 5 19 12"/></svg>',
	copy: '<svg viewBox="0 0 24 24"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>',
	route: '<svg viewBox="0 0 24 24"><circle cx="6" cy="19" r="3"/><circle cx="18" cy="5" r="3"/><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/></svg>',
	shield: '<svg viewBox="0 0 24 24"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>',
	sliders: '<svg viewBox="0 0 24 24"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/></svg>',
	laptop: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><line x1="2" y1="20" x2="22" y2="20"/></svg>',
	server: '<svg viewBox="0 0 24 24"><rect x="2" y="3" width="20" height="8" rx="2"/><rect x="2" y="13" width="20" height="8" rx="2"/><line x1="6" y1="7" x2="6.01" y2="7"/><line x1="6" y1="17" x2="6.01" y2="17"/></svg>'
};

function ic(name) {
	var s = E('i');
	s.innerHTML = ICON[name] || '';
	return s;
}

/* ───────────────────────── страны / флаги ───────────────────────── */

/* [код, основы слов (короткие латинские коды разбираются отдельно)] */
var COUNTRY = [
	['DE', /герман|german|deutsch|frankfurt|berlin|falkenstein|nuremberg/i],
	['GB', /великобритан|британи|britain|london|england|british|manchester/i],
	['US', /сша|америк|america|united.?states|new.?york|los.?angeles|miami|chicago|dallas|seattle|ashburn/i],
	['NL', /нидерланд|голланд|holland|amsterdam|netherlands/i],
	['SE', /швеци|sweden|stockholm/i],
	['FI', /финлянд|finland|helsinki/i],
	['NO', /норвег|norway|oslo/i],
	['DK', /дани[яи]|denmark|copenhagen/i],
	['PL', /польш|poland|warsaw/i],
	['IT', /итали|italy|milan|rome/i],
	['RS', /серби|serbia|belgrade/i],
	['BG', /болгар|bulgaria|sofia/i],
	['HR', /хорват|croatia|zagreb/i],
	['CZ', /чехи|czech|prague/i],
	['FR', /франци|france|paris/i],
	['ES', /испани|spain|madrid/i],
	['TR', /турци|turkey|istanbul/i],
	['JP', /япони|japan|tokyo/i],
	['KR', /коре[яий]|korea|seoul/i],
	['SG', /сингапур|singapore/i],
	['HK', /гонконг|hong.?kong/i],
	['CA', /канад|canada|toronto/i],
	['AU', /австрал|australia|sydney/i],
	['CH', /швейцар|switzerland|zurich/i],
	['AT', /австри|austria|vienna/i],
	['BE', /бельги|belgium|brussels/i],
	['IE', /ирланд|ireland|dublin/i],
	['PT', /португал|portugal|lisbon/i],
	['RO', /румын|romania|bucharest/i],
	['LV', /латви|latvia|riga/i],
	['LT', /литв|lithuania|vilnius/i],
	['EE', /эстони|estonia|tallinn/i],
	['KZ', /казахстан|kazakhstan|almaty/i],
	['GE', /грузи|georgia|tbilisi/i],
	['AM', /армени|armenia|yerevan/i],
	['UA', /украин|ukraine|kyiv|kiev/i],
	['RU', /росси|russia|moscow/i],
	['IN', /индия|india|mumbai/i],
	['BR', /бразил|brazil|sao.?paulo/i],
	['AE', /оаэ|эмират|dubai|emirates/i],
	['IL', /израил|israel|tel.?aviv/i]
];
var KNOWN_CODES = {};
COUNTRY.forEach(function (c) { KNOWN_CODES[c[0]] = c[0]; });
KNOWN_CODES.UK = 'GB';

function flagInfo(name) {
	var raw = String(name || '').replace(/^\s+/, ''), code = '', m, i;

	/* эмодзи-флаг в начале имени (два региональных индикатора) */
	if (/^\uD83C[\uDDE6-\uDDFF]\uD83C[\uDDE6-\uDDFF]/.test(raw)) {
		code = String.fromCharCode(raw.charCodeAt(1) - 0xDDE6 + 65) + String.fromCharCode(raw.charCodeAt(3) - 0xDDE6 + 65);
		raw = raw.slice(4);
	}
	/* «DE | Frankfurt», «NL-02 …» */
	if (!code && (m = raw.match(/^([A-Za-z]{2})(?![A-Za-z])/)) && KNOWN_CODES[m[1].toUpperCase()]) {
		code = KNOWN_CODES[m[1].toUpperCase()];
		raw = raw.slice(2);
	}
	/* слова: «Германия», «Amsterdam» */
	if (!code) for (i = 0; i < COUNTRY.length; i++) if (COUNTRY[i][1].test(raw)) { code = COUNTRY[i][0]; break; }
	/* отдельный токен из двух заглавных букв: «Мост US 2» */
	if (!code && (m = raw.match(/(^|[^A-Za-z])([A-Z]{2})(?![A-Za-z])/)) && KNOWN_CODES[m[2]]) code = KNOWN_CODES[m[2]];

	var clean = raw.replace(/^[\s|·•\-–—_:\[\]()]+/, '').replace(/\s+$/, '');
	return { code: code || '··', name: clean || String(name || '') };
}

/* Значок страны — намеренно нейтральный: цветной круг из хэша кода выглядел
   как разноцветные леденцы и ничего не добавлял — страна и так есть в названии. */
function flagEl(code, auto) {
	var f = E('div', { 'class': 'hv-fl' + (auto ? ' auto' : ''), 'aria-hidden': 'true' }, auto ? '' : code);
	if (auto) f.innerHTML = ICON.bolt.replace('<svg', '<svg style="width:14px;height:14px"');
	return f;
}

/* ───────────────────────── форматирование ───────────────────────── */

function fmtBytes(n) {
	n = +n || 0;
	var u = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)).replace('.', ',') + ' ' + u[i];
}

function fmtTime(s) {
	s = Math.max(0, s | 0);
	var h = (s / 3600) | 0, m = ((s % 3600) / 60) | 0, x = s % 60;
	var p = function (v) { return (v < 10 ? '0' : '') + v; };
	return (h ? h + ':' : '') + p(m) + ':' + p(x);
}

function fmtDate(ts) {
	var d = new Date(ts * 1000);
	return ('0' + d.getDate()).slice(-2) + '.' + ('0' + (d.getMonth() + 1)).slice(-2) + '.' + d.getFullYear();
}

function plural(n, one, few, many) {
	var a = Math.abs(n) % 100, b = a % 10;
	if (a > 10 && a < 20) return many;
	if (b > 1 && b < 5) return few;
	if (b === 1) return one;
	return many;
}

/* ключи совпадают с PRESET_KEYS в /usr/bin/vless и presets в build.jq */
var PRESETS = [
	['telegram', 'Telegram', 'Домены и подсети Telegram'],
	['youtube', 'YouTube', ''],
	['discord', 'Discord', ''],
	['meta', 'Meta', 'Instagram, Facebook, WhatsApp, Threads'],
	['x', 'X (Twitter)', ''],
	['ai', 'ИИ-сервисы', 'ChatGPT, Claude, Gemini, Perplexity, Grok'],
	['adult', '18+', 'Сайты для взрослых']
];

/* бэкенд отдаёт IP объектом {ip, country, code} */
function ipText(ip) {
	if (!ip) return '—';
	if (typeof ip === 'string') return ip;
	return (ip.ip || '—') + (ip.code ? ' · ' + ip.code : '');
}

function msClass(ms) { return ms < 250 ? 'g' : ms < 600 ? 'y' : 'r'; }

function isDarkTheme() {
	var els = [document.body, document.documentElement], i;
	for (i = 0; i < els.length; i++) {
		var c = getComputedStyle(els[i]).backgroundColor, m = c && c.match(/[\d.]+/g);
		if (m && m.length >= 3 && !(m.length > 3 && +m[3] === 0))
			return (0.299 * m[0] + 0.587 * m[1] + 0.114 * m[2]) < 140;
	}
	return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
}

function copyText(text) {
	if (navigator.clipboard && window.isSecureContext)
		return navigator.clipboard.writeText(text);
	/* роутер обычно открыт по http — Clipboard API там недоступен */
	return new Promise(function (resolve, reject) {
		var ta = E('textarea', { style: 'position:fixed;left:-9999px;top:0', readonly: 'readonly' });
		ta.value = text;
		document.body.appendChild(ta);
		ta.select();
		try { document.execCommand('copy') ? resolve() : reject(); } catch (e) { reject(e); }
		document.body.removeChild(ta);
	});
}

function sw(checked) {
	var inp = E('input', { type: 'checkbox' });
	inp.checked = !!checked;
	return { el: E('label', { 'class': 'hv-sw' }, [inp, E('i')]), inp: inp };
}

/* сегмент-переключатель: items = [[значение, подпись], …] */
function seg(items, val, onchange) {
	var cur = val, btns = {};
	var el = E('div', { 'class': 'hv-seg', role: 'radiogroup' });
	var set = function (v, user) {
		cur = v;
		items.forEach(function (it) {
			btns[it[0]].className = it[0] === v ? 'on' : '';
			btns[it[0]].setAttribute('aria-checked', it[0] === v ? 'true' : 'false');
		});
		if (onchange) onchange(v, user);
	};
	items.forEach(function (it) {
		var b = E('button', { type: 'button', role: 'radio', click: function () { if (cur !== it[0]) set(it[0], true); } }, it[1]);
		btns[it[0]] = b;
		el.appendChild(b);
	});
	set(val, false);
	return { el: el, get: function () { return cur; }, set: set };
}

/* ───────────────────────── представление ───────────────────────── */

return view.extend({
	load: function () {
		return rState().then(function (s) { return s || null; }).catch(function () { return null; });
	},

	render: function (st) {
		var self = this;
		this.loadFailed = !st;
		this.S = st || { servers: [], sources: [], settings: {}, status: {}, delays: {}, singbox: '', tun: true };
		this.tab = 'main';
		this.busy = null;        /* { kind: 'on' | 'off', since } */
		this.check = null;
		this.search = '';
		this.pinged = false;
		this.pinging = false;   /* идёт «Пинг всех» — показываем крутилки у серверов */
		this.pingOne = null;    /* id одиночного замера */
		this.rate = { down: 0, up: 0 };
		this._prev = null;
		this._upSince = 0;
		this._tick = 0;
		this.autoLog = true;

		this.root = E('div', { 'class': 'hv' });
		this.toastEl = E('div', { 'class': 'hv-toast', role: 'status', 'aria-live': 'polite' });

		var style = E('style');
		style.textContent = CSS;
		this.root.appendChild(style);

		/* шапка */
		this.tabBtns = {};
		var tabs = E('div', { 'class': 'hv-tabs', role: 'tablist' });
		[['main', 'globe', 'Подключение'], ['settings', 'gear', 'Настройки'], ['log', 'doc', 'Журнал']].forEach(function (t) {
			var b = E('button', { type: 'button', role: 'tab', click: function () { self.setTab(t[0]); } }, [ic(t[1]), E('span', {}, t[2])]);
			self.tabBtns[t[0]] = b;
			tabs.appendChild(b);
		});
		this.pillEl = E('div', { 'class': 'hv-pill' }, 'Отключено');
		this.root.appendChild(E('div', { 'class': 'hv-top' }, [
			E('div', { 'class': 'hv-logo' }, [ic('bolt'), E('div', {}, [E('b', {}, 'VPN'), E('small', {}, 'Вставил ссылку — нажал кнопку — работает')])]),
			E('div', { 'class': 'hv-topr' }, [this.pillEl, tabs])
		]));

		this.banners = E('div');
		this.root.appendChild(this.banners);

		this.paneMain = this.buildMain();
		this.paneSet = E('div', { style: 'display:none' });
		this.paneLog = E('div', { style: 'display:none' });
		this.root.appendChild(this.paneMain);
		this.root.appendChild(this.paneSet);
		this.root.appendChild(this.paneLog);
		this.foot = E('div', { 'class': 'hv-foot' });
		this.root.appendChild(this.foot);
		this.root.appendChild(this.toastEl);

		this.buildSettings();
		this.setTab('main');
		this.afterState();

		/* общие часы: таймер раз в секунду, опрос статуса и состояния по расписанию */
		var clock = setInterval(function () {
			if (!document.body.contains(self.root)) { clearInterval(clock); return; }
			self._tick++;
			if (self._tick % 3 === 0) self.root.setAttribute('data-theme', isDarkTheme() ? 'dark' : 'light');
			if (self.phase() === 'on' && self._upSince && self.timerEl)
				self.timerEl.textContent = fmtTime(Math.floor(Date.now() / 1000) - self._upSince);
			if (document.hidden) return;
			var fast = self.busy ? 1 : 3;
			if (self.tab === 'main' || self.tab === 'settings' || self.busy) {
				if (self._tick % 30 === 0) self.refreshAll();
				else if (self._tick % fast === 0) self.pollStatus();
			}
			if (self.tab === 'log' && self.autoLog && self._tick % 3 === 0) self.loadLogs(true);
			if (self.busy && self.busy.kind === 'on' && Date.now() - self.busy.since > CONNECT_TIMEOUT)
				self.failConnect('Туннель не поднялся за ' + (CONNECT_TIMEOUT / 1000) + ' секунд. Смотрите вкладку «Журнал».');
		}, 1000);
		this.root.setAttribute('data-theme', isDarkTheme() ? 'dark' : 'light');
		setTimeout(function () { self.root.setAttribute('data-theme', isDarkTheme() ? 'dark' : 'light'); }, 300);

		if (this.loadFailed) this.refreshAll();
		return this.root;
	},

	handleSave: null, handleSaveApply: null, handleReset: null,

	/* ───── утилиты ───── */

	toast: function (msg, kind) {
		var t = this.toastEl;
		t.textContent = msg;
		t.className = 'hv-toast show' + (kind === true || kind === 'bad' ? ' bad' : kind === 'warn' ? ' warn' : '');
		clearTimeout(this._tt);
		this._tt = setTimeout(function () { t.className = t.className.replace(' show', ''); }, kind ? 5200 : 2600);
	},

	confirmDlg: function (title, text, okLabel, danger, cb) {
		ui.showModal(title, [
			E('p', {}, text),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button', click: ui.hideModal }, 'Отмена'), ' ',
				E('button', { 'class': 'btn cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-action'),
					click: function () { ui.hideModal(); cb(); } }, okLabel)
			])
		]);
	},

	setTab: function (name) {
		var self = this;
		this.tab = name;
		Object.keys(this.tabBtns).forEach(function (k) {
			self.tabBtns[k].className = (k === name ? 'on' : '');
			self.tabBtns[k].setAttribute('aria-selected', k === name ? 'true' : 'false');
		});
		this.paneMain.style.display = name === 'main' ? '' : 'none';
		this.paneSet.style.display = name === 'settings' ? '' : 'none';
		this.paneLog.style.display = name === 'log' ? '' : 'none';
		if (name === 'log') this.loadLogs();
		if (name === 'settings') this.loadDevices();
		if (name === 'main' && this._tick) this.refreshAll();
	},

	servers: function () { return this.S.servers || []; },
	serverById: function (id) {
		var list = this.servers(), i;
		for (i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
		return null;
	},
	metaOf: function (s) {
		return [s.proto, s.net, s.sec].filter(function (x) { return x && x !== 'none'; }).join(' / ').toUpperCase();
	},

	/* ───── главная вкладка ───── */

	buildMain: function () {
		var self = this;
		var left = E('div', { 'class': 'hv-card' });

		/* заголовок списка */
		this.countEl = E('em', {}, '');
		var refreshAllBtn = E('button', { type: 'button', 'class': 'hv-ibtn', title: 'Обновить все подписки', 'aria-label': 'Обновить все подписки',
			click: function (ev) { self.doRefresh('all', ev.currentTarget); } }, [ic('refresh')]);
		left.appendChild(E('div', { 'class': 'hv-h' }, [E('b', {}, [ic('server'), 'Серверы', this.countEl]), E('div', { 'class': 'acts' }, [refreshAllBtn])]));

		/* добавление */
		var addTa = E('textarea', { placeholder: 'vless://…  или  https://подписка…', spellcheck: 'false', rows: 1, 'aria-label': 'Ссылка на подписку или ключ' });
		var fit = function () {
			addTa.style.height = '40px';
			addTa.style.height = Math.min(120, Math.max(40, addTa.scrollHeight)) + 'px';
			addTa.style.overflowY = addTa.scrollHeight > 120 ? 'auto' : 'hidden';
		};
		addTa.addEventListener('input', fit);
		addTa.addEventListener('keydown', function (ev) {
			if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); self.doAdd(); }
		});
		this.addTa = addTa;
		this.addFit = fit;
		this.addBtn = E('button', { type: 'button', 'class': 'hv-btn', click: function () { self.doAdd(); } }, [ic('plus'), E('span', {}, 'Добавить')]);
		left.appendChild(E('div', { 'class': 'hv-add' }, [addTa, this.addBtn]));

		/* поиск и пинг */
		var searchIn = E('input', { type: 'search', placeholder: 'Поиск по серверам', 'aria-label': 'Поиск по серверам' });
		searchIn.addEventListener('input', function () {
			self.search = searchIn.value.trim().toLowerCase();
			self.drawList();
		});
		this.pingAllBtn = E('button', { type: 'button', 'class': 'hv-btn ghost hv-pingall', title: 'Измерить пинг всех серверов',
			click: function () { self.doPing(true); } }, [ic('zap'), E('span', {}, 'Пинг всех')]);
		left.appendChild(E('div', { 'class': 'hv-tool' }, [E('div', { 'class': 'hv-search' }, [ic('search'), searchIn]), this.pingAllBtn]));

		this.listEl = E('div', { 'class': 'hv-list', role: 'listbox', 'aria-label': 'Список серверов' });
		left.appendChild(this.listEl);

		/* правая панель */
		var right = E('div', { 'class': 'hv-card hv-right' });
		this.powerEl = E('div', { 'class': 'hv-power' });
		this.pbEl = E('button', { type: 'button', 'class': 'hv-pb', title: 'Включить / выключить VPN', 'aria-label': 'Включить или выключить VPN',
			click: function () { self.toggle(); } });
		this.pbEl.innerHTML = ICON.power;
		this.powerEl.appendChild(E('div', { 'class': 'hv-pw' }, [this.pbEl]));
		this.stEl = E('div', { 'class': 'hv-st' }, 'Отключено');
		this.subEl = E('div', { 'class': 'hv-sub' });
		this.timerEl = E('div', { 'class': 'hv-timer' });
		this.powerEl.appendChild(this.stEl);
		this.powerEl.appendChild(this.subEl);
		this.powerEl.appendChild(this.timerEl);

		this.curEl = E('div', { style: 'width:100%' });
		this.statsEl = E('div', { style: 'width:100%' });
		this.errEl = E('div', { 'class': 'hv-err', style: 'display:none', role: 'alert' });
		right.appendChild(this.powerEl);
		right.appendChild(this.curEl);
		right.appendChild(this.statsEl);
		right.appendChild(this.errEl);

		return E('div', { 'class': 'hv-grid' }, [left, E('div', { 'class': 'hv-side' }, [right])]);
	},

	drawList: function () {
		var self = this, S = this.S, list = this.listEl, scroll = list.scrollTop;
		list.innerHTML = '';
		var servers = this.servers();
		this.countEl.textContent = servers.length ? String(servers.length) : '';
		this.countEl.style.display = servers.length ? '' : 'none';

		if (!servers.length) {
			if (this.loadFailed) {
				list.appendChild(E('div', { 'class': 'hv-skel' }));
				list.appendChild(E('div', { 'class': 'hv-skel' }));
				list.appendChild(E('div', { 'class': 'hv-skel' }));
				return;
			}
			list.appendChild(E('div', { 'class': 'hv-hero' }, [
				ic('plus'),
				E('h2', {}, 'Пока нет серверов'),
				E('p', {}, 'Вставьте ссылку на подписку или ключ в поле выше и нажмите «Добавить».'),
				E('div', { 'class': 'hv-steps' }, [
					E('span', {}, [E('em', {}, '1'), 'Вставьте ссылку']),
					E('span', {}, [E('em', {}, '2'), 'Нажмите «Добавить»']),
					E('span', {}, [E('em', {}, '3'), 'Включите кнопкой питания'])
				])
			]));
			return;
		}

		var selected = (S.settings && S.settings.selected) || 'auto';
		list.appendChild(this.rowEl({
			id: 'auto', auto: true, name: 'Авто',
			sub: 'Лучший сервер по пингу', ms: null, sel: selected === 'auto', ok: true, removable: false
		}));

		var q = this.search, groups = {}, order = [];
		servers.forEach(function (s) {
			var f = flagInfo(s.name);
			if (q && (f.name + ' ' + s.name + ' ' + s.server + ' ' + (s.proto || '')).toLowerCase().indexOf(q) < 0) return;
			if (!groups[s.source]) { groups[s.source] = []; order.push(s.source); }
			groups[s.source].push({ s: s, f: f });
		});

		var sources = {};
		(S.sources || []).forEach(function (x) { sources[x.id] = x; });
		var multi = (S.sources || []).length > 1 || (S.sources || []).some(function (x) { return x.kind === 'sub'; });

		order.forEach(function (sid) {
			var src = sources[sid];
			if (multi && src) {
				list.appendChild(E('div', { 'class': 'hv-grp' }, [
					E('b', {}, src.name || 'Серверы'),
					E('em', {}, String(groups[sid].length)),
					src.kind === 'sub' ? E('button', { type: 'button', 'class': 'hv-ibtn sm flat', title: 'Обновить эту подписку', 'aria-label': 'Обновить подписку',
						click: function (ev) { self.doRefresh(src.id, ev.currentTarget); } }, [ic('refresh')]) : null,
					E('button', { type: 'button', 'class': 'hv-ibtn sm flat dng', title: 'Удалить ' + (src.kind === 'sub' ? 'подписку' : 'все ключи'), 'aria-label': 'Удалить',
						click: function () { self.doRemove(src.id, src.name, src.kind === 'sub' ? 'подписку' : 'все ключи'); } }, [ic('trash')])
				].filter(Boolean)));
				var u = self.usageEl(src);
				if (u) list.appendChild(u);
			}
			groups[sid].forEach(function (g) {
				var s = g.s;
				list.appendChild(self.rowEl({
					id: s.id, flagCode: g.f.code, name: g.f.name,
					sub: s.supported ? self.metaOf(s) : (s.reason || 'не поддерживается'),
					ms: (S.delays || {})[s.id], sel: selected === s.id, ok: s.supported, removable: true,
					wait: s.supported && (self.pinging || self.pingOne === s.id)
				}));
			});
		});

		if (list.childNodes.length === 1 && q)
			list.appendChild(E('div', { 'class': 'hv-empty' }, 'Ничего не найдено'));
		list.scrollTop = scroll;
	},

	usageEl: function (src) {
		var used = (src.upload || 0) + (src.download || 0), parts = [], bar;
		if (src.total) {
			var pct = Math.min(100, Math.round(used * 100 / src.total));
			parts.push(fmtBytes(used) + ' из ' + fmtBytes(src.total));
			if (src.expire) parts.push('до ' + fmtDate(src.expire));
			bar = E('div', { 'class': 'hv-bar' + (pct >= 95 ? ' crit' : pct >= 80 ? ' warn' : ''), role: 'progressbar', 'aria-valuenow': String(pct), 'aria-valuemin': '0', 'aria-valuemax': '100' }, [E('span')]);
			bar.firstChild.style.width = pct + '%';
		} else if (src.total === 0 || used > 0) {
			/* панель отдаёт total=0 для безлимита */
			if (used > 0) parts.push('Использовано ' + fmtBytes(used));
			if (src.total === 0) parts.push('безлимит');
			if (src.expire) parts.push('до ' + fmtDate(src.expire));
			bar = E('div', { 'class': 'hv-bar inf' }, [E('span')]);
		} else if (src.expire) {
			return E('div', { 'class': 'hv-usage' }, 'Действует до ' + fmtDate(src.expire));
		} else {
			return null;
		}
		return E('div', { 'class': 'hv-usage' }, [parts.join(' · '), bar]);
	},

	rowEl: function (o) {
		var self = this;
		var pick = function () { if (o.ok) self.doSelect(o.id); else self.toast('Этот сервер не поддерживается: ' + o.sub, true); };
		var row = E('div', {
			'class': 'hv-row' + (o.sel ? ' sel' : '') + (o.ok ? '' : ' off'),
			role: 'option', tabindex: '0', 'aria-selected': o.sel ? 'true' : 'false',
			click: pick,
			keydown: function (ev) { if ((ev.key === 'Enter' || ev.key === ' ') && ev.target === row) { ev.preventDefault(); pick(); } }
		}, [
			o.auto ? flagEl('', true) : flagEl(o.flagCode),
			E('div', { 'class': 'hv-nm' }, [E('b', { title: o.name }, o.name), E('span', {}, o.sub)])
		]);
		/* Пинг: крутилка, значение или пустое место той же ширины.
		   Проверяем «измеряем» первым, чтобы при повторном замере показывалась
		   анимация, а не устаревшее число. Кружок с галочкой убран — выбранный
		   сервер и так выделяется синим. */
		if (!o.auto) {
			if (o.wait)
				row.appendChild(E('div', { 'class': 'hv-ms wait', role: 'progressbar', 'aria-label': 'Измеряем задержку' }));
			else if (typeof o.ms === 'number')
				row.appendChild(E('div', { 'class': 'hv-ms ' + msClass(o.ms), title: 'Задержка до сервера' }, o.ms + ' мс'));
			else
				row.appendChild(E('div', { 'class': 'hv-ms none' }));
		}
		if (o.ok && !o.auto)
			row.appendChild(E('button', {
				type: 'button', 'class': 'hv-ibtn sm flat hv-x', title: 'Пинг этого сервера', 'aria-label': 'Пинг этого сервера',
				click: function (ev) { ev.stopPropagation(); self.doPingOne(o.id, ev.currentTarget); }
			}, [ic('zap')]));
		if (o.removable)
			row.appendChild(E('button', {
				type: 'button', 'class': 'hv-ibtn sm flat dng hv-x', title: 'Удалить сервер', 'aria-label': 'Удалить сервер',
				click: function (ev) { ev.stopPropagation(); self.doRemove(o.id, o.name, 'сервер'); }
			}, [ic('trash')]));
		return row;
	},

	routeSummary: function () {
		var s = this.S.settings || {};
		if (s.scope === 'selected') {
			var names = (s.presets || []).map(function (k) {
				for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i][0] === k) return PRESETS[i][1];
				return null;
			}).filter(Boolean);
			if ((s.proxy_domains || []).length) names.push('свои сайты');
			return 'Через VPN: ' + (names.join(', ') || '—');
		}
		return s.bypass_ru ? 'Всё, кроме российских сайтов' : 'Весь трафик через VPN';
	},

	/* ───── кнопка питания и статус ───── */

	phase: function () {
		var st = this.S.status || {};
		if (this.busy && this.busy.kind === 'off') return 'busy';
		if (st.connected) return 'on';
		if (this.busy) return 'busy';
		if (st.phase === 'error' || (st.error && !st.running)) return 'err';
		if (st.phase === 'starting' || st.running) return 'busy';
		return 'off';
	},

	updatePower: function () {
		var me = this, S = this.S, st = S.status || {}, ph = this.phase();
		var disconnecting = this.busy && this.busy.kind === 'off';
		var errMsg = (ph === 'err' && st.error) ? st.error : '';

		this.powerEl.className = 'hv-power ' + ph;
		this.stEl.className = 'hv-st' + (ph === 'on' ? ' on' : ph === 'err' ? ' err' : '');
		this.stEl.textContent = ph === 'on' ? 'Подключено' : ph === 'busy' ? (disconnecting ? 'Отключение…' : 'Подключение…') : ph === 'err' ? 'Ошибка подключения' : 'Отключено';
		this.pbEl.setAttribute('aria-pressed', ph === 'on' ? 'true' : 'false');
		this.pillEl.className = 'hv-pill ' + (ph === 'on' ? 'on' : ph === 'busy' ? 'busy' : ph === 'err' ? 'err' : '');
		this.pillEl.textContent = this.stEl.textContent;

		var servers = this.servers();
		if (ph === 'on') {
			this.subEl.textContent = this.routeSummary();
			if (typeof st.uptime === 'number') this._upSince = Math.floor(Date.now() / 1000) - st.uptime;
			else if (!this._upSince) this._upSince = Math.floor(Date.now() / 1000);
			this.timerEl.textContent = fmtTime(Math.floor(Date.now() / 1000) - this._upSince);
		} else {
			this._upSince = 0;
			this.timerEl.textContent = '';
			this.subEl.textContent = ph === 'busy' ? (disconnecting ? '' : 'Поднимаем туннель, это занимает несколько секунд')
				: ph === 'err' ? 'Нажмите кнопку, чтобы повторить'
				: servers.length ? 'Нажмите, чтобы подключиться' : 'Сначала добавьте ссылку слева';
		}

		/* текущий сервер */
		this.curEl.innerHTML = '';
		var sel = (S.settings && S.settings.selected) || 'auto';
		var activeId = ph === 'on' && st.active ? st.active : (sel !== 'auto' ? sel : '');
		var cur = activeId ? this.serverById(activeId) : null;
		if (servers.length && (cur || sel === 'auto')) {
			var f = cur ? flagInfo(cur.name) : null;
			var subt = cur ? ((sel === 'auto' && ph === 'on' ? 'Авто · ' : '') + this.metaOf(cur)) : 'Лучший сервер выбирается автоматически';
			this.curEl.appendChild(E('div', { 'class': 'hv-cur' }, [
				cur ? flagEl(f.code) : flagEl('', true),
				E('div', { 'class': 'hv-nm' }, [E('b', {}, cur ? f.name : 'Авто'), E('span', {}, subt)])
			]));
		}

		/* статистика */
		this.statsEl.innerHTML = '';
		if (ph === 'on') {
			var ck = this.check || {}, ip = ck.ip || st.ip;
			var cell = function (icon, label, val, small) {
				return E('div', { 'class': 'hv-stat' }, [E('span', {}, [ic(icon), label]), E('b', { title: val }, val), E('small', {}, small || '')]);
			};
			var tgt = sel !== 'auto' ? sel : (st.active || '');
			var pd = tgt && S.delays ? S.delays[tgt] : undefined;
			var delay = typeof pd === 'number' ? pd : (typeof ck.delay === 'number' ? ck.delay : null);
			this.statsEl.appendChild(E('div', { 'class': 'hv-stats' }, [
				cell('zap', 'Пинг', delay != null ? delay + ' мс' : '—'),
				cell('globe', 'IP', ipText(ip)),
				cell('down', 'Получено', fmtBytes(st.down), this.rate.down > 0 ? fmtBytes(this.rate.down) + '/с' : ''),
				cell('up', 'Отправлено', fmtBytes(st.up), this.rate.up > 0 ? fmtBytes(this.rate.up) + '/с' : '')
			]));
			this.statsEl.appendChild(E('div', { 'class': 'hv-actions' }, [
				E('button', { type: 'button', 'class': 'hv-btn ghost sm', title: 'Замерить пинг и определить IP заново',
					click: function (ev) { me.doRecheck(ev.currentTarget); } }, [ic('refresh'), E('span', {}, 'Проверить')])
			]));
		}

		/* ошибка */
		if (errMsg) {
			this.errEl.style.display = '';
			this.errEl.textContent = errMsg;
		} else {
			this.errEl.style.display = 'none';
			this.errEl.textContent = '';
		}
	},

	/* ───── действия ───── */

	toggle: function () {
		var ph = this.phase();
		if (ph === 'on' || ph === 'busy') this.disconnect();
		else this.connect();
	},

	failConnect: function (msg) {
		this.busy = null;
		this.S.status = Object.assign({}, this.S.status, { connected: false, phase: 'error', error: msg });
		this.updatePower();
		this.drawBanners();
		this.toast(msg, true);
	},

	connect: function () {
		var self = this;
		if (!this.servers().length) { this.toast('Сначала добавьте ссылку', true); return; }
		if (this.busy && this.busy.kind === 'on') return;
		this.busy = { kind: 'on', since: Date.now() };
		this.check = null;
		this.pinged = false;
		this.S.status = Object.assign({}, this.S.status, { error: '', phase: 'starting' });
		this.updatePower();
		this.drawBanners();
		rConnect().then(function (r) {
			if (!self.busy) return;
			if (!r || !r.ok) { self.failConnect((r && r.error) || 'Не удалось запустить VPN'); return; }
			self.pollStatus();
		}).catch(function () {
			if (self.busy) self.failConnect('Нет связи с роутером. Попробуйте ещё раз.');
		});
	},

	disconnect: function () {
		var self = this;
		this.busy = { kind: 'off', since: Date.now() };
		this.updatePower();
		rDisconnect().then(function () {
			self.busy = null;
			self.check = null;
			self.pinged = false;
			self.rate = { down: 0, up: 0 };
			self._prev = null;
			self.S.status = Object.assign({}, self.S.status, { connected: false, running: false, phase: 'off', error: '' });
			self.updatePower();
			self.drawBanners();
			self.toast('VPN отключён');
			self.refreshAll();
		}).catch(function () {
			self.busy = null;
			self.toast('Не удалось отключить', true);
			self.pollStatus();
		});
	},

	doAdd: function () {
		var self = this, ta = this.addTa, text = (ta.value || '').trim();
		if (!text) { this.toast('Вставьте ссылку на подписку или ключ', true); ta.focus(); return; }
		if (this._adding) return;
		this._adding = true;
		ta.disabled = true;
		this.addBtn.disabled = true;
		this.addBtn.classList.add('spin');
		var done = function () {
			self._adding = false;
			ta.disabled = false;
			self.addBtn.disabled = false;
			self.addBtn.classList.remove('spin');
		};
		withRetry(function () { return rAdd(text); }).then(function (r) {
			done();
			if (!r || !r.ok) { self.toast((r && r.error) || 'Не удалось добавить', true); return; }
			ta.value = '';
			self.addFit();
			var n = r.added || 0;
			self.toast(r.kind === 'sub'
				? 'Подписка «' + (r.name || '') + '»: ' + n + ' ' + plural(n, 'сервер', 'сервера', 'серверов')
				: 'Добавлено: ' + n + ' ' + plural(n, 'сервер', 'сервера', 'серверов'));
			self.pinged = false;
			self.refreshAll();
		}).catch(function () {
			done();
			self.toast('Роутер не ответил вовремя. Подписка могла добавиться — обновите страницу.', true);
		});
	},

	doSelect: function (id) {
		var self = this;
		if (((this.S.settings || {}).selected || 'auto') === id) return;
		withRetry(function () { return rSelect(id); }).then(function (r) {
			if (!r || !r.ok) { self.toast((r && r.error) || 'Не удалось выбрать', true); return; }
			if (self.S.settings) self.S.settings.selected = id;
			self.drawList();
			self.updatePower();
			/* бэкенд переключает сервер на лету, перезапускать туннель не нужно */
			if (self.phase() === 'on') {
				self.check = null;
				setTimeout(function () { self.doCheck(); }, 1200);
			}
		}).catch(function () { self.toast('Не удалось выбрать сервер', true); });
	},

	doRemove: function (id, name, what) {
		var self = this;
		this.confirmDlg('Удалить ' + (what || 'сервер') + '?', '«' + (name || id) + '» будет удалён' + (what === 'подписку' ? ' вместе со всеми серверами из неё.' : '.'), 'Удалить', true, function () {
			withRetry(function () { return rRemove(id); }).then(function (r) {
				if (!r || !r.ok) { self.toast((r && r.error) || 'Не удалось удалить', true); return; }
				self.toast('Удалено');
				self.refreshAll();
			}).catch(function () { self.toast('Не удалось удалить', true); });
		});
	},

	doRefresh: function (id, btn) {
		var self = this;
		if (btn) { btn.classList.add('spin'); btn.disabled = true; }
		var done = function () { if (btn) { btn.classList.remove('spin'); btn.disabled = false; } };
		withRetry(function () { return rRefresh(id || 'all'); }).then(function (r) {
			done();
			if (!r || !r.ok) {
				self.toast((r && r.error) || 'Не удалось обновить', true);
				self.refreshAll();
				return;
			}
			self.toast(r.updated ? 'Подписки обновлены' : 'Нет подписок для обновления');
			self.refreshAll();
		}).catch(function () { done(); self.toast('Роутер не ответил вовремя', true); });
	},

	doCheck: function () {
		var self = this;
		if (this._checking) return;
		this._checking = true;
		withRetry(rCheck).then(function (r) {
			self._checking = false;
			if (r && r.ok) self.check = r;
			self.updatePower();
		}).catch(function () { self._checking = false; });
	},

	doRecheck: function (btn) {
		var self = this;
		if (btn) btn.disabled = true;
		this.check = null;
		rCheck().then(function (r) {
			if (btn) btn.disabled = false;
			if (r && r.ok) { self.check = r; self.toast('Проверка пройдена · ' + r.delay + ' мс'); }
			else self.toast((r && r.error) || 'Сервер не отвечает', true);
			self.updatePower();
		}).catch(function () { if (btn) btn.disabled = false; self.toast('Проверка не удалась', true); });
		this.doPing();
	},

	/* manual = пользователь нажал «Пинг всех» (показываем результат тостом) */
	doPing: function (manual) {
		var self = this, btn = manual ? this.pingAllBtn : null;
		if (this._pinging) return;
		this._pinging = true;
		this.pinged = true;
		this.pinging = true;
		this.drawList();                    /* крутилки появляются сразу, а не после ответа */
		if (btn) { btn.disabled = true; btn.classList.add('spin'); btn.lastChild.textContent = 'Измеряю…'; }
		var done = function () {
			self._pinging = false;
			self.pinging = false;
			if (btn) { btn.disabled = false; btn.classList.remove('spin'); btn.lastChild.textContent = 'Пинг всех'; }
		};
		/* Если VPN не подключён — прямой пинг, иначе через VPN (точнее) */
		var pingFn = (this.phase() === 'on') ? rPing : rPingDirect;
		withRetry(pingFn).then(function (r) {
			done();
			if (r && r.delays) self.S.delays = r.delays;
			if (manual) {
				var n = r && r.delays ? Object.keys(r.delays).length : 0;
				if (!r || !r.ok) self.toast((r && r.error) || 'Не удалось измерить пинг', true);
				else if (!n) self.toast('Ни один сервер не ответил', true);
				else self.toast('Пинг обновлён: ' + n + ' ' + plural(n, 'сервер', 'сервера', 'серверов') + (r.direct ? ' (прямой)' : ''));
			}
			self.drawList();
			self.updatePower();
		}).catch(function () { done(); self.drawList(); if (manual) self.toast('Роутер не ответил вовремя', true); });
	},

	doPingOne: function (id, btn) {
		var self = this;
		if (!id) { this.toast('Сначала выберите сервер или подключитесь', true); return; }
		this.pingOne = id;
		this.drawList();
		if (btn) { btn.classList.add('spin'); btn.disabled = true; }
		var done = function () {
			self.pingOne = null;
			if (btn) { btn.classList.remove('spin'); btn.disabled = false; }
		};
		var pingFn = (this.phase() === 'on') ? function () { return rPingOne(id); } : function () { return rPingOneDirect(id); };
		withRetry(pingFn).then(function (r) {
			done();
			if (r && r.delays) self.S.delays = r.delays;
			if (!r || !r.ok) self.toast((r && r.error) || 'Сервер не ответил', true);
			else self.toast('Пинг: ' + r.ms + ' мс' + (r.direct ? ' (прямой)' : ''));
			self.drawList();
			self.updatePower();
		}).catch(function () { done(); self.drawList(); self.toast('Не удалось измерить пинг', true); });
	},

	/* ───── опрос ───── */

	applyStatus: function (r) {
		var prevPhase = this.phase(), now = Date.now();
		/* скорость по разнице счётчиков */
		if (r.connected && this._prev && now > this._prev.t && r.down >= this._prev.down && r.up >= this._prev.up) {
			var dt = (now - this._prev.t) / 1000;
			this.rate = { down: (r.down - this._prev.down) / dt, up: (r.up - this._prev.up) / dt };
		} else this.rate = { down: 0, up: 0 };
		this._prev = r.connected ? { t: now, down: r.down || 0, up: r.up || 0 } : null;

		this.S.status = r;
		if (this.busy && this.busy.kind === 'on') {
			if (r.connected) {
				this.busy = null;
				this.toast('VPN подключён');
			} else if (r.phase === 'error' || (r.phase === 'off' && now - this.busy.since > 4000)) {
				this.failConnect(r.error || 'Служба остановилась сразу после запуска. Смотрите вкладку «Журнал».');
				return;
			}
		}
		var ph = this.phase();
		if (ph !== prevPhase || ph === 'on') this.updatePower();
		if (ph !== prevPhase) this.drawBanners();
		if (ph === 'on' && !this.check) this.doCheck();
		if (ph === 'on' && !this.pinged && this.servers().length) this.doPing();
	},

	pollStatus: function () {
		var self = this;
		if (this._polling) return;
		this._polling = true;
		withRetry(rStatus).then(function (r) {
			self._polling = false;
			if (r && typeof r === 'object') self.applyStatus(r);
		}).catch(function () { self._polling = false; });
	},

	refreshAll: function () {
		var self = this;
		withRetry(rState).then(function (st) {
			if (!st) return;
			self.loadFailed = false;
			self.S = st;
			self.afterState();
		}).catch(function () {
			if (!self.servers().length) { self.loadFailed = true; self.drawBanners(); }
		});
	},

	afterState: function () {
		var st = this.S.status || {};
		if (this.busy && this.busy.kind === 'on') {
			if (st.connected) this.busy = null;
			else if (st.phase === 'error') { this.failConnect(st.error || 'Не удалось подключиться'); return; }
		}
		this.drawList();
		this.updatePower();
		this.drawBanners();
		this.foot.textContent = [this.S.singbox ? 'sing-box ' + this.S.singbox : '', this.S.tun ? 'TUN' : ''].filter(Boolean).join(' · ');
		if (this.phase() === 'on' && !this.check) this.doCheck();
		if (this.phase() === 'on' && !this.pinged && this.servers().length) this.doPing();
	},

	drawBanners: function () {
		var self = this, b = this.banners, S = this.S, st = S.status || {};
		b.innerHTML = '';
		var add = function (kind, title, text, action) {
			b.appendChild(E('div', { 'class': 'hv-banner ' + kind, role: kind === 'bad' ? 'alert' : 'status' }, [
				ic('warn'),
				E('div', { 'class': 'b' }, [E('b', {}, title), E('div', {}, text)]),
				action || null
			].filter(Boolean)));
		};
		if (this.loadFailed)
			add('bad', 'Нет связи с роутером', 'Не удалось получить состояние VPN. Проверьте, что служба rpcd запущена, и обновите страницу (Ctrl+F5).',
				E('button', { type: 'button', 'class': 'hv-btn ghost sm', click: function () { self.refreshAll(); } }, 'Повторить'));
		if (S.tun === false)
			add('bad', 'Модуль TUN не найден', 'Установите пакет kmod-tun и перезагрузите роутер.');
		if (st.other_singbox && !st.connected && this.phase() !== 'busy')
			add('warn', 'Запущен другой sing-box', 'Похоже, работает Podkop или другой VPN на sing-box. Остановите его перед подключением — два VPN одновременно мешают друг другу.');
	},

	/* ───── настройки ───── */

	loadDevices: function () {
		var self = this;
		rDevices().then(function (r) {
			self.devList = (r && r.devices) || [];
			self.drawDevices();
		}).catch(function () { self.devList = []; self.drawDevices(); });
	},

	drawDevices: function () {
		if (!this.devBox) return;
		var box = this.devBox, chosen = this.chosenDevices, seen = {};
		box.innerHTML = '';
		var line = function (ip, title, on) {
			var cb = E('input', { type: 'checkbox' });
			cb.checked = on;
			cb.addEventListener('change', function () {
				var i = chosen.indexOf(ip);
				if (cb.checked && i < 0) chosen.push(ip);
				if (!cb.checked && i >= 0) chosen.splice(i, 1);
			});
			box.appendChild(E('label', { 'class': 'hv-dev' }, [cb, E('div', { title: title }, title), E('span', {}, ip)]));
		};
		(this.devList || []).forEach(function (d) { seen[d.ip] = true; line(d.ip, d.name || d.mac, chosen.indexOf(d.ip) >= 0); });
		chosen.forEach(function (ip) { if (!seen[ip]) line(ip, 'Адрес вручную', true); });
		if (!box.childNodes.length) box.appendChild(E('div', { 'class': 'hv-empty' }, 'Устройства не найдены'));
	},

	markDirty: function () {
		if (this._dirty) return;
		this._dirty = true;
		this.updateSaveBar();
	},

	updateSaveBar: function () {
		if (!this.saveBar) return;
		this.saveBar.className = 'hv-save' + (this._dirty ? ' dirty' : '');
		this.saveMsg.textContent = this._dirty ? 'Есть несохранённые изменения' : 'Все изменения сохранены';
		this.saveBtn.disabled = !this._dirty;
		this.revertBtn.style.display = this._dirty ? '' : 'none';
	},

	buildSettings: function () {
		var self = this, s = this.S.settings || {}, F = {};
		this.F = F;
		this._dirty = false;
		this.chosenDevices = (s.devices || []).slice();
		this.chosenPresets = (s.presets || []).slice();
		this.paneSet.innerHTML = '';

		/* кирпичики */
		var section = function (icon, title, desc, kids) {
			return E('section', { 'class': 'hv-card hv-sec' }, [E('h3', {}, [ic(icon), title]), desc ? E('p', {}, desc) : null].concat(kids).filter(Boolean));
		};
		var optRow = function (title, desc, ctl, first, col) {
			return E('div', { 'class': 'hv-opt' + (first ? ' first' : '') + (col ? ' col' : '') }, [
				E('div', { 'class': 't' }, [E('b', {}, title), desc ? E('span', {}, desc) : null].filter(Boolean)),
				E('div', { 'class': 'c' }, Array.isArray(ctl) ? ctl : [ctl])
			]);
		};
		var toggleRow = function (key, title, desc, val, first) {
			var t = sw(val);
			F[key] = { get: function () { return t.inp.checked; } };
			return E('div', { 'class': 'hv-opt' + (first ? ' first' : '') }, [E('div', { 'class': 't' }, [E('b', {}, title), E('span', {}, desc)]), t.el]);
		};
		var select = function (key, items, val) {
			var el = E('select', { 'class': 'hv-sel' }, items.map(function (it) { return E('option', { value: it[0] }, it[1]); }));
			el.value = String(val);
			F[key] = { get: function () { return el.value; }, el: el };
			return el;
		};
		var input = function (key, val, ph) {
			var el = E('input', { 'class': 'hv-in', type: 'text', value: val == null ? '' : val, placeholder: ph || '', spellcheck: 'false' });
			el.addEventListener('input', function () { el.classList.remove('bad'); });
			F[key] = { get: function () { return el.value.trim(); }, el: el };
			return el;
		};
		var area = function (key, list, ph) {
			var el = E('textarea', { 'class': 'hv-ta', spellcheck: 'false', placeholder: ph });
			el.value = (list || []).join('\n');
			el.addEventListener('input', function () { el.classList.remove('bad'); });
			F[key] = { get: function () { return el.value.split(/[\s,;]+/).filter(Boolean); }, el: el };
			return el;
		};

		/* — маршрутизация — */
		var routeNow = s.scope === 'selected' ? 'selected' : (s.bypass_ru ? 'no_ru' : 'all');
		var presetBox = E('div', { style: 'margin-top:12px' });
		var routeHint = E('div', { 'class': 'hv-hint' });
		var hints = {
			all: 'Весь трафик устройств идёт через VPN.',
			no_ru: '.ru, .рф и популярные российские сервисы идут напрямую, остальное — через VPN.',
			selected: 'Через VPN идут только отмеченные сервисы и ваши сайты, остальное — напрямую.'
		};
		F.route = seg([['all', 'Весь трафик'], ['no_ru', 'Кроме РФ'], ['selected', 'Только выбранное']], routeNow, function (v, user) {
			presetBox.style.display = v === 'selected' ? '' : 'none';
			routeHint.textContent = hints[v];
			if (user) self.markDirty();
		});

		var chipBox = E('div', { 'class': 'hv-chips' });
		PRESETS.forEach(function (p) {
			var cb = E('input', { type: 'checkbox' });
			cb.checked = self.chosenPresets.indexOf(p[0]) >= 0;
			var chip = E('label', { 'class': 'hv-chip' + (cb.checked ? ' on' : ''), title: p[2] || '' }, [cb, E('span', {}, p[1])]);
			cb.addEventListener('change', function () {
				var i = self.chosenPresets.indexOf(p[0]);
				if (cb.checked && i < 0) self.chosenPresets.push(p[0]);
				if (!cb.checked && i >= 0) self.chosenPresets.splice(i, 1);
				chip.className = 'hv-chip' + (cb.checked ? ' on' : '');
			});
			chipBox.appendChild(chip);
		});
		presetBox.appendChild(E('div', { 'class': 'hv-label', style: 'margin-top:0' }, ['Сервисы', E('span', {}, 'Отметьте, что должно идти через VPN')]));
		presetBox.appendChild(chipBox);
		presetBox.appendChild(E('div', { 'class': 'hv-label' }, ['Свои сайты через VPN', E('span', {}, 'Домены или подсети, по одному в строке')]));
		presetBox.appendChild(area('proxy_domains', s.proxy_domains, 'example.com\n203.0.113.0/24'));
		presetBox.appendChild(E('div', { 'class': 'hv-hint' }, 'Остальной трафик идёт напрямую, мимо VPN и без обработки роутером. Сервис попадает в VPN, когда его адрес запрошен через роутер.'));

		/* — устройства — */
		this.devBox = E('div', { 'class': 'hv-devs' });
		var devManual = E('input', { 'class': 'hv-in', type: 'text', placeholder: 'Добавить адрес вручную, например 192.168.1.50 (Enter)', style: 'margin-top:8px', spellcheck: 'false' });
		var devWrap = E('div', { style: 'margin-top:10px' }, [this.devBox, devManual]);
		devManual.addEventListener('keydown', function (ev) {
			if (ev.key !== 'Enter') return;
			ev.preventDefault();
			var v = devManual.value.trim();
			if (/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(v) && self.chosenDevices.indexOf(v) < 0) {
				self.chosenDevices.push(v); devManual.value = ''; self.drawDevices(); self.markDirty();
			} else self.toast('Введите IP-адрес, например 192.168.1.50', true);
		});
		F.mode = seg([['all', 'Все'], ['include', 'Только выбранные'], ['exclude', 'Все, кроме выбранных']], s.mode || 'all', function (v, user) {
			devWrap.style.display = v === 'all' ? 'none' : '';
			if (user) self.markDirty();
		});

		/* — DNS — */
		var dnsPresets = ['1.1.1.1', '8.8.8.8', '9.9.9.9'], dnsCur = s.remote_dns || '1.1.1.1';
		var dnsSel = select('dns_sel', [['1.1.1.1', 'Cloudflare (1.1.1.1)'], ['8.8.8.8', 'Google (8.8.8.8)'], ['9.9.9.9', 'Quad9 (9.9.9.9)'], ['custom', 'Свой адрес…']],
			dnsPresets.indexOf(dnsCur) >= 0 ? dnsCur : 'custom');
		var dnsCustom = input('dns_custom', dnsPresets.indexOf(dnsCur) >= 0 ? '' : dnsCur, '1.2.3.4');
		dnsCustom.style.marginTop = '8px';
		var syncDns = function () { dnsCustom.style.display = dnsSel.value === 'custom' ? '' : 'none'; };
		dnsSel.addEventListener('change', syncDns); syncDns();

		/* — HWID — */
		var hwidRow = E('div', { 'class': 'hv-hwid' }, [
			E('code', {}, s.hwid || '—'),
			E('button', { type: 'button', 'class': 'hv-ibtn', title: 'Скопировать HWID', 'aria-label': 'Скопировать HWID',
				click: function () { copyText(s.hwid || '').then(function () { self.toast('HWID скопирован'); }, function () { self.toast('Не удалось скопировать — выделите вручную', true); }); } }, [ic('copy')])
		]);

		var left = E('div', { 'class': 'hv-colm' }, [
			section('power', 'Основное', 'Всё уже настроено — менять ничего не обязательно.', [
				toggleRow('autostart', 'Запускать при включении роутера', 'VPN поднимется сам после перезагрузки', s.autostart, true),
				optRow('Автообновление подписок', 'Подтягивает новые серверы от провайдера', select('update_interval', [['0', 'Выключено'], ['6', 'Каждые 6 часов'], ['12', 'Каждые 12 часов'], ['24', 'Раз в сутки'], ['72', 'Раз в 3 дня'], ['168', 'Раз в неделю']], s.update_interval == null ? 24 : s.update_interval)),
				toggleRow('kill_switch', 'Kill Switch', 'Блокировать интернет у клиентов, если VPN упал', s.kill_switch)
			]),
			section('route', 'Что пускать через VPN', null, [
				F.route.el, routeHint, presetBox,
				E('div', { 'class': 'hv-label' }, ['Свои исключения', E('span', {}, 'Домены или подсети, которые всегда идут напрямую')]),
				area('direct_domains', s.direct_domains, 'example.com\nbank.ru\n203.0.113.0/24')
			]),
			section('laptop', 'Для каких устройств', 'По умолчанию VPN работает для всех, кто подключён к роутеру.', [F.mode.el, devWrap])
		]);

		var right = E('div', { 'class': 'hv-colm' }, [
			section('zap', 'Автовыбор сервера', 'В режиме «Авто» роутер сам замеряет пинг и переключается на самый быстрый сервер.', [
				optRow('Частота проверки', 'Как часто заново измерять пинг', select('auto_interval', [['30s', 'Каждые 30 секунд'], ['1m', 'Каждую минуту'], ['3m', 'Каждые 3 минуты'], ['5m', 'Каждые 5 минут'], ['10m', 'Каждые 10 минут']], s.auto_interval || '3m'), true),
				optRow('Порог переключения', 'Переключится, если другой сервер быстрее на столько мс', input('auto_tolerance', s.auto_tolerance == null ? 80 : s.auto_tolerance, '80')),
				optRow('Адрес проверки', 'URL для замера задержки', input('auto_test_url', s.auto_test_url || 'https://www.gstatic.com/generate_204'), false, true)
			]),
			section('shield', 'DNS и защита', 'Тонкие настройки — обычно трогать не нужно.', [
				toggleRow('dns_vpn', 'DNS через VPN', 'DNS-запросы клиентов уходят через туннель (DoT)', (s.dns_mode || 'vpn') === 'vpn', true),
				optRow('Удалённый DNS', 'DNS-сервер внутри VPN', [dnsSel, dnsCustom], false, true),
				toggleRow('block_ipv6', 'Блокировать IPv6', 'Иначе IPv6-трафик клиентов утечёт мимо VPN', s.block_ipv6 !== false),
				toggleRow('block_quic', 'Блокировать QUIC', 'Отключает UDP/443 — браузеры переходят на TCP (может помочь с YouTube)', s.block_quic !== false),
				toggleRow('bypass_vpn', 'VPN-серверы мимо туннеля', 'Если на телефоне или ПК запущен свой VPN с теми же серверами, он продолжит работать', s.bypass_vpn !== false)
			]),
			section('sliders', 'Дополнительно', null, [
				optRow('Стек TUN', 'system — быстрее, gvisor — совместимее', select('tun_stack', [['system', 'system'], ['gvisor', 'gvisor'], ['mixed', 'mixed']], s.tun_stack || 'system'), true),
				optRow('MTU', 'Размер пакета (обычно 1400)', input('mtu', s.mtu || 1400, '1400')),
				optRow('Интерфейсы', 'Из каких сетей брать клиентов (через пробел)', input('ifaces', (s.ifaces || ['lan']).join(' '), 'lan')),
				optRow('Уровень логов', '', select('log_level', [['error', 'error'], ['warn', 'warn'], ['info', 'info'], ['debug', 'debug'], ['trace', 'trace']], s.log_level || 'warn')),
				optRow('User-Agent', 'При скачивании подписок (Happ — как с Android)', input('user_agent', s.user_agent || 'Happ/3.13.0'), false, true),
				optRow('HWID роутера', 'Идентификатор устройства для лимита в подписке', hwidRow, false, true)
			])
		]);

		this.paneSet.appendChild(E('div', { 'class': 'hv-set' }, [left, right]));

		this.paneSet.appendChild(E('div', { 'class': 'hv-card hv-danger' }, [
			E('div', { 'class': 't' }, [E('b', {}, 'Сбросить серверы'), E('span', {}, 'Удалит все подписки и ключи и остановит VPN. Настройки сохранятся.')]),
			E('button', { type: 'button', 'class': 'hv-btn dng', click: function () { self.resetAll(); } }, [ic('trash'), E('span', {}, 'Удалить все серверы')])
		]));

		this.saveMsg = E('div', { 'class': 'msg' });
		this.saveBtn = E('button', { type: 'button', 'class': 'hv-btn', click: function () { self.saveSettings(); } }, [ic('check'), E('span', {}, 'Сохранить')]);
		this.revertBtn = E('button', { type: 'button', 'class': 'hv-btn ghost', click: function () { self.buildSettings(); self.loadDevices(); self.toast('Изменения отменены'); } }, 'Отменить');
		this.saveBar = E('div', { 'class': 'hv-save' }, [E('div', { 'class': 'in' }, [this.saveMsg, this.revertBtn, this.saveBtn])]);
		this.paneSet.appendChild(this.saveBar);
		this.updateSaveBar();

		/* любое изменение полей → «есть несохранённые».
		   Слушатель снимается перед перестройкой панели, иначе «Отменить»
		   каждый раз добавлял бы ещё одну пару обработчиков. */
		if (this._dirtyBind) {
			this.paneSet.removeEventListener('input', this._dirtyBind);
			this.paneSet.removeEventListener('change', this._dirtyBind);
		}
		this._dirtyBind = function () { self.markDirty(); };
		this.paneSet.addEventListener('input', this._dirtyBind);
		this.paneSet.addEventListener('change', this._dirtyBind);
		this.drawDevices();
	},

	saveSettings: function () {
		var self = this, F = this.F, btn = this.saveBtn;
		var fail = function (field, msg) {
			if (field && field.el) { field.el.classList.add('bad'); field.el.focus(); }
			self.toast(msg, true);
		};

		var custom = F.dns_sel.get() === 'custom';
		var dns = custom ? F.dns_custom.get() : F.dns_sel.get();
		if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(dns) || dns.split('.').some(function (n) { return +n > 255; }))
			return fail(custom ? F.dns_custom : F.dns_sel, 'DNS-сервер должен быть IP-адресом, например 1.1.1.1');
		var mtu = parseInt(F.mtu.get(), 10);
		if (!(mtu >= 1000 && mtu <= 9000)) return fail(F.mtu, 'MTU должен быть от 1000 до 9000');
		var tolerance = parseInt(F.auto_tolerance.get(), 10);
		if (!(tolerance >= 0 && tolerance <= 1000)) return fail(F.auto_tolerance, 'Порог переключения должен быть от 0 до 1000 мс');
		var testUrl = F.auto_test_url.get() || 'https://www.gstatic.com/generate_204';
		if (!/^https?:\/\/\S+$/.test(testUrl)) return fail(F.auto_test_url, 'Адрес проверки должен начинаться с http:// или https://');
		var ifaces = F.ifaces.get().split(/[\s,]+/).filter(Boolean);
		if (!ifaces.length || ifaces.some(function (n) { return !/^[A-Za-z0-9_]{1,15}$/.test(n); }))
			return fail(F.ifaces, 'Интерфейсы: имена сетей через пробел, например lan');
		var mode = F.mode.get();
		if (mode !== 'all' && !this.chosenDevices.length) { this.toast('Выберите хотя бы одно устройство или оставьте «Все»', true); return; }

		var route = F.route.get(), proxyList = F.proxy_domains.get();
		if (route === 'selected' && !this.chosenPresets.length && !proxyList.length) { this.toast('Отметьте хотя бы один сервис или добавьте свой сайт', true); return; }

		var settings = {
			scope: route === 'selected' ? 'selected' : 'all',
			presets: this.chosenPresets,
			proxy_domains: proxyList,
			mode: mode,
			devices: this.chosenDevices,
			update_interval: parseInt(F.update_interval.get(), 10),
			bypass_ru: route === 'no_ru',
			direct_domains: F.direct_domains.get(),
			kill_switch: F.kill_switch.get(),
			dns_mode: F.dns_vpn.get() ? 'vpn' : 'system',
			block_ipv6: F.block_ipv6.get(),
			block_quic: F.block_quic.get(),
			bypass_vpn: F.bypass_vpn.get(),
			remote_dns: dns,
			tun_stack: F.tun_stack.get(),
			mtu: mtu,
			log_level: F.log_level.get(),
			ifaces: ifaces,
			user_agent: F.user_agent.get() || 'Happ/3.13.0',
			autostart: F.autostart.get(),
			auto_interval: F.auto_interval.get(),
			auto_tolerance: tolerance,
			auto_test_url: testUrl
		};
		btn.disabled = true;
		withRetry(function () { return rSet(settings); }).then(function (r) {
			if (!r || !r.ok) { btn.disabled = false; self.toast((r && r.error) || 'Не удалось сохранить', true); return; }
			var running = self.S.status && (self.S.status.running || self.S.status.connected);
			Object.assign(self.S.settings, settings);
			self._dirty = false;
			self.updateSaveBar();
			if (r.ignored && r.ignored.length) {
				self.toast('Сохранено, но часть значений отклонена: ' + r.ignored.slice(0, 4).join(', '), 'warn');
			} else self.toast(running ? 'Сохранено — перезапускаю VPN…' : 'Сохранено');
			if (running) self.connect();
			self.refreshAll();
		}).catch(function () { btn.disabled = false; self.toast('Не удалось сохранить: роутер не ответил', true); });
	},

	resetAll: function () {
		var self = this;
		this.confirmDlg('Удалить все серверы?', 'Все подписки и ключи будут удалены, VPN остановится. Настройки сохранятся. Это действие нельзя отменить.', 'Удалить всё', true, function () {
			self.busy = null;
			rClear().then(function () {
				self.S.status = Object.assign({}, self.S.status, { connected: false, running: false, phase: 'off', error: '' });
				self.check = null;
				self.toast('Серверы удалены');
				self.setTab('main');
				self.refreshAll();
			}).catch(function () { self.toast('Не удалось удалить', true); });
		});
	},

	/* ───── журнал ───── */

	renderLog: function (text) {
		var box = this.logBox, atEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
		box.innerHTML = '';
		if (!text) { box.textContent = 'Журнал пуст'; return; }
		var frag = document.createDocumentFragment();
		text.split('\n').forEach(function (ln) {
			var cls = /^==/.test(ln) ? 'h' : /fatal|error|ERROR/.test(ln) ? 'e' : /warn|WARN/.test(ln) ? 'w' : '';
			frag.appendChild(E('span', cls ? { 'class': cls } : {}, ln + '\n'));
		});
		box.appendChild(frag);
		if (atEnd || !this._logShown) box.scrollTop = box.scrollHeight;
		this._logShown = true;
	},

	loadLogs: function (quiet) {
		var self = this;
		if (!this.logBox) {
			this.logBox = E('pre', { 'class': 'hv-log', tabindex: '0' }, 'Загрузка…');
			var autoCb = E('input', { type: 'checkbox' });
			autoCb.checked = this.autoLog;
			autoCb.addEventListener('change', function () { self.autoLog = autoCb.checked; });
			var refreshBtn = E('button', { type: 'button', 'class': 'hv-ibtn', title: 'Обновить', 'aria-label': 'Обновить журнал', click: function () { self.loadLogs(); } }, [ic('refresh')]);
			var copyBtn = E('button', { type: 'button', 'class': 'hv-ibtn', title: 'Скопировать журнал', 'aria-label': 'Скопировать журнал', click: function () {
				copyText(self.logBox.textContent).then(function () { self.toast('Журнал скопирован'); }, function () { self.toast('Не удалось скопировать — выделите вручную', true); });
			} }, [ic('copy')]);
			var clearBtn = E('button', { type: 'button', 'class': 'hv-ibtn dng', title: 'Очистить журнал sing-box', 'aria-label': 'Очистить журнал', click: function () {
				rClearLog().then(function () { self._logShown = false; self.loadLogs(); });
			} }, [ic('trash')]);
			this.paneLog.appendChild(E('div', { 'class': 'hv-card' }, [
				E('div', { 'class': 'hv-h' }, [E('b', {}, [ic('doc'), 'Журнал']),
					E('div', { 'class': 'acts', style: 'align-items:center' }, [E('label', { 'class': 'hv-auto' }, [autoCb, 'Обновлять']), refreshBtn, copyBtn, clearBtn])]),
				this.logBox,
				E('div', { 'class': 'hv-hint' }, 'Не публикуйте журнал целиком — в нём могут быть адреса ваших серверов.')
			]));
		}
		rLogs().then(function (r) {
			self.renderLog((r && (r.log || r.logs)) || '');
		}).catch(function () {
			if (!quiet) self.logBox.textContent = 'Не удалось загрузить журнал';
		});
	}
});
