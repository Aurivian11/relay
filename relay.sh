#!/usr/bin/env bash
# =============================================================
#  Relay 中转一键脚本
#  在中转机上运行：粘贴落地的 ss:// 链接（或手动填地址 / 端口 / 加密 / 密码），
#  自动生成客户端连中转机用的节点。支持两层：
#    我 → 中转机 → 落地
#    我 → 中转机 → 跳板 → 落地（跳板也是 SS，例如 TW 落地经 HK 跳一下）
#  入口协议每条线路可选：VLESS-REALITY（默认）/ Shadowsocks
#  内核：Xray（独立安装，不影响本机的 onekey / 3x-ui）
#  系统：Debian / Ubuntu / Alpine（OpenRC）/ CentOS 系
# =============================================================
set -o pipefail

RELAY_VER="1.0.0"
SCRIPT_URL="${RELAY_URL:-https://raw.githubusercontent.com/Aurivian11/relay/main/relay.sh}"

BASE=/etc/relay
LINES=$BASE/lines          # 每条线路一个 .env
CONF=$BASE/xray.json
BIN=/usr/local/bin/xray-relay
CMD=/usr/local/bin/relay
SVC=relay-xray

DEF_SNI="www.amd.com"
XRAY_COMPAT=v26.6.27       # 新版 Xray 的 REALITY 与 sing-box / mihomo 客户端不兼容，默认固定这个版本

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }
die()    { red "错误：$*"; exit 1; }

NONINT=${NONINT:-0}
ask() {   # ask "提示" 默认值 -> 输出结果
  local prompt=$1 def=$2 ans
  if [[ $NONINT == 1 ]]; then echo "$def"; return; fi
  if [[ -n $def ]]; then read -r -p "$prompt [默认 $def]: " ans; else read -r -p "$prompt: " ans; fi
  echo "${ans:-$def}"
}

[[ $EUID -eq 0 ]] || die "请用 root 运行"

# ---------------- 环境 ----------------
detect_os() {
  if command -v apk >/dev/null 2>&1; then PKG=apk
  elif command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  else die "不支持的系统（找不到 apt/apk/dnf/yum）"; fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT=systemd
  elif command -v rc-service >/dev/null 2>&1; then INIT=openrc
  else die "需要 systemd 或 OpenRC"; fi
  case $(uname -m) in
    x86_64|amd64) ASSET=Xray-linux-64.zip ;;
    aarch64|arm64) ASSET=Xray-linux-arm64-v8a.zip ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}
install_deps() {
  local need=0 c
  for c in curl jq openssl qrencode unzip ss; do command -v $c >/dev/null 2>&1 || need=1; done
  [[ $need == 0 ]] && return
  yellow "安装依赖..."
  case $PKG in
    apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl qrencode unzip iproute2 ca-certificates >/dev/null ;;
    apk) apk add --no-cache bash curl jq openssl libqrencode-tools unzip iproute2 ca-certificates >/dev/null ;;
    dnf|yum) $PKG install -y -q epel-release >/dev/null 2>&1; $PKG install -y -q curl jq openssl qrencode unzip iproute >/dev/null ;;
  esac
  for c in curl jq openssl unzip; do command -v $c >/dev/null 2>&1 || die "依赖 $c 安装失败"; done
}
get_ip() {
  IP4=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ipv4.icanhazip.com 2>/dev/null)
  IP6=$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || curl -6 -fsS --max-time 6 https://ipv6.icanhazip.com 2>/dev/null)
  IP4=$(echo "$IP4" | tr -d '[:space:]'); IP6=$(echo "$IP6" | tr -d '[:space:]')
  [[ $IP6 == *:* ]] || IP6=""; [[ $IP4 == *.* ]] || IP4=""
  [[ -n $IP4 || -n $IP6 ]] || die "获取公网 IP 失败"
}
entry_hosts() { [[ -z $IP4$IP6 ]] && get_ip; echo "$IP4 $IP6"; }

