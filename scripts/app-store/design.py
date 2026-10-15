"""Art direction for the Store collection. App pixels always come from native captures."""
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).parent
SF = Path('/System/Library/Fonts/SFNS.ttf')
MONO = Path('/System/Library/Fonts/SFNSMono.ttf')
SIZES = {'iphone': (1284, 2778), 'ipad': (2752, 2064)}
NATIVE_SIZES = {'iphone': (1320, 2868), 'ipad': (2752, 2064)}
FEATURES = [
    dict(scene='chat', title=('Your agents.', 'Anywhere.'),
         tablet=('Your', 'agents.', 'Anywhere.'),
         caption='Your favorite agents. A little more freedom.',
         copy='Think, build, and ship\nwith the agents\nyou already love.',
         detail='Codex · Claude · OpenCode', label='WORK FROM ANYWHERE'),
    dict(scene='projects', title=('Big ideas.', 'One place.'),
         tablet=('Big ideas.', 'One', 'place.'),
         caption='Every project. Every conversation. All here.',
         copy='Your conversations,\nbranches, and tools.\nBeautifully together.',
         detail='Chats · Files · Git', label='YOUR WORK, TOGETHER'),
    dict(scene='review', title=('Every change.', 'In focus.'),
         tablet=('Every', 'change.', 'In focus.'),
         caption='Review. Stage. Commit. Keep things moving.',
         copy='See what changed.\nStage what matters.\nShip with confidence.',
         detail='Review · Stage · Commit', label='CLOSER TO THE CODE'),
    dict(scene='files', title=('Your code.', 'Within reach.'),
         tablet=('Your code.', 'Within', 'reach.'),
         caption='A real editor. Right where you need it.',
         copy='Browse real files.\nMake a quick edit.\nBring your agent in.',
         detail='Browse · Edit · Share', label='MADE FOR REAL WORK'),
    dict(scene='desktop', title=('Your desktop.', 'To go.'),
         tablet=('Your', 'desktop.', 'To go.'),
         caption='Open the screen. Take the controls.',
         copy='Test your UI.\nUse a full desktop.\nFrom wherever you are.',
         detail='Touch · Type · Scroll', label='MORE THAN A CHAT'),
    dict(scene='switch', title=('Take your', 'work with you.'),
         tablet=('Take your', 'work', 'with you.'),
         caption='New workspace. Same code and conversations.',
         copy='From your computer\nto the cloud. Keep\nyour work flowing.',
         detail='Computer → Cloud', label='KEEP YOUR MOMENTUM'),
]


@lru_cache(maxsize=96)
def font(size, weight='Regular', mono=False, display=False):
    f = ImageFont.truetype(str(MONO if mono else SF), int(size))
    if display and not mono:
        weights = {'Regular': 400, 'Medium': 500, 'Semibold': 600, 'Bold': 700, 'Heavy': 800}
        # SF Pro's display optical size gives large headings their proper spacing and shape.
        f.set_variation_by_axes([96, 96, 400, weights.get(weight, 700)])
    else:
        f.set_variation_by_name(weight)
    return f


def text_width(value, size, weight='Regular', tracking=0, mono=False, display=False):
    f = font(size, weight, mono, display)
    return f.getlength(value) + tracking * max(0, len(value)-1)


def write_text(draw, xy, value, size, color, weight='Regular', tracking=0, mono=False, display=False):
    f = font(size, weight, mono, display)
    x, y = xy
    if tracking:
        baseline = y - draw.textbbox((0, 0), value, font=f, anchor='ls')[1]
        for ch in value:
            draw.text((x, baseline), ch, font=f, fill=color, anchor='ls')
            x += draw.textlength(ch, font=f) + tracking
        return x-tracking
    draw.text(xy, value, font=f, fill=color, anchor='lt')
    return x + draw.textlength(value, font=f)


def palette(dark):
    return dict(ink='#f9f7f3' if dark else '#17181b',
                muted='#b2ada7' if dark else '#66615e',
                faint='#77736e' if dark else '#99928a',
                accent='#ff915b' if dark else '#c95224',
                line='#34302d' if dark else '#d9d2c8')


