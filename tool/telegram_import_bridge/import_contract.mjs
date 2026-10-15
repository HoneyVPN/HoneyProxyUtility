export const MAX_ENVELOPE_BYTES = 65536;
export const MAX_SOURCE_BYTES = 16384;

export const PROXY_SCHEMES = Object.freeze([
  'vless', 'vmess', 'trojan', 'ss', 'hy2', 'hysteria2', 'tuic',
  'wireguard', 'awg', 'vpn', 'naive', 'naive+https', 'naive+quic', 'shadowtls',
]);

const controls = /[\u0000-\u001f\u007f]/u;
const malformedPercent = /%(?![0-9a-f]{2})/iu;
const encoder = new TextEncoder();

export class ImportLinkError extends Error {
  constructor(code) {
    // Error messages contain only a stable code, never the supplied URL.
    super(code);
    this.name = 'ImportLinkError';
    this.code = code;
  }
}

function fail(code) { throw new ImportLinkError(code); }

function checkText(value, maximum, code) {
  if (typeof value !== 'string' || value.length === 0) fail(code);
  if (encoder.encode(value).byteLength > maximum) fail('too_long');
  if (controls.test(value) || malformedPercent.test(value)) fail('invalid_link');
}

export function validateSource(source) {
  checkText(source, MAX_SOURCE_BYTES, 'missing_link');
  const scheme = /^([a-z][a-z0-9+.-]*):\/\//u.exec(source)?.[1];
  if (scheme === 'https') {
    const authority = /^https:\/\/([^/?#]+)/u.exec(source)?.[1];
    if (!authority || /[\s\\]/u.test(authority) || authority.endsWith(':')) fail('invalid_link');
    let parsed;
    try { parsed = new URL(source); } catch { fail('invalid_link'); }
    if (!parsed.hostname || parsed.port === '0') fail('invalid_link');
    // Preserve the entire original string, including credentials, % escapes,
    // query, fragment and explicit ports. This page never fetches its contents.
    return Object.freeze({ source, kind: 'subscription' });
  }
  // VMess and some SS forms have a Base64 body rather than a URI authority.
  // Protocol-specific validation remains the app's responsibility.
  if (!PROXY_SCHEMES.includes(scheme) || source.length === scheme.length + 3) {
    fail('unsupported_link');
  }
  return Object.freeze({ source, kind: 'server' });
}

export function buildAppLink(source) {
  validateSource(source);
  let encoded;
  try { encoded = encodeURIComponent(source); } catch { fail('invalid_link'); }
  const link = `honeyvpn://import?url=${encoded}`;
  checkText(link, MAX_ENVELOPE_BYTES, 'invalid_link');
  return link;
}

export function parseLauncherLocation(raw) {
  checkText(raw, MAX_ENVELOPE_BYTES, 'missing_link');
  let location;
  try { location = new URL(raw); } catch { fail('invalid_link'); }
  const localHttp = location.protocol === 'http:' &&
    ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
  if (location.protocol !== 'https:' && !localHttp) fail('invalid_location');
  if (location.username || location.password) fail('invalid_location');
  // Even an empty query marker is rejected. A subscription belongs only in
  // the fragment, which is not sent in an HTTP request.
  if (raw.split('#', 1)[0].includes('?')) fail('query_not_allowed');
  const fragment = location.hash.slice(1);
  if (!fragment) fail('missing_link');
  if (!fragment.startsWith('url=') || fragment.includes('&') || fragment.includes('#')) {
    fail('invalid_link');
  }
  const encoded = fragment.slice(4);
  if (!encoded || malformedPercent.test(encoded)) fail('invalid_link');
  let source;
  try {
    // Match query-component decoding; literal '+' must be encoded as %2B.
    source = decodeURIComponent(encoded.replace(/\+/gu, ' '));
  } catch { fail('invalid_link'); }
  const result = validateSource(source);
  return Object.freeze({ ...result, appLink: buildAppLink(source) });
}
