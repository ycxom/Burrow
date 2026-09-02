# 皮肤包

Burrow 的聊天界面可以整套替换。做法不是让皮肤包描述控件树，而是**骨架归 app、
样式归皮肤**——对应到 Web 就是 Shadow DOM + `::part()`：你拿到的是 CSS，不是 HTML。

这条边界决定了后面所有设计：皮肤包永远是纯数据，没有条件、没有循环、没有脚本。
一个坏皮肤最多不好看，不会让界面失效。

---

## 1. 最小的皮肤包

一个 `.json` 文件就是一个皮肤包：

```json
{
  "schema": 2,
  "id": "ycxom.dusk",
  "name": "暮色",
  "tokens": { "dark": { "brand": "#8F83FF" } }
}
```

带图片的皮肤包打成 `.zip`，根目录（或单层子目录）下放 `skin.json` 和 `assets/`。

**导入**：设置 → 现代聊天界面 → 皮肤包 → 导入皮肤包。可以选文件，也可以直接
从剪贴板粘一段 JSON。「导出当前配色」会把当前皮肤复制成一份可以直接发出去的
JSON。

---

## 2. 顶层字段

| 字段 | 说明 |
|---|---|
| `schema` | manifest 版本，当前是 `2`。比当前新的整包拒绝 |
| `id` | **必填**，且必须带命名空间（含 `.` 或 `/`），例如 `ycxom.dusk`。内置 ID 被保留 |
| `name` | **必填**，显示名 |
| `description` / `author` | 可选 |
| `extends` | 以哪个**内置**皮肤为基座：`nekogram`（默认）、`amethyst_glass`、`slate_flat` |
| `preview` | 列表里那三个色点。省略时从令牌推导 |
| `vars` | 变量表，见 §3 |
| `tokens` | 30 个颜色令牌，见 §4 |
| `parts` | 部件样式与版式，见 §5 |

**不允许链式继承**：`extends` 只能指向内置皮肤。想基于别人的皮肤改，就把它下载
下来改一份——这条限制消灭了环检测和加载顺序的全部复杂度。

---

## 3. 变量与表达式

```json
"vars": {
  "accent":  "#8F83FF",
  "density": 1.0,
  "pad":     "calc(var(density) * 10)"
}
```

之后任何颜色或数字都可以写 `"var(accent)"`。求值结果**只可能是数或颜色**。

可用函数，全部是纯函数：

| 写法 | 说明 |
|---|---|
| `var(name)` | 取变量。参数是裸标识符，不是表达式 |
| `calc(expr)` | 等价于括号，只为可读性 |
| `clamp(lo, x, hi)` / `min(a,b)` / `max(a,b)` | |
| `alpha(color, a)` | 改透明度 |
| `mix(a, b, t)` | 线性混色 |
| `lighten(c, t)` / `darken(c, t)` | |

四则运算 `+ - * /` 只对数字成立。颜色写法只认 `#RRGGBB` 和 `#AARRGGBB`。

几条容易踩的：

- **不支持单位。** `"16px"` 整条作废回落基座值，写 `16`。
- **裸标识符不是变量。** 写 `var(density)`，不是 `density`。和 CSS 一样。
- 循环引用、未定义变量、颜色参与算术，都只让**用到它的那一个属性**回落，
  不会让整个皮肤包装不上。

---

## 4. 令牌（换配色）

```json
"tokens": {
  "all":   { "brand": "var(accent)" },
  "light": { "bubbleOut": "#E7E2FF" },
  "dark":  { "bubbleOut": "#514787" }
}
```

`all` 同时作用于明暗两套，`light` / `dark` 分别覆盖。**稀疏合并**：没写的令牌保持
基座值，所以新版本给 `ChatTokens` 加令牌时老皮肤包自动继承新默认值。

令牌名见 [chat_theme.dart](../lib/src/ui/chat_theme.dart) 的 `ChatTokens`：

