# xray-vps2vps-relay

[![GitHub release](https://img.shields.io/github/v/release/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay/releases)
[![GitHub repo size](https://img.shields.io/github/repo-size/superchaospc/xray-vps2vps-relay?style=flat-square)](https://github.com/superchaospc/xray-vps2vps-relay)
[![License](https://img.shields.io/github/license/superchaospc/xray-vps2vps-relay?style=flat-square)](LICENSE)
[![Shell](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square)](xray_vps2vps_deploy.sh)
[![Platform](https://img.shields.io/badge/platform-Linux%20systemd-blue?style=flat-square)](README.md)

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
EXIT_BUNDLE='...' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
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
EXIT_BUNDLE='...' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

如果你已经提前在 Relay VPS 上下载好了脚本，也可以只执行最后一行：

```bash
EXIT_BUNDLE='...' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
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
EXIT_BUNDLE='...' RELAY_PORT='8443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

如果误用已存在端口，脚本会拒绝覆盖，并提示换一个端口。确实要覆盖旧线路时，额外设置 `ALLOW_OVERWRITE=1`。

## 查看和删除线路

查看所有线路和客户端链接：

```bash
/root/xray_vps2vps_deploy.sh --list
```

删除某条线路：

```bash
/root/xray_vps2vps_deploy.sh --delete
```

删除时只移除指定 Relay 入口端口对应的线路，其余线路不受影响。

## 失败回滚

脚本在写入新配置前会先执行 `xray run -test`。新增线路、删除线路或重启失败时，会自动恢复旧的 Xray 配置和旧的线路表，避免其他已在线路被新操作影响。

### 手动上传脚本

如果你是在本地开发目录里，也可以不用 `curl`，改为手动上传：

```bash
scp xray_vps2vps_deploy.sh root@EXIT_VPS_IP:/root/
scp xray_vps2vps_deploy.sh root@RELAY_VPS_IP:/root/
```

## 命令行方式

如果你不想走菜单，也可以直接指定角色：

```bash
/root/xray_vps2vps_deploy.sh --exit
```

Relay 支持读取 Exit 输出的参数包：

```bash
EXIT_BUNDLE='PASTE_EXIT_BUNDLE_HERE' RELAY_PORT='443' AUTO_YES=1 /root/xray_vps2vps_deploy.sh --relay
```

查看状态：

```bash
/root/xray_vps2vps_deploy.sh --status
```

查看 / 删除 Relay 线路：

```bash
/root/xray_vps2vps_deploy.sh --list
/root/xray_vps2vps_deploy.sh --delete
```

## 可选环境变量

```bash
CLIENT_FP=ios REALITY_SERVER_NAME=www.apple.com REALITY_DEST=www.apple.com:443 bash xray_vps2vps_deploy.sh
```

常用变量：

- `CLIENT_FP`：客户端指纹，默认 `chrome`。
- `REALITY_SERVER_NAME`：REALITY SNI，默认 `www.cloudflare.com`。
- `REALITY_DEST`：REALITY 回源目标，默认 `${REALITY_SERVER_NAME}:443`。
- `XRAY_INSTALL_REF`：XTLS/Xray-install 的 ref，默认 `main`。
- `XRAY_INSTALL_SHA256`：可选，设置后校验安装脚本 sha256。
- `XRAY_REDACT=1`：隐藏输出中的敏感字段中段。
- `AUTO_YES=1`：使用默认值和环境变量，不再交互询问，适合一键安装命令。
- `EXIT_BUNDLE`：Exit 输出的一键参数包，Relay 会自动解析。
- `EXIT_PORT` / `RELAY_PORT`：分别指定 Exit 和 Relay 监听端口。
- `ROUTE_NAME`：Relay 线路名称。
- `ALLOW_OVERWRITE=1`：允许用同一个 Relay 入口端口覆盖旧线路。

## 本地测试

在本机或开发环境中运行：

```bash
bash test_xray_vps2vps_deploy.sh
```

测试内容包括 Bash 语法、可选的 `shellcheck` 静态检查、Exit/Relay 两种配置生成后的 JSON 结构校验，以及一键参数包解析校验。这个测试不会安装 Xray，也不会改系统配置。

## 注意

- 两台 VPS 都需要 root 和 systemd。
- Relay 和 Exit 的监听端口都需要在系统防火墙和云厂商安全组放行。
- 如果 443 被 Nginx/Caddy/旧 Xray 占用，可以换端口。
- 本脚本仅供学习网络协议和 Linux 运维自动化，请遵守所在地法律法规。
