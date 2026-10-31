#!/bin/bash
#
# 交叉编译 SmartDNS（含 eventfd 补丁）for CMCC RAX3000-QY
#   - 目标: armv7 / Cortex-A7 / musl / 静态链接
#   - 内核: 4.4.60，未编译 CONFIG_EVENTFD，故需要本补丁
#
# 用法: ./build.sh [smartdns 源码目录] [输出目录]
#   例: ./build.sh ~/build/smartdns-Release48.4 ~/build/out
#
# Copyright (C) 2018-2025 Ruilin Peng (Nick) <pymumu@gmail.com>.
# Copyright (C) 2026 imzf.
# Modified 2026-10-31: eventfd 兼容补丁与下载校验。
# SPDX-License-Identifier: GPL-3.0-or-later
# 许可证全文见 LICENSE；修改声明与对应源码说明见 NOTICE。
#
set -euo pipefail

SRC_DIR="${1:-$(pwd)/smartdns-src}"
OUT_DIR="${2:-$(pwd)/out}"
WORK_DIR="${WORK_DIR:-$(pwd)/.work}"

TOOLCHAIN_URL="https://musl.cc/arm-linux-musleabihf-cross.tgz"
# 2026-10-31 从 musl.cc 下载的 arm-linux-musleabihf-cross.tgz 的 SHA-256。
# 上游文件更新后需同步修改；确需跳过校验时设 SKIP_VERIFY=1。
TOOLCHAIN_SHA256="11e155a090789c854afb5d91e57c81f441ccdb92f7f277789c3a6d5884a68e58"
OPENSSL_VER="1.1.1w"
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz"
# 官方 openssl-1.1.1w.tar.gz.sha256
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
SMARTDNS_VER="${SMARTDNS_VER:-1.2026.08.05-custom}"
# 版本号加 -custom 后缀用于标识打了补丁的构建，见 NOTICE 修改声明。

CROSS="${WORK_DIR}/arm-linux-musleabihf-cross/bin/arm-linux-musleabihf-"

verify_sha256() {
	local file="$1"
	local expected="$2"
	local actual

	if [ -z "$expected" ] || [ "${SKIP_VERIFY:-0}" = "1" ]; then
		echo ">>> 跳过 SHA-256 校验: $file"
		return 0
	fi

	if command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$file" | awk '{print $1}')
	elif command -v shasum >/dev/null 2>&1; then
		actual=$(shasum -a 256 "$file" | awk '{print $1}')
	else
		echo "错误: 找不到 sha256sum 或 shasum，无法校验 $file" >&2
		exit 1
	fi

	if [ "$actual" != "$expected" ]; then
		echo "错误: SHA-256 校验失败: $file" >&2
		echo "  期望: $expected" >&2
		echo "  实际: $actual" >&2
		exit 1
	fi
	echo ">>> SHA-256 校验通过: $file"
}

mkdir -p "${WORK_DIR}" "${OUT_DIR}"

# ---------- 1. 工具链 ----------
if [ ! -x "${CROSS}gcc" ]; then
	echo ">>> 下载 musl 交叉工具链"
	curl -fL --retry 3 --proto '=https' --proto-redir '=https' -o "${WORK_DIR}/musl-arm.tgz" "${TOOLCHAIN_URL}"
	verify_sha256 "${WORK_DIR}/musl-arm.tgz" "${TOOLCHAIN_SHA256}"
	tar xzf "${WORK_DIR}/musl-arm.tgz" -C "${WORK_DIR}"
fi
export PATH="${WORK_DIR}/arm-linux-musleabihf-cross/bin:${PATH}"

# ---------- 2. OpenSSL 静态库 ----------
OPENSSL_PREFIX="${WORK_DIR}/openssl-arm"
if [ ! -f "${OPENSSL_PREFIX}/lib/libssl.a" ]; then
	echo ">>> 编译 OpenSSL ${OPENSSL_VER} (static)"
	cd "${WORK_DIR}"
	if [ ! -f "openssl-${OPENSSL_VER}.tar.gz" ]; then
		curl -fL --retry 3 --proto '=https' --proto-redir '=https' -o "openssl-${OPENSSL_VER}.tar.gz" "${OPENSSL_URL}"
	fi
	verify_sha256 "openssl-${OPENSSL_VER}.tar.gz" "${OPENSSL_SHA256}"
	tar xzf "openssl-${OPENSSL_VER}.tar.gz"
	cd "openssl-${OPENSSL_VER}"
	CC=arm-linux-musleabihf-gcc \
	AR=arm-linux-musleabihf-ar \
	RANLIB=arm-linux-musleabihf-ranlib \
	./Configure linux-armv4 no-shared no-tests no-async --prefix="${OPENSSL_PREFIX}"
	make -j"$(nproc)"
	make install_sw
fi

# ---------- 3. 打补丁 ----------
PATCH_FILE="$(cd "$(dirname "$0")" && pwd)/smartdns-eventfd.patch"
if [ ! -f "${SRC_DIR}/src/main.c" ]; then
	echo "错误: 源码目录不对: ${SRC_DIR}" >&2
	exit 1
fi

if [ -f "${SRC_DIR}/src/include/eventfd_compat.h" ] && \
	grep -q "eventfd_compat.h" "${SRC_DIR}/src/fast_ping/wakeup_event.c" 2>/dev/null; then
	echo ">>> 补丁已存在，跳过"
else
	echo ">>> 应用补丁"
	cd "${SRC_DIR}"
	patch -p1 --dry-run < "${PATCH_FILE}"
	patch -p1 < "${PATCH_FILE}"
fi

# ---------- 4. 编译 ----------
echo ">>> 编译 SmartDNS"
cd "${SRC_DIR}/src"
make clean >/dev/null 2>&1 || true
make CC=arm-linux-musleabihf-gcc STATIC=yes VER="${SMARTDNS_VER}" \
	EXTRA_CFLAGS="-I${OPENSSL_PREFIX}/include" \
	EXTRA_LDFLAGS="-L${OPENSSL_PREFIX}/lib"

arm-linux-musleabihf-strip smartdns
cp smartdns "${OUT_DIR}/smartdns"
echo ">>> 完成: ${OUT_DIR}/smartdns"
file "${OUT_DIR}/smartdns"