def backdrop(size, dark, index):
    """Warm light and one sculpted orbital line, with a consistent material across the set."""
    w, h = size
    y, x = np.ogrid[0:h, 0:w]
    x, y = x.astype(np.float32)/w, y.astype(np.float32)/h
    tablet = w > h
    cx = (.84 if tablet else .51) + [.0, .14, -.12, .1, -.03, .08][index-1]
    cy = .68 if tablet else .72
    base = np.array((10, 11, 14) if dark else (249, 247, 242), dtype=np.float32)
    rgb = np.broadcast_to(base, (h, w, 3)).copy()
    light = np.exp(-(((x-cx)/.47)**2 + ((y-cy)/.32)**2)*1.5)
    tint = np.array((80, 39, 13) if dark else (-8, -32, -56), dtype=np.float32)
    rgb += light[..., None]*tint
    # An oblique, sharply lit ellipse. Most sits behind the hardware, leaving an elegant edge.
    angle = np.deg2rad([-24, 25, -17, 29, -28, 17][index-1])
    dx, dy = (x-cx)*w, (y-cy)*h
    rx = dx*np.cos(angle)+dy*np.sin(angle)
    ry = -dx*np.sin(angle)+dy*np.cos(angle)
    a, b = (w*.43, h*.37) if tablet else (w*.61, h*.36)
    radius = np.sqrt((rx/a)**2+(ry/b)**2)
    bloom = np.exp(-((radius-1)/.06)**2)
    edge = np.exp(-((radius-1)/.007)**2)
    sheen = .32+.68*np.clip((rx/a+ry/b+2)/4, 0, 1)
    if dark:
        rgb += bloom[..., None]*np.array((51, 19, 3), dtype=np.float32)
        rgb += (edge*sheen)[..., None]*np.array((177, 85, 39), dtype=np.float32)
    else:
        rgb -= bloom[..., None]*np.array((1, 10, 18), dtype=np.float32)
        rgb -= (edge*sheen)[..., None]*np.array((14, 53, 84), dtype=np.float32)
    image = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), 'RGB').convert('RGBA')
    d = ImageDraw.Draw(image)
    p = palette(dark)
    # Precise registration marks echo Mindwire's sharp, open-source identity.
    for px, py in ([(66, 146), (w-66, 146)] if not tablet else [(82, 140), (w-82, 140)]):
        d.line((px-6, py, px+6, py), fill=p['line'], width=1)
        d.line((px, py-6, px, py+6), fill=p['line'], width=1)
    return image


def logo(image, x, y, size, color):
    # Use the actual app brand asset, trimming its transparent source-canvas padding.
    source = Image.open(ROOT/'assets'/'mindwire.png').convert('RGBA').getchannel('A')
    alpha = source.crop(source.getbbox()).resize((size, size), Image.Resampling.LANCZOS)
    mark = Image.new('RGBA', (size, size), color)
    mark.putalpha(alpha)
    image.alpha_composite(mark, (x, y))


def header(image, dark, tablet):
    p = palette(dark)
    d = ImageDraw.Draw(image)
    x, y = (94, 59) if tablet else (82, 65)
    logo(image, x, y-4, 51, p['ink'])
    write_text(d, (x+69, y), 'MindWire', 46, p['ink'], 'Semibold', tracking=-1.1, display=True)
    label = 'OPEN SOURCE'
    right = image.width-(94 if tablet else 83)
    label_w = text_width(label, 20, 'Medium', tracking=2.1)
    d.rounded_rectangle((right-label_w-36, y-1, right+1, y+43), radius=22,
                        outline=p['line'], width=1)
    write_text(d, (right-label_w-18, y+12), label, 20, p['muted'], 'Medium', tracking=2.1)


def gradient_heading(image, xy, value, size, dark):
    mask = Image.new('L', image.size)
    d = ImageDraw.Draw(mask)
    write_text(d, xy, value, size, 255, 'Bold', tracking=-3.4, display=True)
    w, h = image.size
    ramp = np.linspace(0, 1, w, dtype=np.float32)
    first, last = ((255, 191, 141), (255, 107, 55)) if dark else ((154, 64, 27), (232, 106, 56))
    colors = np.array(first)[None, :]*(1-ramp[:, None])+np.array(last)[None, :]*ramp[:, None]
    fill = Image.fromarray(np.repeat(colors[None, :, :], h, axis=0).astype(np.uint8), 'RGB')
    image.paste(fill, (0, 0), mask)


