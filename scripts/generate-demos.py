#!/usr/bin/env python3
"""Render original, schematic README animations. Requires Pillow (docs tooling only).

    python3 -m venv .build/readme-tools
    .build/readme-tools/bin/pip install Pillow
    .build/readme-tools/bin/python scripts/generate-demos.py
"""
from pathlib import Path
import math
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parents[1] / 'assets' / 'demos'
W, H = 900, 480
BG = '#252729'
INK = '#eee9df'
MUTED = '#aaa79f'
ACCENT = '#d29b7e'
FONT = Path('/System/Library/Fonts/Supplemental/Arial.ttf')

def font(size):
    return ImageFont.truetype(str(FONT), size)

def text(d, xy, value, size=18, fill=INK):
    d.text(xy, value, font=font(size), fill=fill)

def ease(t):
    t = max(0, min(1, t))
    return t*t*(3-2*t)

def card(d, x, y, title, active=False, tab=False):
    x, y = int(x), int(y)
    d.rounded_rectangle((x, y, x+246, y+244), 13, fill='#e8e3d8' if active else '#aaa99f',
                        outline=ACCENT if active else '#bbb9af', width=3 if active else 1)
    text(d, (x+18, y+16), title, 17, '#363736')
    d.line((x+16, y+48, x+230, y+48), fill='#c3beb3', width=1)
    if tab:
        for i, label in enumerate(('Overview', 'Notes')):
            d.rounded_rectangle((x+15+i*112, y+59, x+119+i*112, y+88), 5, fill='#d1c7b9')
            text(d, (x+24+i*112, y+65), label, 12, '#55534e')
    for i, width in enumerate((175, 202, 154, 188)):
        yy = y + (109 if tab else 76) + i*27
        d.rounded_rectangle((x+18, yy, x+width, yy+7), 3, fill='#c9c4b9' if active else '#96978f')

def base(title, subtitle):
    im = Image.new('RGB', (W,H), BG)
    d = ImageDraw.Draw(im)
    text(d, (30,22), 'PAPERI  /  '+title, 21)
    text(d, (30,55), subtitle, 16, MUTED)
    d.rounded_rectangle((24,90,876,374), 16, fill='#323536')
    return im, d

def fingers(d, x, y, direction):
    # Three contacts make the trackpad gesture explicit.
    for dx in (-13,0,13):
        d.ellipse((x+dx-4,y-4,x+dx+4,y+4),fill=ACCENT)
    text(d,(560,414),direction,16,ACCENT)

def drag_card(d, x, y, title, height=244, active=False, ghost=False):
    x, y = round(x), round(y)
    fill = '#625b53' if ghost else ('#e8e3d8' if active else '#aaa99f')
    d.rounded_rectangle((x,y,x+246,y+height),12,fill=fill,
                        outline=ACCENT if active or ghost else '#bbb9af',width=2)
    text(d,(x+16,y+13),title,17,INK if ghost else '#363736')
    d.line((x+14,y+43,x+232,y+43),fill='#8e887e',width=1)
    for i in range(2 if height<150 else 5):
        yy=y+60+i*26
        d.rounded_rectangle((x+16,yy,x+197-(i%2)*32,yy+6),3,fill='#81776c' if ghost else '#c3beb3')


def pointer(d, x, y, held):
    d.polygon([(x,y),(x+3,y+21),(x+9,y+15),(x+15,y+25),
               (x+20,y+22),(x+14,y+12),(x+23,y+10)],fill=INK,outline=BG)
    if held:
        d.ellipse((x-9,y-9,x+9,y+9),outline=ACCENT,width=2)


def drop_preview(d, x, y, height, mode, label):
    if mode=='bottom':
        bounds=(x+5,y+height/2+3,x+241,y+height-5)
        for yy in (y+height*.25,y+height*.75):
            for xx in range(int(x)+8,int(x)+240,12):
                d.line((xx,yy,xx+6,yy),fill=ACCENT,width=2)
    elif mode=='left':
        bounds=(x+5,y+5,x+120,y+height-5)
        for xx in (x+61,x+184):
            for yy in range(int(y)+8,int(y+height)-8,12):
                d.line((xx,yy,xx,yy+6),fill=ACCENT,width=2)
    else:
        bounds=(x+5,y+5,x+241,y+height-5)
    d.rounded_rectangle(bounds,6,fill='#756457',outline=ACCENT,width=2)
    # Keep the label below the pointer and above the preview border.
    text(d,(x+17,y+height-29),label,14,INK)