port_used() { ss -Hlntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$1\$"; }
rand_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(( (RANDOM << 15 | RANDOM) % 50001 + 10000 ))
    port_used "$p" || grep -qs "IN_PORT='$p'" "$LINES"/*.env || { echo "$p"; return; }
  done
  echo 34568
}
open_port() {   # open_port 端口 tcp|udp|both
  local p=$1 t=$2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    [[ $t != udp ]] && ufw allow "$p"/tcp >/dev/null
    [[ $t != tcp ]] && ufw allow "$p"/udp >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    [[ $t != udp ]] && firewall-cmd -q --permanent --add-port="$p"/tcp
    [[ $t != tcp ]] && firewall-cmd -q --permanent --add-port="$p"/udp
    firewall-cmd -q --reload
  fi
}
uri() { jq -rn --arg s "$1" '$s|@uri'; }
urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
b64url() { printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'; }
b64dec() { local s=${1//-/+}; s=${s//_/\/}; while (( ${#s} % 4 )); do s+="="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
rand_pw() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-"${1:-24}"; }
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_x25519() {   # "私钥 公钥"（base64url）
  local k; k=$(openssl genpkey -algorithm X25519 2>/dev/null) || die "openssl 不支持 X25519"
  printf '%s %s\n' \
    "$(echo "$k" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')" \
    "$(echo "$k" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
}

# ---------------- 服务 ----------------
svc_write() {
  if [[ $INIT == systemd ]]; then
    cat >/etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=Relay Xray
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable $SVC >/dev/null 2>&1
  else
    cat >/etc/init.d/$SVC <<EOF
#!/sbin/openrc-run
name="$SVC"
command="$BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/$SVC.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/$SVC; rc-update add $SVC default >/dev/null 2>&1
  fi
}
svc() {   # svc start|stop|restart|status
  if [[ $INIT == systemd ]]; then
    case $1 in status) systemctl is-active $SVC 2>/dev/null ;; *) systemctl "$1" $SVC >/dev/null 2>&1 ;; esac
  else
    case $1 in status) rc-service $SVC status 2>/dev/null | grep -q started && echo active || echo inactive ;; *) rc-service $SVC "$1" >/dev/null 2>&1 ;; esac
  fi
}
svc_remove() {
  svc stop
  if [[ $INIT == systemd ]]; then systemctl disable $SVC >/dev/null 2>&1; rm -f /etc/systemd/system/$SVC.service; systemctl daemon-reload
  else rc-update del $SVC default >/dev/null 2>&1; rm -f /etc/init.d/$SVC; fi
}

# ---------------- Xray（独立一份，默认兼容版） ----------------
CORE_ENV=$BASE/core.env
XRAY_VER=${XRAY_VER:-}
[[ -z $XRAY_VER && -f $CORE_ENV ]] && . "$CORE_ENV"
XRAY_VER=${XRAY_VER:-compat}
save_core_env() { mkdir -p "$BASE"; printf "XRAY_VER='%s'\n" "$XRAY_VER" >"$CORE_ENV"; }
xray_tag() {
  case $XRAY_VER in
    compat) echo "$XRAY_COMPAT" ;;
    latest) curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name ;;
    *) echo "$XRAY_VER" ;;
  esac
}
xray_cur() { [[ -x $BIN ]] && "$BIN" version 2>/dev/null | awk 'NR==1{print "v"$2}'; }
install_xray() {   # install_xray [force]
  [[ -x $BIN && $1 != force ]] && return 0
  local tag tmp; tag=$(xray_tag); [[ $tag == v* ]] || { red "获取 Xray 版本失败"; return 1; }
  yellow "下载 Xray $tag..."
  tmp=$(mktemp -d)
  if ! curl -fsL -o "$tmp/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$tag/$ASSET" \
     || ! unzip -o -q "$tmp/x.zip" xray -d "$tmp" || ! "$tmp/xray" version >/dev/null 2>&1; then
    rm -rf "$tmp"; red "下载 Xray $tag 失败，原来的内核没动"; return 1
  fi
  install -m 755 "$tmp/xray" "$BIN"; rm -rf "$tmp"
  save_core_env; svc_write
  green "Xray $(xray_cur) 已安装"
}
set_xray_ver() {   # compat | latest | vX.Y.Z
  local v=$1 old=$XRAY_VER
  case $v in compat|latest) ;; v[0-9]*.*) ;; [0-9]*.*) v=v$v ;; *) red "版本格式不对：$1"; return 1 ;; esac
  [[ $v == "$XRAY_COMPAT" ]] && v=compat
  XRAY_VER=$v
  install_xray force || { XRAY_VER=$old; return 1; }
  if [[ -f $CONF ]]; then
    svc restart; sleep 1
    if [[ $(svc status) != active ]]; then
      red "Xray $(xray_cur) 启动失败，换回原来的版本"; XRAY_VER=$old; install_xray force && svc restart; return 1
    fi
  fi
  green "Xray 已换成 $(xray_cur)$([[ $XRAY_VER == compat ]] && echo "（兼容版）")"
}

# ---------------- SS 链接解析 ----------------
SS_METHODS="aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 chacha20-poly1305 xchacha20-ietf-poly1305 xchacha20-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
method_ok() { [[ " $SS_METHODS " == *" $1 "* ]]; }
parse_ss() {   # parse_ss 链接 -> 设置 P_HOST P_PORT P_METHOD P_PASS P_TAG；失败返回 1
  local l=$1 rest user hp dec
  l=$(echo "$l" | tr -d '[:space:]')
  [[ $l == ss://* ]] || { red "不是 ss:// 链接"; return 1; }
  rest=${l#ss://}
  P_TAG=""; [[ $rest == *#* ]] && { P_TAG=$(urldec "${rest#*#}"); rest=${rest%%#*}; }
  rest=${rest%%\?*}; rest=${rest%/}
  if [[ $rest == *@* ]]; then
    user=${rest%@*}; hp=${rest##*@}
    dec=$(urldec "$user")
    if [[ $dec == *:* ]]; then P_METHOD=${dec%%:*}; P_PASS=${dec#*:}     # SIP002 明文（2022 加密常见）
    else dec=$(b64dec "$user"); P_METHOD=${dec%%:*}; P_PASS=${dec#*:}; fi  # SIP002 base64
  else
    dec=$(b64dec "$rest")                                                  # 旧格式：整段 base64
    [[ $dec == *@* ]] || { red "链接解析失败"; return 1; }
    P_METHOD=${dec%%:*}; dec=${dec#*:}; P_PASS=${dec%@*}; hp=${dec##*@}
  fi
  if [[ $hp == \[* ]]; then P_HOST=${hp#[}; P_HOST=${P_HOST%%]*}; P_PORT=${hp##*]:}
  else P_HOST=${hp%:*}; P_PORT=${hp##*:}; fi
  P_METHOD=${P_METHOD,,}
  [[ -n $P_HOST && $P_PORT =~ ^[0-9]+$ && -n $P_PASS ]] || { red "链接解析失败（地址 / 端口 / 密码不完整）"; return 1; }
  method_ok "$P_METHOD" || { red "不支持的加密方式：$P_METHOD"; return 1; }
}
ask_ss() {   # ask_ss "落地"|"跳板" 前缀(LAND|HOP)：粘贴链接或手动填写 -> 设置 前缀_HOST 等
  local what=$1 pre=$2 c l
  while :; do
    echo
    echo "${what}的 SS 信息怎么填？"
    echo "  1) 粘贴 ss:// 链接"
    echo "  2) 手动填写地址 / 端口 / 加密 / 密码"
    c=$(ask "请选择" 1)
    if [[ $c == 2 ]]; then
      P_TAG=""
      P_HOST=$(ask "$what 地址（IP 或域名）" ""); P_HOST=${P_HOST#[}; P_HOST=${P_HOST%]}
      P_PORT=$(ask "$what 端口" "")
      echo "加密方式："
      local i=1 m arr=(aes-256-gcm aes-128-gcm chacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305)
      for m in "${arr[@]}"; do echo "  $i) $m"; i=$((i+1)); done
      c=$(ask "请选择" 1); [[ $c =~ ^[1-6]$ ]] || c=1; P_METHOD=${arr[$((c-1))]}
      P_PASS=$(ask "$what 密码" "")
      [[ -n $P_HOST && $P_PORT =~ ^[0-9]+$ && -n $P_PASS ]] || { red "地址 / 端口 / 密码不能为空"; continue; }
    else
      read -r -p "粘贴${what}的 ss:// 链接: " l || return 1
      parse_ss "$l" || continue
    fi
    echo "  地址 $P_HOST  端口 $P_PORT  加密 $P_METHOD  密码 ${P_PASS:0:4}****"
    reach "$P_HOST" "$P_PORT" || yellow "  注意：从本机 TCP 连不上 $(hp "$P_HOST" "$P_PORT")，检查地址端口或落地的防火墙（仍会保存）"
    printf -v "${pre}_HOST" '%s' "$P_HOST"; printf -v "${pre}_PORT" '%s' "$P_PORT"
    printf -v "${pre}_METHOD" '%s' "$P_METHOD"; printf -v "${pre}_PASS" '%s' "$P_PASS"
    return 0
  done
}
hp() { [[ $1 == *:* ]] && echo "[$1]:$2" || echo "$1:$2"; }   # 地址:端口（IPv6 加方括号）
reach() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# ---------------- 线路 ----------------
# 线路文件 $LINES/ID.env：NAME IN_TYPE IN_PORT (REALITY: UUID SNI PRIV PUB SID | SS: IN_METHOD IN_PASS)
#                        LAND_HOST LAND_PORT LAND_METHOD LAND_PASS  [HOP_HOST HOP_PORT HOP_METHOD HOP_PASS]
line_ids() { ls "$LINES"/*.env 2>/dev/null | sed 's#.*/##; s#\.env$##' | sort -n; }
next_id() { local m; m=$(line_ids | tail -1); echo $(( ${m:-0} + 1 )); }
save_line() {   # save_line ID KEY=VAL ...
  local f=$LINES/$1.env; shift
  mkdir -p "$LINES"; : >"$f"; chmod 600 "$f"
  local kv; for kv in "$@"; do printf "%s=%q\n" "${kv%%=*}" "${kv#*=}" >>"$f"; done
}
load_line() { NAME=""; IN_TYPE=""; HOP_HOST=""; HOP_PORT=""; HOP_METHOD=""; HOP_PASS=""; . "$LINES/$1.env"; }

ss_out() {   # ss_out tag host port method pass [dialerProxy]
  jq -nc --arg t "$1" --arg h "$2" --argjson p "$3" --arg m "$4" --arg pw "$5" --arg dp "${6:-}" \
    '{tag:$t,protocol:"shadowsocks",settings:{servers:[{address:$h,port:$p,method:$m,password:$pw}]}}
     + (if $dp == "" then {} else {streamSettings:{sockopt:{dialerProxy:$dp}}} end)'
}
in_json() {   # 当前已 load_line 的入口
  case $IN_TYPE in
    reality) jq -nc --arg t "in-$ID" --argjson p "$IN_PORT" --arg u "$UUID" --arg sni "$SNI" --arg pk "$PRIV" --arg sid "$SID" \
      '{tag:$t,listen:"::",port:$p,protocol:"vless",settings:{clients:[{id:$u,flow:"xtls-rprx-vision"}],decryption:"none"},
        streamSettings:{network:"tcp",security:"reality",
          realitySettings:{show:false,target:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$pk,shortIds:[$sid]}},
        sniffing:{enabled:false}}' ;;
    ss) jq -nc --arg t "in-$ID" --argjson p "$IN_PORT" --arg m "$IN_METHOD" --arg pw "$IN_PASS" \
      '{tag:$t,listen:"::",port:$p,protocol:"shadowsocks",settings:{method:$m,password:$pw,network:"tcp,udp"}}' ;;
  esac
}
listen_fix() { [[ -f /proc/net/if_inet6 ]] && cat || sed 's/"listen":"::"/"listen":"0.0.0.0"/g'; }

