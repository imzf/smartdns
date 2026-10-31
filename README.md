# SmartDNS for CMCC RAX3000-QY

中国移动 RAX3000-QY（IPQ5018 / OpenWrt Chaos Calmer 15.05.1 / 内核 4.4.60）上运行 SmartDNS 的补丁、构建脚本与配置归档。

## 许可证与合规

本仓库是 [SmartDNS](https://github.com/pymumu/smartdns) 的衍生作品归档，按
**GPL-3.0-or-later** 发布，许可证全文见 [`LICENSE`](LICENSE)。上游版权归
Ruilin Peng (Nick) `<pymumu@gmail.com>` 所有（2018-2025）。

本仓库只提供补丁、构建脚本和配置，不包含完整的上游源码副本，也不发布
二进制。补丁基于 Release48.4；对应源码、修改声明（8 个 `.c` 文件 + 新增
`src/include/eventfd_compat.h`，修改日期 2026-10-31）和第三方组件许可，见
[`NOTICE`](NOTICE)。如你自行构建并对外分发二进制，请自行按 GPLv3 §6 提供
对应源码。

使用边界、风险与免责声明见 [`DISCLAIMER.md`](DISCLAIMER.md)。以下内容为工程
合规说明，不构成法律意见。

## 为什么需要补丁

这台设备的内核没有编译 `CONFIG_EVENTFD`：

```
eventfd2 (356) -> errno = function not implemented
```

SmartDNS 从 2023 年起在 `fast_ping` 的线程唤醒里用了 eventfd，导致 Release39 及之后所有版本启动即失败：

```
create eventfd failed, Function not implemented
init wakeup event failed, Function not implemented
```

补丁用一个 **connect 到自己的 loopback UDP socket** 实现等价的单 fd 读写语义，替换 eventfd，业务代码零改动。

## 文件说明

| 文件 | 说明 |
|---|---|
| `smartdns-eventfd.patch` | 补丁，`patch -p1` 应用。新增 `src/include/eventfd_compat.h`，替换 8 个文件的 `#include <sys/eventfd.h>` |
| `build.sh` | 一键交叉编译脚本（自动下载工具链、编译 OpenSSL、打补丁、编译 SmartDNS） |
| `smartdns.conf.ipv6` | 线上使用的 IPv6 优化配置（双栈监听 + IPv6 上游 + 国内外分流） |
| `smartdns-fallback.conf` | 降级配置：数据盘不可用、国内域名列表缺失时使用，全部走 DoT |
| `ipv6-check.sh` | IPv6 链路自检脚本，6 组检查项，退出码 0/1 |
| `ipv6-watchdog.sh` | IPv6 地址看门狗：检测地址丢失后重连 wan6，前缀变化时重发 RA |
| `BUILD-NOTES.txt` | 路由器上留存的构建说明 |
| `LICENSE` | GPL-3.0 许可证全文 |
| `NOTICE` | 上游归属、修改声明、对应源码获取方式、第三方组件许可 |
| `DISCLAIMER.md` | 使用边界、风险与免责声明 |
| `LICENSES/OpenSSL.txt` | OpenSSL 1.1.1 的 OpenSSL License + SSLeay License 全文 |

## 快速构建

```bash
# 准备源码
curl -L -o sd.tar.gz https://github.com/pymumu/smartdns/archive/refs/tags/Release48.4.tar.gz
tar xzf sd.tar.gz
mv smartdns-Release48.4 smartdns-src

# 编译（首次会自动下载工具链和 OpenSSL，约需 10 分钟）
./build.sh ./smartdns-src ./out
```

下载的工具链和 OpenSSL 会校验 SHA-256。如上游文件更新导致校验失败，请更新
`build.sh` 中的哈希；仅在可信环境下才考虑临时设置 `SKIP_VERIFY=1`。

产物 `out/smartdns` 约 2.7MB，`static-pie`，直接 scp 到路由器即可。

## 部署

```sh
# 路由器上
cp /usr/sbin/smartdns /usr/sbin/smartdns.bak
scp out/smartdns root@192.168.123.1:/usr/sbin/smartdns
chmod 755 /usr/sbin/smartdns
/etc/init.d/smartdns restart
```

## 回滚

```sh
cp /usr/sbin/smartdns.release38.bak /usr/sbin/smartdns
/etc/init.d/smartdns restart
```

## 补丁细节

`eventfd_compat.h` 的核心：

```c
fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
bind(fd, 127.0.0.1:0);
getsockname(fd, &addr);
connect(fd, &addr);   /* 自己连自己 */
```

写端 `write(fd, &u, 8)` 后，epoll 立即报告 `EPOLLIN`；读端 `read` 取走数据后再次可读返回 `EAGAIN`，与 eventfd 行为一致。

涉及的 8 个文件：

```
src/fast_ping/wakeup_event.c
src/fast_ping/notify_event.c
src/fast_ping/fast_ping.c
src/dns_server/dns_server.c
src/dns_server/neighbor.c
src/dns_server/local_addr.c
src/dns_server/connection.c
src/dns_client/wake_event.c
```

## 已知限制

- 内核 raw socket 受限，`ICMP ping is disabled`，IP 优选只能用 `tcp:443,tcp:80` 测速
- 路由器 `/overlay` 仅剩约 2.8MB，二进制 2.7MB，注意别塞满
- 国内 DoH（如 dns.alidns.com）对境外域名仍返回污染结果，防污染必须用境外 DoT；实测只有 `1.1.1.1:853` 可达
- 构建使用 OpenSSL 1.1.1w；该系列已于 2023-09-11 EOL，不再获得安全修复，建议升级到 OpenSSL 3.x

## 安全边界

- **DoT 证书校验**：当前配置的 `server-tls ... -no-check-certificate` 会关闭上游证书校验，只提供加密而不认证服务器，存在中间人风险。建议在路由器安装 CA 证书包后，改用 `-host-name cloudflare-dns.com`（或 `-tls-host-verify`）并移除该选项；若只能保持现状，请把上游网络视为不可信。
- **监听面**：`bind [::]:6053` 会监听所有接口。必须确认 WAN 侧防火墙丢弃 6053/tcp+udp，或改成只绑定 LAN 地址；否则会成为可被利用的开放递归解析器。
- **数据暴露**：DNS 查询会发送给配置中的第三方上游（境外 DoT 和国内明文 DNS）；`cache-file` 与日志可能包含访问记录。建议缓存目录 0700、日志使用 `log-file-mode 600`，并缩短保留时间。
- **供应链**：`build.sh` 会下载工具链和 OpenSSL，现已内置 SHA-256 校验；仍建议在可信网络构建，并保留校验记录。

## IPv6 配置要点

移动宽带的 IPv6 质量不错（公网前缀 `2409:8a20:2a9a:e890::/60`），配置做了这些优化：

- `bind [::]:6053` —— 依赖 `net.ipv6.bindv6only=0`，一个 socket 同时服务 IPv4/IPv6
- 国内组上游：阿里 `2400:3200::1`、`2400:3200:baba::1`、腾讯 `2402:4e00::`，IPv4 的 223.5.5.5 / 119.29.29.29 作备用
- 国外组上游：Cloudflare DoT `2606:4700:4700::1111` / `::1001`，IPv4 的 1.1.1.1 / 1.0.0.1 作备用
- `dualstack-ip-selection yes` + `threshold 30` —— A/AAAA 并存时按实测延迟排序
- 腾讯 `2402:4e00::` 的 ICMP 被禁，ping 不通但 DNS 查询正常

自检：

```sh
/usr/sbin/ipv6-check.sh
```

检查接口地址、默认路由、上游可达性、服务状态、A/AAAA 解析，共 6 组。busybox 的 `nslookup` 不支持 `-type=AAAA`，所以 AAAA 部分用 `ping6` 的解析结果判断。

## IPv6 地址看门狗

这台路由器偶尔会丢 IPv6 地址（odhcp6c 挂掉或运营商 PD 租约变化）。`ipv6-watchdog.sh` 负责检测和恢复：

```sh
/usr/sbin/ipv6-watchdog.sh          # 静默模式，供 cron 调用
/usr/sbin/ipv6-watchdog.sh --verbose
```

检查逻辑：

1. `odhcp6c` 进程是否在
2. `pppoe-wan` 是否有全局 IPv6 地址
3. `br-lan` 是否有全局 IPv6 前缀

任一缺失就 `ifup wan6` 重启 odhcp6c；12 秒后仍缺就 `ifup wan` 重拨 PPPoE。

另外记录 `br-lan` 前缀到 `/tmp/ipv6-wd.prefix`，前缀变化时 `dnsmasq reload`，让 dnsmasq 用新前缀重新发 RA——终端 SLAAC 会拿到新地址，旧前缀地址按 RA 里的 lifetime 自动弃用。

cron 每 5 分钟跑一次：

```
*/5 * * * * /usr/sbin/ipv6-watchdog.sh
```

实测：`kill -9` odhcp6c 后，脚本检测到 WAN 地址缺失并执行 `ifup wan6`，地址恢复；手动改状态文件模拟前缀变化，日志出现 `LAN prefix changed ... reloading dnsmasq`。

## 性能优化

实测发现最大的延迟来源不是 DoT 握手，而是 **`speed-check-mode` 的 TCP 测速**：每个返回的 IP 都要建一次 TCP 连接，境外 IP 一次几百毫秒。

改成分组设置后（国内测速、境外不测速）：

```conf
speed-check-mode none          # 默认组（境外）

group-begin cn
speed-check-mode tcp:443,tcp:80
group-end
```

冷缓存对比（直接查 6053）：

| 域名 | 全局测速 | 分组测速 |
|---|---|---|
| www.google.com | 647ms | **51ms** |
| www.youtube.com | 998ms | **50ms** |
| github.com | 311ms | **53ms** |
| 平均 | 592ms | **72ms** |

其他优化：

- `cache-size 16384`（原 8192）
- `cache-persist yes` + `cache-file /mnt/data/smartdns/smartdns.cache` —— 重启后缓存不丢
- `log-level warn`（原 info），减少 tmpfs 写入
- `serve-expired-prefetch-time 21600` —— 过期缓存提前预取

`response-mode fastest-ip` 试过，但它依赖测速结果，`speed-check-mode none` 下不生效，所以没启用。

## 免责声明

完整条款见 [`DISCLAIMER.md`](DISCLAIMER.md)。要点：

- 本仓库是第三方独立作品，与上游 SmartDNS 及中国移动、Qualcomm、OpenWrt、
  Cloudflare、阿里、腾讯等官方无隶属、合作或背书关系。
- 按「现状」提供，不附带任何明示或默示担保；修改固件或替换系统二进制有设备
  变砖、断网、失去保修的风险，请先备份并保留回滚版本。
- 仅限本人拥有或已获授权的设备与网络，仅限个人/私有环境使用；不得把 6053
  端口作为公共 DNS 解析器对外开放；请自行遵守当地法律法规与运营商条款。
- DNS 查询会发送给第三方上游；缓存与日志可能包含访问记录；当前配置的
  `-no-check-certificate` 会关闭 DoT 证书校验，存在中间人风险。
- 在适用法律允许的最大范围内，作者不承担任何直接或间接责任。
