"""由上游宽松许可数据生成 data/pinyin.txt（从仓库根目录运行：python3 scripts/build_pinyin_dict.py）。

主体：rime-pinyin-simp（Apache-2.0，源自 AOSP PinyinIME），字 + 词，带词频。
补充：pinyin-data 的 pinyin.txt（MIT，数据源自 Unicode Unihan），仅补 pinyin-simp 缺少的「字 + 读音」。
"""

import hashlib
import math
from pathlib import Path
import tempfile
import unicodedata
import urllib.request

ROOT_DIR = Path(__file__).resolve().parent.parent
OUTPUT = ROOT_DIR / "data" / "pinyin.txt"
ANDROID_COPY = ROOT_DIR / "platform/android/app/src/main/assets/data/pinyin.txt"

SIMP_REPO = "rime/rime-pinyin-simp"
SIMP_SHA = "0c6861ef7420ee780270ca6d993d18d4101049d0"
SIMP_PATH = "pinyin_simp.dict.yaml"
SIMP_SHA256 = "e341598343a0f0f2035bb1aafc34a7f3bb7887deeecb3f60796262aaa2983e6b"

DATA_REPO = "mozillazg/pinyin-data"
DATA_SHA = "fe29ad32bdf352b31a02b9936e537f575432e9a6"
DATA_PATH = "pinyin.txt"
DATA_SHA256 = "2342a6f98c85dbc3c8d26aef31744876a36326c6466e51e9a0f16898c36c2011"

MAX_WEIGHT = 9999
MIN_WEIGHT = 2  # 词频为 0 的条目
EXTRA_WEIGHT = 1  # pinyin-data 补充条目，排在最后


def fetch(repo: str, sha: str, path: str, expected_sha256: str) -> str:
    url = f"https://raw.githubusercontent.com/{repo}/{sha}/{path}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        raw = resp.read()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != expected_sha256:
        raise SystemExit(f"SHA-256 不匹配：{url}\n  期望 {expected_sha256}\n  实际 {digest}")
    return raw.decode("utf-8")


def normalize_pinyin(reading: str) -> str | None:
    """带声调拼音 -> 无声调、ü 写作 v，且 lüe/nüe 写作 lue/nue（与 pinyin-simp 一致）。

    含 ê 等无法落到 a-z 的读音返回 None。
    """
    s = unicodedata.normalize("NFD", reading.strip().lower())
    if "̂" in s:  # ê
        return None
    s = s.replace("ü", "v")
    s = "".join(c for c in s if not unicodedata.combining(c))
    if s.endswith(("lve", "nve")):
        s = s[:-2] + "ue"
    return s if s.isascii() and s.isalpha() else None


def parse_simp(content: str) -> dict[tuple[str, str], int]:
    """pinyin-simp 行格式：文本<TAB>空格分隔的拼音<TAB>词频；词频对数缩放到 2..9999。"""
    rows: list[tuple[str, str, int]] = []
    in_body = False
    for line in content.splitlines():
        if line == "...":
            in_body = True
            continue
        parts = line.split("\t")
        if not in_body or len(parts) != 3:
            continue
        text, pinyin, freq = parts[0], parts[1].replace(" ", "").lower(), int(parts[2])
        rows.append((pinyin, text, freq))
    max_freq = max(r[2] for r in rows)
    entries: dict[tuple[str, str], int] = {}
    for pinyin, text, freq in rows:
        # 权重 = 2 + round(log(1+freq) / log(1+max_freq) * (9999-2))；freq=0 时即为 2，保持相对顺序
        weight = MIN_WEIGHT + round(math.log1p(freq) / math.log1p(max_freq) * (MAX_WEIGHT - MIN_WEIGHT))
        key = (pinyin, text)
        entries[key] = max(entries.get(key, 0), weight)
    return entries


def parse_extra(content: str) -> set[tuple[str, str]]:
    """pinyin-data 行格式：U+4E2D: zhōng,zhòng  # 中"""
    out: set[tuple[str, str]] = set()
    for line in content.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line.startswith("U+"):
            continue
        code, readings = line.split(":", 1)
        char = chr(int(code[2:], 16))
        for reading in readings.split(","):
            pinyin = normalize_pinyin(reading)
            if pinyin:
                out.add((pinyin, char))
    return out


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:  # 下载内容只在内存/临时目录中，不落在仓库里
        simp = fetch(SIMP_REPO, SIMP_SHA, SIMP_PATH, SIMP_SHA256)
        extra = fetch(DATA_REPO, DATA_SHA, DATA_PATH, DATA_SHA256)
        (Path(tmp) / SIMP_PATH).write_text(simp, encoding="utf-8")
        (Path(tmp) / f"pinyin-data-{DATA_PATH}").write_text(extra, encoding="utf-8")

    entries = parse_simp(simp)
    for key in parse_extra(extra):
        entries.setdefault(key, EXTRA_WEIGHT)

    rows = sorted(entries.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))
    header = [
        "# 晗戈五笔 拼音码表",
        "# 格式：拼音\t汉字\t权重",
        f"# 来源：rime-pinyin-simp（Apache-2.0，{SIMP_SHA[:12]}）",
        f"# 来源：mozillazg/pinyin-data（MIT，数据源自 Unicode Unihan，{DATA_SHA[:12]}）",
        "# 由 scripts/build_pinyin_dict.py 生成，请勿手工编辑",
        f"# 条目数：{len(rows)}",
    ]
    body = [f"{pinyin}\t{text}\t{weight}" for (pinyin, text), weight in rows]
    data = "\n".join(header + body) + "\n"
    for target in (OUTPUT, ANDROID_COPY):
        target.write_bytes(data.encode("utf-8"))
    print(f"写入 {len(rows)} 条 -> {OUTPUT}")


if __name__ == "__main__":
    main()