def agent_row(image, x, y, dark, labels=True, size=39):
    p = palette(dark)
    draw = ImageDraw.Draw(image)
    for asset, name in [('codex', 'Codex'), ('claude', 'Claude'), ('opencode', 'OpenCode')]:
        path = ROOT/'assets'/f'{asset}.png'
        if path.exists():
            alpha = Image.open(path).convert('RGBA').getchannel('A')
            box = alpha.getbbox()
            alpha = alpha.crop(box).resize((size, size), Image.Resampling.LANCZOS)
            color = Image.new('RGBA', (size, size), p['ink'])
            color.putalpha(alpha)
            image.alpha_composite(color, (round(x), round(y)))
        x += size+13
        if labels:
            x = write_text(draw, (x, y+3), name, 30, p['muted'], 'Medium')+37
        else:
            x += 24


def phone_layer(screen, screen_width):
    if screen.size != NATIVE_SIZES['iphone']:
        raise ValueError(f'Use the iPhone 17 Pro Max capture, not a notched device: {screen.size}')
    # XCTest exports the app framebuffer without the physical sensor mask. The frame adds
    # the Pro Max's sensor housing only in the reserved status-bar area, never over content.
    bezel = 17
    sh = round(screen_width*screen.height/screen.width)
    w, h = screen_width+bezel*2, sh+bezel*2
    pad = 10
    layer = Image.new('RGBA', (w+pad*2, h+pad*2))
    d = ImageDraw.Draw(layer)
    x, y = pad, pad
    radius = round(screen_width*.14)
    metal = '#9c9287'
    # Restrained metal edge, antenna seams, and side controls. No inflated plastic bezel.
    for offset, length in [(190, 51), (284, 98), (407, 98)]:
        d.rounded_rectangle((x-4, y+offset, x+4, y+offset+length), 3, fill=metal)
    d.rounded_rectangle((x+w-4, y+328, x+w+4, y+485), 3, fill=metal)
    d.rounded_rectangle((x+w-3, y+734, x+w+3, y+829), 3, fill='#655e55')
    d.rounded_rectangle((x, y, x+w, y+h), radius, fill='#08090b', outline=metal, width=2)
    d.rounded_rectangle((x+3, y+3, x+w-3, y+h-3), radius-3, outline='#343230', width=2)
    d.rounded_rectangle((x+6, y+6, x+w-6, y+h-6), radius-6, outline='#151517', width=2)
    resized = screen.resize((screen_width, sh), Image.Resampling.LANCZOS).convert('RGBA')
    mask = Image.new('L', resized.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen_width-1, sh-1), radius-bezel, fill=255)
    layer.paste(resized, (x+bezel, y+bezel), mask)
    d = ImageDraw.Draw(layer)
    scale = screen_width/1320
    island_w, island_h = round(378*scale), round(111*scale)
    ix, iy = x+w//2-island_w//2, y+bezel+round(42*scale)
    d.rounded_rectangle((ix, iy, ix+island_w, iy+island_h), island_h//2, fill='#000000')
    cx, cy, cr = ix+island_w-round(54*scale), iy+island_h//2, round(8*scale)
    d.ellipse((cx-cr, cy-cr, cx+cr, cy+cr), fill='#090c13')
    return layer


def tablet_layer(screen, screen_width):
    bezel = 24
    sh = round(screen_width*screen.height/screen.width)
    w, h = screen_width+bezel*2, sh+bezel*2
    layer = Image.new('RGBA', (w+10, h+10))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((4, 4, w+4, h+4), 63, fill='#08090b', outline='#9d9991', width=2)
    d.rounded_rectangle((8, 8, w, h), 59, outline='#333439', width=2)
    resized = screen.resize((screen_width, sh), Image.Resampling.LANCZOS).convert('RGBA')
    mask = Image.new('L', resized.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen_width-1, sh-1), 40, fill=255)
    layer.paste(resized, (4+bezel, 4+bezel), mask)
    d = ImageDraw.Draw(layer)
    cx, cy = w//2+4, 16
    d.ellipse((cx-4, cy-4, cx+4, cy+4), fill='#17212d', outline='#282d33')
    return layer


