// Optional design-preview checks; native app has no Node dependency.
const { chromium } = require('playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
(async () => {
  const root = path.resolve(__dirname, '../docs');
  const server = http.createServer((req, res) => {
    if (req.url !== '/ui-preview.html') { res.writeHead(404); res.end(); return; }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(fs.readFileSync(path.join(root, 'ui-preview.html')));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({
      executablePath: process.env.CHROMIUM_PATH || undefined,
      headless: true,
      args: process.platform === 'linux' ? ['--no-sandbox'] : []
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 1040 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/ui-preview.html`);
    await page.screenshot({ path: path.join(root, 'UI-preview.png'), fullPage: true });
    await page.locator('[data-tab="timeline"]').click();
    await page.locator('#events [data-event="0"]').click();
    await page.getByRole('button', { name: '紧张', exact: true }).click();
    if (await page.locator('#confirmed').textContent() !== '本人确认：紧张') throw Error('Confirmation failed');
    await page.locator('.close').click();
    await page.locator('[data-tab="report"]').click();
    await page.locator('#generate').click();
    if (!(await page.locator('#reportText').textContent()).includes('本人感受：紧张')) throw Error('Summary lost evidence');
    await page.locator('[data-tab="settings"]').click();
    if (!await page.locator('#settings').isVisible()) throw Error('Settings missing');
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator('[data-tab="now"]').click();
    if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw Error('Mobile overflow');
    if (errors.length) throw Error(errors.join('\n'));
    console.log('Preview passed: navigation, detail, confirmation, evidence, settings, responsive layout, no JS errors.');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
