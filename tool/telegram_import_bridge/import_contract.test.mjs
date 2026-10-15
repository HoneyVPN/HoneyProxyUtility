import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer, get } from 'node:http';
import {
  MAX_ENVELOPE_BYTES, MAX_SOURCE_BYTES, PROXY_SCHEMES,
  ImportLinkError, validateSource, buildAppLink, parseLauncherLocation,
} from './import_contract.mjs';
import { mountBridge, copyPrivately } from './bridge.mjs';

const base = 'https://links.example.com/import';
const source = 'https://sub.example.com:8443/a%2Fb?token=fake%2Ftoken&label=A+B#Профиль';
const bridge = (value) => `${base}#url=${encodeURIComponent(value)}`;
const reject = (value, code) => assert.throws(() => parseLauncherLocation(value),
  (error) => error instanceof ImportLinkError && (!code || error.code === code));

test('subscription round trip retains escapes, query, plus, fragment and nondefault port', () => {
  const result = parseLauncherLocation(bridge(source));
  assert.equal(result.source, source);
  assert.equal(result.kind, 'subscription');
  const app = new URL(result.appLink);
  assert.equal(app.protocol, 'honeyvpn:');
  assert.equal(app.hostname, 'import');
  assert.deepEqual([...app.searchParams.keys()], ['url']);
  assert.equal(app.searchParams.get('url'), source);
  assert.equal(app.hash, '');
});

test('HTTPS source credentials remain in the source, not the launcher request', () => {
  const value = 'https://fake-user:fake-password@sub.example.com/config?token=fake';
  const target = new URL(bridge(value));
  assert.equal(target.username, '');
  assert.equal(target.password, '');
  assert.equal(target.search, '');
  assert.equal(target.pathname, '/import');
  assert.equal(parseLauncherLocation(target.href).source, value);
});

test('one decode preserves literal encoded separators and encodes the complete app payload', () => {
  const value = 'vless://fake-uuid@example.com:443?type=ws&path=%2Fa%3Fb%3D1%26c%3D2#A+B';
  const result = parseLauncherLocation(bridge(value));
  assert.equal(result.source, value);
  assert.equal(result.appLink, `honeyvpn://import?url=${encodeURIComponent(value)}`);
  assert.ok(result.appLink.includes('%252F'));
  assert.ok(result.appLink.includes('%2B'));
});

test('proxy allowlist also accepts Base64 bodies without imposing an authority grammar', () => {
  for (const scheme of PROXY_SCHEMES) {
    const value = `${scheme}://ZXhhbXBsZS1maXh0dXJlLXBheWxvYWQ=`;
    assert.equal(parseLauncherLocation(bridge(value)).kind, 'server');
  }
});

test('unsupported schemes, recursive imports and HTTP feeds fail closed', () => {
  for (const value of [
    'javascript://alert(1)', 'file:///private/fixture', 'intent://fixture',
    'honeyvpn://import?url=https%3A%2F%2Fexample.com', 'happ://crypt5/fixture',
    'http://sub.example.com/config', 'VLESS://fixture', 'vless://',
  ]) reject(bridge(value), 'unsupported_link');
});

test('URL authority and port validation rejects invalid HTTPS destinations', () => {
  for (const value of [
    'https://', 'https:///config', 'https://sub.example.com:0/config',
    'https://sub.example.com:65536/config', 'https://sub.example.com:/config',
    'https://sub.example.com\\@other.example/config', 'https://bad host/config',
  ]) reject(bridge(value), 'invalid_link');
  assert.equal(validateSource('https://[2001:db8::1]:65535/config').kind, 'subscription');
});

test('query payloads, empty query marker, duplicates and extra fragment fields are rejected', () => {
  for (const value of [
    `${base}?url=${encodeURIComponent(source)}`, `${base}?#url=${encodeURIComponent(source)}`,
    `${base}?sub=fixture#url=${encodeURIComponent(source)}`,
  ]) reject(value, 'query_not_allowed');
  for (const value of [
    `${bridge(source)}&url=${encodeURIComponent(source)}`,
    `${bridge(source)}&action=connect`, `${base}#other=${encodeURIComponent(source)}`,
    `${bridge(source)}#extra`, `${base}#url=`,
  ]) reject(value);
});

