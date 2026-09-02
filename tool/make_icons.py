#!/usr/bin/env python3
"""从品牌图生成 Android 启动图标。

    python tool/make_icons.py [源图]

源图默认是 `assets/branding/logo.png`，一张「图标方块 + Burrow 字标」的
竖版品牌图。脚本自己把上面那块方块找出来，字标不进图标。

## 为什么是脚本而不是 flutter_launcher_icons

那个包只会把一张图缩放到各个密度，**自适应图标的前景它照样只是缩放**——
而自适应图标的前景有一个 108dp 画布里只有中间 66dp 一定可见的规矩，
直接把满幅的图丢进去，各家启动器的圆形/方形遮罩会把石头边缘啃掉一圈。
这里的做法是：前景按安全区缩进，背景用一个和方块底色一样的纯色，
于是方块自己的圆角在背景上是看不见的，遮罩切到哪里都不露馅。

跑一次就够，产物入 git。图标不是每次构建都要重算的东西。
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'

# 传统图标：按密度给的 dp 都是 48。
LEGACY = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

# 自适应图标：画布固定 108dp。
ADAPTIVE = {
    'mipmap-mdpi': 108,
    'mipmap-hdpi': 162,
    'mipmap-xhdpi': 216,
    'mipmap-xxhdpi': 324,
    'mipmap-xxxhdpi': 432,
}

# 前景在 108dp 画布里占多宽。72 是遮罩后**一定**可见的范围，66 是安全区。
# 取 74 略微出一点头：方块的圆角本来就该被遮罩吃掉，露一点反而更满。
FOREGROUND_DP = 74.0

# 方块底色。取的是卡片边缘一圈的中位数 —— 背景和它一致，圆角才会隐形。
# 改这里要同时改 res/values/ic_launcher_background.xml。
BACKGROUND = '#101114'

# 前景边缘往透明里化开多少（占边长的比例）。
#
# **不化开的话自适应图标上能看见一个方框。** 卡片本身带一点从上到下的
# 明暗渐变，纯色背景不可能同时对上它的上边和下边，差那么两三个色阶，
# 在深色启动器背景上就是一道清清楚楚的边。化开之后没有"边"这个东西了。
FEATHER = 0.06


def find_tile(image: Image.Image) -> tuple[int, int, int, int]:
    """在品牌图里找出图标方块，返回一个正方形 box。

    分两步，两步都有它必须存在的理由：

    1. **按空行把内容切成几块。** 品牌图是「方块在上、字标在下」，中间隔着
       一条纯黑。不切开的话，字标那一行比方块还宽（745 vs 687），
       "取最宽的一行" 会一头栽进字标里。切开之后按长宽比挑，方块是接近
       正方形的那一块，字标是扁的。

    2. **在方块那一块里，用宽度定边长、用满宽的行定中心。** 直接取包围盒会
       把圆角外溢的辉光算进去 —— 辉光只往下方溢（洞口的光），于是包围盒
       是个竖长方形，补成正方形时中心就偏了。左右两条边是硬边，可信。
    """
    lum = np.asarray(image.convert('RGB')).astype(int).sum(axis=2)
    spans: list[tuple[int, int, int]] = []
    for y in range(lum.shape[0]):
        cols = np.where(lum[y] > 40)[0]
        spans.append((y, int(cols.min()), int(cols.max())) if len(cols)
                     else (y, -1, -1))

    bands: list[list[tuple[int, int, int]]] = []
    for span in spans:
        if span[1] < 0:
            bands.append([]) if bands and bands[-1] else None
            continue
        if not bands or not bands[-1]:
            bands.append([])
        bands[-1].append(span)
    bands = [b for b in bands if b]
    if not bands:
        raise SystemExit('源图全黑，找不到图标')

    def aspect(band: list[tuple[int, int, int]]) -> float:
        width = max(s[2] for s in band) - min(s[1] for s in band) + 1
        return width / len(band)

    band = min(bands, key=lambda b: abs(aspect(b) - 1.0))

    side = max(s[2] - s[1] + 1 for s in band)
    # 只用「接近满宽」的那些行定上下中心。93% 是给圆角留的余量。
    solid = [s for s in band if s[2] - s[1] + 1 > side * 0.93]
    center_x = (min(s[1] for s in solid) + max(s[2] for s in solid)) // 2
    center_y = (solid[0][0] + solid[-1][0]) // 2
    left = center_x - side // 2
    top = center_y - side // 2
    return (left, top, left + side, top + side)


def feather_mask(side: int) -> Image.Image:
    """一张把方块边缘化进背景的 alpha 遮罩。

    形状跟着卡片的圆角走（半径按 iOS/Android 图标常见的 22% 取），再整体
    高斯模糊 —— 模糊会把硬边变成一条渐变带，那条带子从卡片色过渡到背景色，
    两者差几个色阶也看不出来了。
    """
    blur = max(1.0, side * FEATHER)
    # 先按模糊半径往里缩一圈再画，否则模糊会把不透明区域啃掉一截，
    # 图标看起来比设定的小。
    inset = round(blur)
    mask = Image.new('L', (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, side - 1 - inset, side - 1 - inset),
        radius=round(side * 0.22),
        fill=255,
    )
    return mask.filter(ImageFilter.GaussianBlur(blur))


def write_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format='PNG', optimize=True)
    print('  ', path.relative_to(ROOT))


def main() -> None:
    # Windows 控制台默认是 GBK，中文进度会变成乱码。
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'assets' / 'branding' / 'logo.png'
    if not source.exists():
        raise SystemExit(f'找不到源图：{source}')

    logo = Image.open(source).convert('RGBA')
    box = find_tile(logo)
    tile = logo.crop(box)
    print(f'图标方块：{box}，{tile.size[0]}×{tile.size[1]}')

    print('传统图标：')
    for folder, size in LEGACY.items():
        write_png(tile.resize((size, size), Image.LANCZOS),
                  RES / folder / 'ic_launcher.png')

    print('自适应前景：')
    for folder, canvas in ADAPTIVE.items():
        inner = round(canvas * FOREGROUND_DP / 108.0)
        art = tile.resize((inner, inner), Image.LANCZOS)
        art.putalpha(feather_mask(inner))
        layer = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
        offset = (canvas - inner) // 2
        layer.paste(art, (offset, offset), art)
        write_png(layer, RES / folder / 'ic_launcher_foreground.png')

    print('完成。XML 和背景色在 res/mipmap-anydpi-v26 与 res/values 里，不由脚本生成。')


if __name__ == '__main__':
    main()
