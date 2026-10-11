// Скриншоты и проверки интерфейса в headless Chromium.
//   sh build-docs.sh            — Linux
//   npx playwright install chromium && node tests/ui/shot.js [outdir]
// Своё расположение браузера можно задать переменной PW_CHROMIUM.
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..', '..');
const src = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/vless/main.js'), 'utf8');
const mock = require('./mock.js');
const out = process.argv[2] || path.join(__dirname, 'out');
fs.mkdirSync(out, { recursive: true });
let failed = 0;
const ok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) failed = 1; };

async function open(browser, scenario, { w = 1280, h = 900, dark = false, lag } = {}) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 1, colorScheme: dark ? 'dark' : 'light' });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await page.goto('file://' + path.join(__dirname, 'harness.html'));
  await page.evaluate(`document.body.className='${dark ? 'dark' : 'light'}'; ${lag ? 'window.MOCK_LAG=' + lag + ';' : ''}`);
  await page.evaluate(mock(scenario));
  await page.evaluate(s => window.start(s), src);
  await page.waitForTimeout(500);
  return { page, errors, ctx };
}
const text = (page) => page.evaluate(() => document.body.innerText);

(async () => {
  const launchOpts = { args: ['--no-sandbox'] };
  if (process.env.PW_CHROMIUM) launchOpts.executablePath = process.env.PW_CHROMIUM;
  const browser = await chromium.launch(launchOpts);

  console.log('== подключено, светлая тема');
  let { page, errors } = await open(browser, 'connected');
  await page.screenshot({ path: out + '/connected.png' });
  let t = await text(page);
  ok(!/\bnull\b|undefined|\[object/.test(t), 'нет «null»/«undefined»/[object Object] в тексте');
  ok(/Подключено/.test(t) && /203\.0\.113\.42 · FI/.test(t), 'статус и IP со страной');
  ok(/14,0 ГБ из 93,1 ГБ/.test(t), 'остаток трафика подписки');
  ok(/Германия/.test(t) && !/🇩🇪/.test(t), 'эмодзи-флаг убран из названия');
  ok(await page.locator('.hv-fl', { hasText: 'DE' }).count() >= 1 && await page.locator('.hv-fl', { hasText: 'FI' }).count() >= 1, 'коды стран: DE, FI определены');
  ok(await page.locator('.hv-fl', { hasText: 'US' }).count() >= 1, 'код US из «US New York 3»');
  ok(await page.locator('.hv-row.off').count() === 1, 'неподдерживаемый сервер приглушён');
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'нет горизонтальной прокрутки');
  // выбор сервера на лету, без повторного connect
  const before = await page.evaluate(() => window.__calls.length);
  await page.locator('.hv-row', { hasText: 'Швеция' }).click();
  await page.waitForTimeout(300);
  const calls = await page.evaluate((b) => window.__calls.slice(b), before);
  ok(calls.some(c => c.startsWith('select')) && !calls.some(c => c.startsWith('connect')), 'выбор сервера не перезапускает туннель');
  ok(await page.locator('.hv-row.sel', { hasText: 'Швеция' }).count() === 1, 'выбранный сервер подсвечен');
  // удаление через подтверждение
  await page.locator('.hv-row', { hasText: 'Польша' }).hover();
  await page.locator('.hv-row', { hasText: 'Польша' }).locator('.dng').click();
  ok(await page.locator('#modal').count() === 1, 'удаление требует подтверждения');
  await page.evaluate(() => document.getElementById('modal').remove());
  // поиск
  await page.fill('.hv-search input', 'чех');
  await page.waitForTimeout(100);
  ok(await page.locator('.hv-row:not(:first-child)').count() === 1, 'поиск фильтрует список');
  ok(errors.length === 0, 'нет ошибок в консоли ' + errors.join('; '));
  await page.context().close();

  console.log('== отключено / тёмная тема / подключение по кнопке');
  ({ page, errors } = await open(browser, 'off', { dark: true }));
  await page.screenshot({ path: out + '/off_dark.png' });
  ok(/Отключено/.test(await text(page)), 'статус «Отключено»');
  // Без работающего туннеля пинг должен идти по прямому каналу (метод ping-direct)
  await page.click('.hv-pingall');
  await page.waitForTimeout(400);
  ok(await page.evaluate(() => window.__calls.some(c => c.startsWith('ping-direct'))),
     'без VPN пинг идёт через ping-direct');
  ok(await page.evaluate(() => window.__calls.filter(c => c.startsWith('ping-direct')).length === 1),
     'прямой пинг вызвал ровно один раз');
  await page.click('.hv-pb');
  await page.waitForTimeout(400);
  ok(/Подключение…/.test(await text(page)), 'после клика — «Подключение…»');
  await page.screenshot({ path: out + '/connecting_dark.png' });
  await page.waitForTimeout(6000);
  ok(/Подключено/.test(await text(page)), 'через поллинг дошли до «Подключено»');
  await page.screenshot({ path: out + '/connected_dark.png' });
  await page.click('.hv-pb');
  await page.waitForTimeout(500);
  ok(/Отключено/.test(await text(page)), 'кнопка снова выключает VPN');
  ok(errors.length === 0, 'нет ошибок в консоли ' + errors.join('; '));
  await page.context().close();

  console.log('== ошибки запуска');
  ({ page, errors } = await open(browser, 'fail'));
  await page.click('.hv-pb');
  await page.waitForTimeout(500);
  t = await text(page);
  ok(/Ошибка подключения/.test(t) && /Не установлен sing-box/.test(t), 'ошибка запуска показана, а не «подключено»');
  await page.screenshot({ path: out + '/error.png' });
  await page.context().close();
  ({ page } = await open(browser, 'error'));
  ok(/Интерфейс vless0 не появился/.test(await text(page)), 'ошибка из статуса показана');
  await page.context().close();

  console.log('== пустой экран');
  ({ page } = await open(browser, 'empty'));
  await page.screenshot({ path: out + '/empty.png' });
  t = await text(page);
  ok(/Пока нет серверов/.test(t) && /Сначала добавьте ссылку/.test(t), 'подсказка первого запуска');
  await page.fill('textarea', 'bad link');
  await page.click('.hv-add .hv-btn');
  await page.waitForTimeout(300);
  ok(/Не удалось распознать/.test(await text(page)), 'ошибка добавления показана тостом');
  await page.context().close();

  console.log('== настройки');
  ({ page, errors } = await open(browser, 'connected', { h: 1000 }));
  await page.click('.hv-tabs button:nth-child(2)');
  await page.waitForTimeout(400);
  await page.screenshot({ path: out + '/settings.png', fullPage: true });
  ok(await page.locator('.hv-save.dirty').count() === 0 && await page.locator('.hv-save .hv-btn:not(.ghost)').isDisabled(), 'без изменений «Сохранить» неактивна');
  await page.locator('.hv-seg button', { hasText: 'Только выбранное' }).click();
  ok(await page.locator('.hv-save.dirty').count() === 1, 'изменение → «Есть несохранённые изменения»');
  await page.locator('.hv-chip', { hasText: 'Discord' }).click();
  await page.screenshot({ path: out + '/settings_selected.png', fullPage: true });
  // валидация
  await page.locator('.hv-seg button', { hasText: 'Весь трафик' }).click();
  const mtu = page.locator('.hv-opt', { hasText: 'MTU' }).locator('input');
  await mtu.fill('12');
  await page.locator('.hv-save .hv-btn:not(.ghost)').click();
  ok(await mtu.evaluate(e => e.classList.contains('bad')), 'неверный MTU подсвечен красным');
  ok(await page.evaluate(() => !window.__calls.some(c => c.startsWith('set'))), '…и не отправляется на роутер');
  await mtu.fill('1234');
  await page.locator('.hv-save .hv-btn:not(.ghost)').click();
  await page.waitForTimeout(400);
  ok(/часть значений отклонена: mtu/.test(await text(page)), 'отклонённые бэкендом значения показаны');
  ok(await page.evaluate(() => window.__calls.some(c => c.startsWith('connect'))), 'при работающем VPN сохранение перезапускает туннель');
  ok(errors.length === 0, 'нет ошибок в консоли ' + errors.join('; '));
  await page.context().close();

  console.log('== настройки, тёмная тема');
  ({ page } = await open(browser, 'connected', { h: 1000, dark: true }));
  await page.click('.hv-tabs button:nth-child(2)');
  await page.waitForTimeout(400);
  await page.screenshot({ path: out + '/settings_dark.png', fullPage: true });
  await page.context().close();

  console.log('== журнал');
  ({ page } = await open(browser, 'connected'));
  await page.click('.hv-tabs button:nth-child(3)');
  await page.waitForTimeout(400);
  await page.screenshot({ path: out + '/log.png' });
  ok(await page.locator('.hv-log .e').count() === 1 && await page.locator('.hv-log .w').count() === 1, 'ошибки и предупреждения подсвечены');
  await page.context().close();

  console.log('== мобильная версия');
  ({ page, errors } = await open(browser, 'connected', { w: 390, h: 844 }));
  await page.screenshot({ path: out + '/mobile.png', fullPage: true });
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'на телефоне нет горизонтальной прокрутки');
  const order = await page.evaluate(() => { const p = document.querySelector('.hv-power').getBoundingClientRect().top, l = document.querySelector('.hv-list').getBoundingClientRect().top; return p < l; });
  ok(order, 'на телефоне кнопка питания выше списка');
  await page.click('.hv-tabs button:nth-child(2)');
  await page.waitForTimeout(300);
  await page.screenshot({ path: out + '/mobile_settings.png', fullPage: true });
  ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'настройки на телефоне без горизонтальной прокрутки');
  ok(errors.length === 0, 'нет ошибок в консоли ' + errors.join('; '));
  await page.context().close();

  await browser.close();
  console.log(failed ? 'ЕСТЬ ОШИБКИ В ИНТЕРФЕЙСЕ' : 'ТЕСТЫ ИНТЕРФЕЙСА ПРОЙДЕНЫ');
  process.exit(failed);
})();
