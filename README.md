# xray-xhttp-wireguard-relay

[![Release](https://img.shields.io/github/v/release/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/releases)
[![Release date](https://img.shields.io/github/release-date/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/releases)
[![Downloads](https://img.shields.io/github/downloads/superchaospc/xray-xhttp-wireguard-relay/total?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/releases)
[![Last commit](https://img.shields.io/github/last-commit/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/commits/main)
[![Issues](https://img.shields.io/github/issues/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/issues)
[![Stars](https://img.shields.io/github/stars/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/stargazers)
[![Forks](https://img.shields.io/github/forks/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay/network/members)
[![Repo size](https://img.shields.io/github/repo-size/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay)
[![Code size](https://img.shields.io/github/languages/code-size/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](https://github.com/superchaospc/xray-xhttp-wireguard-relay)
[![License](https://img.shields.io/github/license/superchaospc/xray-xhttp-wireguard-relay?style=flat-square)](LICENSE)
![Tests](https://img.shields.io/badge/tests-bash%20%2B%20shellcheck-brightgreen?style=flat-square)
![Bash](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square)
![Linux](https://img.shields.io/badge/platform-Linux%20systemd-blue?style=flat-square)
![Xray](https://img.shields.io/badge/core-Xray-2F6FED?style=flat-square)
![XHTTP](https://img.shields.io/badge/transport-XHTTP-0EA5E9?style=flat-square)
![REALITY](https://img.shields.io/badge/security-REALITY-7C3AED?style=flat-square)
![WireGuard](https://img.shields.io/badge/relay-WireGuard-88171A?style=flat-square)
![Debian](https://img.shields.io/badge/Debian-supported-A81D33?style=flat-square)
![Ubuntu](https://img.shields.io/badge/Ubuntu-supported-E95420?style=flat-square)
![RHEL](https://img.shields.io/badge/RHEL--compatible-supported-EE0000?style=flat-square)

单文件部署工具：

```text
客户端
  -> 中转 VPS：VLESS + XHTTP + REALITY
  -> 独立 WireGuard 隧道
  -> 落地 VPS：转发 + NAT
  -> Internet
```

同一台 Relay 可以管理多条 Exit 线路。每条线路拥有独立客户端 TCP
端口、XHTTP 路径、REALITY 凭据、WireGuard 接口、UDP 端口、密钥和
`/30` 子网。修改客户端端口不会改变 WireGuard 身份。

> **秘密参数包警告：** Exit 输出的 `WG_BUNDLE` 包含 Relay WireGuard
> 私钥。只通过可信的加密渠道传输，不要发到聊天群、工单或公开日志。
> 参数包内的 SHA-256 仅检测意外损坏，不提供加密、签名或身份认证。

## 要求

- Linux、root、systemd。
- 优先支持 Debian/Ubuntu，兼容使用 `dnf` 的 RHEL 系发行版。
- 客户端与 Xray core 必须支持 XHTTP + REALITY。
- Relay 对外开放每条线路的 TCP 入口端口。
- Exit 对外开放每条线路的 WireGuard UDP 端口。
- 云厂商安全组也必须同步放行；脚本无法修改云控制台规则。

## 安装

### 1. 先在 Exit 运行

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-xhttp-wireguard-relay/main/xray_xhttp_wireguard_relay.sh \
  -o /root/xray_xhttp_wireguard_relay.sh
chmod +x /root/xray_xhttp_wireguard_relay.sh
/root/xray_xhttp_wireguard_relay.sh --exit
```

Exit 会安装 WireGuard、自动分配 `/30` 子网和 UDP 端口、启用精确范围的
转发/NAT，并输出一条包含 `WG_BUNDLE` 的 Relay 命令。

### 2. 在 Relay 粘贴 Exit 输出的命令

示意：

```bash
WG_BUNDLE='SECRET_BUNDLE' \
RELAY_PORT='443' \
ROUTE_NAME='US Exit' \
AUTO_YES=1 \
bash /root/xray_xhttp_wireguard_relay.sh --relay
```

成功后会输出 `vless://` 客户端链接并刷新：

```text
/root/xray_xhttp_wireguard_subscription.txt
```

### 3. 添加更多线路

在新 Exit 重复第一步，然后在同一 Relay 导入新参数包，使用另一个客户端
端口：

```bash
WG_BUNDLE='SECOND_SECRET_BUNDLE' RELAY_PORT='8443' ROUTE_NAME='DE Exit' \
  AUTO_YES=1 bash /root/xray_xhttp_wireguard_relay.sh --relay
```

默认从 `10.77.0.0/16` 分配 `/30`，UDP 从 `51821` 开始。存在内网冲突时：

```bash
WG_SUBNET_POOL='10.199.0.0/16' WG_PORT_START='52000' \
  bash /root/xray_xhttp_wireguard_relay.sh --exit
```

## 管理

```bash
# 查看线路和链接
bash /root/xray_xhttp_wireguard_relay.sh --list

# 刷新并显示 base64 订阅
bash /root/xray_xhttp_wireguard_relay.sh --sub

# 终端二维码与当前流量
bash /root/xray_xhttp_wireguard_relay.sh --qr
bash /root/xray_xhttp_wireguard_relay.sh --stats

# 状态与诊断
bash /root/xray_xhttp_wireguard_relay.sh --status
bash /root/xray_xhttp_wireguard_relay.sh --doctor

# 改名
RELAY_PORT=443 ROUTE_NAME='Main Exit' bash /root/xray_xhttp_wireguard_relay.sh --rename

# 修改客户端入口端口
RELAY_PORT=443 NEW_RELAY_PORT=9443 bash /root/xray_xhttp_wireguard_relay.sh --port

# 删除单条线路
RELAY_PORT=9443 bash /root/xray_xhttp_wireguard_relay.sh --delete

# 重启和更新 Xray
bash /root/xray_xhttp_wireguard_relay.sh --restart
bash /root/xray_xhttp_wireguard_relay.sh --update

# 删除本项目管理的资源
bash /root/xray_xhttp_wireguard_relay.sh --uninstall
```

直接运行脚本会进入交互菜单。线路状态以版本化 JSON 保存，敏感文件权限为 `600`。脚本使用稳定的
`route_id` 生成不超过 15 字符的 WireGuard 接口名，例如
`xwg-a1b2c3d4`。项目 firewall 规则带
`xray-xhttp-wireguard-relay:<route_id>` 标记，删除时不会按模糊端口匹配
清理无关规则。

## XHTTP

默认 `XHTTP_MODE=auto`，还支持：

```text
stream-one
stream-up
packet-up
```

每条线路生成独立随机路径。客户端 URI 包含 `type=xhttp`、`path`、
`mode`、`security=reality`、`pbk`、`sid`、`sni` 和 `fp`。

## IPv6 与 MTU

Relay 或 Exit 的公网 endpoint 可以是 IPv4 或 IPv6；IPv6 WireGuard
endpoint 会自动格式化为 `[2001:db8::1]:51821`。

默认 `WG_MTU=1380`。若出现网页部分加载、TLS 卡顿或大包丢失，可尝试：

```bash
WG_MTU=1280 bash /root/xray_xhttp_wireguard_relay.sh --relay
```

同时检查云安全组、宿主机 UDP 限制和路径 MTU。

## 排错

```bash
xray run -test -config /usr/local/etc/xray/config.json
wg show
ip rule show
ip route show table all
systemctl status xray
systemctl status wg-quick@xwg-ROUTEID
```

`--doctor` 会显示 Xray 配置、监听端口、策略路由、WireGuard latest
handshake 和流量计数。它不会输出 WireGuard 私钥或预共享密钥，即使
`XRAY_REDACT=0`。

没有握手时依次检查：

1. Exit UDP 端口及云安全组。
2. Exit endpoint 是否正确，IPv6 是否可达。
3. 两端系统时间和 WireGuard 服务。
4. NAT/forward 规则及 `net.ipv4.ip_forward=1`。
5. 地址池是否和 Docker、Tailscale、内网或其他 VPN 冲突。

## 测试

```bash
bash run_all_tests.sh
```

测试包含 Bash 语法、ShellCheck、项目身份、XHTTP 配置、IPv6 endpoint、
稳定接口名、多线路生命周期、策略路由、firewall 所有权和诊断入口。

自动化测试不等同于真实公网验证。正式使用前应在可丢弃 VPS 上确认：

- WireGuard 完成握手并有双向计数。
- 代理后的公网 IP 是 Exit 地址。
- 重启后 Xray 和所有 `wg-quick@...` 服务恢复。
- 删除一条线路不影响其他线路和 SSH。

## v1.0.0

- 客户端入口改为 VLESS XHTTP REALITY。
- VPS 间传输改为每线路独立 WireGuard。
- 保留多线路、链接、订阅、改名、改端口、删除、状态、诊断、更新和卸载。
- 增加秘密 route bundle、稳定接口名、源地址策略路由和带归属标记的 NAT。
- 支持 IPv4/IPv6 WireGuard endpoint。

## 来源与许可

本项目派生自
[superchaospc/xray-vps2vps-relay](https://github.com/superchaospc/xray-vps2vps-relay)
v1.4.3，保留 MIT License。感谢 Xray-core、WireGuard 及上游项目。

本项目仅用于合法的网络运维、隐私保护与协议研究。使用者需遵守所在地法律
及服务商条款，并自行承担部署和使用风险。
