# Relay · 中转一键脚本

在**中转机**上运行：粘贴落地的 `ss://` 链接（或手动填地址 / 端口 / 加密 / 密码），自动生成客户端连中转机用的节点。

```
一层：我 ──→ 中转机 ──→ 落地
两层：我 ──→ 中转机 ──→ 跳板 ──→ 落地      （例如 TW 落地经 HK 跳一下）
```

- **落地 / 跳板都用 Shadowsocks**：粘贴 `ss://` 链接自动识别，也可以手动填写；支持 aes-128/256-gcm、chacha20-ietf-poly1305、2022-blake3-* 等
- **入口协议每条线路可选**：VLESS-REALITY（默认，最不容易被识别）/ Shadowsocks
- **多条线路**：一台中转机接多个落地，每条线路一个入口端口，随时添加 / 修改 / 删除
- **换落地不换链接**：修改线路的落地或跳板时，客户端链接不变，不用重新导入
- **自动测试**：添加后在本机连一遍自己的入口，显示出口 IP（应该是落地的 IP）
- **独立安装**：自带一份 Xray（`xray-relay`），和本机的 [onekey](https://github.com/Aurivian11/onekey)、3x-ui 互不影响，可以装在同一台机器上
- **Xray 兼容版**：默认固定 v26.6.27，REALITY 对 Xray / sing-box / mihomo（Clash Meta）内核的客户端都能连

## 安装

用 root 登录**中转机**，运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Aurivian11/relay/main/relay.sh)
```

以后输入 `relay` 打开菜单：

```
=========== Relay 中转一键脚本 v1.0.0 ===========
  1) 添加线路（粘贴落地 ss:// 链接或手动填写，可加跳板）
  2) 查看线路（客户端链接 / 二维码 / Clash）
  3) 测试线路（出口是不是落地 IP）
  4) 修改线路（换落地 / 跳板，客户端链接不变）
  5) 删除线路
  6) 运行状态
  7) 开启 BBR
  8) 更新（脚本 / Xray 版本）
  9) 卸载
  0) 退出
```

## 添加一条线路

1. 菜单 **1**，选「粘贴 ss:// 链接」，把落地的 SS 链接粘进去（落地用 [onekey](https://github.com/Aurivian11/onekey) 搭的话，装 SS 时就会给出链接和明文参数）。
2. 问「要经过跳板吗？」：直连落地直接回车；要两层就输入 `y`，再粘贴跳板的 SS 链接。
3. 起个线路名称（显示在客户端里），选入口协议（回车 = VLESS-REALITY），端口回车随机。
4. 自动输出客户端链接、二维码和 Clash 配置行，并测试一遍：

```
  ✅ [1] 落地HK      132 ms  出口 IP 160.x.x.x
通过 1 / 1（出口 IP 应该是落地机的 IP）
```

> **落地机的防火墙**：如果落地只允许指定 IP 连接，要放行中转机（两层时放行跳板）的 IP。

## 命令行

```bash
relay                       # 打开菜单
relay add                   # 非交互添加，参数用环境变量：
LAND='ss://...' relay add                                  # 一层，入口 VLESS-REALITY
LAND='ss://落地' HOP='ss://跳板' NAME=落地TW relay add      # 两层
LAND='ss://...' IN=ss PORT=20000 relay add                 # 入口用 SS，指定端口
relay list                  # 查看全部线路（链接 / Clash）
relay test                  # 测试全部线路（relay test 2 只测第 2 条）
relay del 2                 # 删除第 2 条线路
relay status                # 运行状态
relay xray compat           # Xray 换成兼容版 v26.6.27（latest 最新版，或写版本号）
relay update                # 更新脚本
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

- 每条线路一个入口（`in-编号`）和一个 SS 出站（`land-编号`），路由按入口分流，互不影响。
- 两层时多一个跳板出站（`hop-编号`），落地出站用 `sockopt.dialerProxy` 经跳板连出去，和 3x-ui 里的「中转」做法一样。
- 访问内网 / 保留地址的请求会被拦截，避免中转机的内网被访问。

## 文件位置

| 路径 | 内容 |
|---|---|
| `/etc/relay/lines/` | 每条线路的参数（权限 600） |
| `/etc/relay/xray.json` | 生成的 Xray 配置 |
| `/usr/local/bin/relay` | 菜单命令 |
| `/usr/local/bin/xray-relay` | 本脚本自带的 Xray |
| `relay-xray` | 系统服务 |

## 系统要求

Debian / Ubuntu（systemd）、Alpine（OpenRC）、CentOS 系；amd64、arm64；需要 root。已在 Debian 13 实测。

## 免责声明

本项目仅供学习和研究网络技术使用。请遵守你所在地区以及服务器所在地的法律法规，使用本脚本产生的一切后果由使用者自行承担。
