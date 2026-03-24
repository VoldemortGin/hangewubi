use std::collections::HashMap;

/// 五笔编码 Trie 树
/// 支持精确匹配和前缀匹配，专为 a-z 的26个字母优化
#[derive(Debug, Default)]
pub struct Trie {
    root: TrieNode,
}

#[derive(Debug, Default)]
struct TrieNode {
    children: HashMap<u8, TrieNode>,
    /// 该节点对应的候选词索引列表
    values: Vec<usize>,
}

impl Trie {
    pub fn new() -> Self {
        Self::default()
    }

    /// 插入编码及对应的候选词索引
    pub fn insert(&mut self, code: &str, value_index: usize) {
        let mut node = &mut self.root;
        for &byte in code.as_bytes() {
            node = node.children.entry(byte).or_default();
        }
        node.values.push(value_index);
    }

    /// 精确匹配：返回该编码对应的所有候选词索引
    pub fn exact_match(&self, code: &str) -> &[usize] {
        let mut node = &self.root;
        for &byte in code.as_bytes() {
            match node.children.get(&byte) {
                Some(child) => node = child,
                None => return &[],
            }
        }
        &node.values
    }

    /// 前缀匹配：返回所有以该前缀开头的编码对应的候选词索引
    pub fn prefix_match(&self, prefix: &str) -> Vec<usize> {
        let mut node = &self.root;
        for &byte in prefix.as_bytes() {
            match node.children.get(&byte) {
                Some(child) => node = child,
                None => return vec![],
            }
        }
        let mut results = Vec::new();
        Self::collect_all(node, &mut results);
        results
    }

    /// Z键万能键匹配：z 可替代任意字母
    pub fn wildcard_match(&self, pattern: &str) -> Vec<usize> {
        let mut results = Vec::new();
        Self::wildcard_search(&self.root, pattern.as_bytes(), 0, &mut results);
        results
    }

    fn wildcard_search(node: &TrieNode, pattern: &[u8], pos: usize, results: &mut Vec<usize>) {
        if pos == pattern.len() {
            results.extend_from_slice(&node.values);
            return;
        }

        let byte = pattern[pos];
        if byte == b'z' {
            // z 是万能键，匹配所有子节点
            for child in node.children.values() {
                Self::wildcard_search(child, pattern, pos + 1, results);
            }
        } else {
            if let Some(child) = node.children.get(&byte) {
                Self::wildcard_search(child, pattern, pos + 1, results);
            }
        }
    }

    fn collect_all(node: &TrieNode, results: &mut Vec<usize>) {
        results.extend_from_slice(&node.values);
        for child in node.children.values() {
            Self::collect_all(child, results);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_exact_match() {
        let mut trie = Trie::new();
        trie.insert("a", 0);
        trie.insert("aa", 1);
        trie.insert("aad", 2);
        trie.insert("aadk", 3);

        assert_eq!(trie.exact_match("a"), &[0]);
        assert_eq!(trie.exact_match("aa"), &[1]);
        assert_eq!(trie.exact_match("aad"), &[2]);
        assert_eq!(trie.exact_match("aadk"), &[3]);
        assert_eq!(trie.exact_match("b"), &[] as &[usize]);
        assert_eq!(trie.exact_match("aadx"), &[] as &[usize]);
    }

    #[test]
    fn test_prefix_match() {
        let mut trie = Trie::new();
        trie.insert("a", 0);
        trie.insert("aa", 1);
        trie.insert("aad", 2);
        trie.insert("ab", 3);

        let mut results = trie.prefix_match("a");
        results.sort();
        assert_eq!(results, vec![0, 1, 2, 3]);

        let mut results = trie.prefix_match("aa");
        results.sort();
        assert_eq!(results, vec![1, 2]);

        assert_eq!(trie.prefix_match("b"), vec![] as Vec<usize>);
    }

    #[test]
    fn test_wildcard_match() {
        let mut trie = Trie::new();
        trie.insert("ab", 0);
        trie.insert("ac", 1);
        trie.insert("ad", 2);
        trie.insert("bb", 3);

        // z 替代第二位
        let mut results = trie.wildcard_match("az");
        results.sort();
        assert_eq!(results, vec![0, 1, 2]);

        // z 替代第一位
        let mut results = trie.wildcard_match("zb");
        results.sort();
        assert_eq!(results, vec![0, 3]);
    }
}
