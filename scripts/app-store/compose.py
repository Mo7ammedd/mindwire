#!/usr/bin/env python3
"""Compose App Store PNGs from real, upright simulator captures. No app UI is redrawn.

python3 scripts/app-store/compose.py --captures apps/apple/artifacts/app-store/native --output apps/apple/artifacts/app-store
"""
import argparse
import html
import io
import json
from pathlib import Path
import zipfile

from PIL import Image, ImageCms, ImageDraw, ImageOps

from design import FEATURES, NATIVE_SIZES, SIZES, compose, write_text

SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()


def upright(path):
    with Image.open(path) as original:
        image = ImageOps.exif_transpose(original).convert('RGB')
        if original.info.get('icc_profile'):
            source_profile = ImageCms.ImageCmsProfile(io.BytesIO(original.info['icc_profile']))
            image = ImageCms.profileToProfile(image, source_profile, ImageCms.ImageCmsProfile(io.BytesIO(SRGB)), outputMode='RGB')
        return image


def gallery(output, manifest):
    cards = []
    for item in manifest:
        title = html.escape(item['title'])
        cards.append(f'<a class="shot" data-device="{item["device"]}" data-theme="{item["theme"]}" href="{item["path"]}"><img loading="lazy" src="{item["thumbnail"]}" alt="{title}"><span>{item["index"]:02d} &nbsp; {title}</span></a>')
    document = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MindWire · App Store collection</title><style>
    *{box-sizing:border-box}body{margin:0;background:#131416;color:#f1efeb;font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:48px clamp(24px,5vw,90px)}h1{font-size:clamp(30px,5vw,56px);font-weight:600;letter-spacing:-2px;margin:0 0 12px}p{color:#a5a5a3;line-height:1.6}nav{display:flex;flex-wrap:wrap;gap:10px;margin:32px 0}.group{display:flex;background:#222327;border:1px solid #34363a;border-radius:100px;padding:4px}button{appearance:none;border:0;border-radius:100px;background:transparent;color:#afafb3;padding:11px 23px;font:inherit;cursor:pointer}button.selected{background:#f1efeb;color:#202126}button:focus-visible,a:focus-visible{outline:2px solid #f1966d;outline-offset:4px}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:28px;align-items:start}body[data-device="iphone"] .grid{grid-template-columns:repeat(6,minmax(0,1fr))}.shot{text-decoration:none;color:#c9c8c6;display:block}.shot[hidden]{display:none}.shot img{display:block;width:100%;border:1px solid #393a3e;border-radius:10px}.shot span{display:block;font-size:12px;line-height:1.5;margin:13px 1px}.meta{display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px;margin:20px 0;color:#7d8086;font-size:12px}.meta a{color:#c9c8c6}dialog{border:1px solid #3b3e45;border-radius:16px;background:#17191d;color:#eee;max-width:94vw;max-height:94vh;padding:12px}dialog::backdrop{background:#000c}dialog img{display:block;max-width:88vw;max-height:78vh;object-fit:contain;margin:auto}dialog footer{display:flex;align-items:center;justify-content:space-between;padding:12px}dialog a{color:#f7a17e}@media(max-width:1100px){body[data-device="iphone"] .grid{grid-template-columns:repeat(3,minmax(0,1fr))}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:620px){body[data-device="iphone"] .grid{grid-template-columns:repeat(2,minmax(0,1fr))}.grid{grid-template-columns:1fr}body{padding:28px 20px}.grid{gap:16px}}
    </style><body data-device="iphone"><h1>MindWire. Anywhere.</h1><p>The App Store collection. Six features, two appearances, made for iPhone and iPad.</p><nav><div class="group" id="devices"><button data-value="iphone" class="selected">iPhone 17 Pro Max</button><button data-value="ipad">iPad Pro</button></div><div class="group" id="themes"><button data-value="dark" class="selected">Dark</button><button data-value="light">Light</button></div></nav><div class="meta"><span id="dimensions">1284 × 2778 · RGB PNG · 6 screenshots</span><a href="README.md">Capture &amp; upload notes</a></div><main class="grid">''' + ''.join(cards) + '''</main><dialog><img alt="Full-size screenshot"><footer><a download>Download PNG</a><button>Close</button></footer></dialog><script>
    let device='iphone',theme='dark';const dialog=document.querySelector('dialog');function update(){document.body.dataset.device=device;document.querySelectorAll('.shot').forEach(c=>c.hidden=c.dataset.device!==device||c.dataset.theme!==theme);document.querySelector('#dimensions').textContent=(device==='iphone'?'1284 × 2778':'2752 × 2064')+' · RGB PNG · 6 screenshots'}for(const [id,key]of[['devices','device'],['themes','theme']])document.querySelector('#'+id).addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;document.querySelectorAll('#'+id+' button').forEach(x=>x.classList.toggle('selected',x===b));if(key==='device')device=b.dataset.value;else theme=b.dataset.value;update()});document.querySelectorAll('.shot').forEach(a=>a.addEventListener('click',e=>{e.preventDefault();dialog.querySelector('img').src=a.href;dialog.querySelector('a').href=a.href;dialog.showModal()}));dialog.querySelector('button').onclick=()=>dialog.close();dialog.addEventListener('click',e=>{if(e.target===dialog)dialog.close()});update();</script></body></html>'''
    (output/'gallery.html').write_text(document)


def contact_sheet(output, manifest):
    tile_w, gutter, margin = 260, 18, 32
    width = margin*2 + tile_w*6 + gutter*5
    heights = [620,620,255,255]
    image = Image.new('RGB', (width, sum(heights)+100), '#1b1c1f')
    draw = ImageDraw.Draw(image)
    write_text(draw,(margin,24),'MindWire · App Store collection',30,'#f2f0ec','Semibold')
    y=85
    for (device_name,theme),height in zip([('iphone','dark'),('iphone','light'),('ipad','dark'),('ipad','light')],heights):
        write_text(draw,(margin,y),f'{device_name.upper()}  /  {theme.upper()}',15,'#aaa9a5','Medium',tracking=1)
        y+=28
        items=sorted((x for x in manifest if x['device']==device_name and x['theme']==theme),key=lambda x:x['index'])
        for col,item in enumerate(items):
            shot=Image.open(output/item['path'])
            shot=shot.resize((tile_w,round(tile_w*shot.height/shot.width)),Image.Resampling.LANCZOS)
            image.paste(shot,(margin+col*(tile_w+gutter),y))
        y+=height-28
    image.save(output/'contact-sheet.jpg',quality=92,subsampling=0,icc_profile=SRGB)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--captures',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--allow-partial',action='store_true')
    parser.add_argument('--zip',action='store_true')
    args=parser.parse_args()
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    manifest=[]
    for kind in SIZES:
        for theme in ('dark','light'):
            for index,feature in enumerate(FEATURES,1):
                name=f"{index:02d}-{feature['scene']}"
                source=args.captures/kind/f'{name}-{theme}.png'
                if not source.exists():
                    if args.allow_partial:continue
                    raise SystemExit(f'Missing native screenshot: {source}')
                screen=upright(source)
                if screen.size != NATIVE_SIZES[kind]:
                    raise SystemExit(f'Unexpected native size: {source}: {screen.size}')
                native=out/'native'/kind/f'{name}-{theme}.png'
                native.parent.mkdir(parents=True,exist_ok=True)
                screen.save(native,icc_profile=SRGB)
                target=out/kind/theme/f'{name}.png';target.parent.mkdir(parents=True,exist_ok=True)
                result=compose(screen,kind,theme,index,feature)
                result.save(target,optimize=True,icc_profile=SRGB)
                thumb=out/'thumbnails'/kind/theme/f'{name}.jpg';thumb.parent.mkdir(parents=True,exist_ok=True)
                size=(320,round(result.height*320/result.width)) if kind=='iphone' else (720,540)
                result.resize(size,Image.Resampling.LANCZOS).save(thumb,quality=90,subsampling=0,icc_profile=SRGB)
                manifest.append(dict(device=kind,theme=theme,index=index,feature=feature['scene'],title=' '.join(feature['title']),path=str(target.relative_to(out)),thumbnail=str(thumb.relative_to(out)),width=result.width,height=result.height,mode=result.mode,native=str(native.relative_to(out)),native_width=screen.width,native_height=screen.height,capture_device='iPhone 17 Pro Max' if kind=='iphone' else 'iPad Pro 13-inch (M5)'))
                print(f'Composed {kind}/{theme}/{name}.png',flush=True)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    gallery(out,manifest);contact_sheet(out,manifest)
    (out/'README.md').write_text('''# MindWire App Store screenshots

