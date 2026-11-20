# 第三方声明

本项目自身采用 Apache-2.0（见 `LICENSE`、`NOTICE`）。以下为随仓库分发的第三方数据与主要依赖。

## 数据文件

以下三份数据在 `data/` 下，其中 `wubi86.txt`、`pinyin.txt` 另在 `platform/android/app/src/main/assets/data/` 有字节相同的副本。上游许可证依据为各上游仓库的 LICENSE 文件（经 GitHub API 核实）。

### 1. 五笔 86 码表

- 路径：`data/wubi86.txt`、`platform/android/app/src/main/assets/data/wubi86.txt`
- 上游：rime-wubi86-jidian (KyleBing)，https://github.com/KyleBing/rime-wubi86-jidian
- 上游许可证：MIT。依据：上游仓库 LICENSE 文件，GitHub 识别为 MIT License，版权行为 "Copyright (c) Kyle Bing"。
- 本项目处理：转换为「编码 汉字 权重」制表符格式，版本 4.3（见文件头）。

MIT 许可证要求保留的版权声明：

    Copyright (c) Kyle Bing

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

### 2. 拼音码表

- 路径：`data/pinyin.txt`、`platform/android/app/src/main/assets/data/pinyin.txt`
- 上游（文件头标注两个来源）：
  - rime-pinyin-simp，https://github.com/rime/rime-pinyin-simp ：Apache-2.0。依据：上游仓库 LICENSE 文件，GitHub 识别为 Apache License 2.0。
  - rime-luna-pinyin，https://github.com/rime/rime-luna-pinyin ：LGPL-3.0。依据：上游仓库 LICENSE 文件，GitHub 识别为 GNU Lesser General Public License v3.0；其 README 写明「授權條款：見 LICENSE」。
- 本项目处理：合并两个来源并转换为「拼音 汉字 权重」格式，共 119004 条（见文件头）。
- 许可证全文：Apache-2.0 见根目录 `LICENSE`；LGPL-3.0 见 `LICENSES/LGPL-3.0.txt`。
- 说明：文件头未标明每个条目具体来自哪个上游，故整份文件按两个上游许可证同时声明。

### 3. 繁简单字转换表

- 路径：`data/STCharacters.txt`（仅此一份）
- 上游：OpenCC (BYVoid)，https://github.com/BYVoid/OpenCC
- 上游许可证：Apache-2.0。依据：上游仓库 LICENSE 文件，GitHub 识别为 Apache License 2.0；文件头亦写明 "License: Apache-2.0"。
- 本项目处理：见文件头（未见修改说明）。
- 许可证全文：见根目录 `LICENSE`。

## Rust 依赖

直接依赖（版本取自 `Cargo.lock`，许可证取自 `cargo metadata`）：

| crate | 版本 | 许可证 | 用途 |
|-------|------|--------|------|
| encoding_rs | 0.8.44 | (Apache-2.0 OR MIT) AND BSD-3-Clause | 运行时 |
| serde | 1.0.228 | MIT OR Apache-2.0 | 运行时 |
| serde_json | 1.0.149 | MIT OR Apache-2.0 | 运行时 |
| toml | 0.8.23 | MIT OR Apache-2.0 | 运行时 |
| tempfile | 3.27.0 | MIT OR Apache-2.0 | 仅测试 |
| cbindgen | 0.29.4 | MPL-2.0 | 仅构建期，不随产物分发 |

传递依赖请以 `cargo metadata` 或 `cargo tree` 的输出为准。
