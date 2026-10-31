#!/bin/sh
#
# SmartDNS IPv6 自检脚本
# 适用于 CMCC RAX3000-QY (OpenWrt Chaos Calmer / busybox)
#
# 用法: sh ipv6-check.sh
# 退出码: 0 = 正常, 1 = 有 FAIL 项

PASS=0
FAIL=0
WARN=0

ok()   { echo "  [ OK ] $*"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN + 1)); }

echo "=========================================="
echo " SmartDNS IPv6 自检"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

echo
echo "[1/6] 接口 IPv6 地址"
v6lan=$(ip -6 addr show br-lan 2>/dev/null | awk '/scope global/{print $2; exit}')
if [ -n "$v6lan" ]; then
	ok "br-lan      $v6lan"
else
	bad "br-lan 没有全局 IPv6 地址"
fi

v6wan=$(ip -6 addr show pppoe-wan 2>/dev/null | awk '/scope global/{print $2; exit}')
if [ -n "$v6wan" ]; then
	ok "pppoe-wan   $v6wan"
else
	bad "pppoe-wan 没有全局 IPv6 地址"
fi

echo
echo "[2/6] IPv6 默认路由"
defroute=$(ip -6 route 2>/dev/null | grep "^default" | head -1)
if [ -n "$defroute" ]; then
	ok "默认路由存在"
	echo "         $defroute"
else
	bad "没有 IPv6 默认路由"
fi

echo
echo "[3/6] 上游 DNS 可达性"
for a in 2400:3200::1 2400:3200:baba::1 2402:4e00:: 2606:4700:4700::1111; do
	if ping6 -c 1 -W 2 "$a" >/dev/null 2>&1; then
		ok "$a"
	else
		warn "$a ping 不通（ICMP 可能被禁，不代表 DNS 不可用）"
	fi
done

echo
echo "[4/6] SmartDNS 服务"
psline=$(ps w 2>/dev/null | grep "[s]martdns" | head -1 || true)
if [ -n "$psline" ]; then
	pid=$(echo "$psline" | awk '{print $1}')
	ver=$(/usr/sbin/smartdns -v 2>/dev/null)
	ok "进程运行中  PID $pid  ($ver)"
else
	bad "进程未运行"
fi

listen=$(netstat -lnup 2>/dev/null | grep -E ":::6053|\[::\]:6053" || netstat -lnu 2>/dev/null | grep -E ":::6053|\[::\]:6053" || true)
if [ -n "$listen" ]; then
	ok "监听 [::]:6053（双栈）"
else
	bad "未监听 IPv6 6053"
fi

echo
echo "[5/6] A 记录解析（经 dnsmasq:53）"
if nslookup www.qq.com 127.0.0.1 2>/dev/null | awk '
	/^[[:space:]]*Name:/ { seen = 1 }
	seen && /^[[:space:]]*Address/ { found = 1 }
	END { exit !found }
'; then
	ok "www.qq.com A 记录正常"
else
	bad "www.qq.com A 记录解析失败"
fi

echo
echo "[6/6] AAAA 记录解析（经 dnsmasq:53）"
for d in www.qq.com www.taobao.com; do
	out=$(ping6 -c 1 -W 2 "$d" 2>&1)
	case "$out" in
		*"bad address"*|*"unknown host"*|*"not known"*|*"cannot resolve"*)
			bad "$d AAAA 解析失败"
			;;
		*)
			ok "$d AAAA 解析正常"
			;;
	esac
done

echo
echo "=========================================="
echo " 通过 $PASS 项，失败 $FAIL 项，警告 $WARN 项"
if [ "$FAIL" -eq 0 ]; then
	echo " 结论: IPv6 链路正常"
	exit 0
else
	echo " 结论: 存在异常，请检查上面的 FAIL 项"
	exit 1
fi