24 composed screenshots: six features × light/dark × iPhone/iPad.
Each appearance is a complete alternative set, ordered 01–06.

- `iphone/dark` and `iphone/light`: **1284 × 2778 px** (portrait).
- `ipad/dark` and `ipad/light`: **2752 × 2064 px** (landscape).
- `native`: complete original app captures, with orientation baked into the pixels.
- `gallery.html`: browse, compare, and download individual PNGs locally.
- `contact-sheet.jpg`: overview of all four sets.
- `manifest.json`: file inventory and exact dimensions.

All upload images are opaque, 8-bit RGB PNGs with an sRGB profile. No screenshots are upscaled. The app content is captured from the production SwiftUI/UIKit screens in dedicated iPhone 17 Pro Max and iPad Pro 13-inch (M5) simulators. The thin Pro device frame and editorial artwork sit outside the app UI. XCTest omits the hardware sensor mask; the frame includes Dynamic Island in the Pro Max’s reserved status-bar area, without covering app content. Native iPhone captures are 1320 × 2868 and are downsampled proportionally inside the requested 1284 × 2778 Store canvas.

The demo projects, filenames, chats, and accounts are fictional. The desktop frame shows a locally rendered demo website through the app's actual desktop viewer. Screenshot fixtures and the preview entry point exist only in Debug simulator builds. No real account, remote workspace, or user files are modified during capture.

Choose one full theme set per device, or select a mix (App Store Connect allows up to ten images per device slot). This folder does not upload or publish anything.

Reproduce captures and composition with `scripts/app-store/capture.py` and `scripts/app-store/compose.py`; see `docs/iPadAndAppStore.md` in the repository.
''')
    if args.zip:
        target=out.parent/'Mindwire-App-Store.zip'
        with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
            for p in sorted(out.rglob('*')):
                if p.is_file() and p.suffix.lower() in {'.png','.jpg','.json','.html','.md'}:
                    archive.write(p,Path('Mindwire-App-Store')/p.relative_to(out))
        print(target)
    print(f'Saved {len(manifest)} App Store screenshots to {out}')


if __name__=='__main__':main()
