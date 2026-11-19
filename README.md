# Relay · 中转一键脚本

在**中转机**上运行：粘贴落地的 `ss://` 链接（或手动填地址 / 端口 / 加密 / 密码），自动生成客户端连中转机用的节点。

```
一层：我 ──→ 中转机 ──→ 落地
两层：我 ──→ 中转机 ──→ 跳板 ──→ 落地          （例如 TW 落地经 HK 跳一下）
备用：我 ──→ 中转机 ──→ 落地 A / 落地 B        （自动选延迟最低的可用落地，挂了自动切换）
```

- **落地 / 跳板都用 Shadowsocks**：粘贴 `ss://` 链接自动识别，也可以手动填写；支持 2022-blake3-*、aes-128/256-gcm、chacha20-ietf-poly1305 等
- **入口协议每条线路可选**：VLESS-REALITY（默认，最不容易被识别）/ Shadowsocks
- **多条线路**：一台中转机接多个落地，每条线路一个入口端口，随时添加 / 修改 / 删除
- **备用落地自动切换**：一条线路可以挂多个落地，每 30 秒测一次延迟，自动走最快的可用落地；某个落地挂了自动避开，手机上不用切节点
- **换落地不换链接**：修改线路的落地、跳板、备用落地时，客户端链接不变，不用重新导入
- **订阅链接**：小火箭 / Clash 一次导入全部线路，加线路后客户端点「更新订阅」就同步
- **自动测试**：整条线路走一遍 + 每个落地单独直连测一遍，一眼看出是中转的问题还是落地的问题
- **独立安装**：自带一份 Xray（`xray-relay`），和本机的 [onekey](https://github.com/Aurivian11/onekey)、3x-ui 互不影响，可以装在同一台机器上
- **Xray 兼容版**：默认固定 v26.6.27，REALITY 对 Xray / sing-box / mihomo（Clash Meta）内核的客户端都能连

## 安装

用 root 登录**中转机**，运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aurivian11/relay/main/relay.sh)
```

以后输入 `relay` 打开菜单：

```
=========== Relay 中转一键脚本 v1.1.1 ===========
  1) 添加线路（粘贴落地 ss:// 链接或手动填写，可加跳板 / 备用落地）
  2) 查看线路（客户端链接 / 二维码 / Clash）
  3) 测试线路（整条线路 + 每个落地单独测）
  4) 修改线路（换落地 / 加备用落地 / 跳板，客户端链接不变）
  5) 删除线路
  6) 订阅链接（小火箭 / Clash 一次导入全部线路）
  7) 运行状态
  8) 开启 BBR
  9) 更新（脚本 / Xray 版本）
 10) 卸载
  0) 退出
