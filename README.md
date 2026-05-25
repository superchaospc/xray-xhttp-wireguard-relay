# xray-vps2vps-relay

[![GitHub release](https://img.shields.io/github/v/release/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/releases)
[![Release date](https://img.shields.io/github/release-date/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/releases)
[![Downloads](https://img.shields.io/github/downloads/superchaospc/xray-vps2vps-relay/total?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/releases)
[![Last commit](https://img.shields.io/github/last-commit/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/commits/main)
[![Issues](https://img.shields.io/github/issues/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/issues)
[![Stars](https://img.shields.io/github/stars/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/stargazers)
[![Forks](https://img.shields.io/github/forks/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/network/members)
[![GitHub repo size](https://img.shields.io/github/repo-size/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay)
[![Code size](https://img.shields.io/github/languages/code-size/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay)
[![License](https://img.shields.io/github/license/superchaospc/xray-vps2vps-relay?style=flat-square)](LICENSE)
[![Shell](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square)](xray_vps2vps_deploy.sh)
[![Platform](https://img.shields.io/badge/platform-Linux%20systemd-blue?style=flat-square)](README.md)
[![Xray](https://img.shields.io/badge/core-Xray-2F6FED?style=flat-square)](https://github.com/XTLS/Xray-core)
[![VLESS REALITY](https://img.shields.io/badge/protocol-VLESS%20%2B%20REALITY-7C3AED?style=flat-square)](README.md)
[![BBR](https://img.shields.io/badge/BBR-auto%20enable-00A86B?style=flat-square)](README.md)
[![Multi route](https://img.shields.io/badge/relay-multi--route-orange?style=flat-square)](README.md)
[![QR import](https://img.shields.io/badge/client-QR%20import-0EA5E9?style=flat-square)](README.md)
[![Subscription](https://img.shields.io/badge/subscription-base64-10B981?style=flat-square)](README.md)
[![Debian](https://img.shields.io/badge/Debian-supported-A81D33?style=flat-square)](README.md)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-supported-E95420?style=flat-square)](README.md)
[![CentOS](https://img.shields.io/badge/CentOS-supported-262577?style=flat-square)](README.md)

单文件脚本，用于部署：

```text
客户端 -> 中转 VPS(Relay, VLESS+REALITY) -> 落地 VPS(Exit, VLESS+REALITY) -> Internet
```

它适合“入口 VPS 不想作为最终出口，希望落地到另一台 VPS 的公网 IP”的场景。和住宅 SOCKS5 中转不同，Exit VPS 不再配置 SOCKS5，直接用 `freedom` 出站。

同一台 Relay VPS 支持管理多条落地线路。每条线路使用独立入口端口，互不影响：

```text
Relay:443   -> Spain Exit
Relay:8443  -> Germany Exit
Relay:9443  -> US Exit
```

## 推荐向导安装

正常安装顺序是：**先安装落地 VPS（Exit），再把这条线路添加到中转 VPS（Relay）**。

### Step 1：在落地 VPS 上安装 Exit

先登录落地 VPS：

```bash
ssh root@EXIT_VPS_IP
```

下载并运行脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-vps2vps-relay/main/xray_vps2vps_deploy.sh -o /root/xray_vps2vps_deploy.sh
chmod +x /root/xray_vps2vps_deploy.sh
/root/xray_vps2vps_deploy.sh
```

选择：

```text
1) 推荐向导安装
1) Exit 落地 VPS
```

安装时会让你选择 REALITY 伪装站点：

```text
1) Microsoft   - www.microsoft.com（推荐，避免被识别成 Cloudflare 反代）
2) Apple       - www.apple.com
3) Cloudflare  - www.cloudflare.com
4) 自定义域名
```

部署完成后，Exit 会输出：

- `Exit Host`
- `Exit Port`
- `Exit UUID`
- `Exit Public Key`
- `Exit Short ID`
- `Exit SNI`
- 一段给 Relay VPS 使用的一键安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-vps2vps-relay/main/xray_vps2vps_deploy.sh -o /root/xray_vps2vps_deploy.sh
chmod +x /root/xray_vps2vps_deploy.sh
REALITY_SITE='microsoft' REALITY_SERVER_NAME='www.microsoft.com' EXIT_BUNDLE='...' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

### Step 2：在中转 VPS 上添加这条线路

再登录中转 VPS：

```bash
ssh root@RELAY_VPS_IP
```

直接粘贴 Step 1 里 Exit 输出的整段 Relay 安装命令。第一条线路默认使用 `443`：

```bash
curl -fsSL https://raw.githubusercontent.com/superchaospc/xray-vps2vps-relay/main/xray_vps2vps_deploy.sh -o /root/xray_vps2vps_deploy.sh
chmod +x /root/xray_vps2vps_deploy.sh
REALITY_SITE='microsoft' REALITY_SERVER_NAME='www.microsoft.com' EXIT_BUNDLE='...' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

如果你在 Exit 安装时选择了 Microsoft 或 Apple，Exit 输出的 Relay 一键命令会自动带上对应的 `REALITY_SITE` / `REALITY_SERVER_NAME`，Relay 对客户端的入口也会使用同一个伪装站点。

如果你已经提前在 Relay VPS 上下载好了脚本，也可以只执行最后一行：

```bash
REALITY_SITE='microsoft' REALITY_SERVER_NAME='www.microsoft.com' EXIT_BUNDLE='...' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

### Step 3：导入客户端

Relay 添加线路完成后会输出：

- `vless://...` 客户端链接
- 终端二维码

用 Shadowrocket、Neobox、V2rayN、V2rayNG、NekoBox 扫码或导入链接即可。

## 添加更多落地线路

要在同一台 Relay VPS 上增加第二条、第三条线路：

1. 在新的落地 VPS 上重复 Step 1，安装 Exit。
2. 回到同一台 Relay VPS，执行新 Exit 输出的 Relay 安装命令。
3. 把命令里的 `RELAY_PORT='443'` 改成一个未使用端口，例如 `8443`、`9443`。

如果 Relay VPS 已经用旧版脚本部署过第一条单线路，新版脚本会在添加新线路前自动把现有 Xray 配置迁移到线路表，避免新增线路时覆盖旧线路。

示例：

```bash
REALITY_SITE='microsoft' REALITY_SERVER_NAME='www.microsoft.com' EXIT_BUNDLE='...' RELAY_PORT='8443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

如果误用已存在端口，脚本会拒绝覆盖，并提示换一个端口。确实要覆盖旧线路时，额外设置 `ALLOW_OVERWRITE=1`。

## Relay 管理菜单

在中转 VPS 上直接运行脚本，会进入管理菜单：

```bash
/root/xray_vps2vps_deploy.sh
```

菜单包含：

- 添加/更新落地线路
- 查看线路状态：Xray 服务、本地监听端口、到 Exit 的 TCP 连通性
- 流量统计：按线路显示 Xray 启动以来的上下行流量
- 查看所有线路和 VLESS 链接：不用记命令，直接在菜单里显示已建线路的 `vless://` 链接
- 显示线路二维码：选择单条或全部线路，直接在终端扫码导入
- 刷新/显示订阅：生成 `/root/xray_vps2vps_subscription.txt` 和 `data:text/plain;base64,...` 订阅链接
- 修改线路入口端口：保留线路参数，只更换 Relay 对客户端监听的端口
- 删除线路
- 修改线路名称
- 查看所有线路和客户端链接
- 一键排错诊断：检查 Xray、配置、端口监听、Exit 连通性、防火墙、BBR、系统资源和最近日志
- 更新 Xray
- 重启 Xray

## 菜单操作

所有常用操作都可以在菜单里完成。登录 **Relay 中转 VPS** 后只需要运行一次：

```bash
/root/xray_vps2vps_deploy.sh
```

然后按菜单编号选择：

- `6) 查看所有线路和 VLESS 链接`：显示已建线路和 `vless://` 客户端链接
- `7) 显示线路二维码`：选择单条线路或全部线路，直接扫码导入
- `8) 刷新/显示订阅`：生成订阅文件并显示订阅 Data URL
- `9) Relay 多线路管理`：进入改名、改端口、删除线路等管理入口
- `10) 一键排错诊断`：检查服务、配置、端口、防火墙、BBR、Exit 连通性和最近日志
- `11) 更新 Xray`：更新 Xray 并重启
- `12) 重启 Xray`
- `13) 卸载`

删除线路时只移除指定 Relay 入口端口对应的线路，其余线路不受影响。

## 失败回滚

脚本在写入新配置前会先执行 `xray run -test`。新增线路、删除线路或重启失败时，会自动恢复旧的 Xray 配置和旧的线路表，避免其他已在线路被新操作影响。

### 手动上传脚本

如果你是在本地开发目录里，也可以不用 `curl`，改为手动上传：

```bash
scp xray_vps2vps_deploy.sh root@EXIT_VPS_IP:/root/
scp xray_vps2vps_deploy.sh root@RELAY_VPS_IP:/root/
```

## 可选命令行方式

日常使用推荐走菜单；下面的命令行参数只适合自动化、复制一键命令或批量部署时使用。

直接指定安装 Exit：

```bash
/root/xray_vps2vps_deploy.sh --exit
```

Relay 支持读取 Exit 输出的参数包：

```bash
REALITY_SITE='microsoft' REALITY_SERVER_NAME='www.microsoft.com' EXIT_BUNDLE='PASTE_EXIT_BUNDLE_HERE' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

## 可选环境变量

```bash
REALITY_SITE=microsoft bash xray_vps2vps_deploy.sh
CLIENT_FP=ios REALITY_SITE=apple bash xray_vps2vps_deploy.sh
REALITY_SITE=custom REALITY_SERVER_NAME=www.example.com REALITY_DEST=www.example.com:443 bash xray_vps2vps_deploy.sh
```

常用变量：

- `CLIENT_FP`：客户端指纹，默认 `chrome`。
- `REALITY_SITE`：伪装站点预设，支持 `microsoft` / `apple` / `cloudflare` / `custom`，默认 `microsoft`。
- `REALITY_SERVER_NAME`：自定义 REALITY SNI。使用 `REALITY_SITE=custom` 时必填；预设模式下会自动设置。
- `REALITY_DEST`：REALITY 回源目标，默认 `${REALITY_SERVER_NAME}:443`。
- `XRAY_INSTALL_REF`：XTLS/Xray-install 的 ref，默认 `main`。
- `XRAY_INSTALL_SHA256`：可选，设置后校验安装脚本 sha256。
- `XRAY_REDACT=1`：隐藏输出中的敏感字段中段。
- `AUTO_YES=1`：使用默认值和环境变量，不再交互询问，适合一键安装命令。
- `EXIT_BUNDLE`：Exit 输出的一键参数包，Relay 会自动解析。
- `EXIT_PORT` / `RELAY_PORT`：分别指定 Exit 和 Relay 监听端口。
- `ROUTE_NAME`：Relay 线路名称；默认使用落地 VPS 的 Host/IP。
- `ALLOW_OVERWRITE=1`：允许用同一个 Relay 入口端口覆盖旧线路。

## 本地测试

在本机或开发环境中运行：

```bash
bash test_xray_vps2vps_deploy.sh
```

当前测试状态：

| 项目 | 结果 |
| --- | --- |
| Bash 语法检查（部署脚本 + 测试脚本） | 通过 |
| 项目自带测试套件 `test_xray_vps2vps_deploy.sh` | 7 项全部通过，退出码 0 |
| `shellcheck -S warning`（脚本作者标准） | 0 警告 |
| `shellcheck -S style`（额外严格检查） | 仅 2 条风格/误报提示，均不影响功能 |

自带测试套件覆盖：

- Bash 语法检查
- `shellcheck` 静态检查
- Exit / Relay / 多线路 Relay 配置生成
- 旧版单线路配置迁移
- Exit bundle 编解码
- 订阅文件生成、base64 编码和 URL 编码
- `xray x25519` 密钥输出解析

`shellcheck -S style` 的两条提示说明：

- `SC2153`：`RELAY_PORT` 和 `relay_port` 是 Bash 环境变量与 JSON/Python 字段名同时存在导致的误报，不是拼写错误。
- `SC2001`：`echo | sed 's/^/ /'` 可改成参数展开，属于纯风格建议，不影响功能。

这些测试不会安装 Xray，也不会改系统配置。部署脚本本体面向 Linux + systemd + root 环境；真实端到端部署仍建议在 Linux VPS 上验证。

## 注意

- 两台 VPS 都需要 root 和 systemd。
- Relay 和 Exit 的监听端口都需要在系统防火墙和云厂商安全组放行。
- 如果 443 被 Nginx/Caddy/旧 Xray 占用，可以换端口。
- 本脚本仅供学习网络协议和 Linux 运维自动化，请遵守所在地法律法规。
