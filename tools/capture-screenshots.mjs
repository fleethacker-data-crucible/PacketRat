// Development-only: captures the README screenshots of the PacketRat overview page (docs/screenshots/).
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

const browser = await playwright.chromium.launch({ headless: true });
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
} finally {
  await browser.close();
  server.close();
}
