use std::path::Path;

fn main() {
    let crate_dir = env!("CARGO_MANIFEST_DIR");

    // 仅当 FFI 契约相关文件变化时才重新生成头文件，避免无谓重建。
    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    let config = cbindgen::Config::from_root_or_default(crate_dir);

    let bindings = cbindgen::generate_with_config(crate_dir, config)
        .expect("cbindgen 生成 include/hangewubi.h 失败");

    let out_path = Path::new(crate_dir).join("include").join("hangewubi.h");

    // write_to_file 内部会与现有文件逐字节比对，仅在内容变化时落盘，
    // 避免 mtime 抖动导致的 rebuild 循环。
    bindings.write_to_file(&out_path);
}
