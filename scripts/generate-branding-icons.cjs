#!/usr/bin/env node
// Run with Node.js and sharp available. Generated PNGs are committed so normal
// Flutter/native builds do not need an SVG renderer or this development tool.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');

const root = path.resolve(__dirname, '..');
const artwork = path.join(root, 'assets/branding/hibiki');

async function render(source, size, output) {
  await fs.mkdir(path.dirname(output), { recursive: true });
  // Rasterize the outlined 512-unit SVG at the target density. Preserve its
  // existing corners and transparency without adding masks or substitutions.
  await sharp(source, { density: (72 * size) / 512 })
    .resize(size, size)
    .png({ compressionLevel: 9 })
    .toFile(output);
}

async function main() {
  for (const colour of ['black', 'white']) {
    const source = await fs.readFile(path.join(artwork, 'source', `hibiki-${colour}.svg`));
    for (const scale of [1, 2, 4]) {
      const directory = scale === 1 ? artwork : path.join(artwork, `${scale}.0x`);
      await render(source, 64 * scale, path.join(directory, `hibiki-${colour}.png`));
    }
    for (const size of [16, 20, 24, 32, 40, 48, 64]) {
      await render(source, size,
        path.join(root, 'linux/runner/resources/tray', `hibiki-${colour}-${size}.png`));
    }
  }
  console.log('Generated Flutter and Linux icons from the original hibiki SVGs.');
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
