//! IBus 引擎入口 (Linux)
//! 通过 D-Bus 与 IBus daemon 通信
//! 注意：需要 Linux 环境和 IBus 开发库才能编译

fn main() {
    eprintln!("函戈五笔 IBus 引擎");
    eprintln!("此模块需要在 Linux 环境下配合 IBus 开发库编译");
    eprintln!("请参考 platform/linux/README.md");
    std::process::exit(1);
}
