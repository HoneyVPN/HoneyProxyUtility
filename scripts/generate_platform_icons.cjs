// Export the shared shield to Android adaptive/legacy, Windows and web icons.
// Requires sharp; generate_macos_icon.cjs exports the same artwork for macOS.
const path = require('node:path');
const fs = require('node:fs/promises');
const sharp = require('sharp');

(async () => {
  const root = path.resolve(__dirname, '..');
  const source = await fs.readFile(path.join(root, 'assets/images/honey-shield.svg'));
  const svg = source.toString('utf8');
  const background = /<rect\b[^>]*fill="url\(#surface\)"\s*\/>/;
  if (!background.test(svg)) throw new Error('Expected the shared shield background');
  const surface = svg.match(/<linearGradient\b[^>]*id="surface"[^>]*>([\s\S]*?)<\/linearGradient>/);
  const stops = surface && [...surface[1].matchAll(/stop-color="(#[0-9a-f]{6})"/gi)].map(m => m[1]);
  if (!stops || stops.length !== 2) throw new Error('Expected two shared surface colors');
  // The standalone mark has its own relative inset, retaining its crop/layout.
  const standaloneScale = Number(svg.match(/data-standalone-scale="([.\d]+)"/)?.[1] ?? 1);
  if (!(standaloneScale > 0 && standaloneScale <= 1)) throw new Error('Invalid standalone mark scale');
  const fullSizeMark = svg.replace(
    /<g id="icon-mark"[^>]*>([\s\S]*?)<\/g>/,
    `<g transform="translate(${(128 * (1 - standaloneScale)).toFixed(4)} ${(130 * (1 - standaloneScale)).toFixed(4)}) scale(${standaloneScale})">$1</g>`,
  );
  // Flutter renders a theme-tinted alpha mask without an SVG dependency.
  const mark = Buffer.from(fullSizeMark.replace(background, '').replace(
    'viewBox="0 0 256 256"', 'viewBox="48 38 160 184"',
  ));
  await sharp(mark, { density: 192 }).resize(223, 256).png()
    .toFile(path.join(root, 'assets/images/honey-mark.png'));
  // Android masks its 108dp foreground. Keep the shield inside the 66dp safe zone.
  const foreground = Buffer.from(svg.replace(background, '')
    .replace('</defs>', '</defs><g transform="translate(23.04 23.04) scale(.82)">')
    .replace('</svg>', '</g></svg>'));
  const res = path.join(root, 'android/app/src/main/res');
  // Android tints notification artwork: export the same empty shield in white,
  // with a 24dp crop, and no colored tile. Service wiring is a separate change.
  const geometry = svg.match(/<g id="icon-mark"[^>]*transform="translate\(([.\d]+) ([.\d]+)\) scale\(([.\d]+)\)"/);
  const outline = svg.match(/<path\b[^>]*fill-rule="evenodd"[^>]*d="([^"]+)"/);
  if (!geometry || !outline) throw new Error('Expected the shared empty shield geometry');
  await fs.writeFile(path.join(res, 'drawable/ic_stat_honey.xml'),
    '<?xml version="1.0" encoding="utf-8"?>\n' +
    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n' +
    '    android:width="24dp" android:height="24dp"\n' +
    '    android:viewportWidth="24" android:viewportHeight="24">\n' +
    '    <group android:scaleX=".125" android:scaleY=".125" android:translateX="-4" android:translateY="-4">\n' +
    `        <group android:scaleX="${geometry[3]}" android:scaleY="${geometry[3]}" android:translateX="${geometry[1]}" android:translateY="${geometry[2]}">\n` +
    `            <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd" android:pathData="${outline[1]}"/>\n` +
    '        </group>\n    </group>\n</vector>\n');
  for (const [density, size, adaptiveSize] of [
    ['mdpi', 48, 108], ['hdpi', 72, 162], ['xhdpi', 96, 216],
    ['xxhdpi', 144, 324], ['xxxhdpi', 192, 432],
  ]) {
    const directory = path.join(res, `mipmap-${density}`);
    await sharp(source, { density: 192 }).resize(size, size).png()
      .toFile(path.join(directory, 'ic_launcher.png'));
    await sharp(foreground, { density: 192 }).resize(adaptiveSize, adaptiveSize).png()
      .toFile(path.join(directory, 'ic_launcher_foreground.png'));
  }
  await fs.writeFile(path.join(res, 'drawable/ic_launcher_background.xml'),
    '<?xml version="1.0" encoding="utf-8"?>\n<shape xmlns:android="http://schemas.android.com/apk/res/android">\n' +
    `    <gradient android:startColor="${stops[0]}" android:endColor="${stops[1]}" android:angle="270"/>\n</shape>\n`);

  await sharp(source, { density: 192 }).resize(32, 32).png()
    .toFile(path.join(root, 'web/favicon.png'));
  await sharp(source, { density: 192 }).resize(16, 16).png()
    .toFile(path.join(root, 'favicon.png'));
  // A maskable icon needs an opaque full-bleed background; the shield itself
  // already fits inside the central 80% safe circle.
  const maskable = Buffer.from(svg.replace(background,
    '<rect width="256" height="256" fill="url(#surface)"/>'));
  for (const directory of ['web/icons', 'icons']) {
    for (const size of [192, 512]) {
      await sharp(source, { density: 192 }).resize(size, size).png()
        .toFile(path.join(root, `${directory}/Icon-${size}.png`));
      await sharp(maskable, { density: 192 }).resize(size, size).png()
        .toFile(path.join(root, `${directory}/Icon-maskable-${size}.png`));
    }
  }

  // Windows Vista+ understands PNG entries in ICO containers.
  const sizes = [16, 32, 48, 64, 128, 256];
  const images = await Promise.all(sizes.map(size =>
    sharp(source, { density: 192 }).resize(size, size).png().toBuffer()));
  const header = Buffer.alloc(6 + images.length * 16);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  for (let i = 0; i < images.length; i++) {
    const entry = 6 + i * 16;
    header[entry] = sizes[i] === 256 ? 0 : sizes[i];
    header[entry + 1] = header[entry];
    header.writeUInt16LE(1, entry + 4);
    header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(images[i].length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += images[i].length;
  }
  await fs.writeFile(path.join(root, 'windows/runner/resources/app_icon.ico'),
    Buffer.concat([header, ...images]));
  await fs.copyFile(path.join(root, 'assets/images/honey-shield.svg'),
    path.join(root, 'tool/telegram_import_bridge/honey-shield.svg'));
  console.log('Exported shared shield: Android (10+notification), web/root (10), Windows (6 ICO sizes), Flutter mark (1), bridge vector (1).');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
