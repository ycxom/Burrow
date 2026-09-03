// 圆角矩形的边缘折射 —— 「液态玻璃」真正的那一下。
//
// 算法出处：Kyant0/AndroidLiquidGlass（Apache-2.0）里的
// ROUNDED_RECT_REFRACTION_SHADER。KernelSU 的悬浮底栏用的是同一份（经 miuix
// 转了一道），这里把那份 AGSL 翻成 Flutter 的 GLSL。
//
// ## 它和「毛玻璃」差在哪
//
// 毛玻璃只是把背景糊一下。糊得再狠也只是一块半透明面板 —— 因为真玻璃让人
// 认出来的不是模糊，是**边缘那圈把背景拉弯的折射**。所以模糊只给 4dp 左右，
// 主要的活是：离边缘越近，采样坐标越往外推，推的方向是圆角矩形 SDF 的梯度。
//
// ## 踩过的坑：uSize 不是药丸
//
// 第一版假设引擎塞进来的 `uSize` 就是药丸的尺寸。**不是。** 在 BackdropFilter
// 里，`ImageFilter.shader` 拿到的是整块背景纹理（基本上就是全屏），
// `FlutterFragCoord()` 也在那个空间里。
//
// 后果非常直观：SDF 把整个屏幕当成了那个圆角矩形，于是位移量从「十几像素」
// 变成了「近千像素」，每个像素都跑到屏幕另一头去采样，再被色散拆成三路、
// 被饱和度放大 —— 结果是一整块彩色噪点。
//
// 所以现在药丸的位置和尺寸由 Dart 那边量好传进来（uRect），
// 并且**位移一律钳死在药丸短边的一半以内**：万一那个矩形还是不对，
// 最坏也只是边上一圈轻微拖影，不会再变成满屏乱采样。

#include <flutter/runtime_effect.glsl>

// 引擎会把第一个 vec2 设成输入纹理的尺寸（见 ImageFilter.shader 的文档）。
uniform vec2 uSize;

// 药丸在**逻辑像素**下的矩形：xy = 屏幕坐标下的左上角，zw = 宽高。
uniform vec4 uRect;

// 屏幕逻辑尺寸。用来把逻辑像素换算成纹理像素 —— 换算比例是
// `uSize.x / uScreen.x`，这样 DPR 和引擎对背景做的任何降采样都自动抵消。
uniform vec2 uScreen;

// 四角半径（左上、右上、右下、左下），逻辑像素。KernelSU 的 lens 也把
// CornerBasedShape 展开成四个值；否则皮肤换了形状，折射仍会留在旧圆角上。
uniform vec4 uCornerRadii;

// 折射参数，全部是**逻辑像素**：x 折射带宽度，y 折射强度，z 色散。
// 写成绝对值而不是比例，是因为它们该跟着 dp 走 ——
// 输入框长高时那圈玻璃的厚度不该跟着变厚。
uniform vec4 uRefract;

// x: 饱和度（KernelSU 的 vibrancy 用 1.5）；y: 亮度补偿。
uniform vec2 uTone;

// **边缘**的采样柔化半径，逻辑像素。跟着折射的衰减走：贴边最强，往里归零。
//
// 这不是「模糊」—— 真正的高斯模糊已经由外面一层 BackdropFilter 做掉了。
// 这里要治的是另一个毛病：折射把边缘那一圈**压缩**了（一大片背景被挤进
// 几个像素），минification 会当场锯齿化，表现成一圈毛刺。
// 采样时按压缩程度柔化一点，那圈毛刺就没了。
//
// 上一版把整块模糊也放在这里做，用一个 9 点方框、半径给到 20 多个纹理
// 像素 —— 9 个点摊在 40 多像素上根本不是模糊，是**重影**。
uniform float uBlur;

uniform sampler2D uTexture;

out vec4 fragColor;

float radiusAt(vec2 coord, vec4 radii) {
    if (coord.x >= 0.0) {
        return coord.y >= 0.0 ? radii.z : radii.y;
    }
    return coord.y >= 0.0 ? radii.w : radii.x;
}

float sdRoundedRect(vec2 coord, vec2 halfSize, vec4 radii) {
    float radius = radiusAt(coord, radii);
    vec2 c = abs(coord) - (halfSize - vec2(radius));
    return length(max(c, vec2(0.0))) - radius + min(max(c.x, c.y), 0.0);
}

// SDF 的梯度 = 「往外」是哪个方向。折射就是沿着它推采样点。
vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 c = abs(coord) - (halfSize - vec2(radius));
    // 正中心时 sign() 会得到 0，法线就没了。加一个极小的偏移躲开那一个点。
    vec2 s = sign(coord + vec2(1e-6));
    if (c.x >= 0.0 || c.y >= 0.0) {
        vec2 m = max(c, vec2(0.0));
        float len = length(m);
        // 贴着边但还没进圆角时 m 可能是零向量，normalize 会出 NaN，
        // 而 NaN 采样出来是一整块黑斑。
        if (len < 1e-5) return s * vec2(1.0, 0.0);
        return s * (m / len);
    }
    float gx = step(c.y, c.x);
    return s * vec2(gx, 1.0 - gx);
}

// 让位移在贴边处急剧变化、往里迅速衰减 —— 玻璃的厚度是圆弧不是斜坡。
float circleMap(float x) {
    return 1.0 - sqrt(max(0.0, 1.0 - x * x));
}