def place_device(image, device, x, y, dark, angle=0):
    if angle:
        device = device.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    x, y = round(x-device.width/2), round(y)
    # Keep the entire captured interface visible, including composer and toolbar actions.
    if min(x, y) < 0 or x+device.width > image.width or y+device.height > image.height-16:
        raise ValueError(f'Device outside safe canvas bounds: {x, y, *device.size}')
    shadow = Image.new('RGBA', image.size)
    alpha = Image.new('L', image.size)
    alpha.paste(device.getchannel('A'), (x, y+24))
    alpha = alpha.filter(ImageFilter.GaussianBlur(26))
    alpha = alpha.point(lambda v: round(v*(.8 if dark else .24)))
    shadow.putalpha(alpha)
    image.alpha_composite(shadow)
    image.alpha_composite(device, (x, y))


def tablet_side_copy(image, feature, dark, index):
    p = palette(dark)
    draw = ImageDraw.Draw(image)
    write_text(draw, (97, 291), f'{index:02d}  /', 21, p['accent'], 'Medium', mono=True)
    write_text(draw, (176, 293), feature['label'], 19, p['muted'], 'Medium', tracking=1.15)
    lines = feature['tablet']
    size = 109
    while max(text_width(line, size, 'Bold', -3.4, display=True) for line in lines) > 493:
        size -= 1
    for n, line in enumerate(lines):
        xy = (91, 424+n*123)
        if n == len(lines)-1:
            gradient_heading(image, xy, line, size, dark)
        else:
            write_text(draw, xy, line, size, p['ink'], 'Bold', tracking=-3.4, display=True)
    for n, line in enumerate(feature['copy'].split('\n')):
        write_text(draw, (98, 866+n*49), line, 35, p['muted'])
    draw.line((99, 1090, 206, 1090), fill=p['accent'], width=2)
    if feature['scene'] == 'chat':
        agent_row(image, 99, 1135, dark, labels=False, size=57)
        write_text(draw, (99, 1230), 'Your agent. Your choice.', 25, p['muted'])
    else:
        write_text(draw, (99, 1140), feature['detail'], 28, p['muted'], 'Medium')
    write_text(draw, (99, 1860), 'BUILT FOR IPAD', 20, p['muted'], 'Medium', tracking=2.1)
    write_text(draw, (99, 1906), 'mindwire.sh', 28, p['ink'], 'Medium')


def compose(screen, kind, theme, index, feature):
    dark = theme == 'dark'
    tablet = kind == 'ipad'
    image = backdrop(SIZES[kind], dark, index)
    p = palette(dark)
    header(image, dark, tablet)
    draw = ImageDraw.Draw(image)
    if tablet:
        tablet_side_copy(image, feature, dark, index)
        # The sidebar and the editor are legible together; the native wide layout is the hero.
        layer = tablet_layer(screen, 2020)
        place_device(image, layer, 1691, 352, dark)
    else:
        size = 150
        while max(text_width(line, size, 'Bold', -3.4, display=True) for line in feature['title']) > 1118:
            size -= 1
        write_text(draw, (76, 181), feature['title'][0], size, p['ink'], 'Bold', tracking=-3.4, display=True)
        gradient_heading(image, (76, 333), feature['title'][1], size, dark)
        if feature['scene'] == 'chat':
            agent_row(image, 86, 475, dark, size=37)
        else:
            write_text(draw, (83, 478), feature['caption'], 31, p['muted'])
        widths = [984, 950, 980, 950, 975, 950]
        angles = [0, -1.6, 0, 1.6, 0, -1.3]
        layer = phone_layer(screen, widths[index-1])
        place_device(image, layer, 642, [553, 571, 561, 571, 571, 578][index-1], dark, angles[index-1])
    return image.convert('RGB')