test('malformed percent escapes and invalid UTF8 fail without leaking supplied text', () => {
  for (const value of [`${base}#url=%`, `${base}#url=%GG`, `${base}#url=%C0%AF`,
    bridge('https://sub.example.com/secret%2G')]) {
    reject(value, 'invalid_link');
  }
  try { parseLauncherLocation(`${base}?url=private-fixture-secret`); }
  catch (error) {
    assert.equal(error.message, 'query_not_allowed');
    assert.ok(!JSON.stringify(error).includes('private-fixture-secret'));
    assert.ok(!String(error).includes('private-fixture-secret'));
  }
});

test('actual ASCII controls are rejected before URL normalization or after decoding', () => {
  for (const value of ['\n', '\r', '\t', '\u0000', '\u007f']) {
    reject(`${base}${value}#url=${encodeURIComponent(source)}`, 'invalid_link');
    reject(bridge(`https://sub.example.com/config${value}`), 'invalid_link');
  }
});

test('limits count UTF8 bytes, not characters, and include the full envelope', () => {
  const prefix = 'https://sub.example.com/';
  const exactly = prefix + 'x'.repeat(MAX_SOURCE_BYTES - prefix.length);
  assert.equal(parseLauncherLocation(bridge(exactly)).source, exactly);
  reject(bridge(exactly + 'x'), 'too_long');
  reject(bridge(prefix + '🍯'.repeat(4096)), 'too_long');
  reject(`https://links.example.com/${'x'.repeat(MAX_ENVELOPE_BYTES)}#url=x`, 'too_long');
});

test('HTTP launcher is accepted only on loopback for local review', () => {
  for (const host of ['localhost', '127.0.0.1', '[::1]']) {
    assert.equal(parseLauncherLocation(`http://${host}:8099/import#url=${encodeURIComponent(source)}`).source, source);
  }
  reject(`http://links.example.com/import#url=${encodeURIComponent(source)}`, 'invalid_location');
  reject(`https://fake:password@links.example.com/import#url=${encodeURIComponent(source)}`, 'invalid_location');
});

class Element {
  constructor() { this.textContent = ''; this.attributes = {}; this.listeners = {}; this.hidden = false; this.disabled = false; this.value = ''; }
  setAttribute(key, value) { this.attributes[key] = value; }
  addEventListener(name, listener) { this.listeners[name] = listener; }
  select() { this.selected = true; }
  remove() { this.removed = true; }
  focus() { this.focused = true; }
}
function environment(href = bridge(source), platform = 'Win32', userAgent = 'Desktop fixture') {
  const nodes = new Map();
  const fields = [];
  const opened = [];
  const copied = [];
  const clean = [];
  const focus = new Element();
  const document = {
    documentElement: {}, activeElement: focus,
    getElementById(name) { if (!nodes.has(name)) nodes.set(name, new Element()); return nodes.get(name); },
    createElement() { const field = new Element(); fields.push(field); return field; },
    body: { appendChild(field) { field.appended = true; } },
    execCommand() { return true; },
  };
  const navigator = { platform, userAgent, languages: ['ru-RU'], maxTouchPoints: 0,
    clipboard: { async writeText(value) { copied.push(value); } } };
  const location = { href, assign(value) { opened.push(value); } };
  const history = { replaceState(...args) { clean.push(args); } };
  return { document, navigator, location, history, nodes, fields, opened, copied, clean, focus };
}

test('mount never opens, copies or displays a token; language changes also have no side effects', () => {
  const env = environment();
  mountBridge(env);
  assert.deepEqual(env.opened, []);
  assert.deepEqual(env.copied, []);
  assert.deepEqual(env.clean, [[null, '', '/import']]);
  for (const node of env.nodes.values()) {
    assert.ok(!node.textContent.includes(source));
    assert.ok(!JSON.stringify(node.attributes).includes('fake%2Ftoken'));
  }
  env.nodes.get('language-en').listeners.click();
  assert.equal(env.document.documentElement.lang, 'en');
  assert.equal(env.nodes.get('open-app').textContent, 'Open in HoneyProxyUtility');
  assert.deepEqual(env.opened, []);
  assert.deepEqual(env.copied, []);
});