vec4 tap(vec2 px, vec2 size) {
    // 采样点被推到纹理外时 clamp 会重复最边上那一列 —— 比采到透明黑好，
    // 后者会在药丸边上留一圈黑边。
    vec2 uv = clamp(px / size, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    return texture(uTexture, uv);
}

vec4 sampleAt(vec2 px, vec2 size, float blurPx) {
    if (blurPx <= 0.0) return tap(px, size);
    vec2 d = vec2(blurPx);
    vec4 sum = tap(px, size) * 4.0;
    sum += (tap(px + vec2(d.x, 0.0), size) + tap(px - vec2(d.x, 0.0), size)) * 2.0;
    sum += (tap(px + vec2(0.0, d.y), size) + tap(px - vec2(0.0, d.y), size)) * 2.0;
    sum += tap(px + d, size) + tap(px - d, size);
    sum += tap(px + vec2(d.x, -d.y), size) + tap(px - vec2(d.x, -d.y), size);
    return sum / 16.0;
}

void main() {
    vec2 size = max(uSize, vec2(1.0));
    vec2 coord = FlutterFragCoord().xy;

    // 逻辑像素 → 纹理像素。
    //
    // 引擎给的到底是「整屏背景」还是「只有这一块」，文档没有保证，两种都
    // 见得到。**用长宽比认**：药丸是又扁又长的（300x48，比值 6 上下），
    // 屏幕是竖的（比值 0.5 上下），两者差着一个数量级，认错不了。
    // 这样两种情况都对，不用赌其中一种。
    float texAspect = size.x / size.y;
    float pillAspect = uRect.z / max(uRect.w, 1.0);
    float screenAspect = uScreen.x / max(uScreen.y, 1.0);

    float s;
    vec2 origin;
    vec2 rect;
    if (abs(texAspect - pillAspect) < abs(texAspect - screenAspect)) {
        // 纹理就是药丸本身：整张图都是它，原点在 0。
        s = size.x / max(uRect.z, 1.0);
        origin = vec2(0.0);
        rect = size;
    } else {
        // 纹理是整屏：药丸得按它的全局坐标定位。
        s = size.x / max(uScreen.x, 1.0);
        origin = uRect.xy * s;
        rect = uRect.zw * s;
    }

    float edgeSoftness = uBlur * s;

    // 量出来的矩形不可用（首帧还没测到）时就原样取 ——
    // 宁可这一帧只有外层那道高斯（看着像毛玻璃），也不要拿一个瞎猜的
    // 矩形去算 SDF。
    bool ok = rect.x > 2.0 && rect.y > 2.0;

    vec4 color;
    if (!ok) {
        color = tap(coord, size);
    } else {
        vec2 halfSize = rect * 0.5;
        vec2 local = coord - origin - halfSize;

        float maxRadius = min(halfSize.x, halfSize.y);
        vec4 radii = clamp(uCornerRadii * s, vec4(0.0), vec4(maxRadius));
        float radius = radiusAt(local, radii);
        float height = max(uRefract.x * s, 1e-3);
        // 负号：位移方向朝**内**，于是外面的背景被拉进边缘。原版同此。
        float amount = -uRefract.y * s;
        float aberration = uRefract.z * s;

        float sd = sdRoundedRect(local, halfSize, radii);

        // 法线和衰减各算一次，**折射和色散共用**。
        //
        // 之前色散的方向是 `normalize(shift + 1e-6)` —— 在折射带的内边界上
        // shift 趋近于零，那个 1e-6 就成了主导项，方向逐像素乱翻。表现就是
        // 沿着带边缘的一条彩色噪点（实测在输入框顶边看得很清楚）。
        // 改成直接用法线：它是单位长度、处处连续的，且随衰减一起归零。
        float falloff = 0.0;
        vec2 grad = vec2(0.0);
        if (-sd < height) {
            falloff = circleMap(1.0 - (-min(sd, 0.0)) / height);
            float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
            grad = gradSdRoundedRect(local, halfSize, gradRadius);
        }

        // **这条钳制是安全带。** 矩形万一还是错的，位移也不会超过药丸
        // 短边的一半 —— 边上多一圈拖影，而不是满屏彩色噪点。
        float limit = 0.5 * min(halfSize.x, halfSize.y);
        vec2 shift = clamp(falloff * amount, -limit, limit) * grad;

        // 只在折射带里柔化，而且跟着衰减走 —— 压缩最狠的地方柔化最多，
        // 中间那一大片一个多余的采样都不做。
        float soft = edgeSoftness * falloff;

        if (aberration <= 0.0) {
            color = sampleAt(coord + shift, size, soft);
        } else {
            // 色散：三个通道沿法线各推一点点，边缘就有了极淡的彩虹口。
            // 只分三路而不是原版的七路 —— 手机上这一层每帧都要跑满整个药丸。
            vec2 dir = grad * (aberration * falloff);
            float r = sampleAt(coord + shift + dir, size, soft).r;
            vec4 g = sampleAt(coord + shift, size, soft);
            float b = sampleAt(coord + shift - dir, size, soft).b;
            color = vec4(r, g.g, b, g.a);
        }
    }

    // vibrancy：透过玻璃看到的东西比原来更「有色」，这是苹果那套材质里
    // 很容易被忽略、但少了就发灰的一步。
    float luma = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    color.rgb = clamp(mix(vec3(luma), color.rgb, uTone.x) + uTone.y,
                      vec3(0.0), vec3(1.0));
    fragColor = color;
}
