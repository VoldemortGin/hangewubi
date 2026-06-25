# 晗戈五笔 · 组合门禁（铁律 5：唯一裁判 / 铁律 6：漂移守卫）
#
# `make check` 是本仓库的唯一裁判：core 门禁 + 契约新鲜度 + 宿主构建（尽力而为）。
# 所有 recipe 以 bash -euo pipefail 执行，失败即响亮中止（host 段除外，见下）。

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# 交叉构建目标（与 build-all.sh 一致）
LINUX_TARGET   := x86_64-unknown-linux-gnu
WINDOWS_TARGET := x86_64-pc-windows-gnu

# 时限：优先 timeout，其次 gtimeout，都没有则不限时（保持跨平台健壮）。
HOST_BUILD_TIMEOUT ?= 300
TIMEOUT := $(shell if command -v timeout >/dev/null 2>&1; then echo "timeout $(HOST_BUILD_TIMEOUT)"; elif command -v gtimeout >/dev/null 2>&1; then echo "gtimeout $(HOST_BUILD_TIMEOUT)"; fi)

.PHONY: help check core bindings check-hosts hosts-soft

help:
	@echo "晗戈五笔 门禁目标："
	@echo "  make check        唯一裁判：core 门禁 + 契约新鲜度 + 宿主构建(尽力而为/响亮跳过)"
	@echo "  make core         仅 core 门禁：cargo fmt --check → clippy(-D warnings) → test"
	@echo "  make bindings     重新生成契约头 include/hangewubi.h（= cargo build）"
	@echo "  make check-hosts  完整逐宿主构建（含 ios/android，重型；缺工具链响亮跳过）"
	@echo "  make help         显示本帮助"

# ==================== core 门禁（硬门禁，失败即中止）====================
core:
	@echo "==> [core 1/3] cargo fmt --check"
	cargo fmt --check
	@echo "==> [core 2/3] cargo clippy --all-targets --all-features -- -D warnings"
	cargo clippy --all-targets --all-features -- -D warnings
	@echo "==> [core 3/3] cargo test"
	cargo test

# ==================== 重新生成契约头 ====================
bindings:
	@echo "==> 重新生成 include/hangewubi.h（cargo build 写时比对落盘）"
	cargo build

# ==================== 唯一裁判 ====================
check: core
	@echo ""
	@echo "==> [bindings] 契约头新鲜度守卫（漂移守卫）"
	@bash scripts/check_bindings.sh
	@echo ""
	@$(MAKE) --no-print-directory hosts-soft
	@echo ""
	@echo "============================================================"
	@echo " make check 通过：core 门禁 + 契约新鲜度 全绿；宿主摘要见上。"
	@echo "============================================================"

