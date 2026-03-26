# 晗戈五笔 Icon 生成提示词

## 核心概念
- 品牌名：晗戈五笔 (HangeWubi)
- "晗"字是品牌标识，也是菜单栏图标
- 五笔 = 五种笔画输入法
- Rust 引擎 = 高性能、现代
- 风格：简洁、现代、专业

---

## 方案 A：以"晗"字为核心

### A1 - 极简汉字
```
A minimal, modern app icon featuring the Chinese character "晗" centered on a soft rounded square background with a gradient from #2563EB (blue) to #1E40AF (dark blue). The character is in clean white, using a modern sans-serif Chinese typeface. Subtle shadow beneath the character. macOS app icon style, 1024x1024, clean vector look.
```

### A2 - 汉字 + 键盘元素
```
A sleek app icon: the Chinese character "晗" in bold white, placed on a rounded square with a deep blue (#1E3A8A) to teal (#0D9488) gradient. A minimal keyboard key outline subtly frames the character from below, suggesting an input method. macOS Big Sur icon style, 3D-like with soft lighting, 1024x1024.
```

### A3 - 汉字印章风格
```
A modern app icon inspired by Chinese seal carving (篆刻). The character "晗" is rendered in a traditional seal script style, white on a vermillion red (#DC2626) rounded square. Clean, minimal, with a subtle paper texture. The seal aesthetic meets modern app design. macOS icon, 1024x1024.
```

---

## 方案 B：以笔画/书写为核心

### B1 - 五笔笔画抽象
```
A minimal app icon showing five abstract brush strokes (横竖撇捺折) arranged in a harmonious geometric pattern on a rounded square with a gradient from indigo (#4F46E5) to blue (#2563EB). The strokes are white with slight calligraphic variation. Modern, clean, vector style. macOS app icon, 1024x1024.
```

### B2 - 毛笔笔触
```
A sophisticated app icon: a single elegant Chinese calligraphy brush stroke forming an abstract "W" shape (for Wubi) on a dark navy (#0F172A) rounded square. The stroke is rendered in a luminous blue gradient (#60A5FA to #3B82F6) with subtle ink splash effects. Minimalist, artistic. macOS icon, 1024x1024.
```

---

## 方案 C：以键盘/输入为核心

### C1 - 极简键盘
```
A clean app icon showing a minimal keyboard key with the character "晗" on it. Rounded square background in soft blue (#3B82F6). The key has a subtle 3D effect with light top edge and shadow. Modern flat design with depth. macOS Big Sur style icon, 1024x1024.
```

### C2 - 光标 + 汉字
```
A minimal app icon: a text cursor (blinking caret line) next to the Chinese character "晗", both in white, on a rounded square with a smooth gradient from #2563EB to #7C3AED (blue to purple). Clean, modern, represents text input. macOS icon style, 1024x1024.
```

---

## 方案 D：几何/抽象

### D1 - 五边形
```
A geometric app icon featuring a regular pentagon (representing the "five" in 五笔/Wubi) with the character "晗" centered inside. The pentagon has a blue (#2563EB) gradient fill, white character, on a white rounded square with subtle shadow. Minimal, symbolic. macOS icon, 1024x1024.
```

### D2 - 方块拼字
```
A modern app icon showing four small colored squares arranged in a 2x2 grid pattern (representing the wubi encoding structure), with subtle Chinese character stroke elements emerging from the grid. Colors: shades of blue (#1D4ED8, #3B82F6, #60A5FA, #93C5FD). Rounded square background in white. macOS icon, 1024x1024.
```

---

## 通用后缀（可追加到任何提示词后面）

### 提升质量
```
High quality, professional app icon design, suitable for macOS App Store. Sharp, crisp edges. No text other than the specified character. Centered composition. Glossy or matte finish.
```

### 指定风格
```
Style reference: Apple macOS Big Sur icon guidelines. Rounded squircle shape. Subtle 3D lighting from top-left. Soft shadow.
```

### 多尺寸适配
```
Design should remain recognizable at small sizes (16x16, 32x32). Avoid fine details that disappear at small scale. Strong silhouette.
```

---

## 推荐生成工具
- Midjourney（质量最好，用 --style raw --ar 1:1）
- DALL-E 3（理解中文字符较好）
- Stable Diffusion + ControlNet（精确控制构图）
- Recraft.ai（专门做 icon，免费）

## 推荐组合
个人建议优先尝试 **A1**（最简洁）或 **C1**（最直观），这两个在小尺寸下辨识度最高。