apply() {   # 按全部线路生成 Xray 配置并重启
  local ins=() outs=() rules=() ID
  for ID in $(line_ids); do
    load_line "$ID"
    ins+=("$(in_json)")
    if [[ -n $HOP_HOST ]]; then
      outs+=("$(ss_out "hop-$ID" "$HOP_HOST" "$HOP_PORT" "$HOP_METHOD" "$HOP_PASS")")
      outs+=("$(ss_out "land-$ID" "$LAND_HOST" "$LAND_PORT" "$LAND_METHOD" "$LAND_PASS" "hop-$ID")")
    else
      outs+=("$(ss_out "land-$ID" "$LAND_HOST" "$LAND_PORT" "$LAND_METHOD" "$LAND_PASS")")
    fi
    rules+=("$(jq -nc --arg i "in-$ID" --arg o "land-$ID" '{type:"field",inboundTag:[$i],outboundTag:$o}')")
  done
  if [[ ${#ins[@]} -eq 0 ]]; then svc stop; rm -f "$CONF"; return 0; fi
  install_xray || return 1
  local td; td=$(mktemp -d)
  jq -n --argjson i "$(printf '%s\n' "${ins[@]}" | jq -s .)" --argjson o "$(printf '%s\n' "${outs[@]}" | jq -s .)" \
        --argjson r "$(printf '%s\n' "${rules[@]}" | jq -s .)" \
    '{log:{loglevel:"warning"},inbounds:$i,
      outbounds:([{protocol:"blackhole",tag:"block"}] + $o),
      routing:{domainStrategy:"AsIs",rules:([{type:"field",outboundTag:"block",
        ip:["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","100.64.0.0/10","fc00::/7","fe80::/10","::1/128"]}] + $r)}}' \
    | listen_fix >"$td/xray.json"
  if ! "$BIN" run -test -c "$td/xray.json" >"$td/err" 2>&1; then
    red "Xray 配置检查失败："; tail -5 "$td/err"; rm -rf "$td"; return 1
  fi
  install -m 600 "$td/xray.json" "$CONF"; rm -rf "$td"
  svc restart; sleep 1
  [[ $(svc status) == active ]] || { red "Xray 启动失败，查看日志：journalctl -u $SVC -n 30"; return 1; }
}

# ---------------- 输出 ----------------
client_link() {   # client_link 主机（已 load_line）
  local h=$1 hb=$1 tag; [[ $h == *:* ]] && hb="[$h]"
  tag=$(uri "$NAME$([[ $h == *:* ]] && echo "-v6")")
  case $IN_TYPE in
    reality) echo "vless://$UUID@$hb:$IN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp&headerType=none#$tag" ;;
    ss) echo "ss://$(b64url "$IN_METHOD:$IN_PASS")@$hb:$IN_PORT#$tag" ;;
  esac
}
clash_line() {   # clash_line 主机
  local h=$1 n="$NAME$([[ $1 == *:* ]] && echo "-v6")"
  case $IN_TYPE in
    reality) echo "  - {name: \"$n\", type: vless, server: \"$h\", port: $IN_PORT, uuid: \"$UUID\", network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: \"$SNI\", client-fingerprint: chrome, reality-opts: {public-key: \"$PUB\", short-id: \"$SID\"}}" ;;
    ss) echo "  - {name: \"$n\", type: ss, server: \"$h\", port: $IN_PORT, cipher: $IN_METHOD, password: \"$IN_PASS\", udp: true}" ;;
  esac
}
route_text() {   # 已 load_line
  if [[ -n $HOP_HOST ]]; then echo "我 → 本机:$IN_PORT → 跳板 $(hp "$HOP_HOST" "$HOP_PORT") → 落地 $(hp "$LAND_HOST" "$LAND_PORT")"
  else echo "我 → 本机:$IN_PORT → 落地 $(hp "$LAND_HOST" "$LAND_PORT")"; fi
}
in_label() { [[ $IN_TYPE == reality ]] && echo "VLESS-REALITY" || echo "Shadowsocks ($IN_METHOD)"; }
show_line() {   # show_line ID
  local ID=$1 h
  load_line "$ID"
  echo; blue "========== [$ID] $NAME =========="
  echo "线路：$(route_text)"
  echo "入口：$(in_label)，端口 $IN_PORT"
  for h in $(entry_hosts); do client_link "$h"; done
  if [[ $NONINT != 1 ]] && command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 "$(client_link "$(entry_hosts | awk '{print $1}')")"; fi
  if [[ $IN_TYPE == ss ]]; then
    echo "手动填写：地址 $(entry_hosts | sed 's/ / 或 /')  端口 $IN_PORT  加密 $IN_METHOD  密码 $IN_PASS"
  fi
  echo "Clash（mihomo）："; for h in $(entry_hosts); do clash_line "$h"; done
}
list_lines() {
  local ids; ids=$(line_ids)
  [[ -n $ids ]] || { yellow "还没有线路，主菜单 1 添加"; return 1; }
  local ID; for ID in $ids; do show_line "$ID"; done
  echo
}
brief() {   # 一行一条的简表
  local ID; for ID in $(line_ids); do load_line "$ID"; echo "  [$ID] $NAME   $(in_label)   $(route_text)"; done
}
pick_line() {   # -> PICKED
  local ids; ids=$(line_ids); [[ -n $ids ]] || { yellow "还没有线路"; return 1; }
  brief
  local c; read -r -p "输入线路编号: " c || return 1
  [[ -f $LINES/$c.env ]] || { red "没有这条线路"; return 1; }
  PICKED=$c
}

