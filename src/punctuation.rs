use std::collections::HashMap;

/// 标点转换器：英文标点 → 中文标点
#[derive(Debug)]
pub struct PunctuationConverter {
    /// 简单映射（一对一）
    simple_map: HashMap<char, char>,
    /// 成对标点状态（引号、括号等需要交替输出）
    pair_state: HashMap<char, bool>,
    /// 成对标点映射：英文标点 → (左中文标点, 右中文标点)
    pair_map: HashMap<char, (char, char)>,
    /// 是否启用全角标点
    pub enabled: bool,
}

impl PunctuationConverter {
    pub fn new() -> Self {
        let mut simple_map = HashMap::new();
        // 简单一对一映射
        simple_map.insert(',', '，');
        simple_map.insert('.', '。');
        simple_map.insert('?', '？');
        simple_map.insert('!', '！');
        simple_map.insert(':', '：');
        simple_map.insert(';', '；');
        simple_map.insert('\\', '、');
        simple_map.insert('~', '～');
        simple_map.insert('@', '＠');
        simple_map.insert('#', '＃');
        simple_map.insert('%', '％');
        simple_map.insert('&', '＆');
        simple_map.insert('*', '×');
        simple_map.insert('-', '－');
        simple_map.insert('_', '—');
        simple_map.insert('+', '＋');
        simple_map.insert('=', '＝');
        simple_map.insert('$', '￥');
        simple_map.insert('^', '…');

        let mut pair_map = HashMap::new();
        // 成对标点
        pair_map.insert('"', ('\u{201c}', '\u{201d}'));
        pair_map.insert('\'', ('\u{2018}', '\u{2019}'));
        pair_map.insert('(', ('（', '）'));
        pair_map.insert('[', ('【', '】'));
        pair_map.insert('{', ('｛', '｝'));
        pair_map.insert('<', ('《', '》'));

        Self {
            simple_map,
            pair_state: HashMap::new(),
            pair_map,
            enabled: true,
        }
    }

    /// 转换标点符号，返回 Some(中文标点) 或 None（非标点字符）
    pub fn convert(&mut self, ch: char) -> Option<String> {
        if !self.enabled {
            return None;
        }

        // 成对标点处理
        if let Some(&(left, right)) = self.pair_map.get(&ch) {
            let is_left = self.pair_state.entry(ch).or_insert(true);
            let result = if *is_left { left } else { right };
            *is_left = !*is_left;
            return Some(result.to_string());
        }

        // 右括号直接映射
        match ch {
            ')' => return Some('）'.to_string()),
            ']' => return Some('】'.to_string()),
            '}' => return Some('｝'.to_string()),
            '>' => return Some('》'.to_string()),
            _ => {}
        }

        // 简单映射
        if let Some(&cn_ch) = self.simple_map.get(&ch) {
            return Some(cn_ch.to_string());
        }

        None
    }

    /// 判断字符是否为可转换的标点
    pub fn is_punctuation(ch: char) -> bool {
        matches!(
            ch,
            ',' | '.'
                | '?'
                | '!'
                | ':'
                | ';'
                | '\\'
                | '~'
                | '@'
                | '#'
                | '%'
                | '&'
                | '*'
                | '-'
                | '_'
                | '+'
                | '='
                | '$'
                | '^'
                | '"'
                | '\''
                | '('
                | ')'
                | '['
                | ']'
                | '{'
                | '}'
                | '<'
                | '>'
        )
    }

    /// 重置成对标点状态
    pub fn reset_pairs(&mut self) {
        self.pair_state.clear();
    }
}

impl Default for PunctuationConverter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_punctuation() {
        let mut converter = PunctuationConverter::new();
        assert_eq!(converter.convert(','), Some("，".to_string()));
        assert_eq!(converter.convert('.'), Some("。".to_string()));
        assert_eq!(converter.convert('?'), Some("？".to_string()));
        assert_eq!(converter.convert('!'), Some("！".to_string()));
        assert_eq!(converter.convert(':'), Some("：".to_string()));
        assert_eq!(converter.convert('$'), Some("￥".to_string()));
    }

    #[test]
    fn test_paired_punctuation() {
        let mut converter = PunctuationConverter::new();
        // 引号交替输出
        assert_eq!(converter.convert('"'), Some("\u{201c}".to_string())); // "
        assert_eq!(converter.convert('"'), Some("\u{201d}".to_string())); // "
        assert_eq!(converter.convert('"'), Some("\u{201c}".to_string())); // " 再次
    }

    #[test]
    fn test_brackets() {
        let mut converter = PunctuationConverter::new();
        assert_eq!(converter.convert('('), Some("（".to_string()));
        assert_eq!(converter.convert(')'), Some("）".to_string()));
        assert_eq!(converter.convert('['), Some("【".to_string()));
        assert_eq!(converter.convert(']'), Some("】".to_string()));
        assert_eq!(converter.convert('<'), Some("《".to_string()));
        assert_eq!(converter.convert('>'), Some("》".to_string()));
    }

    #[test]
    fn test_disabled() {
        let mut converter = PunctuationConverter::new();
        converter.enabled = false;
        assert_eq!(converter.convert(','), None);
    }

    #[test]
    fn test_non_punctuation() {
        let mut converter = PunctuationConverter::new();
        assert_eq!(converter.convert('a'), None);
        assert_eq!(converter.convert('1'), None);
    }

    #[test]
    fn test_is_punctuation() {
        assert!(PunctuationConverter::is_punctuation(','));
        assert!(PunctuationConverter::is_punctuation('"'));
        assert!(!PunctuationConverter::is_punctuation('a'));
        assert!(!PunctuationConverter::is_punctuation('1'));
    }

    #[test]
    fn test_reset_pairs() {
        let mut converter = PunctuationConverter::new();
        converter.convert('"'); // 输出左引号
        converter.reset_pairs();
        // 重置后应该重新从左引号开始
        assert_eq!(converter.convert('"'), Some("\u{201c}".to_string()));
    }
}
