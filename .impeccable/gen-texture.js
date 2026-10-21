const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage();
  await page.goto('about:blank');
  const dataUrl = await page.evaluate(() => {
    const c = document.createElement('canvas');
    c.width = 128; c.height = 128;
    const ctx = c.getContext('2d');
    const img = ctx.createImageData(128, 128);
    for (let i = 0; i < img.data.length; i += 4) {
      const v = 118 + Math.floor(Math.random() * 20); // tight mid-gray band
      img.data[i] = v; img.data[i+1] = v; img.data[i+2] = v; img.data[i+3] = 255;
    }
    ctx.putImageData(img, 0, 0);
    return c.toDataURL('image/png');
  });
  fs.writeFileSync(path.join(__dirname, 'mocks/plastic-noise.png'),
    Buffer.from(dataUrl.split(',')[1], 'base64'));
  await browser.close();
  console.log('texture written');
})().catch(e => { console.error(e); process.exit(1); });
