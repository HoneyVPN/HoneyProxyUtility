// Export the repository's vector brand artwork into native macOS AppIcon sizes.
// Requires the sharp package; this does not modify the SVG source.
const path = require('node:path');
const fs = require('node:fs/promises');
const sharp = require('sharp');

(async () => {
  const root = path.resolve(__dirname, '..');
  const source = await fs.readFile(path.join(root, 'assets/images/honey-shield.svg'));
  const target = path.join(root, 'macos/Runner/Assets.xcassets/AppIcon.appiconset');
  const sizes = [16, 32, 64, 128, 256, 512, 1024];
  await Promise.all(sizes.map(size => sharp(source, { density: 192 })
    .resize(size, size).png().toFile(path.join(target, `app_icon_${size}.png`))));
  console.log(`Exported ${sizes.length} native AppIcon sizes from honey-shield.svg.`);
})().catch(error => { console.error(error.message); process.exitCode = 1; });