test('an explicit click opens only the fixed import command; copy writes the original source', async () => {
  const env = environment();
  mountBridge(env);
  env.nodes.get('open-app').listeners.click();
  assert.deepEqual(env.opened, [buildAppLink(source)]);
  await env.nodes.get('copy-source').listeners.click();
  assert.deepEqual(env.copied, [source]);
  assert.equal(env.nodes.get('feedback').textContent, 'Ссылка скопирована');
});

test('invalid launcher cannot dispatch or copy even if a click is invoked programmatically', async () => {
  const env = environment(`${base}?url=private-fixture-secret`);
  mountBridge(env);
  assert.equal(env.nodes.get('actions').hidden, true);
  env.nodes.get('open-app').listeners.click();
  await env.nodes.get('copy-source').listeners.click();
  assert.deepEqual(env.opened, []);
  assert.deepEqual(env.copied, []);
  assert.ok([...env.nodes.values()].every((node) => !node.textContent.includes('private-fixture-secret')));
});

test('iPhone and desktop-mode iPad do not claim an available Honey app', () => {
  for (const [platform, userAgent, points] of [
    ['iPhone', 'iPhone fixture', 0], ['MacIntel', 'Macintosh fixture', 5],
  ]) {
    const env = environment(bridge(source), platform, userAgent);
    env.navigator.maxTouchPoints = points;
    mountBridge(env);
    assert.equal(env.nodes.get('open-app').hidden, true);
    assert.equal(env.nodes.get('open-app').disabled, true);
    env.nodes.get('open-app').listeners.click();
    assert.deepEqual(env.opened, []);
    assert.ok(env.nodes.get('help').textContent.includes('пока недоступно'));
  }
});

test('Mac preview limitation is explicit while import can still be opened', () => {
  const env = environment(bridge(source), 'MacIntel', 'Macintosh fixture');
  mountBridge(env);
  assert.equal(env.nodes.get('open-app').hidden, false);
  assert.ok(env.nodes.get('help').textContent.includes('VPN пока недоступен'));
});

test('clipboard fallback clears and removes the private field even when copying fails', async () => {
  for (const succeeds of [true, false]) {
    const env = environment();
    env.navigator.clipboard.writeText = async () => { throw new Error('denied'); };
    env.document.execCommand = () => succeeds;
    assert.equal(await copyPrivately(source, env.document, env.navigator), succeeds);
    assert.equal(env.fields.length, 1);
    const field = env.fields[0];
    assert.equal(field.className, 'clipboard-only');
    assert.equal(field.attributes['aria-hidden'], 'true');
    assert.equal(field.tabIndex, -1);
    assert.equal(field.value, '');
    assert.equal(field.removed, true);
    assert.equal(env.focus.focused, true);
  }
});

test('an outstanding copy cannot be duplicated and does not trigger navigation', async () => {
  const env = environment();
  let release;
  env.navigator.clipboard.writeText = (value) => {
    env.copied.push(value);
    return new Promise((resolve) => { release = resolve; });
  };
  mountBridge(env);
  const first = env.nodes.get('copy-source').listeners.click();
  await env.nodes.get('copy-source').listeners.click();
  assert.equal(env.copied.length, 1);
  assert.equal(env.nodes.get('copy-source').disabled, true);
  assert.deepEqual(env.opened, []);
  release();
  await first;
  assert.equal(env.nodes.get('copy-source').disabled, false);
});

