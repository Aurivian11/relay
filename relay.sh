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

RELAY_VER="1.1.0"
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
      local i=1 m arr=(2022-blake3-aes-128-gcm aes-256-gcm aes-128-gcm chacha20-ietf-poly1305 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305)
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
# 线路文件 $LINES/ID.env：
#   NAME IN_TYPE IN_PORT  (REALITY: UUID SNI PRIV PUB SID | SS: IN_METHOD IN_PASS)
#   LN=落地个数；第 k 个落地：Lk_HOST Lk_PORT Lk_METHOD Lk_PASS  [Lk_HOP_HOST Lk_HOP_PORT Lk_HOP_METHOD Lk_HOP_PASS]
#   多个落地时自动选延迟最低的可用落地，挂了自动切换
# 1.0 版的线路（LAND_* / HOP_*）读取时自动当成 1 个落地
line_ids() { ls "$LINES"/*.env 2>/dev/null | sed 's#.*/##; s#\.env$##' | sort -n; }
next_id() { local m; m=$(line_ids | tail -1); echo $(( ${m:-0} + 1 )); }
save_line() {   # save_line ID KEY=VAL ...
  local f=$LINES/$1.env; shift
  mkdir -p "$LINES"; : >"$f.tmp"; chmod 600 "$f.tmp"
  local kv; for kv in "$@"; do printf "%s=%q\n" "${kv%%=*}" "${kv#*=}" >>"$f.tmp"; done
  mv -f "$f.tmp" "$f"
}
gv() { echo "${!1}"; }
load_line() {   # -> NAME IN_* LN 和数组 LH LP LM LW（落地）HH HP HM HW（跳板，可为空）
  NAME=""; IN_TYPE=""; IN_PORT=""; UUID=""; SNI=""; PRIV=""; PUB=""; SID=""; IN_METHOD=""; IN_PASS=""
  LN=0; LAND_HOST=""; LAND_PORT=""; LAND_METHOD=""; LAND_PASS=""; HOP_HOST=""; HOP_PORT=""; HOP_METHOD=""; HOP_PASS=""
  LH=(); LP=(); LM=(); LW=(); HH=(); HP=(); HM=(); HW=()
  . "$LINES/$1.env"
  if [[ $LN == 0 && -n $LAND_HOST ]]; then   # 1.0 格式
    LN=1; LH[1]=$LAND_HOST; LP[1]=$LAND_PORT; LM[1]=$LAND_METHOD; LW[1]=$LAND_PASS
    HH[1]=$HOP_HOST; HP[1]=$HOP_PORT; HM[1]=$HOP_METHOD; HW[1]=$HOP_PASS
    return
  fi
  local k
  for ((k = 1; k <= LN; k++)); do
    LH[k]=$(gv "L${k}_HOST"); LP[k]=$(gv "L${k}_PORT"); LM[k]=$(gv "L${k}_METHOD"); LW[k]=$(gv "L${k}_PASS")
    HH[k]=$(gv "L${k}_HOP_HOST"); HP[k]=$(gv "L${k}_HOP_PORT"); HM[k]=$(gv "L${k}_HOP_METHOD"); HW[k]=$(gv "L${k}_HOP_PASS")
    unset "L${k}_HOST" "L${k}_PORT" "L${k}_METHOD" "L${k}_PASS" "L${k}_HOP_HOST" "L${k}_HOP_PORT" "L${k}_HOP_METHOD" "L${k}_HOP_PASS"
  done
}
line_kv() {   # 当前变量 -> save_line 参数（NUL 分隔）
  local a=(NAME="$NAME" IN_TYPE="$IN_TYPE" IN_PORT="$IN_PORT") k
  if [[ $IN_TYPE == reality ]]; then a+=(UUID="$UUID" SNI="$SNI" PRIV="$PRIV" PUB="$PUB" SID="$SID")
  else a+=(IN_METHOD="$IN_METHOD" IN_PASS="$IN_PASS"); fi
  a+=(LN="$LN")
  for ((k = 1; k <= LN; k++)); do
    a+=("L${k}_HOST=${LH[k]}" "L${k}_PORT=${LP[k]}" "L${k}_METHOD=${LM[k]}" "L${k}_PASS=${LW[k]}"
        "L${k}_HOP_HOST=${HH[k]}" "L${k}_HOP_PORT=${HP[k]}" "L${k}_HOP_METHOD=${HM[k]}" "L${k}_HOP_PASS=${HW[k]}")
  done
  printf '%s\0' "${a[@]}"
}
store_line() { local kv; mapfile -d '' kv < <(line_kv); save_line "$1" "${kv[@]}"; }

ss_out() {   # ss_out tag host port method pass [dialerProxy]
  jq -nc --arg t "$1" --arg h "$2" --argjson p "$3" --arg m "$4" --arg pw "$5" --arg dp "${6:-}" \
    '{tag:$t,protocol:"shadowsocks",settings:{servers:[{address:$h,port:$p,method:$m,password:$pw}]}}
     + (if $dp == "" then {} else {streamSettings:{sockopt:{dialerProxy:$dp}}} end)'
}
land_outs() {   # land_outs 前缀：当前线路全部落地（和跳板）的出站，tag = 前缀k / 前缀k-hop
  local k
  for ((k = 1; k <= LN; k++)); do
    if [[ -n ${HH[k]} ]]; then
      ss_out "$1$k-hop" "${HH[k]}" "${HP[k]}" "${HM[k]}" "${HW[k]}"
      ss_out "$1$k" "${LH[k]}" "${LP[k]}" "${LM[k]}" "${LW[k]}" "$1$k-hop"
    else
      ss_out "$1$k" "${LH[k]}" "${LP[k]}" "${LM[k]}" "${LW[k]}"
    fi
  done
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
jarr() { if [[ $# -eq 0 ]]; then echo '[]'; else printf '%s\n' "$@" | jq -s .; fi; }

apply() {   # 按全部线路生成 Xray 配置并重启
  local ins=() outs=() rules=() bals=() subj=() ID o
  for ID in $(line_ids); do
    load_line "$ID"
    ins+=("$(in_json)")
    while IFS= read -r o; do outs+=("$o"); done < <(land_outs "land-$ID-")
    if (( LN > 1 )); then   # 多个落地：observatory 测延迟，leastPing 自动选最快的可用落地
      bals+=("$(jq -nc --arg t "bal-$ID" --arg s "land-$ID-" --arg f "land-$ID-1" \
        '{tag:$t,selector:[$s],strategy:{type:"leastPing"},fallbackTag:$f}')")
      subj+=("\"land-$ID-\"")   # jarr 要的是 JSON，字符串要带引号
      rules+=("$(jq -nc --arg i "in-$ID" --arg b "bal-$ID" '{type:"field",inboundTag:[$i],balancerTag:$b}')")
    else
      rules+=("$(jq -nc --arg i "in-$ID" --arg o "land-$ID-1" '{type:"field",inboundTag:[$i],outboundTag:$o}')")
    fi
  done
  if [[ ${#ins[@]} -eq 0 ]]; then svc stop; rm -f "$CONF"; gen_sub; return 0; fi
  install_xray || return 1
  local td; td=$(mktemp -d)
  jq -n --argjson i "$(jarr "${ins[@]}")" --argjson o "$(jarr "${outs[@]}")" --argjson r "$(jarr "${rules[@]}")" \
        --argjson b "$(jarr "${bals[@]}")" --argjson s "$(jarr "${subj[@]}")" \
    '{log:{loglevel:"warning"},inbounds:$i,
      outbounds:([{protocol:"blackhole",tag:"block"}] + $o),
      routing:{domainStrategy:"AsIs",balancers:$b,rules:([{type:"field",outboundTag:"block",
        ip:["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","100.64.0.0/10","fc00::/7","fe80::/10","::1/128"]}] + $r)}}
     + (if ($s|length) == 0 then {} else
         {observatory:{subjectSelector:$s,probeUrl:"https://www.gstatic.com/generate_204",probeInterval:"30s",enableConcurrency:true}} end)' \
    | listen_fix >"$td/xray.json"
  if ! "$BIN" run -test -c "$td/xray.json" >"$td/err" 2>&1; then
    red "Xray 配置检查失败："; tail -5 "$td/err"; rm -rf "$td"; return 1
  fi
  install -m 600 "$td/xray.json" "$CONF"; rm -rf "$td"
  svc restart; sleep 1
  [[ $(svc status) == active ]] || { red "Xray 启动失败，查看日志：journalctl -u $SVC -n 30"; return 1; }
  gen_sub
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
land_text() {   # land_text k
  local k=$1
  if [[ -n ${HH[k]} ]]; then echo "跳板 $(hp "${HH[k]}" "${HP[k]}") → 落地 $(hp "${LH[k]}" "${LP[k]}")"
  else echo "落地 $(hp "${LH[k]}" "${LP[k]}")"; fi
}
route_text() {   # 已 load_line
  if (( LN <= 1 )); then echo "我 → 本机:$IN_PORT → $(land_text 1)"; return; fi
  echo "我 → 本机:$IN_PORT → $LN 个落地自动切换（选延迟最低的可用落地）："
  local k; for ((k = 1; k <= LN; k++)); do echo "      $k) $(land_text "$k")"; done
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
  sub_on && { echo; import_info; }
  echo
}
brief() {   # 简表
  local ID; for ID in $(line_ids); do load_line "$ID"; echo "  [$ID] $NAME   $(in_label)   $(route_text)"; done
}
pick_line() {   # -> PICKED
  local ids; ids=$(line_ids); [[ -n $ids ]] || { yellow "还没有线路"; return 1; }
  brief
  local c; read -r -p "输入线路编号: " c || return 1
  [[ -f $LINES/$c.env ]] || { red "没有这条线路"; return 1; }
  PICKED=$c
}
pick_land() {   # 已 load_line -> PK（只有 1 个落地时直接选它）
  if (( LN == 1 )); then PK=1; return 0; fi
  local k; for ((k = 1; k <= LN; k++)); do echo "  $k) $(land_text "$k")"; done
  read -r -p "选哪个落地: " PK || return 1
  [[ $PK =~ ^[0-9]+$ ]] && (( PK >= 1 && PK <= LN )) || { red "没有这个落地"; return 1; }
}

# ---------------- 测试 ----------------
curl_t() {   # curl_t socks端口 -> "状态码 秒 出口IP"
  # Xray 刚重启后第一次连接要多等几秒，第一次不通就再试一次，免得误报
  local r ip n
  for n in 1 2; do
    r=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$1" -o /dev/null -w "%{http_code} %{time_total}" https://www.google.com/generate_204)
    [[ ${r%% *} == 204 ]] && break
  done
  ip=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$1" https://api64.ipify.org)
  echo "$r ${ip:--}"
}
ms() { awk -v t="$1" 'BEGIN{printf "%.0f", t*1000}'; }
test_lines() {   # test_lines [ID...]：①从入口走一遍完整线路 ②每个落地单独直连测试
  local ids=("$@"); [[ ${#ids[@]} -eq 0 ]] && mapfile -t ids < <(line_ids)
  [[ ${#ids[@]} -gt 0 ]] || { yellow "还没有线路"; return 1; }
  [[ -f $CONF && $(svc status) == active ]] || { red "中转服务没有运行"; return 1; }
  local td ins=() outs=() rules=() ID k o port=15100; td=$(mktemp -d)
  declare -A EP LPORT
  for ID in "${ids[@]}"; do
    [[ -f $LINES/$ID.env ]] || { red "没有线路 $ID"; continue; }
    load_line "$ID"
    EP[$ID]=$port
    ins+=("$(jq -nc --arg t "t$ID" --argjson p $port '{tag:$t,listen:"127.0.0.1",port:$p,protocol:"socks",settings:{udp:true}}')")
    case $IN_TYPE in
      reality) outs+=("$(jq -nc --arg t "o$ID" --argjson p "$IN_PORT" --arg u "$UUID" --arg sni "$SNI" --arg pbk "$PUB" --arg sid "$SID" \
        '{tag:$t,protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$p,users:[{id:$u,flow:"xtls-rprx-vision",encryption:"none"}]}]},
          streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid}}}')") ;;
      ss) outs+=("$(ss_out "o$ID" 127.0.0.1 "$IN_PORT" "$IN_METHOD" "$IN_PASS")") ;;
    esac
    rules+=("$(jq -nc --arg i "t$ID" --arg o "o$ID" '{type:"field",inboundTag:[$i],outboundTag:$o}')")
    port=$((port + 1))
    # 每个落地（含跳板）单独一个出口，不经过中转入口，用来判断是落地的问题还是中转的问题
    while IFS= read -r o; do outs+=("$o"); done < <(land_outs "d$ID-")
    for ((k = 1; k <= LN; k++)); do
      LPORT[$ID-$k]=$port
      ins+=("$(jq -nc --arg t "t$ID-$k" --argjson p $port '{tag:$t,listen:"127.0.0.1",port:$p,protocol:"socks",settings:{udp:true}}')")
      rules+=("$(jq -nc --arg i "t$ID-$k" --arg o "d$ID-$k" '{type:"field",inboundTag:[$i],outboundTag:$o}')")
      port=$((port + 1))
    done
  done
  jq -n --argjson i "$(jarr "${ins[@]}")" --argjson o "$(jarr "${outs[@]}")" --argjson r "$(jarr "${rules[@]}")" \
    '{log:{loglevel:"error"},inbounds:$i,outbounds:$o,routing:{rules:$r}}' >"$td/c.json"
  "$BIN" run -c "$td/c.json" >"$td/log" 2>&1 & local pid=$!
  sleep 2
  echo
  local ok=0 total=0 r
  for ID in "${ids[@]}"; do
    [[ -n ${EP[$ID]} ]] || continue
    load_line "$ID"; total=$((total + 1))
    read -r -a r <<<"$(curl_t "${EP[$ID]}")"
    if [[ ${r[0]} == 204 ]]; then
      ok=$((ok + 1)); printf '  ✅ [%s] %-14s 整条线路通  %5s ms  出口 IP %s\n' "$ID" "$NAME" "$(ms "${r[1]}")" "${r[2]}"
    else
      printf '  ❌ [%s] %-14s 整条线路不通\n' "$ID" "$NAME"
    fi
    for ((k = 1; k <= LN; k++)); do
      read -r -a r <<<"$(curl_t "${LPORT[$ID-$k]}")"
      if [[ ${r[0]} == 204 ]]; then
        printf '       %s%s  ✅ %s ms  出口 %s\n' "$( ((LN > 1)) && echo "落地$k：")" "$(land_text "$k")" "$(ms "${r[1]}")" "${r[2]}"
      else
        printf '       %s%s  ❌ 不通' "$( ((LN > 1)) && echo "落地$k：")" "$(land_text "$k")"
        if [[ -n ${HH[k]} ]] && ! reach "${HH[k]}" "${HP[k]}"; then echo "（本机 TCP 连不上跳板）"
        elif [[ -z ${HH[k]} ]] && ! reach "${LH[k]}" "${LP[k]}"; then echo "（本机 TCP 连不上落地）"
        else echo "（端口能连上，多半是加密方式或密码不对）"; fi
      fi
    done
  done
  kill $pid 2>/dev/null; rm -rf "$td"
  echo "整条线路通过 $ok / $total（出口 IP 应该是落地机的 IP；多个落地时会自动避开不通的那个）"
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
    SNI=$(ask "伪装域名 (SNI)" "${SNI_SET:-$DEF_SNI}")
    local kp; kp=$(gen_x25519); PRIV=${kp%% *}; PUB=${kp##* }; UUID=$(gen_uuid); SID=$(openssl rand -hex 8)
  else
    if [[ $NONINT == 1 ]]; then IN_METHOD=${IN_METHOD_SET:-2022-blake3-aes-128-gcm}
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
ask_landing() {   # ask_landing k 标题：交互填第 k 个落地（可带跳板）
  local k=$1 a
  ask_ss "$2" LAND || return 1
  LH[k]=$LAND_HOST; LP[k]=$LAND_PORT; LM[k]=$LAND_METHOD; LW[k]=$LAND_PASS; LTAG=$P_TAG
  HH[k]=""; HP[k]=""; HM[k]=""; HW[k]=""
  read -r -p "这个落地要经过跳板吗？（我 → 本机 → 跳板 → 落地）[y/N]: " a || a=n
  if [[ $a == [yY] ]]; then
    ask_ss "跳板" HOP || return 1
    HH[k]=$HOP_HOST; HP[k]=$HOP_PORT; HM[k]=$HOP_METHOD; HW[k]=$HOP_PASS
  fi
}
add_line() {
  local ID tag="" a l; ID=$(next_id)
  LN=0; LH=(); LP=(); LM=(); LW=(); HH=(); HP=(); HM=(); HW=()
  if [[ $NONINT == 1 ]]; then   # 非交互：LAND='ss://落地1 ss://落地2' [HOP=ss://跳板（所有落地都经过它）] [IN=reality|ss] [PORT=] [NAME=]
    [[ -n ${LAND:-} ]] || die "需要 LAND=落地的 ss:// 链接（多个落地用空格隔开）"
    if [[ -n ${HOP:-} ]]; then parse_ss "$HOP" || die "跳板链接无效"; local hh=$P_HOST hpp=$P_PORT hm=$P_METHOD hw=$P_PASS; fi
    for l in $LAND; do
      parse_ss "$l" || die "落地链接无效：$l"
      LN=$((LN + 1)); LH[LN]=$P_HOST; LP[LN]=$P_PORT; LM[LN]=$P_METHOD; LW[LN]=$P_PASS
      [[ -z $tag ]] && tag=$P_TAG
      [[ -n ${HOP:-} ]] && { HH[LN]=$hh; HP[LN]=$hpp; HM[LN]=$hm; HW[LN]=$hw; }
    done
    NAME=${NAME:-${tag:-线路$ID}}
  else
    ask_landing 1 "落地" || return; LN=1; tag=$LTAG
    while :; do
      echo
      read -r -p "再加一个备用落地吗？（多个落地时自动选延迟最低的，挂了自动切换）[y/N]: " a || a=n
      [[ $a == [yY] ]] || break
      ask_landing $((LN + 1)) "备用落地 $LN" && LN=$((LN + 1))
    done
    echo
    NAME=$(ask "线路名称（显示在客户端里）" "${tag:-线路$ID}")
  fi
  NAME=${NAME//[\"\'\\]/}
  ask_entry
  store_line "$ID"
  open_port "$IN_PORT" both
  if ! apply; then rm -f "$LINES/$ID.env"; apply >/dev/null 2>&1; red "添加失败，已撤销"; return 1; fi
  green "线路 [$ID] $NAME 已添加"
  show_line "$ID"
  sub_on && yellow "订阅已自动更新，客户端点「更新订阅」就能看到新线路"
  echo; yellow "测试这条线路..."; test_lines "$ID"
}
edit_line() {   # 改落地 / 跳板，入口（客户端链接）不变
  pick_line || return
  local ID=$PICKED c k; load_line "$ID"
  echo "线路：$(route_text)"
  echo "  1) 换掉某个落地"
  echo "  2) 加一个备用落地（多个落地自动切换）"
  echo "  3) 删掉某个落地"
  echo "  4) 给某个落地加上 / 换跳板"
  echo "  5) 去掉某个落地的跳板"
  echo "  6) 改线路名称"
  echo "  0) 返回"
  read -r -p "请选择 [0-6]: " c || return
  case $c in
    1) pick_land || return; ask_ss "新落地" LAND || return
       LH[PK]=$LAND_HOST; LP[PK]=$LAND_PORT; LM[PK]=$LAND_METHOD; LW[PK]=$LAND_PASS ;;
    2) ask_landing $((LN + 1)) "备用落地 $LN" || return; LN=$((LN + 1)) ;;
    3) (( LN > 1 )) || { red "只有 1 个落地，不能删；要换落地选 1"; return 1; }
       pick_land || return
       for ((k = PK; k < LN; k++)); do
         LH[k]=${LH[k+1]}; LP[k]=${LP[k+1]}; LM[k]=${LM[k+1]}; LW[k]=${LW[k+1]}
         HH[k]=${HH[k+1]}; HP[k]=${HP[k+1]}; HM[k]=${HM[k+1]}; HW[k]=${HW[k+1]}
       done
       LN=$((LN - 1)) ;;
    4) pick_land || return; ask_ss "跳板" HOP || return
       HH[PK]=$HOP_HOST; HP[PK]=$HOP_PORT; HM[PK]=$HOP_METHOD; HW[PK]=$HOP_PASS ;;
    5) pick_land || return; HH[PK]=""; HP[PK]=""; HM[PK]=""; HW[PK]="" ;;
    6) local n; n=$(ask "新名称" "$NAME"); NAME=${n//[\"\'\\]/} ;;
    *) return ;;
  esac
  local bak; bak=$(cat "$LINES/$ID.env")
  store_line "$ID"
  if ! apply; then printf '%s\n' "$bak" >"$LINES/$ID.env"; apply >/dev/null 2>&1; red "修改失败，已恢复"; return 1; fi
  load_line "$ID"
  if [[ $c == 6 ]]; then green "已改名为 $NAME（客户端里的名称要重新导入或更新订阅才会变）"
  else green "已修改（客户端链接不变，不用重新导入）"; echo "线路：$(route_text)"; test_lines "$ID"; fi
}
del_line() {   # del_line [ID]
  local ID=$1
  if [[ -z $ID ]]; then pick_line || return; ID=$PICKED; fi
  [[ -f $LINES/$ID.env ]] || { red "没有线路 $ID"; return 1; }
  load_line "$ID"; local n=$NAME; rm -f "$LINES/$ID.env"; apply
  green "线路 [$ID] $n 已删除"
}

# ---------------- 订阅（小火箭 / Clash 一次导入全部线路） ----------------
SUB_ENV=$BASE/sub.env
WWW=$BASE/www
SUB_SVC=relay-sub
sub_on() { [[ -f $SUB_ENV ]]; }
httpd_cmd() {   # busybox httpd（Debian 在 busybox 里，Alpine 在 busybox-extras 里）
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then echo "$(command -v busybox) httpd"
  elif command -v busybox-extras >/dev/null 2>&1; then echo "$(command -v busybox-extras) httpd"; fi
}
sub_svc() {   # sub_svc write|restart|status|remove
  local port; port=$( . "$SUB_ENV" 2>/dev/null; echo "$PORT")
  if [[ $INIT == systemd ]]; then
    case $1 in
      write) cat >/etc/systemd/system/$SUB_SVC.service <<EOF
[Unit]
Description=Relay subscription
After=network-online.target

[Service]
ExecStart=$(httpd_cmd) -f -p $port -h $WWW
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
             systemctl daemon-reload; systemctl enable $SUB_SVC >/dev/null 2>&1 ;;
      restart) systemctl restart $SUB_SVC >/dev/null 2>&1 ;;
      status) systemctl is-active $SUB_SVC 2>/dev/null ;;
      remove) systemctl disable --now $SUB_SVC >/dev/null 2>&1; rm -f /etc/systemd/system/$SUB_SVC.service; systemctl daemon-reload ;;
    esac
  else
    local h; h=$(httpd_cmd)
    case $1 in
      write) cat >/etc/init.d/$SUB_SVC <<EOF
#!/sbin/openrc-run
name="$SUB_SVC"
command="${h%% *}"
command_args="${h#* } -f -p $port -h $WWW"
command_background=true
pidfile="/run/$SUB_SVC.pid"
depend() { need net; }
EOF
             chmod +x /etc/init.d/$SUB_SVC; rc-update add $SUB_SVC default >/dev/null 2>&1 ;;
      restart) rc-service $SUB_SVC restart >/dev/null 2>&1 ;;
      status) rc-service $SUB_SVC status 2>/dev/null | grep -q started && echo active || echo inactive ;;
      remove) rc-service $SUB_SVC stop >/dev/null 2>&1; rc-update del $SUB_SVC default >/dev/null 2>&1; rm -f /etc/init.d/$SUB_SVC ;;
    esac
  fi
}
gen_sub() {   # 按全部线路生成订阅文件（每次改线路后自动调用）
  sub_on || return 0
  local ID h links="" proxies="" names=()
  for ID in $(line_ids); do
    load_line "$ID"
    for h in $(entry_hosts); do
      links+="$(client_link "$h")"$'\n'
      proxies+="$(clash_line "$h")"$'\n'
      names+=("$NAME$([[ $h == *:* ]] && echo "-v6")")
    done
  done
  ( . "$SUB_ENV"
    mkdir -p "$WWW/$TOKEN"; rm -f "$WWW/$TOKEN"/*
    printf '%s' "$links" | base64 | tr -d '\n' >"$WWW/$TOKEN/sub"
    if [[ ${#names[@]} -gt 0 ]]; then
      local list; list=$(printf '"%s", ' "${names[@]}"); list=${list%, }
      cat >"$WWW/$TOKEN/clash.yaml" <<EOF
# Relay 生成的 Clash Meta / mihomo 配置
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
tcp-concurrent: true
geodata-mode: true
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
proxies:
${proxies%$'\n'}
proxy-groups:
  - {name: "节点选择", type: select, proxies: [$list, DIRECT]}
rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
EOF
    fi
    chmod -R go-rwx "$WWW" )
}
sub_url() {   # sub_url sub|clash.yaml
  ( . "$SUB_ENV"; local h; h=$(entry_hosts | awk '{print $1}'); [[ $h == *:* ]] && h="[$h]"; echo "http://$h:$PORT/$TOKEN/$1" )
}
qr() { [[ $NONINT != 1 ]] && command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$1"; }
import_info() {
  sub_on || return
  local cu su; cu=$(sub_url clash.yaml); su=$(sub_url sub)
  blue "【订阅 · Clash Verge / Clash Meta / mihomo】"
  echo "订阅地址：$cu"
  echo "一键导入：clash://install-config?url=$(uri "$cu")&name=relay"
  qr "$cu"
  blue "【订阅 · 小火箭 Shadowrocket / v2rayN】"
  echo "订阅地址：$su"
  qr "sub://$(printf '%s' "$su" | base64 | tr -d '\n')#relay"
  yellow "订阅地址等于全部线路的密码，不要公开；泄露后在订阅菜单里更换地址"
}
sub_enable() {
  if ! sub_on; then
    if [[ -z $(httpd_cmd) ]]; then
      case $PKG in apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq busybox >/dev/null ;; apk) apk add --no-cache busybox-extras >/dev/null ;; dnf|yum) $PKG install -y -q busybox >/dev/null ;; esac
    fi
    [[ -n $(httpd_cmd) ]] || { red "安装 busybox httpd 失败"; return 1; }
    printf "PORT='%s'\nTOKEN='%s'\n" "$(rand_port)" "$(openssl rand -hex 16)" >"$SUB_ENV"; chmod 600 "$SUB_ENV"
    mkdir -p "$WWW"
    open_port "$( . "$SUB_ENV"; echo "$PORT")" tcp
    sub_svc write
  fi
  gen_sub; sub_svc restart; sleep 1
  [[ $(sub_svc status) == active ]] || { red "订阅服务启动失败"; return 1; }
  green "订阅已开启（加线路 / 改线路后自动更新，客户端点「更新订阅」即可）"
  import_info
}
sub_reset() {
  sub_on || { yellow "订阅未开启"; return; }
  ( . "$SUB_ENV"; rm -rf "${WWW:?}/$TOKEN"; printf "PORT='%s'\nTOKEN='%s'\n" "$PORT" "$(openssl rand -hex 16)" >"$SUB_ENV" )
  gen_sub; green "已更换订阅地址，旧地址立即失效："; import_info
}
sub_disable() {
  sub_on || { yellow "订阅未开启"; return; }
  sub_svc remove; rm -rf "$WWW" "$SUB_ENV"; green "订阅已关闭"
}
sub_menu() {
  echo
  echo "订阅链接（小火箭 / Clash 一次导入全部线路）：$(sub_on && echo 已开启 || echo 未开启)"
  echo "  1) 开启 / 查看订阅地址和二维码"
  echo "  2) 更换订阅地址（旧地址失效）"
  echo "  3) 关闭订阅"
  echo "  0) 返回"
  local c; read -r -p "请选择 [0-3]: " c || return
  case $c in 1) sub_enable ;; 2) sub_reset ;; 3) sub_disable ;; esac
}

# ---------------- 其它 ----------------
status() {
  echo
  if [[ -f $CONF ]]; then
    [[ $(svc status) == active ]] && green "$SVC：运行中" || red "$SVC：未运行"
  else yellow "还没有线路"; fi
  sub_on && { [[ $(sub_svc status) == active ]] && green "$SUB_SVC（订阅）：运行中" || red "$SUB_SVC（订阅）：未运行"; }
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
  install -m 755 "$tmp" "$CMD"; rm -f "$tmp"
  "$CMD" migrate
  green "脚本已更新：v$RELAY_VER → v$nv（线路和客户端链接不变）"
}
migrate() {   # 新版第一次运行：把旧格式线路存成新格式、重新生成配置
  local ID; for ID in $(line_ids); do load_line "$ID"; store_line "$ID"; done
  [[ -n $(line_ids) ]] && apply >/dev/null 2>&1
  return 0
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
  svc_remove; sub_on && sub_svc remove
  rm -rf "$BASE" "$BIN" "$CMD" /etc/sysctl.d/99-relay-bbr.conf
  green "中转脚本已全部卸载（本机的 onekey / 3x-ui 不受影响）"
}

main_menu() {
  while :; do
    echo
    blue "=========== Relay 中转一键脚本 v$RELAY_VER ==========="
    local n; n=$(line_ids | wc -l); echo "  当前 $n 条线路$(sub_on && echo "，订阅已开启")"
    echo "  1) 添加线路（粘贴落地 ss:// 链接或手动填写，可加跳板 / 备用落地）"
    echo "  2) 查看线路（客户端链接 / 二维码 / Clash）"
    echo "  3) 测试线路（整条线路 + 每个落地单独测）"
    echo "  4) 修改线路（换落地 / 加备用落地 / 跳板，客户端链接不变）"
    echo "  5) 删除线路"
    echo "  6) 订阅链接（小火箭 / Clash 一次导入全部线路）"
    echo "  7) 运行状态"
    echo "  8) 开启 BBR"
    echo "  9) 更新（脚本 / Xray 版本）"
    echo " 10) 卸载"
    echo "  0) 退出"
    echo
    local c; read -r -p "请选择 [0-10]: " c || { echo; exit 0; }
    case $c in
      1) add_line ;;
      2) list_lines ;;
      3) test_lines ;;
      4) edit_line ;;
      5) del_line ;;
      6) sub_menu ;;
      7) status ;;
      8) enable_bbr ;;
      9) update_menu ;;
      10) uninstall_all; exit 0 ;;
      0) exit 0 ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：relay                  打开菜单
      relay add              非交互添加（参数用环境变量）：
                               LAND='ss://落地'                   一个落地
                               LAND='ss://落地1 ss://落地2'        多个落地，自动选最快的可用落地
                               HOP='ss://跳板'                    经跳板（所有落地都经过它）
                               IN=reality|ss  PORT=  NAME=  SNI_SET=  IN_METHOD_SET=
      relay list             查看全部线路
      relay test [编号]      测试线路（整条 + 每个落地单独测）
      relay del <编号>       删除线路
      relay sub [on|reset|off]  订阅：开启·查看 / 换地址 / 关闭
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
  sub) case $2 in reset) sub_reset ;; off) sub_disable ;; *) NONINT=1 sub_enable ;; esac ;;
  status) status ;;
  xray) if [[ -n $2 ]]; then set_xray_ver "$2"; else echo "Xray：$( [[ -x $BIN ]] && xray_cur || echo 未安装)（设置：$XRAY_VER）"; fi ;;
  update) self_update "$2" ;;
  migrate) migrate ;;
  uninstall) NONINT=1 uninstall_all ;;
  -v|--version) echo "$RELAY_VER" ;;
  *) usage ;;
esac
