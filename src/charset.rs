//! 字符集工具：简→繁单字转换（OpenCC STCharacters）与 GB2312 常用字判定。

use std::collections::HashMap;
use std::sync::OnceLock;

/// OpenCC 简→繁单字表（Apache-2.0），编进二进制，宿主无需额外打包
const ST_CHARACTERS: &str = include_str!("../data/STCharacters.txt");

fn st_map() -> &'static HashMap<char, char> {
    static MAP: OnceLock<HashMap<char, char>> = OnceLock::new();
    MAP.get_or_init(|| {
        ST_CHARACTERS
            .lines()
            .filter(|l| !l.starts_with('#'))
            .filter_map(|l| {
                let (simp, trad) = l.split_once('\t')?;
                let mut simp = simp.chars();
                let (s, t) = (simp.next()?, trad.split(' ').next()?.chars().next()?);
                simp.next().is_none().then_some((s, t))
            })
            .collect()
    })
}

/// 简→繁单字转换：按字映射取第一个繁体候选，未收录字原样保留
pub fn to_traditional(s: &str) -> String {
    let map = st_map();
    s.chars().map(|c| *map.get(&c).unwrap_or(&c)).collect()
}

/// 是否为汉字（CJK 统一表意文字及其扩展 / 兼容区）
pub(crate) fn is_han(c: char) -> bool {
    matches!(c as u32,
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F | 0x30000..=0x323AF)
}

/// 单个汉字是否在 GB2312 内：编码为 GBK 后双字节，
/// 首字节 0xB0–0xF7、尾字节 0xA1–0xFE（GB2312 第 55 区末尾 0xD7FA–0xD7FE 为空位）
fn in_gb2312(c: char) -> bool {
    let mut buf = [0u8; 4];
    let (bytes, _, had_errors) = encoding_rs::GBK.encode(c.encode_utf8(&mut buf));
    if had_errors || bytes.len() != 2 {
        return false;
    }
    let (b1, b2) = (bytes[0], bytes[1]);
    (0xB0..=0xF7).contains(&b1) && (0xA1..=0xFE).contains(&b2) && !(b1 == 0xD7 && b2 >= 0xFA)
}

/// 文本中每个汉字都在 GB2312 内（非汉字字符不参与判断）
pub fn is_gb2312_text(s: &str) -> bool {
    s.chars().all(|c| !is_han(c) || in_gb2312(c))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gb2312_total_is_6763() {
        let n = ('\u{4E00}'..='\u{9FFF}').filter(|&c| in_gb2312(c)).count();
        assert_eq!(n, 6763);
    }

    #[test]
    fn test_gb2312_text() {
        assert!(is_gb2312_text("汉字"));
        assert!(is_gb2312_text("A1，。"));
        assert!(!is_gb2312_text("龘"));
        assert!(!is_gb2312_text("工龘"));
    }

    #[test]
    fn test_to_traditional() {
        assert_eq!(to_traditional("汉语 ABC，国"), "漢語 ABC，國");
        assert_eq!(to_traditional("𠀀工"), "𠀀工");
    }

    #[test]
    fn test_st_table_size() {
        assert!(st_map().len() > 3000);
    }
}
