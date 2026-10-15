#!/usr/bin/env python3
"""Compose MindWire's App Store creative assets from existing brand and native UI.

The 16:9 master keeps its content within the shared 21:9 / 3:2 crop area.
No app interface, model response, or logo is generated or redrawn.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import zipfile

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFilter

from design import logo, phone_layer, tablet_layer, write_text


ROOT = Path(__file__).resolve().parents[2]
MASTER = (5244, 2950)
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
SPECS = 'https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications'
GUIDANCE = 'https://developer.apple.com/app-store/asset-best-practices/'


def backdrop():
    # Soft light is rendered separately from the full-resolution typography and UI.
    w, h = MASTER
    sw, sh = w // 3, h // 3
    y, x = np.mgrid[0:sh, 0:sw].astype(np.float32)
    x /= sw
    y /= sh
    rgb = np.broadcast_to(np.array((9, 11, 15), dtype=np.float32), (sh, sw, 3)).copy()
    pools = [
        (.78, .77, .35, .51, (58, 22, 6)),
        (.63, .32, .34, .39, (20, 17, 16)),
        (.15, .36, .30, .40, (6, 5, 5)),
        (.97, .52, .16, .48, (14, 5, 1)),
    ]
    for cx, cy, rx, ry, tint in pools:
        light = np.exp(-(((x-cx)/rx)**2 + ((y-cy)/ry)**2)*1.7)
        rgb += light[..., None] * np.array(tint, dtype=np.float32)
    rgb += np.random.default_rng(23).normal(0, .38, (sh, sw, 1))
    image = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8)).resize(MASTER, Image.Resampling.BICUBIC).convert('RGBA')

    # A restrained, copper-lit rounded opening echoes the app's existing brand mark.
    portal = Image.new('RGBA', (3300, 2550))
    d = ImageDraw.Draw(portal)
    d.rounded_rectangle((175, 125, 3030, 2350), 570, outline=(246, 145, 86, 105), width=5)
    d.rounded_rectangle((193, 144, 3012, 2332), 554, outline=(244, 163, 115, 24), width=2)
    portal = portal.rotate(-17, Image.Resampling.BICUBIC, expand=True)
    p = (int(3535-portal.width/2), int(1540-portal.height/2))
    bloom = Image.new('RGBA', MASTER)
    bloom.alpha_composite(portal, p)
    image.alpha_composite(bloom.filter(ImageFilter.GaussianBlur(38)))
    image.alpha_composite(bloom.filter(ImageFilter.GaussianBlur(10)))
    image.alpha_composite(portal, p)
    d = ImageDraw.Draw(image)
    for cx, cy in ((590, 554), (4654, 554), (590, 2400), (4654, 2400)):
        d.line((cx-11, cy, cx+11, cy), fill=(140, 135, 128, 58), width=2)
        d.line((cx, cy-11, cx, cy+11), fill=(140, 135, 128, 58), width=2)
    return image


def place_device(image, layer, center, angle, shadow_opacity=.80):
    layer = layer.rotate(angle, Image.Resampling.BICUBIC, expand=True)
    x, y = round(center[0]-layer.width/2), round(center[1]-layer.height/2)
    mask = Image.new('L', MASTER)
    mask.paste(layer.getchannel('A'), (x+12, y+38))
    mask = mask.filter(ImageFilter.GaussianBlur(45)).point(lambda value: round(value*shadow_opacity))
    shadow = Image.new('RGBA', MASTER, (0, 0, 0, 0))
    shadow.putalpha(mask)
    image.alpha_composite(shadow)
    image.alpha_composite(layer, (x, y))
    return [x, y, x+layer.width, y+layer.height]


def gradient_text(image, xy, text, size):
    mask = Image.new('L', MASTER)
    d = ImageDraw.Draw(mask)
    right = write_text(d, xy, text, size, 255, 'Bold', tracking=-6.3, display=True)
    x0 = xy[0]
    x = np.arange(MASTER[0], dtype=np.float32)
    t = np.clip((x-x0) / max(1, right-x0), 0, 1)
    colors = np.array((255, 203, 159))[None, :]*(1-t[:, None]) + np.array((255, 133, 82))[None, :]*t[:, None]
    fill = Image.fromarray(np.clip(colors, 0, 255).astype(np.uint8)[None, :, :]).resize(MASTER)
    image.paste(fill, (0, 0), mask)
    return right


def master(captures):
    image = backdrop()
    tablet = Image.open(captures/'ipad/03-review-light.png').convert('RGB')
    phone = Image.open(captures/'iphone/01-chat-dark.png').convert('RGB')
    assert tablet.size == (2752, 2064)
    assert phone.size == (1320, 2868)
    bounds = {}
    bounds['code_screen'] = place_device(image, tablet_layer(tablet, 2055), (3510, 1506), -7, .65)
    bounds['chat_screen'] = place_device(image, phone_layer(phone, 900), (2690, 1500), 4, .94)

    # Full-size original logo + exact MindWire casing, not a generated wordmark.
    logo(image, 714, 775, 107, '#f8f6f2')
    d = ImageDraw.Draw(image)
    brand_right = write_text(d, (851, 778), 'MindWire', 106, '#f8f6f2', 'Semibold', tracking=-2.5, display=True)
    title_right = write_text(d, (701, 1088), 'Your agents.', 256, '#f8f6f2', 'Bold', tracking=-6.0, display=True)
    second_right = gradient_text(image, (701, 1381), 'Anywhere.', 281)
    d = ImageDraw.Draw(image)
    copy_right = write_text(d, (719, 1757), 'Code, review, and ship.', 67, '#b4aea9', 'Regular', tracking=-.5)
    d.line((720, 2016, 790, 2016), fill='#ed9063', width=3)
    write_text(d, (824, 1996), 'OPEN SOURCE', 46, '#b9b1aa', 'Medium', tracking=4.3)
    bounds['brand'] = [714, 775, math.ceil(brand_right), 883]
    bounds['headline'] = [701, 1088, math.ceil(max(title_right, second_right)), 1662]
    bounds['copy'] = [719, 1757, math.ceil(copy_right), 1840]
    return image.convert('RGB'), bounds


def save_png(image, target):
    image.convert('RGB').save(target, optimize=True, icc_profile=SRGB)


def make_preview(image, target, width):
    image.resize((width, round(image.height*width/image.width)), Image.Resampling.LANCZOS).save(
        target, quality=94, subsampling=0, icc_profile=SRGB)


def gallery(out, items):
    cards = ''.join(f'<article><div class="meta"><h2>{item["title"]}</h2><span>{item["width"]} × {item["height"]} · RGB PNG</span></div><a href="{item["file"]}" download><img src="{item["preview"]}" alt="{item["title"]} for MindWire"><span class="download">Download PNG ↗</span></a></article>' for item in items)
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MindWire · Product page artwork</title><style>
*{box-sizing:border-box}body{background:#090b0f;color:#f8f6f2;font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;max-width:1540px;margin:0 auto;padding:64px 32px}h1{font-size:clamp(32px,5vw,62px);font-weight:600;letter-spacing:-2px;margin:0 0 16px}p{color:#a9a29a;line-height:1.6;margin:0 0 50px}article{margin-bottom:56px}.meta{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:18px}h2{font-size:20px;margin:0;font-weight:500}.meta span{color:#a9a29a;font-size:13px}a{color:#f8b38d;text-decoration:none}a:focus-visible{outline:2px solid #ffab80;outline-offset:6px}img{width:100%;display:block;border:1px solid #272421;border-radius:14px}.download{display:block;font-size:14px;margin-top:14px}footer{font-size:14px;color:#999188;border-top:1px solid #292523;padding-top:24px}@media(max-width:600px){body{padding:36px 18px}.meta{display:block}.meta span{display:block;margin-top:8px}article{margin-bottom:36px}}
</style><h1>MindWire. Anywhere.</h1><p>Matching App Store artwork. Use the dedicated Header and Search Results files, or the Universal image in both placements.</p>''' + cards + '<footer>Original app branding and real native UI. Opaque sRGB PNGs. <a href="README.md">Asset notes</a> · <a href="manifest.json">Dimensions and checksums</a></footer></html>'
    (out/'gallery.html').write_text(page)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--captures', type=Path, default=ROOT/'apps/apple/artifacts/app-store/native')
    parser.add_argument('--output', type=Path, default=ROOT/'apps/apple/artifacts/app-store/product-page-v1')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    image, bounds = master(args.captures)

    # Center crops derive exactly from the universal composition. No focal content moves.
    wide_h = MASTER[0] * 1646/3840
    header_box = (0, (MASTER[1]-wide_h)/2, MASTER[0], (MASTER[1]+wide_h)/2)
    search_w = MASTER[1] * 3/2
    search_box = ((MASTER[0]-search_w)/2, 0, (MASTER[0]+search_w)/2, MASTER[1])
    for name, box in (('header', header_box), ('search', search_box)):
        for key in ('brand', 'headline', 'copy', 'chat_screen'):
            subject = bounds[key]
            if not (subject[0] >= box[0] and subject[1] >= box[1] and subject[2] <= box[2] and subject[3] <= box[3]):
                raise ValueError(f'{key} is outside the {name} safe crop: {subject}, {box}')

    definitions = [
        ('Header', 'MindWire-Header-3840x1646.png', image.resize((3840, 1646), Image.Resampling.LANCZOS, box=header_box)),
        ('Search Results', 'MindWire-Search-3840x2560.png', image.resize((3840, 2560), Image.Resampling.LANCZOS, box=search_box)),
        ('Universal', 'MindWire-Universal-5244x2950.png', image),
    ]
    items = []
    for title, filename, output in definitions:
        target = out/filename
        save_png(output, target)
        preview = filename.replace('.png', '-preview.jpg')
        make_preview(output, out/preview, 1440 if title != 'Search Results' else 1080)
        with Image.open(target) as checked:
            checked.load()
            assert checked.mode == 'RGB'
            assert checked.size == output.size
            assert checked.info.get('icc_profile')
            assert 'transparency' not in checked.info
        items.append(dict(title=title, file=filename, preview=preview, width=output.width, height=output.height,
                          mode='RGB', colorSpace='sRGB', alpha=False,
                          bytes=target.stat().st_size, sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        print(f'Created {target}', flush=True)
    metadata = dict(assets=items, sourceDimensions=list(MASTER), sourceBounds=bounds,
                    crops={'header':header_box, 'search':search_box},
                    sources=['apps/apple/artifacts/app-store/native/iphone/01-chat-dark.png', 'apps/apple/artifacts/app-store/native/ipad/03-review-light.png', 'scripts/app-store/assets/mindwire.png'],
                    specification=SPECS, guidance=GUIDANCE)
    (out/'manifest.json').write_text(json.dumps(metadata, indent=2)+'\n')
    (out/'README.md').write_text(f'''# MindWire product page artwork

## Upload

- **Header:** `MindWire-Header-3840x1646.png` (21:9).
- **Search Results:** `MindWire-Search-3840x2560.png` (3:2).
- **Universal:** `MindWire-Universal-5244x2950.png` (16:9). This also works in both placements; App Store Connect can use the header asset in search results.

Upload the full-size PNGs. Preview JPGs are for inspection only.
All three exports are opaque, 8-bit RGB with an embedded sRGB profile and no transparency. `manifest.json` records dimensions, crop bounds, and SHA-256 checksums.

The shared safe area preserves the actual MindWire logo, headline, and complete primary chat screen in both crops. The secondary screen shows the actual iPad source control UI. App screenshots are downsampled, never upscaled or redrawn. The phone uses the existing iPhone 17 Pro Max frame and native capture.

## Art direction / production brief

Create a coordinated App Store header and search asset for MindWire. Use the existing white logo and the exact wordmark **MindWire** on a charcoal background with restrained copper light. Place real agent chat and code review screens together to present the app as a mobile workspace. Give the primary chat screen the foreground. Preserve all captured UI. Use crisp SF Pro typography. Keep the artwork readable when cropped to both aspect ratios. Exact copy: **Your agents. Anywhere.** / **Code, review, and ship.** / **OPEN SOURCE**. No prices, URLs, marketplace logos, Apple endorsements, or invented UI.

Created by deterministic composition of existing brand assets and native screenshots. No image-generation API was used. Existing logos and typefaces are reused; font files are not distributed.

## Reproduce

Install `scripts/app-store/requirements.txt` in a Python environment, then run:

```sh
python scripts/app-store/product_page.py
```

This generates artwork only; it does not upload or publish the assets.

Apple references, checked 2026-10-07:
- [Creative asset specifications]({SPECS})
- [Asset best practices and templates]({GUIDANCE})
''')
    gallery(out, items)
    package = out.parent/'MindWire-Product-Page-v1.zip'
    with zipfile.ZipFile(package, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(out.iterdir()):
            if file.is_file(): archive.write(file, Path('MindWire-Product-Page')/file.name)
    print(f'Package: {package}', flush=True)


if __name__ == '__main__':
    main()