```
bgPrimary  bgSecondary  bgTertiary  bgBrandSecondary  bgErrorSecondary
tintPrimary  tintSecondary  tintTertiary  tintError  tintWarning  tintSuccess
borderPrimary  brand
wallpaperTop  wallpaperBottom
bubbleIn  bubbleOut  tintOnIn  tintOnOut  timeIn  timeOut
servicePill  tintOnService
headerBg  composerBg  composerField
composerDockTop  composerDockBottom  composerDockRim  composerDockShadow
```

拼错的键会被忽略并在导入后的「已自动修正」里列出来。

---

## 5. 部件（换版式）

```json
"parts": {
  "bubble":           { "radius": 16, "padding": 11 },
  "bubble.out":       { "background": { "gradient": ["#8F83FF", "#514787"], "angle": 140 } },
  "bubble.out:first": { "radius": { "tr": 4 } },
  "header:dark":      { "background": { "color": "#1715217F", "blur": 24 } },
  "header.drawer":    { "icon": "menu_open", "shape": "circle" },
  "layout":           { "bubble": "tail", "time": "inside" }
}
```

### 5.1 部件名

| 部件 | 是什么 |
|---|---|
| `shell.background` | 聊天区壁纸层 |
| `header` | 顶栏本身 |
| `header.title` / `header.subtitle` / `header.avatar` / `header.action` | 顶栏里的元素 |
| **`header.drawer`** | 抽屉入口。**必留**，见 §6 |
| `list` | 消息列表的内边距 |
| `bubble` | 气泡的抽象基（自己不渲染） |
| `bubble.in` / `bubble.out` / `bubble.error` | 收到 / 发出 / 报错气泡 |
| `bubble.time` | 气泡里那行时间戳 |
| `bubble.tail` | 尾巴。只认 `size`（宽度）和 `visible` |
| `avatar` | 头像的抽象基 |
| `avatar.assistant` / `avatar.user` | |
| `date.pill` | 日期分隔与系统提示胶囊 |
| `composer.dock` | 输入区外层底座 |
| **`composer.field`** | 输入框本体。**必留** |
| `composer.send` / `composer.icon` | 发送键 / 输入框里的图标按钮 |

**继承只有两条**：`bubble` → `bubble.in/out/error`，`avatar` → `avatar.assistant/user`。

`header` 和 `header.title` **互不继承**。让点号变成通用层级听起来更规整，实际后果是
给顶栏加一层毛玻璃会把标题也变成毛玻璃——规整的规则在这里给出的是错误答案。

### 5.2 状态修饰符（CSS 伪类的对应物）

`bubble.out:first`、`header:scrolled`、`composer.field:focused`。

| 修饰符 | 触发 |
|---|---|
| `:first` / `:last` | 一组连续消息里的第一条 / 最后一条 |
| `:generating` | 正在流式输出 |
| `:scrolled` | 列表已滚离顶部 |
| `:focused` | 输入框获得焦点 |
| `:light` / `:dark` | 只在对应明暗模式下生效 |

状态样式在**加载时**就被合成为完整样式，所以只写要变的那一条属性就行，其余
继承无条件那份。

### 5.3 属性

| 属性 | 取值 |
|---|---|
| `background` | `"#RRGGBB"`，或 `{ color, gradient: [...], angle, image, fit, imageOpacity, blur }` |
| `border` | `"#RRGGBB"` 或 `{ color, width }` |
| `radius` | 数字，或 `{ all, tl, tr, br, bl }` |
| `shadow` | `{ color, blur, spread, dx, dy }`、它们的数组（最多 4 层），或 `"none"` 去掉内置阴影 |
| `padding` / `margin` | 数字、`[水平, 垂直]`，或 `{ l, t, r, b, h, v }` |
| `size` | 方形尺寸（头像、圆形按钮、尾巴宽度） |
| `height` | 顶栏高度 |
| `maxWidth` | 气泡最大宽度占屏宽的比例，`0.3`–`1.0` |
| `text` | `{ size, height, spacing, weight, color, monospace }` |
| `icon` | `"menu_open"` 或 `{ name, size, color }`，名字见 `skinIcons` |
| `opacity` / `transform` | `{ dx, dy, scale, rotate }` |
| `shape` | `rounded` / `circle` / `stadium` |
| `visible` | `false` 隐藏。**必留部件上会被忽略** |