test('a real local HTTP request and same-origin assets never include the fragment source', async () => {
  const requests = [];
  const files = new Set(['index.html', 'bridge.css', 'bridge.mjs', 'import_contract.mjs', 'honey-shield.svg']);
  const server = createServer(async (request, response) => {
    requests.push(request.url);
    const name = request.url === '/import/' ? 'index.html' : request.url?.slice('/import/'.length);
    if (!request.url?.startsWith('/import/') || !files.has(name)) {
      response.writeHead(404).end();
      return;
    }
    try {
      const type = name.endsWith('.mjs') ? 'text/javascript' :
        name.endsWith('.css') ? 'text/css' : name.endsWith('.svg') ? 'image/svg+xml' : 'text/html';
      response.setHeader('Content-Type', type);
      response.end(await readFile(new URL(`./${name}`, import.meta.url)));
    } catch { response.writeHead(500).end(); }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  try {
    const address = server.address();
    const target = new URL(`http://127.0.0.1:${address.port}/import/#url=${encodeURIComponent(source)}`);
    const request = (url) => new Promise((resolve, reject) => {
      get(url, (response) => {
        let body = '';
        response.setEncoding('utf8');
        response.on('data', (part) => { body += part; });
        response.on('end', () => resolve({ status: response.statusCode, body, headers: response.headers }));
      }).on('error', reject);
    });
    const page = await request(target);
    assert.equal(page.status, 200);
    assert.equal(page.headers['content-type'], 'text/html');
    assert.ok(page.body.includes('name="referrer" content="no-referrer"'));
    const references = [...page.body.matchAll(/(?:src|href)="(\.\/[^"]+)"/gu)].map((match) => match[1]);
    references.push('./import_contract.mjs');
    for (const relative of references) {
      const asset = await request(new URL(relative, target));
      assert.equal(asset.status, 200);
      if (relative.endsWith('.mjs')) assert.equal(asset.headers['content-type'], 'text/javascript');
    }
    assert.deepEqual(requests, ['/import/', '/import/bridge.css', '/import/bridge.mjs', '/import/honey-shield.svg', '/import/import_contract.mjs']);
    assert.ok(requests.every((url) => !url.includes('?') && !url.includes('#') && !url.includes('fake')));
  } finally { await new Promise((resolve) => server.close(resolve)); }
});

test('small text and button colors have normal-text contrast in light and dark themes', async () => {
  const css = await readFile(new URL('./bridge.css', import.meta.url), 'utf8');
  const light = css.match(/:root\s*\{([^}]+)\}/u)[1];
  const dark = css.match(/prefers-color-scheme: dark[^]*?:root\s*\{([^}]+)\}/u)[1];
  const variables = (block) => Object.fromEntries([...block.matchAll(/--([\w-]+):\s*(#[0-9a-f]+);/gu)].map((match) => [match[1], match[2]]));
  function luminance(hex) {
    const expanded = hex.length === 4 ? hex.slice(1).split('').map((x) => x + x).join('') : hex.slice(1);
    const components = expanded.match(/../gu).map((value) => Number.parseInt(value, 16) / 255)
      .map((value) => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
    return components[0] * .2126 + components[1] * .7152 + components[2] * .0722;
  }
  const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + .05) / (Math.min(luminance(a), luminance(b)) + .05);
  for (const palette of [variables(light), { ...variables(light), ...variables(dark) }]) {
    for (const [foreground, background] of [
      ['text', 'surface'], ['secondary', 'surface'], ['secondary', 'background'],
      ['accent', 'surface'], ['button-text', 'button'], ['button-text', 'button-hover'],
    ]) assert.ok(contrast(palette[foreground], palette[background]) >= 4.5, `${foreground}/${background}`);
  }
});

test('page policy excludes connections, external resources, query interpolation and automatic navigation', async () => {
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const js = await readFile(new URL('./bridge.mjs', import.meta.url), 'utf8');
  const css = await readFile(new URL('./bridge.css', import.meta.url), 'utf8');
  assert.ok(html.includes('name="referrer" content="no-referrer"'));
  assert.ok(html.includes("connect-src 'none'"));
  assert.ok(html.includes("default-src 'none'"));
  assert.ok(!/\b(?:src|href)="(?:https?:|\/\/)/u.test(html));
  assert.ok(!/url\(\s*['"]?(?:https?:|\/\/)/u.test(css));
  assert.ok(!/\b(?:fetch|XMLHttpRequest|WebSocket|sendBeacon|console|localStorage|sessionStorage)\b/u.test(js));
  assert.ok(!js.includes('innerHTML'));
  assert.ok(!/http-equiv="refresh"/iu.test(html));
});