# ---------------- 测试 ----------------
test_lines() {   # test_lines [ID...]：在本机用 Xray 客户端连自己的入口，看出口是不是落地
  local ids=("$@"); [[ ${#ids[@]} -eq 0 ]] && mapfile -t ids < <(line_ids)
  [[ ${#ids[@]} -gt 0 ]] || { yellow "还没有线路"; return 1; }
  [[ -f $CONF && $(svc status) == active ]] || { red "中转服务没有运行"; return 1; }
  local td ins=() outs=() rules=() ID port i=0; td=$(mktemp -d)
  for ID in "${ids[@]}"; do
    load_line "$ID"; port=$((15100 + i)); i=$((i+1))
    ins+=("$(jq -nc --arg t "t$ID" --argjson p $port '{tag:$t,listen:"127.0.0.1",port:$p,protocol:"socks",settings:{udp:true}}')")
    case $IN_TYPE in
      reality) outs+=("$(jq -nc --arg t "o$ID" --argjson p "$IN_PORT" --arg u "$UUID" --arg sni "$SNI" --arg pbk "$PUB" --arg sid "$SID" \
        '{tag:$t,protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$p,users:[{id:$u,flow:"xtls-rprx-vision",encryption:"none"}]}]},
          streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid}}}')") ;;
      ss) outs+=("$(ss_out "o$ID" 127.0.0.1 "$IN_PORT" "$IN_METHOD" "$IN_PASS")") ;;
    esac
    rules+=("$(jq -nc --arg i "t$ID" --arg o "o$ID" '{type:"field",inboundTag:[$i],outboundTag:$o}')")
  done
  jq -n --argjson i "$(printf '%s\n' "${ins[@]}" | jq -s .)" --argjson o "$(printf '%s\n' "${outs[@]}" | jq -s .)" \
        --argjson r "$(printf '%s\n' "${rules[@]}" | jq -s .)" \
    '{log:{loglevel:"error"},inbounds:$i,outbounds:$o,routing:{rules:$r}}' >"$td/c.json"
  "$BIN" run -c "$td/c.json" >"$td/log" 2>&1 & local pid=$!
  sleep 2
  echo
  i=0; local ok=0
  for ID in "${ids[@]}"; do
    load_line "$ID"; port=$((15100 + i)); i=$((i+1))
    local r ip
    r=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$port" -o /dev/null -w "%{http_code} %{time_total}" https://www.google.com/generate_204)
    ip=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$port" https://api64.ipify.org)
    if [[ ${r%% *} == 204 ]]; then
      ok=$((ok+1)); printf '  ✅ [%s] %-14s %5.0f ms  出口 IP %s\n' "$ID" "$NAME" "$(awk -v t="${r##* }" 'BEGIN{print t*1000}')" "$ip"
    else
      printf '  ❌ [%s] %-14s 不通\n' "$ID" "$NAME"
      reach "$LAND_HOST" "$LAND_PORT" || echo "       本机 TCP 连不上落地 $(hp "$LAND_HOST" "$LAND_PORT")"
      [[ -n $HOP_HOST ]] && { reach "$HOP_HOST" "$HOP_PORT" || echo "       本机 TCP 连不上跳板 $(hp "$HOP_HOST" "$HOP_PORT")"; }
      echo "       也可能是落地$([[ -n $HOP_HOST ]] && echo " / 跳板")的加密方式或密码填错了"
    fi
  done
  kill $pid 2>/dev/null; rm -rf "$td"
  echo "通过 $ok / ${#ids[@]}（出口 IP 应该是落地机的 IP）"
}

# ---------------- 添加 / 修改 / 删除 ----------------
ask_entry() {   # 入口协议、端口 -> IN_*（REALITY 还有 UUID SNI PRIV PUB SID）
  local c
  if [[ $NONINT == 1 ]]; then IN_TYPE=${IN:-reality}
  else
    echo
    echo "客户端连这台中转机用什么协议？"
    echo "  1) VLESS-REALITY（默认，最不容易被识别）"
    echo "  2) Shadowsocks"
    c=$(ask "请选择" 1); [[ $c == 2 ]] && IN_TYPE=ss || IN_TYPE=reality
  fi
  while :; do
    IN_PORT=$(ask "入口端口" "${PORT:-$(rand_port)}")
    [[ $IN_PORT =~ ^[0-9]+$ ]] && (( IN_PORT > 0 && IN_PORT < 65536 )) || { red "端口无效"; [[ $NONINT == 1 ]] && die "端口无效"; continue; }
    port_used "$IN_PORT" && { red "端口 $IN_PORT 已被占用"; [[ $NONINT == 1 ]] && die "端口被占用"; continue; }
    break
  done
  if [[ $IN_TYPE == reality ]]; then
    SNI=$(ask "伪装域名 (SNI)" "${SNI:-$DEF_SNI}")
    local kp; kp=$(gen_x25519); PRIV=${kp%% *}; PUB=${kp##* }; UUID=$(gen_uuid); SID=$(openssl rand -hex 8)
  else
    if [[ $NONINT == 1 ]]; then IN_METHOD=${IN_METHOD:-2022-blake3-aes-128-gcm}
    else
      echo "入口加密方式："
      echo "  1) 2022-blake3-aes-128-gcm（默认）"
      echo "  2) aes-256-gcm"
      echo "  3) chacha20-ietf-poly1305"
      case $(ask "请选择" 1) in 2) IN_METHOD=aes-256-gcm ;; 3) IN_METHOD=chacha20-ietf-poly1305 ;; *) IN_METHOD=2022-blake3-aes-128-gcm ;; esac
    fi
    if [[ $IN_METHOD == 2022-* ]]; then IN_PASS=$(openssl rand -base64 16); else IN_PASS=$(rand_pw 24); fi
  fi
}
line_kv() {   # 当前变量 -> save_line 参数
  local a=(NAME="$NAME" IN_TYPE="$IN_TYPE" IN_PORT="$IN_PORT")
  if [[ $IN_TYPE == reality ]]; then a+=(UUID="$UUID" SNI="$SNI" PRIV="$PRIV" PUB="$PUB" SID="$SID")
  else a+=(IN_METHOD="$IN_METHOD" IN_PASS="$IN_PASS"); fi
  a+=(LAND_HOST="$LAND_HOST" LAND_PORT="$LAND_PORT" LAND_METHOD="$LAND_METHOD" LAND_PASS="$LAND_PASS")
  [[ -n $HOP_HOST ]] && a+=(HOP_HOST="$HOP_HOST" HOP_PORT="$HOP_PORT" HOP_METHOD="$HOP_METHOD" HOP_PASS="$HOP_PASS")
  printf '%s\0' "${a[@]}"
}
add_line() {
  local ID; ID=$(next_id)
  HOP_HOST=""; HOP_PORT=""; HOP_METHOD=""; HOP_PASS=""
  if [[ $NONINT == 1 ]]; then   # 非交互：LAND=ss://... [HOP=ss://...] [IN=reality|ss] [PORT=] [NAME=]
    [[ -n ${LAND:-} ]] || die "需要 LAND=落地的 ss:// 链接"
    parse_ss "$LAND" || die "落地链接无效"
    LAND_HOST=$P_HOST; LAND_PORT=$P_PORT; LAND_METHOD=$P_METHOD; LAND_PASS=$P_PASS; local tag=$P_TAG
    if [[ -n ${HOP:-} ]]; then parse_ss "$HOP" || die "跳板链接无效"; HOP_HOST=$P_HOST; HOP_PORT=$P_PORT; HOP_METHOD=$P_METHOD; HOP_PASS=$P_PASS; fi
    NAME=${NAME:-${tag:-落地$ID}}
  else
    ask_ss "落地" LAND || return
    local tag=$P_TAG a
    echo
    read -r -p "要经过跳板吗？（我 → 本机 → 跳板 → 落地，比如落地只允许某台机器连）[y/N]: " a || a=n
    [[ $a == [yY] ]] && { ask_ss "跳板" HOP || return; }
    echo
    NAME=$(ask "线路名称（显示在客户端里）" "${tag:-落地$ID}")
  fi
  NAME=${NAME//[\"\'\\]/}
  ask_entry
  mapfile -d '' kv < <(line_kv)
  save_line "$ID" "${kv[@]}"
  open_port "$IN_PORT" both
  if ! apply; then rm -f "$LINES/$ID.env"; apply >/dev/null 2>&1; red "添加失败，已撤销"; return 1; fi
  green "线路 [$ID] $NAME 已添加"
  show_line "$ID"
  echo; yellow "测试这条线路..."; test_lines "$ID"
}
edit_line() {   # 换落地 / 跳板，入口（客户端链接）不变
  pick_line || return
  local ID=$PICKED c; load_line "$ID"
  echo "线路：$(route_text)"
  echo "  1) 换落地"
  echo "  2) 加上 / 换跳板"
  echo "  3) 去掉跳板（直连落地）"
  echo "  0) 返回"
  read -r -p "请选择 [0-3]: " c || return
  case $c in
    1) ask_ss "新落地" LAND || return ;;
    2) ask_ss "跳板" HOP || return ;;
    3) HOP_HOST="" ;;
    *) return ;;
  esac
  mapfile -d '' kv < <(line_kv)
  local bak; bak=$(cat "$LINES/$ID.env")
  save_line "$ID" "${kv[@]}"
  if ! apply; then printf '%s\n' "$bak" >"$LINES/$ID.env"; apply >/dev/null 2>&1; red "修改失败，已恢复"; return 1; fi
  load_line "$ID"; green "已修改：$(route_text)（客户端链接不变，不用重新导入）"
  test_lines "$ID"
}
del_line() {   # del_line [ID]
  local ID=$1
  if [[ -z $ID ]]; then pick_line || return; ID=$PICKED; fi
  [[ -f $LINES/$ID.env ]] || { red "没有线路 $ID"; return 1; }
  load_line "$ID"; local n=$NAME; rm -f "$LINES/$ID.env"; apply
  green "线路 [$ID] $n 已删除"
}

