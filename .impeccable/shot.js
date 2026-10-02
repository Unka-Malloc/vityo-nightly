const { chromium } = require('playwright');
const path = require('path').join(__dirname, 'mocks/vityo-step-row.html');
const out = require('path').join(__dirname, 'review') + require('path').sep;
(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto('file://' + path);
  await page.waitForTimeout(1800);
  // FLOW notation is the default first score
  await page.screenshot({ path: out + 'desktop.png' });
  // signals riding the cables mid-run
  await page.click('#runBtn');
  await page.waitForTimeout(900);
  await page.screenshot({ path: out + 'desktop-flow-running.png' });
  // held at the step-11 fault: signal frozen at RENDER's door
  await page.waitForTimeout(1400);
  await page.screenshot({ path: out + 'desktop-held.png' });
  // HELD is not a dead end: slow the tempo, replay the fault under the microscope
  await page.evaluate(() => setBpm(40));
  await page.click('#runBtn'); /* the key now says REPLAY */
  await page.waitForTimeout(1200);
  await page.screenshot({ path: out + 'desktop-replay.png' });
  await page.waitForTimeout(3600); /* the fault re-latches at the same step */
  await page.evaluate(() => setBpm(128));
  // source notation, one tap away
  await page.click('#clearBtn');
  await page.click('#tabSource');
  await page.waitForTimeout(300);
  await page.screenshot({ path: out + 'desktop-source.png' });
  // explorer + permission gate as before
  await page.click('[data-inst="EXP"]');
  await page.waitForTimeout(300);
  await page.screenshot({ path: out + 'desktop-explorer.png' });
  await page.click('[data-inst="AGT"]');
  await page.click('#authBtn');
  await page.waitForTimeout(1000);
  await page.screenshot({ path: out + 'desktop-authorized.png' });
  // the fix is real: consume routeIn in the buffer and the diagnostic clears live
  await page.click('#tabSource');
  await page.evaluate(() => {
    const ed = document.getElementById('editor');
    ed.value = ed.value.replace('  emit staged', '  emit staged\n  emit routeIn');
    ed.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await page.waitForTimeout(300);
  await page.screenshot({ path: out + 'desktop-fixed.png' });
  // the graph answers: routeIn's cable patches itself into MAIN
  await page.click('#tabFlow');
  await page.waitForTimeout(300);
  await page.screenshot({ path: out + 'desktop-patched.png' });
  // a clean buffer passes all sixteen steps
  await page.click('#runBtn');
  await page.waitForTimeout(2600);
  await page.screenshot({ path: out + 'desktop-pass.png' });
  // the generator draws whatever buffer is open: util.styio gets its own board
  await page.evaluate(() => {
    [...document.querySelectorAll('#explorerFiles .frow')].find(b => b.textContent.includes('util.styio'))?.click();
  });
  await page.waitForTimeout(250);
  await page.click('#tabFlow');
  await page.waitForTimeout(350);
  await page.screenshot({ path: out + 'desktop-util-flow.png' });
  // mobile: FLOW defaults, the well pans horizontally
  const m = await browser.newPage();
  await m.setViewportSize({ width: 390, height: 844 });
  await m.goto('file://' + path);
  await m.waitForTimeout(1500);
  await m.screenshot({ path: out + 'mobile.png' });
  await browser.close();
  console.log('done');
})().catch(e => { console.error(e); process.exit(1); });