# ==================== 宿主构建（尽力而为：缺工具链/失败 → 响亮跳过，绝不静默）====================
# 默认裁判只跑能在本机非交互完成的轻量宿主构建；iOS/Android 重型构建见 make check-hosts。
hosts-soft:
	@echo "------------------------------------------------------------"
	@echo " 宿主构建（尽力而为；缺工具链或失败将响亮 SKIP，不影响裁判）"
	@echo "------------------------------------------------------------"
	@# ---- macOS：dev 模式 ad-hoc 签名，非交互 ----
	@if command -v swiftc >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then \
		if bash platform/macos/build.sh dev >/tmp/hangewubi-host-macos.log 2>&1; then \
			echo "OK   host macos: platform/macos/build.sh dev (ad-hoc 签名 .app)"; \
		else \
			echo "SKIP host macos: build.sh dev 失败（日志 /tmp/hangewubi-host-macos.log）"; \
		fi; \
	else \
		echo "SKIP host macos: 缺 swiftc/xcodebuild"; \
	fi
	@# ---- Linux：交叉编译 .so（本机 macOS 通常缺 ELF 交叉链接器）----
	@if rustup target list --installed 2>/dev/null | grep -q '^$(LINUX_TARGET)$$'; then \
		if $(TIMEOUT) cargo build --release --target $(LINUX_TARGET) >/tmp/hangewubi-host-linux.log 2>&1; then \
			echo "OK   host linux: cargo build --release --target $(LINUX_TARGET)"; \
		else \
			echo "SKIP host linux: 交叉构建失败/超时（本机缺 ELF 交叉链接器或 sysroot；CI 用 Linux runner 原生构建）。日志 /tmp/hangewubi-host-linux.log"; \
		fi; \
	else \
		echo "SKIP host linux: 未安装 rustup target（rustup target add $(LINUX_TARGET)）"; \
	fi
	@# ---- Windows：交叉编译 .dll ----
	@if rustup target list --installed 2>/dev/null | grep -q '^$(WINDOWS_TARGET)$$'; then \
		if $(TIMEOUT) cargo build --release --target $(WINDOWS_TARGET) >/tmp/hangewubi-host-windows.log 2>&1; then \
			echo "OK   host windows: cargo build --release --target $(WINDOWS_TARGET)"; \
		else \
			echo "SKIP host windows: 交叉构建失败/超时（日志 /tmp/hangewubi-host-windows.log；原生构建见 platform/windows/build.bat）"; \
		fi; \
	else \
		echo "SKIP host windows: 未安装 rustup target（rustup target add $(WINDOWS_TARGET)）"; \
	fi
	@# ---- iOS / Android：重型 Xcode/Gradle 构建，默认裁判不跑 ----
	@echo "SKIP host ios: 重型 Xcode 构建，默认裁判跳过（make check-hosts）"
	@echo "SKIP host android: 重型 Gradle/NDK 构建，默认裁判跳过（make check-hosts）"

# ==================== 完整逐宿主构建（显式、重型）====================
# 缺工具链 → 响亮 SKIP（非致命）；工具链就绪但构建失败 → 响亮 FAIL 并最终退出非零。
check-hosts:
	@echo "==> 完整逐宿主构建（含 ios/android）"
	@fail=0; \
	run_host() { \
		name="$$1"; shift; \
		echo ""; echo "── host: $$name ──"; \
		if "$$@"; then echo "OK   host $$name"; else echo "FAIL host $$name"; fail=1; fi; \
	}; \
	skip_host() { echo ""; echo "── host: $$1 ──"; echo "SKIP host $$1: $$2"; }; \
	if command -v swiftc >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then \
		run_host macos bash platform/macos/build.sh dev; \
	else skip_host macos "缺 swiftc/xcodebuild"; fi; \
	if command -v xcodebuild >/dev/null 2>&1 && command -v xcodegen >/dev/null 2>&1; then \
		run_host ios bash platform/ios/build.sh dev; \
	else skip_host ios "缺 xcodebuild/xcodegen"; fi; \
	if command -v cargo-ndk >/dev/null 2>&1 && [ -n "$${ANDROID_NDK_HOME:-}$${ANDROID_NDK_ROOT:-}$${NDK_HOME:-}" ]; then \
		run_host android bash platform/android/build.sh; \
	else skip_host android "缺 cargo-ndk 或 ANDROID_NDK_HOME（cargo install cargo-ndk）"; fi; \
	if rustup target list --installed 2>/dev/null | grep -q '^$(LINUX_TARGET)$$'; then \
		run_host linux env CARGO_TARGET=$(LINUX_TARGET) cargo build --release --target $(LINUX_TARGET); \
	else skip_host linux "未安装 rustup target（rustup target add $(LINUX_TARGET)）"; fi; \
	if rustup target list --installed 2>/dev/null | grep -q '^$(WINDOWS_TARGET)$$'; then \
		run_host windows cargo build --release --target $(WINDOWS_TARGET); \
	else skip_host windows "未安装 rustup target（rustup target add $(WINDOWS_TARGET)）"; fi; \
	echo ""; \
	if [ "$$fail" -ne 0 ]; then echo "check-hosts: 有宿主构建失败"; exit 1; fi; \
	echo "check-hosts: 完成（失败 0）"
