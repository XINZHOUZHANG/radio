#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TX-5DR 应用图标生成器。
用法:  python3 tools/make_appicon.py [--out <AppIcon.appiconset 目录>]
只依赖 Pillow。输出无 alpha 通道的 RGB PNG（App Store 要求）。"""
import argparse, json, os, sys
from PIL import Image, ImageDraw

SS = 4096                      # 超采样画布，最后 LANCZOS 缩到目标尺寸
BG_WARM, BG_COLD = '#123840', '#070C11'
TEAL, AMBER, TRACK = '#29D1B7', '#FFAD2E', '#14303A'
RING_R, RING_W, RING_SWEEP = 400, 70, 252          # 半径 / 环宽 / 扫过角度（FT8 时隙进度）
BARS = [(240, TEAL), (436, TEAL), (312, AMBER)]    # 高度, 颜色
BAR_W, BAR_GAP = 112, 58

IPHONE = [("20x20","2x",40), ("20x20","3x",60), ("29x29","2x",58), ("29x29","3x",87),
          ("40x40","2x",80), ("40x40","3x",120), ("60x60","2x",120), ("60x60","3x",180)]
IPAD = [("20x20","1x",20), ("20x20","2x",40), ("29x29","1x",29), ("29x29","2x",58),
        ("40x40","1x",40), ("40x40","2x",80), ("76x76","1x",76), ("76x76","2x",152),
        ("83.5x83.5","2x",167)]

def background(size):
    r = int(0.78 * size)
    mask = Image.new('L', (size, size), 255)
    mask.paste(Image.radial_gradient('L').resize((r*2, r*2), Image.LANCZOS),
               (size//2 - r, int(0.62*size) - r))
    return Image.composite(Image.new('RGB', (size, size), BG_COLD),
                           Image.new('RGB', (size, size), BG_WARM), mask)

def render(size):
    im = background(size); d = ImageDraw.Draw(im); u = size / 1024.0
    box = [(512-RING_R)*u, (512-RING_R)*u, (512+RING_R)*u, (512+RING_R)*u]
    d.arc(box, 0, 360, fill=TRACK, width=max(1, int(RING_W*u)))
    d.arc(box, -90, -90+RING_SWEEP, fill=TEAL, width=max(1, int(RING_W*u)))
    total = len(BARS)*BAR_W + (len(BARS)-1)*BAR_GAP
    x = (1024 - total) / 2.0
    for h, col in BARS:
        d.rounded_rectangle([x*u, (512-h/2)*u, (x+BAR_W)*u, (512+h/2)*u],
                            radius=BAR_W/2*u, fill=col)
        x += BAR_W + BAR_GAP
    return im

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=None, help='AppIcon.appiconset 目录')
    a = ap.parse_args()
    out = a.out
    if out is None:
        hits = []
        for root, dirs, _ in os.walk('.'):
            if '.git' in root or 'DerivedData' in root: continue
            for dn in dirs:
                if dn == 'AppIcon.appiconset': hits.append(os.path.join(root, dn))
        if len(hits) == 1: out = hits[0]
        elif not hits:
            sys.exit('找不到 AppIcon.appiconset，请用 --out 指定路径')
        else:
            sys.exit('找到多个 AppIcon.appiconset，请用 --out 指定其一:\n  ' + '\n  '.join(hits))
    os.makedirs(out, exist_ok=True)
    master = render(SS)
    wanted = sorted({px for _, _, px in IPHONE + IPAD} | {1024})
    for px in wanted:
        master.resize((px, px), Image.LANCZOS).convert('RGB')\
              .save(os.path.join(out, 'icon-%d.png' % px), optimize=True)
    images = [{"idiom": "iphone", "size": s, "scale": sc, "filename": "icon-%d.png" % px}
              for s, sc, px in IPHONE]
    images.extend({"idiom": "ipad", "size": s, "scale": sc, "filename": "icon-%d.png" % px}
                  for s, sc, px in IPAD)
    images.append({"idiom": "ios-marketing", "size": "1024x1024", "scale": "1x",
                   "filename": "icon-1024.png"})
    with open(os.path.join(out, 'Contents.json'), 'w', encoding='utf-8') as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
                  f, indent=2, ensure_ascii=False)
        f.write('\n')
    for px in wanted:
        p = os.path.join(out, 'icon-%d.png' % px)
        im = Image.open(p)
        assert im.mode == 'RGB' and im.size == (px, px), p
    print('已写入 %s：%d 个 PNG + Contents.json' % (out, len(wanted)))

if __name__ == '__main__':
    main()
