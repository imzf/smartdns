#!/bin/sh
#
# IPv6 地址看门狗
#   检测 WAN/LAN 的 IPv6 全局地址是否丢失，丢失则重连 wan6；
#   检测 LAN 前缀变化，变化后重载 dnsmasq 让终端收到新 RA。
#
# 用法: ipv6-watchdog.sh [--verbose]
# 建议由 cron 每 5 分钟调用一次。

set -u

LOG_TAG="ipv6-wd"
STATE_FILE="/tmp/ipv6-wd.prefix"
LOCK_DIR="/tmp/ipv6-wd.lock"

# 原子加锁；进程异常退出后，下一次运行会清理过期锁。
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		exit 0
	fi
	rm -rf "$LOCK_DIR"
	mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# wan6 未配置时不做恢复，避免 IPv4-only 环境每 5 分钟重拨 WAN。
if command -v ifstatus >/dev/null 2>&1 && ! ifstatus wan6 >/dev/null 2>&1; then
	logger -t "$LOG_TAG" "wan6 not configured, skip"
	exit 0
fi

get_wan6() {
	ip -6 addr show pppoe-wan 2>/dev/null | awk '/scope global/{print $2; exit}'
}

get_lan6() {
	ip -6 addr show br-lan 2>/dev/null | awk '/scope global/{print $2; exit}'
}

check_odhcp6c() {
	ps w 2>/dev/null | grep -q "[o]dhcp6c"
}

reconnect() {
	reason="$1"
	logger -t "$LOG_TAG" "$reason, reconnecting wan6"
	ifup wan6 2>/dev/null
	sleep 12

	wan6=$(get_wan6)
	lan6=$(get_lan6)
	if [ -z "$wan6" ] || [ -z "$lan6" ]; then
		logger -t "$LOG_TAG" "still missing after wan6 up (wan='$wan6' lan='$lan6'), bouncing wan"
		ifup wan 2>/dev/null
		sleep 25
	fi
}

# ---- 1. odhcp6c 进程 ----
if ! check_odhcp6c; then
	reconnect "odhcp6c not running"
fi

# ---- 2. 全局地址 ----
wan6=$(get_wan6)
lan6=$(get_lan6)

if [ -z "$wan6" ] || [ -z "$lan6" ]; then
	reconnect "IPv6 address missing (wan='$wan6' lan='$lan6')"
	wan6=$(get_wan6)
	lan6=$(get_lan6)
fi

# ---- 3. LAN 前缀变化 ----
if [ -n "$lan6" ]; then
	prefix=$(echo "$lan6" | cut -d/ -f1)
	# 取前 4 段作为前缀标识（/60 时前 3 段固定，第 4 段也属于前缀）
	prefix_key=$(echo "$prefix" | cut -d: -f1-4)
	old_key=$(cat "$STATE_FILE" 2>/dev/null)

	if [ -z "$old_key" ]; then
		# 首次运行，只记录
		echo "$prefix_key" > "$STATE_FILE"
		logger -t "$LOG_TAG" "initial prefix recorded: $prefix_key"
	elif [ "$old_key" != "$prefix_key" ]; then
		logger -t "$LOG_TAG" "LAN prefix changed: $old_key -> $prefix_key, reloading dnsmasq for new RA"
		echo "$prefix_key" > "$STATE_FILE"
		/etc/init.d/dnsmasq reload 2>/dev/null || /etc/init.d/dnsmasq restart 2>/dev/null
	fi
fi

# ---- 4. 结果 ----
if [ -n "$wan6" ] && [ -n "$lan6" ]; then
	[ "${1:-}" = "--verbose" ] && echo "OK  wan=$wan6  lan=$lan6"
	exit 0
fi

logger -t "$LOG_TAG" "IPv6 still unavailable after recovery attempts"
exit 1