# ---------------- 其它 ----------------
status() {
  echo
  if [[ -f $CONF ]]; then
    [[ $(svc status) == active ]] && green "$SVC：运行中" || red "$SVC：未运行"
  else yellow "还没有线路"; fi
  [[ -x $BIN ]] && echo "Xray：$(xray_cur)$([[ $XRAY_VER == compat ]] && echo "（兼容版，REALITY 对 Xray / sing-box / mihomo 客户端都能连）")"
  echo "线路："; brief
  echo
}
enable_bbr() {
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then green "BBR 已开启"; return; fi
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-relay-bbr.conf
  sysctl -p /etc/sysctl.d/99-relay-bbr.conf >/dev/null 2>&1
  [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] && green "BBR 已开启" || red "BBR 开启失败（内核可能不支持）"
}
self_install() {
  [[ -x $CMD && $1 != force ]] && return
  if [[ -f $0 && $0 != /dev/fd/* && $0 != /proc/* ]]; then install -m 755 "$0" "$CMD"
  else curl -fsSL -o "$CMD" "$SCRIPT_URL" && chmod 755 "$CMD"; fi
  [[ -x $CMD ]] && green "快捷命令已安装：以后输入 relay 即可打开菜单"
}
self_update() {
  local tmp nv; tmp=$(mktemp)
  if ! curl -fsSL -o "$tmp" "$SCRIPT_URL" || ! bash -n "$tmp" 2>/dev/null || ! grep -q '^RELAY_VER=' "$tmp"; then
    rm -f "$tmp"; red "下载失败，没有更新"; return 1
  fi
  nv=$(grep -m1 '^RELAY_VER=' "$tmp" | cut -d'"' -f2)
  if [[ $nv == "$RELAY_VER" && $1 != force ]]; then rm -f "$tmp"; green "已经是最新版 v$RELAY_VER"; return 0; fi
  install -m 755 "$tmp" "$CMD"; rm -f "$tmp"; green "脚本已更新：v$RELAY_VER → v$nv（线路不变）"
}
update_menu() {
  echo
  echo "  1) 更新脚本（当前 v$RELAY_VER）"
  echo "  2) Xray 换成兼容版 $XRAY_COMPAT（推荐：REALITY 对所有内核客户端都能连）"
  echo "  3) Xray 换成最新版"
  echo "  4) Xray 指定版本号"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-4]: " c || return
  case $c in
    1) self_update && exec "$CMD" ;;
    2) set_xray_ver compat ;;
    3) set_xray_ver latest ;;
    4) local v; read -r -p "版本号（如 v26.6.27）：" v; [[ -n $v ]] && set_xray_ver "$v" ;;
  esac
}
uninstall_all() {
  if [[ $NONINT != 1 ]]; then
    local a; read -r -p "确定删除全部中转线路并卸载？[Y/n]: " a || return; [[ $a == [nN] ]] && return
  fi
  svc_remove; rm -rf "$BASE" "$BIN" "$CMD" /etc/sysctl.d/99-relay-bbr.conf
  green "中转脚本已全部卸载（本机的 onekey / 3x-ui 不受影响）"
}

main_menu() {
  while :; do
    echo
    blue "=========== Relay 中转一键脚本 v$RELAY_VER ==========="
    local n; n=$(line_ids | wc -l); echo "  当前 $n 条线路"
    echo "  1) 添加线路（粘贴落地 ss:// 链接或手动填写，可加跳板）"
    echo "  2) 查看线路（客户端链接 / 二维码 / Clash）"
    echo "  3) 测试线路（出口是不是落地 IP）"
    echo "  4) 修改线路（换落地 / 跳板，客户端链接不变）"
    echo "  5) 删除线路"
    echo "  6) 运行状态"
    echo "  7) 开启 BBR"
    echo "  8) 更新（脚本 / Xray 版本）"
    echo "  9) 卸载"
    echo "  0) 退出"
    echo
    local c; read -r -p "请选择 [0-9]: " c || { echo; exit 0; }
    case $c in
      1) add_line ;;
      2) list_lines ;;
      3) test_lines ;;
      4) edit_line ;;
      5) del_line ;;
      6) status ;;
      7) enable_bbr ;;
      8) update_menu ;;
      9) uninstall_all; exit 0 ;;
      0) exit 0 ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：relay                  打开菜单
      relay add              非交互添加：LAND='ss://落地' [HOP='ss://跳板'] [IN=reality|ss] [PORT=] [NAME=] [SNI=]
      relay list             查看全部线路
      relay test [编号]      测试线路
      relay del <编号>       删除线路
      relay status           运行状态
      relay xray [compat|latest|v26.6.27]  查看 / 切换 Xray 版本
      relay update           更新脚本
      relay uninstall        卸载
EOF
}

detect_os
mkdir -p "$BASE" "$LINES"; chmod 700 "$BASE"
case $1 in
  "") install_deps; self_install; main_menu ;;
  add) NONINT=1; install_deps; self_install; add_line ;;
  list) NONINT=1 list_lines ;;
  test) shift; test_lines "$@" ;;
  del|remove) del_line "$2" ;;
  status) status ;;
  xray) if [[ -n $2 ]]; then set_xray_ver "$2"; else echo "Xray：$( [[ -x $BIN ]] && xray_cur || echo 未安装)（设置：$XRAY_VER）"; fi ;;
  update) self_update "$2" ;;
  uninstall) NONINT=1 uninstall_all ;;
  -v|--version) echo "$RELAY_VER" ;;
  *) usage ;;
esac
