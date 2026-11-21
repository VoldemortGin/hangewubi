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
- 生成脚本：`scripts/build_pinyin_dict.py`（按钉死的提交 SHA 下载上游文件并校验 SHA-256，输出完全由下列两个上游生成，可复现）。
- 上游一：rime-pinyin-simp，https://github.com/rime/rime-pinyin-simp ，提交 `0c6861ef7420ee780270ca6d993d18d4101049d0`。上游许可证：Apache-2.0（上游仓库 LICENSE 文件）。其数据源自 Android Open Source Project 的 PinyinIME。提供字、词与词频，为本文件主体。
- 上游二：pinyin-data (mozillazg)，https://github.com/mozillazg/pinyin-data ，提交 `fe29ad32bdf352b31a02b9936e537f575432e9a6`，仅使用根目录 `pinyin.txt`。上游许可证：MIT。其数据来自 Unicode Unihan 数据库，适用 Unicode License V3。仅用于补充上游一缺少的「字 + 读音」组合（权重 1）。
- 本项目处理：转换为「拼音 汉字 权重」格式（去声调、ü 写作 v、词的拼音不带空格、词频对数缩放为权重），共 101379 条（见文件头）。
- 许可证全文：Apache-2.0 见根目录 `LICENSE`；Unicode License V3 见 `LICENSES/Unicode-3.0.txt`；MIT 须保留的版权声明如下。

pinyin-data 的 MIT 许可证要求保留的版权声明：

    The MIT License (MIT)

    Copyright (c) 2016 mozillazg

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
