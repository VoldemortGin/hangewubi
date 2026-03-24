use hangewubi::config::Config;
use hangewubi::dict::DictEngine;
use hangewubi::engine::{EngineAction, InputEngine, InputMode};
use hangewubi::user_dict::UserDict;
use std::io::{self, Read, Write};
use std::path::PathBuf;

fn main() {
    println!("╔══════════════════════════════════════╗");
    println!("║        函戈五笔 v0.1.0               ║");
    println!("║   FungeWubi Input Method Engine       ║");
    println!("╚══════════════════════════════════════╝");
    println!();

    // 加载码表
    let mut dict = DictEngine::new();
    let dict_path = find_dict_path();

    match &dict_path {
        Some(path) => match dict.load_from_file(path) {
            Ok(count) => println!("[码表] 已加载 {} 条词条 ({})", count, path.display()),
            Err(e) => {
                eprintln!("[错误] 无法加载码表 {}: {}", path.display(), e);
                println!("[提示] 使用内置测试码表");
                load_builtin_dict(&mut dict);
            }
        },
        None => {
            println!("[提示] 未找到码表文件，使用内置测试码表");
            load_builtin_dict(&mut dict);
        }
    }

    // 加载用户词典
    let user_dict_path = PathBuf::from("data/user_dict.json");
    let user_dict = UserDict::load(&user_dict_path).unwrap_or_default();

    let config = Config::default();
    let mut engine = InputEngine::new(dict, user_dict, config);

    println!();
    println!("使用说明：");
    println!("  输入字母 a-y 进行五笔编码");
    println!("  空格     选择第一个候选");
    println!("  1-9      选择对应候选");
    println!("  退格     删除末位编码");
    println!("  ESC      清空编码");
    println!("  Enter    提交编码原文");
    println!("  Tab      切换中/英文模式");
    println!("  Ctrl+C   退出");
    println!();

    // 设置终端为 raw 模式
    let mut stdout = io::stdout();
    enable_raw_mode();

    let mut committed_text = String::new();

    loop {
        // 显示状态栏
        print!("\r\x1b[K"); // 清除当前行
        let mode_str = match engine.mode() {
            InputMode::Chinese => "中",
            InputMode::English => "英",
            InputMode::TempEnglish => "临英",
        };
        print!("[{}] ", mode_str);

        if !committed_text.is_empty() {
            print!("{}", committed_text);
        }

        if !engine.buffer().is_empty() {
            print!("\x1b[36m{}\x1b[0m", engine.buffer()); // 青色显示编码
        }

        // 显示候选
        if !engine.candidates().is_empty() {
            print!("  ");
            for (i, candidate) in engine.candidates().iter().enumerate() {
                let marker = if candidate.is_user { "*" } else { "" };
                print!(
                    "\x1b[33m{}\x1b[0m.{}{} ",
                    i + 1,
                    candidate.text,
                    marker
                );
            }
        }

        stdout.flush().unwrap();

        // 读取按键
        let key = read_key();
        match key {
            Key::Char(c) if c.is_ascii_uppercase() => {
                let action = engine.handle_uppercase(c);
                handle_action(&action, &mut committed_text);
            }
            Key::Char(c) if c.is_ascii_lowercase() => {
                let action = engine.handle_key(c);
                handle_action(&action, &mut committed_text);
            }
            Key::Semicolon => {
                let action = engine.handle_semicolon();
                handle_action(&action, &mut committed_text);
            }
            Key::Punctuation(ch) => {
                let action = engine.handle_punctuation(ch);
                handle_action(&action, &mut committed_text);
            }
            Key::Space => {
                // 临时英文模式下空格提交
                if let Some(action) = engine.handle_space_for_temp_english() {
                    handle_action(&action, &mut committed_text);
                } else {
                    let action = engine.handle_space();
                    handle_action(&action, &mut committed_text);
                }
            }
            Key::Number(n) => {
                let action = engine.handle_number(n);
                handle_action(&action, &mut committed_text);
            }
            Key::Backspace => {
                let action = engine.handle_backspace();
                handle_action(&action, &mut committed_text);
            }
            Key::Escape => {
                let action = engine.handle_escape();
                handle_action(&action, &mut committed_text);
            }
            Key::Enter => {
                if engine.buffer().is_empty() && engine.mode() == InputMode::Chinese {
                    print!("\r\n");
                    committed_text.clear();
                } else {
                    let action = engine.handle_enter();
                    handle_action(&action, &mut committed_text);
                }
            }
            Key::Tab => {
                engine.toggle_mode();
            }
            Key::CtrlC => {
                // 退出前保存用户词典
                let _ = engine.user_dict().save(&user_dict_path);
                disable_raw_mode();
                println!("\r\n再见！");
                break;
            }
            _ => {}
        }
    }
}