def render_drag(t):
    phase=min(2,int(t*3)); u=min(1,t*3-phase)
    names=('1 / Reorder columns','2 / Tile vertically','3 / Pull out a column')
    hints=('Drag to the middle, then release to swap.',
           'Drag to the bottom zone, then release to stack.',
           'Drag to the left zone of the other stacked window, then release.')
    im,d=base('DRAG TO ARRANGE',hints[phase])
    text(d,(30,416),names[phase],18,ACCENT)
    text(d,(510,416),'Title bar drag  /  preview  /  release',16,MUTED)
    move=ease((u-.13)/.38); settle=ease((u-.69)/.14)
    held=.1<u<.69
    preview=.43<u<.69
    if phase==0:
        # Browser starts left; Editor is dragged from the right onto its center.
        drag_card(d,180+290*settle,110,'Browser')
        if u>=.69:
            drag_card(d, (470-290*move)*(1-settle)+180*settle,
                      (110+95*move)*(1-settle)+110*settle,'Editor',active=True)
        else:
            drag_card(d,470,110,'Editor')
            if held: drag_card(d,470-290*move,110+95*move,'Editor',ghost=True)
        if preview: drop_preview(d,180,110,244,'middle','Swap')
        px,py= (470-290*move+100,132+95*move) if u<.69 else (280,227)
    elif phase==1:
        # Editor now starts left. Bottom-quarter pointer chooses vertical tiling.
        drag_card(d,470-145*settle,110,'Browser',height=244-126*settle)
        if u>=.69:
            drag_card(d,470-145*settle,288-52*settle,'Editor',height=244-126*settle,active=True)
        else:
            drag_card(d,180,110,'Editor',active=True)
            if held: drag_card(d,180+290*move,110+178*move,'Editor',ghost=True)
        if preview: drop_preview(d,470,110,244,'bottom','Stack below')
        px,py=570,310
        if u<.69: px,py=280+290*move,132+178*move
    else:
        # Same-column target exposes left/right zones for unstacking.
        drag_card(d,325+145*settle,110,'Browser',height=118+126*settle)
        if u>=.69:
            drag_card(d,325-145*settle,236-126*settle,'Editor',height=118+126*settle,active=True)
        else:
            drag_card(d,325,236,'Editor',height=118,active=True)
            if held: drag_card(d,325-70*move,236-105*move,'Editor',height=118,ghost=True)
        if preview: drop_preview(d,325,110,118,'left','New column left')
        px,py=425-70*move,258-105*move
    pointer(d,px,py,held)
    # Keep moving illustrations inside the desktop canvas.
    d.rectangle((0,375,899,479),fill=BG)
    text(d,(30,416),names[phase],18,ACCENT)
    text(d,(510,416),'Title bar drag  /  preview  /  release',16,MUTED)
    return im


def render(kind, t):
    if kind == 'dragging':
        return render_drag(t)
    if kind == 'navigation':
        p = ease((t-.18)/.38)
        im,d=base('MOVE THROUGH YOUR WORKSPACE','Swipe left to reveal the column on the right.')
        for i,title in enumerate(('Files','Browser','Editor','Notes')):
            card(d, 60+i*266-266*p, 110, title, active=(i==(2 if p>.5 else 1)))
        d.rectangle((0,90,23,375),fill=BG); d.rectangle((877,90,899,375),fill=BG)
        fingers(d, 760-120*p, 402,'3 fingers   /   swipe left')
        text(d,(30,416),'One column at a time. Windows keep their width.',16,MUTED)
    elif kind == 'close-window':
        p=ease((t-.14)/.36); gap=ease((t-.55)/.23)
        im,d=base('FLICK TO CLOSE','Swipe up, then release. The remaining columns close the gap.')
        card(d,60+133*gap,110,'Files')
        card(d,592-133*gap,110,'Editor')
        card(d,326,110-420*p,'Browser',True)
        # Clip the diagram's moving card to the desktop viewport.
        d.rectangle((0,0,899,89),fill=BG)
        text(d,(30,22),'PAPERI  /  FLICK TO CLOSE',21)
        text(d,(30,55),'Swipe up, then release. The remaining columns close the gap.',16,MUTED)
        fingers(d,760,420-22*p,'3 fingers   /   swipe up')
        text(d,(30,416),'Pull back before release to cancel.',16,MUTED)
    else:
        down=ease((t-.1)/.2); right=ease((t-.35)/.28)
        im,d=base('DOWN, THEN RIGHT','Turn without lifting to change New Window into Close Tab.')
        card(d,60,110,'Files'); card(d,326,110,'Browser',True,tab=True); card(d,592,110,'Editor')
        if .16<t<.88:
            closing=right>.08
            label=('Release to Close' if right>.8 else 'Close Tab') if closing else 'New Window'
            color='#d99b91' if right>.8 else INK
            x=450 if not closing else 410+40*right
            d.rounded_rectangle((x-108,260,x+108,309),24,fill='#252729',outline=color,width=2)
            text(d,(x-88,275),label,17,color)
            d.arc((x+76,275,x+94,293),-90,-90+max(.01,right if closing else down*.4)*359,fill=color,width=3)
        if t>=.88:
            d.rounded_rectangle((453,169,557,198),5,fill='#e8e3d8')
            text(d,(400,284),'Tab closed',16,'#55534e')
        # L-shaped finger path; the right leg is deliberately sequential.
        d.line((719,391,719,413,800,413),fill='#605951',width=2)
        fingers(d,719+81*right,391+22*down,'3 fingers   /   down, then right')
        text(d,(30,416),'A short turn cancels both actions.',16,MUTED)
    return im

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for kind in ('navigation','close-window','close-tab','dragging'):
        count = 216 if kind == 'dragging' else 72
        frames=[render(kind,i/(count-1)) for i in range(count)]
        # A shared palette prevents color shimmer between frames.
        palette=frames[0].quantize(colors=96)
        frames=[im.quantize(palette=palette,dither=Image.Dither.NONE) for im in frames]
        path=OUT/(kind+'.gif')
        frames[0].save(path,save_all=True,append_images=frames[1:],duration=[65]*(count-1)+[1200],loop=0,optimize=True,disposal=2)
        print(path.relative_to(OUT.parents[1]), path.stat().st_size)

if __name__ == '__main__':
    main()
