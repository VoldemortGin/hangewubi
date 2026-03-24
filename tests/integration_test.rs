use fungewubi::config::Config;
use fungewubi::dict::DictEngine;
use fungewubi::engine::{EngineAction, InputEngine};
use fungewubi::user_dict::UserDict;
use std::path::PathBuf;

fn load_real_dict() -> Option<DictEngine> {
    let path = PathBuf::from("data/wubi86.txt");
    if !path.exists() {
        return None;
    }
    let mut dict = DictEngine::new();
    dict.load_from_file(&path).ok()?;
    Some(dict)
}

#[test]
fn test_load_real_dict() {
    let dict = load_real_dict();
    if let Some(dict) = dict {
        // 应该有大量词条
        assert!(dict.entry_count() > 80000, "码表应有8万+词条，实际 {}", dict.entry_count());
        println!("加载了 {} 条词条", dict.entry_count());
    } else {
        println!("跳过：未找到码表文件 data/wubi86.txt");
    }
}

#[test]
fn test_one_key_simple_codes() {
    let Some(dict) = load_real_dict() else {
        println!("跳过：未找到码表文件");
        return;
    };

    // 一级简码测试：每个字母键对应一个最常用字
    let expected = [
        ("g", "一"), ("f", "地"), ("d", "在"), ("s", "要"), ("a", "工"),
        ("h", "上"), ("j", "是"), ("k", "中"), ("l", "国"),
        ("t", "和"), ("r", "的"), ("e", "有"), ("w", "人"), ("q", "我"),
        ("y", "主"), ("u", "产"), ("i", "不"), ("o", "为"), ("p", "这"),
        ("n", "民"), ("b", "了"), ("v", "发"), ("c", "以"), ("x", "经"),
    ];

    for (code, expected_char) in &expected {
        let results = dict.lookup_exact(code);
        assert!(
            results.iter().any(|e| e.text == *expected_char),
            "一级简码 '{}' 应包含 '{}'，实际候选: {:?}",
            code,
            expected_char,
            results.iter().map(|e| &e.text).collect::<Vec<_>>()
        );
    }
}

#[test]
fn test_common_words() {
    let Some(dict) = load_real_dict() else {
        println!("跳过：未找到码表文件");
        return;
    };

    // 测试常见词组
    let test_cases = [
        ("wqvb", "你好"),
        ("imde", "没有"),
        ("ytsm", "计算机"),
    ];

    for (code, expected) in &test_cases {
        let results = dict.lookup_exact(code);
        assert!(
            results.iter().any(|e| e.text == *expected),
            "编码 '{}' 应包含 '{}'，实际候选: {:?}",
            code,
            expected,
            results.iter().map(|e| &e.text).collect::<Vec<_>>()
        );
    }
}

#[test]
fn test_engine_with_real_dict() {
    let Some(dict) = load_real_dict() else {
        println!("跳过：未找到码表文件");
        return;
    };

    let config = Config::default();
    let mut engine = InputEngine::new(dict, UserDict::new(), config);

    // 输入 'g' + 空格 = "一"
    engine.handle_key('g');
    assert!(!engine.candidates().is_empty());
    let action = engine.handle_space();
    // 第一个候选应该包含 "一" 或 "工"（取决于权重）
    if let EngineAction::Commit(text) = action {
        println!("g + 空格 => {}", text);
    }

    // 输入 'r' + 空格 = "的"
    engine.handle_key('r');
    let action = engine.handle_space();
    if let EngineAction::Commit(text) = action {
        println!("r + 空格 => {}", text);
    }
}

#[test]
fn test_prefix_matching_with_real_dict() {
    let Some(dict) = load_real_dict() else {
        println!("跳过：未找到码表文件");
        return;
    };

    // 输入 "wq" 应有多个候选
    let results = dict.lookup("wq", false, 10);
    assert!(!results.is_empty(), "前缀 'wq' 应有候选");
    println!("wq 的候选: {:?}", results.iter().map(|e| format!("{}({})", e.text, e.code)).collect::<Vec<_>>());
}

#[test]
fn test_four_code_unique_auto_commit() {
    let Some(dict) = load_real_dict() else {
        println!("跳过：未找到码表文件");
        return;
    };

    let config = Config {
        auto_commit_on_unique_four: true,
        ..Config::default()
    };
    let mut engine = InputEngine::new(dict, UserDict::new(), config);

    // 找一个只有唯一匹配的四码
    // "rngg" 可能不唯一，但可以测试四码输入流程
    engine.handle_key('r');
    engine.handle_key('n');
    engine.handle_key('g');
    let action = engine.handle_key('g');

    match action {
        EngineAction::Commit(text) => println!("rngg 自动上屏: {}", text),
        EngineAction::UpdateCandidates => println!("rngg 有多个候选，未自动上屏"),
        EngineAction::Reset => println!("rngg 无匹配"),
        _ => {}
    }
}
