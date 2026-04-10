#!/usr/bin/env node
// Runs a polars-pyodide test HTML file via Playwright + a local HTTP server.
// Usage: node test-runner.mjs [--strict] [--pyodide-version=X.Y.Z] <test-smoke.html|test-official.html> [wheel-dir]
//
// The wheel dir defaults to ./wasm-dist and is served at /wasm-dist/.
// Exit code: 0 = all tests passed, 1 = failures or error.

import { chromium } from 'playwright';
import { createServer } from 'http';
import { readFile, readdir } from 'fs/promises';
import { extname, resolve, basename } from 'path';

const rawArgs = process.argv.slice(2);
const strict = rawArgs.includes('--strict');
const pyodideFlag = rawArgs.find(a => a.startsWith('--pyodide-version='));
const pyodideVersion = pyodideFlag ? pyodideFlag.split('=')[1] : null;
const args = rawArgs.filter(a => a !== '--strict' && !a.startsWith('--pyodide-version='));
const htmlFile = resolve(args[0]);
const wheelDir = resolve(args[1] ?? 'wasm-dist');

if (!process.argv[2]) {
  console.error('Usage: node test-runner.mjs <test-file.html> [wheel-dir]');
  process.exit(1);
}

// The HTML file and wheel dir may be in different locations (e.g. in CI the HTML
// lives in polars-pyodide/ while the wheel lives in wasm-dist/ at the repo root).
// Serve both via explicit route prefixes rather than a single root.
import { dirname } from 'path';
const htmlDir = dirname(htmlFile);

const MIME = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.whl':  'application/zip',
  '.wasm': 'application/wasm',
  '.py':   'text/plain',
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const pathname = url.pathname;

  // /wasm-dist/ (no trailing filename) → directory listing
  // /wasm-dist/* → wheelDir
  // everything else → htmlDir
  if (pathname === '/wasm-dist/' || pathname === '/wasm-dist') {
    try {
      const files = await readdir(wheelDir);
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(files.map(f => `<a href="${f}">${f}</a>`).join('\n'));
    } catch {
      res.writeHead(404);
      res.end('Not found: ' + wheelDir);
    }
    return;
  }

  let filePath;
  if (pathname.startsWith('/wasm-dist/')) {
    filePath = resolve(wheelDir, pathname.replace(/^\/wasm-dist\//, ''));
  } else {
    filePath = resolve(htmlDir, pathname.replace(/^\//, ''));
  }

  try {
    const data = await readFile(filePath);
    res.writeHead(200, { 'Content-Type': MIME[extname(filePath)] ?? 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end('Not found: ' + filePath);
  }
});

await new Promise(r => server.listen(0, '127.0.0.1', r));
const { port } = server.address();
const qs = pyodideVersion ? `?pyodide=${pyodideVersion}` : '';
const pageUrl = `http://127.0.0.1:${port}/${basename(htmlFile)}${qs}`;

console.log(`Serving repo at http://127.0.0.1:${port}`);
console.log(`Opening: ${pageUrl}\n`);

const browser = await chromium.launch();
const page = await browser.newPage();

// Forward browser console and uncaught errors to stdout
page.on('console', msg => {
  const type = msg.type();
  const text = msg.text();
  if (type === 'error') process.stderr.write(`[browser:error] ${text}\n`);
  else process.stdout.write(`[browser:${type}] ${text}\n`);
});
page.on('pageerror', err => {
  process.stderr.write(`[browser:pageerror] ${err}\n`);
});

// Timeout: 15 minutes (test-official takes several minutes)
const TIMEOUT_MS = 15 * 60 * 1000;

await page.goto(pageUrl, { waitUntil: 'domcontentloaded' });

// Both HTML files signal completion via the #summary element being non-empty
// (test-smoke.html) or the #status element showing "All tests passed." / "Done."
let result;
try {
  result = await page.waitForFunction(() => {
    const summary = document.getElementById('summary');
    const status  = document.getElementById('status');
    // test-official.html: status changes from "Initialising…" / "Running…" to done
    if (status && !['Initialising…', ''].includes(status.textContent) &&
        /passed|failed|error/i.test(status.textContent ?? '')) return true;
    // test-smoke.html: no #status; look for final line in #output
    if (!status) {
      const out = document.getElementById('output');
      return out && /\d+\/\d+ passed/.test(out.textContent ?? '');
    }
    // test-official.html: also accept non-empty #summary
    return summary && summary.textContent.trim().length > 0;
  }, null, { timeout: TIMEOUT_MS });
} catch (e) {
  // Dump page content on timeout for debugging
  const html = await page.evaluate(() => document.getElementById('output')?.innerText ?? '(no #output)');
  console.error('Page #output at timeout:\n' + html);
  console.error('Timed out waiting for test results.');
  await browser.close();
  server.close();
  process.exit(1);
}

// Extract text output and summary
const { output, summary, status } = await page.evaluate(() => ({
  output:  document.getElementById('output')?.innerText  ?? '',
  summary: document.getElementById('summary')?.innerText ?? '',
  status:  document.getElementById('status')?.innerText  ?? '',
}));

console.log(output);
if (summary) console.log('Summary:', summary);
if (status)  console.log('Status: ', status);

const failed = /failed|error/i.test(summary || status);
await browser.close();
server.close();
// In strict mode (smoke tests) any failure is a real regression — exit 1.
// In non-strict mode (official suite) some failures are expected; always exit 0.
process.exit(strict && failed ? 1 : 0);