```

## 最快的用法：配合 onekey

落地机用 [onekey](https://github.com/Aurivian11/onekey) 装好 SS 后，它会多输出一行：

```
在中转机上一键加线路（relay 中转脚本，github.com/Aurivian11/relay）：
  command -v relay >/dev/null || bash <(curl -Ls https://raw.githubusercontent.com/Aurivian11/relay/main/relay.sh) </dev/null; LAND='ss://...' relay add
```

把这一行复制到**中转机**上运行，就加好了一条 VLESS-REALITY 线路（中转机没装 relay 会先自动装上）。

## 在菜单里添加线路

1. 菜单 **1**，选「粘贴 ss:// 链接」，把落地的 SS 链接粘进去。
2. 「这个落地要经过跳板吗？」：直连直接回车；要两层就输入 `y`，再粘贴跳板的 SS 链接。
3. 「再加一个备用落地吗？」：不要就回车；要就输入 `y`，再填备用落地（同样可以带跳板），可以加多个。
4. 起个线路名称，选入口协议（回车 = VLESS-REALITY），端口回车随机。
5. 自动输出客户端链接、二维码、Clash 配置行，并测试：

```
  ✅ [3] 双落地      整条线路通    127 ms  出口 IP 154.x.x.x
       落地1：落地 154.x.x.x:44139  ✅ 78 ms  出口 154.x.x.x
       落地2：落地 187.x.x.x:15917  ❌ 不通（本机 TCP 连不上落地）
```

> **落地机的防火墙**：如果落地只允许指定 IP 连接，要放行中转机（两层时放行跳板）的 IP。

## 修改线路（菜单 4）

换掉某个落地 / 加备用落地 / 删掉某个落地 / 给某个落地加或换跳板 / 去掉跳板 / 改名。除了改名，其它修改客户端链接都不变。

## 订阅（菜单 6）

开启后显示 Clash 订阅地址（含 `clash://` 一键导入链接和二维码）和小火箭订阅二维码。之后加线路、改线路、删线路，订阅自动更新。订阅地址带 32 位随机密钥，等于全部线路的密码，泄露后在菜单 6 更换地址。

## 命令行

```bash
relay                       # 打开菜单
LAND='ss://...' relay add                                  # 一层，入口 VLESS-REALITY
LAND='ss://落地' HOP='ss://跳板' NAME=落地TW relay add      # 两层
LAND='ss://落地A ss://落地B' NAME=HK relay add             # 多个落地自动切换（空格隔开）
LAND='ss://...' IN=ss PORT=20000 relay add                 # 入口用 SS，指定端口
SNI_SET=www.microsoft.com LAND='ss://...' relay add        # 换 REALITY 伪装域名
relay list                  # 查看全部线路（链接 / Clash / 订阅）
relay test                  # 测试全部线路（relay test 2 只测第 2 条）
relay del 2                 # 删除第 2 条线路
relay sub                   # 开启订阅 / 查看订阅地址（sub reset 换地址，sub off 关闭）
relay status                # 运行状态
relay xray compat           # Xray 换成兼容版 v26.6.27（latest 最新版，或写版本号）
relay update                # 更新脚本（线路和客户端链接不变）
relay uninstall             # 卸载
```

## 支持的 ss:// 链接格式

| 格式 | 例子 |
|---|---|
| SIP002（base64） | `ss://YWVzLTI1Ni1nY206cGFzcw@1.2.3.4:8388#名称` |
| SIP002（明文，2022 加密常见） | `ss://2022-blake3-aes-128-gcm:base64密码%3D%3D@1.2.3.4:8388#名称` |
| 旧格式（整段 base64） | `ss://YWVzLTI1Ni1nY206cGFzc0AxLjIuMy40OjgzODg=#名称` |
| IPv6 / 域名落地 | `ss://...@[2001:db8::1]:8388`、`ss://...@hk.example.com:8388` |

链接后面带的 `?plugin=...` 会被忽略（不支持 SS 插件）。

## 工作原理

- 每条线路一个入口（`in-编号`），每个落地一个 SS 出站（`land-编号-序号`），路由按入口分流，互不影响。
- 两层时多一个跳板出站，落地出站用 `sockopt.dialerProxy` 经跳板连出去，和 3x-ui 里的「中转」做法一样。
- 多个落地时用 Xray 的 observatory 每 30 秒测一次各落地延迟，balancer 按 `leastPing` 选最快的可用落地；都不通时走第 1 个。
- 访问内网 / 保留地址的请求会被拦截，避免中转机的内网被访问。

## 实测（2026-11，Debian 13）

| 场景 | Xray 客户端 | mihomo 客户端 |
|---|---|---|
| 一层：我 → 中转（REALITY）→ 落地 SS | ✅ | ✅ |
| 两层：我 → 中转 → 跳板 SS → 落地 SS | ✅ | ✅ |
| 两个落地，断开其中一个 | ✅ 自动换到另一个；恢复后自动换回 | ✅ |
| 入口用 SS 2022 | ✅ | — |
| 1.0 版线路升级到 1.1 | ✅ 客户端链接不变 | — |

## 文件位置

| 路径 | 内容 |
|---|---|
| `/etc/relay/lines/` | 每条线路的参数（权限 600） |
| `/etc/relay/xray.json` | 生成的 Xray 配置 |
| `/etc/relay/www/` | 订阅文件 |
| `/usr/local/bin/relay` | 菜单命令 |
| `/usr/local/bin/xray-relay` | 本脚本自带的 Xray |
| `relay-xray` / `relay-sub` | 系统服务 |

## Xray 版本

relay 用自己单独的一份 Xray（`/usr/local/bin/xray-relay`），版本可以自己选：

| 选项 | 版本 | VLESS-REALITY 入口能连的客户端 |
|---|---|---|
| **兼容版（默认）** | 固定 v26.6.27 | Xray / sing-box / mihomo（Clash Meta）内核都能连 |
| 最新版 | 跟随 Xray 最新正式版 | 只有 Xray 内核客户端（如 v2rayN）；sing-box / mihomo 内核连不上 |
| 指定版本号 | 自己填，如 v26.3.27 | — |

- **菜单里第一次加线路**（本机还没装 relay 的 Xray）时会问选哪个，回车 = 兼容版。
- **一键命令**（`relay add`）全自动不提问，默认兼容版；要别的版本在前面加 `XRAY_VER=`：
  `XRAY_VER=latest LAND='ss://...' relay add`
- **以后换版本**：菜单 9（更新）里的 2 / 3 / 4，或 `relay xray compat|latest|v26.x.y`。换版本时先下载确认能运行才替换，失败自动换回，线路和客户端链接不变。

## 已知情况

- Xray 刚启动后的**第一次连接要等约 5 秒**，之后正常（Xray 自身的行为，onekey 也一样）。脚本测试时会自动重试，不会误报。

## 系统要求

Debian / Ubuntu（systemd）、Alpine（OpenRC）、CentOS 系；amd64、arm64；需要 root。已在 Debian 13 实测。

## 免责声明

本项目仅供学习和研究网络技术使用。请遵守你所在地区以及服务器所在地的法律法规，使用本脚本产生的一切后果由使用者自行承担。
