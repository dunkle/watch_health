// HTML design-reference verification only. This does not validate native SwiftUI or Apple APIs.
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');
const assert = require('assert');
(async () => {
  const root = path.resolve(__dirname, '..');
  const content = fs.readFileSync(path.join(root, 'docs/ui-preview-v08.html'));
  const server = http.createServer((req, res) => { res.setHeader('Content-Type', 'text/html; charset=utf-8'); res.end(content); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({viewport:{width:390,height:900}, deviceScaleFactor:1});
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  try {
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.locator('#start').click(); await page.locator('#start').click();
    assert.strictEqual(await page.locator('#markers').textContent(), '2');
    await page.locator('#trace-toggle').click(); assert(await page.locator('#trace').isVisible());
    await page.locator('.nav [data-go="moments"]').click(); assert(await page.locator('#moments').isVisible());
    await page.locator('#moments [data-detail="library"]').click();
    await page.locator('#search').fill('散步'); assert((await page.locator('#detailbody').textContent()).includes('14:32'));
    await page.locator('#search').fill('notfound'); assert((await page.locator('#detailbody').textContent()).includes('没有匹配'));
    await page.locator('#back').click();
    await page.locator('.nav [data-go="review"]').click(); await page.locator('#generate').click();
    assert(await page.locator('#reviewresult').isVisible());
    await page.locator('#language').click(); assert((await page.locator('#reviewtext').textContent()).includes('Simulated review'));
    await page.locator('.nav [data-go="mine"]').click(); assert(await page.locator('#mine').isVisible());
    // Check full-page overflow in both themes/languages at compact and normal phone widths, including larger text.
    for (const width of [320, 390, 430]) {
      await page.setViewportSize({width,height:1000});
      for (const dark of [false,true]) for (const large of [false,true]) {
        await page.evaluate(({dark,large})=>{document.body.classList.toggle('dark',dark);document.getElementById('app').classList.toggle('large',large);},{dark,large});
        for (const locale of ['zh-Hans','en']) {
          await page.evaluate(locale => { if(document.documentElement.lang!== (locale==='en'?'en':'zh-CN'))document.getElementById('language').click(); },locale);
          for (const tab of ['today','moments','review','mine']) {
            await page.locator(`.nav [data-go="${tab}"]`).click();
            const overflow = await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth);
            assert(!overflow,`Page overflow: ${width}, ${dark}, ${large}, ${locale}, ${tab}`);
          }
        }
      }
    }
    // Reference screenshots use fictional data and are explicitly labelled in the image.
    await page.setViewportSize({width:430,height:1000});
    await page.evaluate(()=>{document.body.classList.remove('dark');document.getElementById('app').classList.remove('large');if(document.documentElement.lang==='en')document.getElementById('language').click();});
    await page.reload(); await page.locator('.nav [data-go="today"]').click();
    await page.locator('#trace-toggle').click();
    await page.screenshot({path:path.join(root,'docs/UI-v08-today.png'),fullPage:true});
    await page.locator('#theme').click(); await page.locator('#language').click();
    await page.screenshot({path:path.join(root,'docs/UI-v08-dark.png'),fullPage:true});
    assert.deepStrictEqual(errors,[]);
    console.log('Design HTML verified: simulated actions, local sample search, tabs, bilingual review, 96 layout combinations, light/dark screenshots. Not native UI validation.');
  } finally { await browser.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(error=>{console.error(error);process.exitCode=1;});