fn handle_action(action: &EngineAction, committed_text: &mut String) {
    if let EngineAction::Commit(text) = action {
        committed_text.push_str(text);
    }
}

fn find_dict_path() -> Option<PathBuf> {
    let candidates = [
        PathBuf::from("data/wubi86.txt"),
        PathBuf::from("../data/wubi86.txt"),
    ];
    candidates.into_iter().find(|p| p.exists())
}

fn load_builtin_dict(dict: &mut DictEngine) {
    // 86版五笔一级简码（25个最常用字）
    dict.load_from_str(
        "g\t一\t9999
f\t地\t9998
d\t在\t9997
s\t要\t9996
a\t工\t9995
h\t上\t9994
j\t是\t9993
k\t中\t9992
l\t国\t9991
t\t和\t9990
r\t的\t9989
e\t有\t9988
w\t人\t9987
q\t我\t9986
y\t主\t9985
u\t产\t9984
i\t不\t9983
o\t为\t9982
p\t这\t9981
n\t民\t9980
b\t了\t9979
v\t发\t9978
c\t以\t9977
x\t经\t9976
gg\t五\t8000
gf\t一下\t7000
gh\t正\t7500
gt\t与\t7400
gd\t天\t7800
gs\t太\t6500
ga\t形\t6000
jj\t日\t8000
jf\t时\t7500
jh\t早\t7000
kk\t口\t8000
kf\t叶\t6000
ll\t田\t8000
ff\t土\t8000
dd\t大\t8500
ss\t木\t7000
aa\t式\t6000
hh\t目\t7000
tt\t竹\t6500
rr\t白\t7000
ee\t月\t7500
ww\t人\t7000
qq\t金\t7500
yy\t言\t7000
uu\t立\t6500
ii\t水\t7500
oo\t火\t7000
pp\t之\t7500
nn\t已\t6000
bb\t子\t7500
vv\t女\t7000
cc\t又\t6000
xx\t纟\t5000
",
    );
}

// 终端 raw 模式相关
use hangewubi::punctuation::PunctuationConverter;

enum Key {
    Char(char),
    Space,
    Number(usize),
    Semicolon,
    Punctuation(char),
    Backspace,
    Escape,
    Enter,
    Tab,
    CtrlC,
    Unknown,
}

fn read_key() -> Key {
    let mut buf = [0u8; 3];
    let stdin = io::stdin();
    let n = stdin.lock().read(&mut buf).unwrap_or(0);
    if n == 0 {
        return Key::Unknown;
    }

    match buf[0] {
        3 => Key::CtrlC,        // Ctrl+C
        9 => Key::Tab,          // Tab
        13 => Key::Enter,       // Enter
        27 => Key::Escape,      // Escape
        32 => Key::Space,       // Space
        127 => Key::Backspace,  // Backspace (macOS)
        8 => Key::Backspace,    // Backspace (Linux)
        b'0'..=b'9' => Key::Number((buf[0] - b'0') as usize),
        b'a'..=b'z' => Key::Char(buf[0] as char),
        b'A'..=b'Z' => Key::Char(buf[0] as char), // 保留原大写
        b';' => Key::Semicolon,
        ch if PunctuationConverter::is_punctuation(ch as char) => {
            Key::Punctuation(ch as char)
        }
        _ => Key::Unknown,
    }
}

fn enable_raw_mode() {
    // 使用 stty 设置 raw 模式
    std::process::Command::new("stty")
        .args(["-echo", "raw", "-icanon"])
        .stdin(std::process::Stdio::inherit())
        .status()
        .ok();
}

fn disable_raw_mode() {
    // 恢复终端模式
    std::process::Command::new("stty")
        .args(["echo", "cooked", "icanon"])
        .stdin(std::process::Stdio::inherit())
        .status()
        .ok();
}