图标只能从白名单里挑（见 [skin_style.dart](../lib/src/ui/skin_style.dart) 的
`skinIcons`）。不支持任意码点：那既没法 tree-shake，又会因为 Material 图标码点在
版本间变动而在某次升级后悄悄变成另一个图标。

字体只有 `monospace` 一个开关，不能指定字体名——皮肤包带不了字体文件，而写一个
用户设备上没有的字体名只会静默回落。

### 5.4 版式开关

```json
"layout": {
  "bubble":   "tail | plain | card",
  "time":     "inside | outside | hidden",
  "avatar":   "side | none",
  "composer": "floating | docked",
  "header":   "bar | transparent"
}
```

`bubble: tail` 是 Telegram 那种带尾巴的形状；此时 `border` 不生效（描边要沿着尾巴
走，而尾巴是一条自定义路径）。

---

## 6. 必留部件

`header.drawer`（抽屉入口）和 `composer.field`（输入框）**可以改样式，不能不显示**。

这不是靠校验 manifest 实现的——让一个按钮事实上消失至少有六条路，schema 检查
一条都拦不住。所以逐条钳死：

| 招数 | 结果 |
|---|---|
| `visible: false` | 忽略 |
| `opacity: 0` | 钳到 ≥ 0.55 |
| 尺寸归零 | 钳到 ≥ 48×48（Material 最小可触达） |
| `transform` 推出屏幕 | 位移钳到 ±12，缩放钳到 ≥ 0.75 |
| 图标色写成背景色 | 对比度不足就**只**丢掉这一个属性，回落骨架色 |
| 用别的图层盖住 | 骨架固定 z 序，抽屉入口画在皮肤可控图层之上 |

另外还有三条与皮肤完全无关的逃生舱：

1. **从屏幕边缘右滑**唤出抽屉。
2. **长按抽屉入口** → 用内置样式渲染的菜单，里面有「临时停用皮肤」。
3. **外观页永远用内置主题渲染**（预览区除外），所以哪怕皮肤把界面变成一片纯色，
   换回来的入口仍然可读。

---

## 7. 和用户自己的设置谁说了算

外观页里那些设置（壁纸、头像、输入区材质）是**用户覆盖层**，压过皮肤：

```
内置基座  ←  皮肤包  ←  用户在外观页的显式改动
```

具体来说，壁纸的优先级是：用户选的图片 > 用户选的非 `classic` 预设 >
皮肤的 `shell.background` > 令牌里的 `wallpaperTop/Bottom`。

理由是：装一个新皮肤时，不该发现自己明确设过的背景被悄悄换掉了。

---

## 8. 装不上的情况

只有三类会让整包被拒绝：

- `schema` 比当前版本新；
- 缺 `id` / `name`，或 `id` 占用了内置名 / 没带命名空间；
- **对比度闸门**：正文与页面底色、气泡文字与气泡底色几乎没有对比度。

最后一条拦的不是可读性，是「皮肤把界面变成一片纯色，用户再也换不回来」。导入是
一次显式操作，在那里报错代价最低。

其余问题（拼错的键、无法求值的表达式、越界的数值、指向包外的资源路径）都只影响
对应的那一个属性，并在导入后的「已自动修正」对话框里列出来。

---

## 9. 装在哪

```
<appSupport>/skins/<sanitized-id>/skin.json
<appSupport>/skins/<sanitized-id>/assets/...
```

**不在 rootfs 里**：rootfs 会被「代目录 + 原子 rename」整个换掉，换个发行版皮肤就
没了；而降级模式下压根没有 rootfs。

没有索引文件——目录在就是装了，所以索引和磁盘不可能不一致。上限：manifest
256 KB、单张资源 8 MB、整包 20 MB、资源数 16。
