// Development-only: captures the README screenshots of the PacketRat overview page (docs/screenshots/)
// and the walkthrough screenshots (docs/assets/walkthrough/, Night watch theme).
// Mock data only: serves the shipped Web/ files from a throwaway 127.0.0.1 static server and opens
// the built-in offline demo (?demo=1, the sample mail in Web/app.js). No PowerShell service runs,
// so Outlook, Graph, Lazarette and AI providers are never contacted.
//
//   PACKETRAT_PLAYWRIGHT=<path to playwright package> node tools/capture-screenshots.mjs
//
// Both Fleet themes are captured at 1440x900 with the sidebar expanded: Night watch (dark) and Chart room
// (light), each following the emulated prefers-color-scheme. Headless; no window opens.
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const playwright = require(process.env.PACKETRAT_PLAYWRIGHT || 'playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const web = path.join(root, 'Web');
const out = path.join(root, 'docs', 'screenshots');
const shots = [
  { scheme: 'dark', file: 'overview-night-watch.png' },
  { scheme: 'light', file: 'overview-chart-room.png' },
];
const walkthroughOut = path.join(root, 'docs', 'assets', 'walkthrough');
const nav = (view) => async (page) => { await page.click(`.nav[data-view="${view}"]`); };
const walkthrough = [
  { file: '01-first-launch.png', run: async () => {} },
  { file: '02-action-queue.png', run: nav('triage') },
  { file: '03-draft-response.png', run: async (page) => {
    await nav('triage')(page);
    await page.click('[data-act="draft"][data-key="demo-1"]');
    await page.click('#generateDraft');
    await page.waitForFunction(() => document.querySelector('#draftBody').value.trim().length > 0);
    await page.evaluate(() => document.querySelector('#notice').classList.add('hidden'));
  } },
  { file: '04-ai-intelligence.png', run: nav('report') },
  { file: '05-report-followup.png', run: async (page) => {
    await nav('report')(page);
    await page.click('[data-report-generate-section]');
    await page.waitForSelector('#reportGenerated:not(.hidden)');
    await page.evaluate(() => document.querySelector('#notice').classList.add('hidden'));
    await page.locator('#reportGenerated').evaluate((el) => el.scrollIntoView({ block: 'end' }));
  } },
  { file: '06-dismissal-memory.png', run: async (page) => {
    await nav('triage')(page);
    page.once('dialog', (d) => d.accept('No action needed'));
    await page.click('[data-act="dismiss"][data-key="demo-4"]');
    await page.waitForSelector('#notice:not(.hidden):text("Action updated")');
    await nav('dismissals')(page);
  } },
  { file: '07-configuration.png', run: nav('settings') },
];
const types = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml' };

const server = createServer((req, res) => {
  const name = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname.slice(1)) || 'index.html';
  const file = path.resolve(web, name);
  if (!file.startsWith(web + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
  res.end(fs.readFileSync(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/index.html?demo=1`;

// Segoe UI and Cascadia are Windows fonts. On Linux, system-ui often resolves to Inter, which the Fleet UI
// forbids (UNIFIED-UI.md section 4), so hide Inter from Chromium and resolve the generic families to Liberation
// Sans, the Arial-metric face the stack's Arial fallback would use.
const launchEnv = { ...process.env };
if (process.platform === 'linux' && fs.existsSync('/etc/fonts/fonts.conf')) {
  const conf = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'packetrat-fonts-')), 'fonts.conf');
  fs.writeFileSync(conf, '<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig><include>/etc/fonts/fonts.conf</include>'
    + '<selectfont><rejectfont><pattern><patelt name="family"><string>Inter</string></patelt></pattern>'
    + '<pattern><patelt name="family"><string>Inter Display</string></patelt></pattern></rejectfont></selectfont>'
    + ['system-ui', 'sans-serif'].map((f) => `<alias binding="strong"><family>${f}</family><prefer><family>Liberation Sans</family></prefer></alias>`).join('')
    + '</fontconfig>');
  launchEnv.FONTCONFIG_FILE = conf;
}
const browser = await playwright.chromium.launch({ headless: true, env: launchEnv });
try {
  fs.mkdirSync(out, { recursive: true });
  for (const shot of shots) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: shot.scheme });
    const page = await context.newPage();
    await page.goto(url);
    await page.waitForSelector('#mOpen:text-is("3")');
    await page.waitForTimeout(800);
    await page.screenshot({ path: path.join(out, shot.file) });
    console.log('wrote docs/screenshots/' + shot.file);
    await context.close();
  }
  for (const shot of walkthrough) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: 'dark' });
    const page = await context.newPage();
    await page.goto(url);
    await page.waitForSelector('#mOpen:text-is("3")');
    await shot.run(page);
    await page.waitForTimeout(800);
    await page.screenshot({ path: path.join(walkthroughOut, shot.file) });
    console.log('wrote docs/assets/walkthrough/' + shot.file);
    await context.close();
  }
} finally {
  await browser.close();
  server.close();
}
