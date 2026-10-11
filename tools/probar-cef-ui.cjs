'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { readFile } = require('node:fs/promises');
const http = require('node:http');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true,
    ...(process.env.CEF_TEST_CHROMIUM ? { executablePath: process.env.CEF_TEST_CHROMIUM } : {}) });
  const server = http.createServer(async (request, response) => {
    const file = new URL(request.url, 'http://localhost').pathname.slice(1);
    const types = { 'index.html': 'text/html', 'app.js': 'text/javascript', 'style.css': 'text/css' };
    if (!types[file]) { response.writeHead(404).end(); return; }
    try {
      const body = await readFile(path.resolve(__dirname, '../scriptfiles/cef/auth', file));
      response.writeHead(200, { 'Content-Type': `${types[file]}; charset=utf-8` }).end(body);
    } catch { response.writeHead(500).end(); }
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const url = `http://127.0.0.1:${server.address().port}/index.html`;
    await page.goto(url);
    assert.equal(await page.locator('#submit').isDisabled(), true);
    assert.match(await page.locator('#status').textContent(), /Vista previa/);
    await page.addInitScript(() => {
      window.sent = [];
      window.listeners = {};
      window.cef = {
        on: (event, callback) => { window.listeners[event] = callback; },
        emit: (event, ...args) => { window.sent.push([event, ...args]); }
      };
    });
    await page.goto(`${url}?session=11&epoch=23`);
    assert.equal(await page.locator('#submit').isDisabled(), true);
    await page.waitForFunction(() => window.sent.some(event => event[0] === 'auth:ready'));
    assert.deepEqual(await page.evaluate(() => window.sent[0]), ['auth:ready', 11, 23]);
    const state = (name, register, busy, message = '') => page.evaluate(
      args => window.listeners['auth:state'](...args), [name, register, busy, message]);
    const submit = () => page.locator('#auth-form').evaluate(form => form.requestSubmit());
    const submissions = () => page.evaluate(() => window.sent.filter(event => event[0] === 'auth:submit'));
    await state('Ana_Santos', true, true);
    assert.match(await page.locator('#heading').textContent(), /Crea tu cuenta/);
    assert.equal(await page.locator('#submit').isDisabled(), true);
    await state('Ana_Santos', true, false);
    assert.match(await page.locator('#heading').textContent(), /Crea tu cuenta/);
    assert.equal(await page.locator('#submit').isDisabled(), false);
    await page.locator('#password').fill('corta');
    await submit();
    assert.equal((await submissions()).length, 0);
    assert.match(await page.locator('#status').textContent(), /8 y 72/);
    await page.locator('#password').fill('Contraseña123');
    await submit();
    assert.equal((await submissions()).length, 0);
    assert.match(await page.locator('#status').textContent(), /Acceso clásico/);
    await page.locator('#password').fill('ValidPass123!');
    await page.getByRole('button', { name: 'Mostrar contraseña' }).click();
    assert.equal(await page.locator('#password').getAttribute('type'), 'text');
    await submit();
    assert.deepEqual(await submissions(), [['auth:submit', 11, 23, 'ValidPass123!']]);
    assert.equal(await page.locator('#password').inputValue(), '');
    assert.equal(await page.locator('#password').getAttribute('type'), 'password');
    assert.equal(await page.locator('#submit').isDisabled(), true);
    await submit();
    assert.equal((await submissions()).length, 1);
    await state('Ana_Santos', false, true);
    assert.match(await page.locator('#heading').textContent(), /Crea tu cuenta/);
    await state('Ana_Santos', false, false, 'Contrasena incorrecta.');
    assert.match(await page.locator('#heading').textContent(), /Bienvenido/);
    assert.equal(await page.locator('#status').textContent(), 'Contrasena incorrecta.');
    await state('<img src=x onerror=alert(1)>', false, false);
    assert.equal(await page.locator('#account-name img').count(), 0);
    assert.equal(await page.locator('#account-name').textContent(), '<img src=x onerror=alert(1)>');
    await state('Ana_Santos', true, false);
    await page.locator('#password').evaluate(input => { input.value = 'A'.repeat(73); });
    await submit();
    assert.equal((await submissions()).length, 1);
    await page.locator('#password').fill('SecretForClassic');
    await page.locator('#classic').click();
    assert.equal(await page.locator('#password').inputValue(), '');
    assert.deepEqual(await page.evaluate(() => window.sent.at(-1)), ['auth:fallback', 11, 23]);
    await page.locator('#password').fill('SecretForCancel');
    await page.locator('#cancel').click();
    assert.equal(await page.locator('#password').inputValue(), '');
    assert.deepEqual(await page.evaluate(() => window.sent.at(-1)), ['auth:cancel', 11, 23]);
    await state('Ana_Santos', true, false);
    await page.setViewportSize({ width: 800, height: 600 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    if (process.env.CEF_TEST_SCREENSHOT) await page.screenshot({ path: process.env.CEF_TEST_SCREENSHOT, fullPage: true });
    await page.goto(`${url}?session=0&epoch=23`);
    assert.equal(await page.locator('#submit').isDisabled(), true);
    assert.deepEqual(await page.evaluate(() => window.sent), []);
    assert.deepEqual(errors, []);
    console.log('[CEF UI] Registro/login, errores, envios duplicados, limpieza de clave y vista previa: OK.');
  } finally {
    await new Promise(resolve => server.close(resolve));
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
