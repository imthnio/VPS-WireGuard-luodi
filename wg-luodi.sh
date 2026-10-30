#!/bin/sh
# ============================================================
# wg-luodi：WireGuard 落地一键脚本（小白版）
#
# 它做什么：
#   你手里有一份 WireGuard 配置（落地机给你的）。在任何 VPS 上运行本脚本，
#   它只问两件事：① 把 WireGuard 配置粘贴进来；② 哪些端口要走 WireGuard。
#   之后全自动：监听在这些端口上的代理节点，出口 IP 变成 WireGuard 的 IP；
#   其它端口上的节点照旧用这台服务器自己的 IP。SSH 和服务器自己的网络完全不动。
#
# 用法（root 用户）：
#   安装：          sh wg-luodi.sh
#   更新：          装过的服务器再运行一次安装命令就自动更新（配置、端口都保留），或者 wg-luodi update
#   装好以后管理：  wg-luodi            （中文菜单）
#   命令行：        wg-luodi status | test | add-port 端口 | del-port 端口 | set-conf [文件]
#                   wg-luodi mode auto|kernel|userspace | reapply | update | uninstall
#
# 无人值守（不提问，全部用环境变量）：
#   WG_CONF_FILE=/root/wg.conf WG_PORTS="45192 50000" WG_MODE=auto sh wg-luodi.sh
#   WG_MODE=userspace 表示强制“无网卡模式”（不需要 TUN、不需要内核模块）。
#
# ---------------- 名词小词典（看不懂下面的注释先看这里） ----------------
# WireGuard：一种 VPN。你的配置文件里有 [Interface]（你这一端）和 [Peer]（对面落地机）。
# 落地 / 出口 IP：网站看到的“你是谁”的那个 IP。走 WireGuard 的节点，出口 IP 就是落地机的 IP。
# 节点：手机/电脑客户端连的那个“入口”，由 Xray、sing-box 或 Hysteria2 程序提供，每个节点占一个端口。
# 入站 / 出站：节点程序里，“客户端连进来”的那一头叫入站，“替你去访问网站”的那一头叫出站。
#       本脚本做的事情就是：给指定端口的入站，换一个“走 WireGuard”的出站。
# 母鸡 / 小鸡：母鸡是独立服务器或宿主机；小鸡是从母鸡分出来的 VPS（KVM、OpenVZ、LXC、NAT 小鸡等）。
# KVM / OpenVZ / LXC：小鸡的几种虚拟化方式。KVM 有自己的内核，什么都能装；
#       OpenVZ、LXC 和母鸡共用内核，通常不能加载 WireGuard 内核模块，也常常没有 TUN。
# 内核模块：Linux 内核的“插件”。有 wireguard 模块，就能建一张真正的 WireGuard 网卡。
# TUN：一种“虚拟网卡”设备（/dev/net/tun）。本脚本两种模式都不需要它，这里只是顺便检测给你看。
# 内核网卡模式（kernel）：用内核模块建一张叫 wg-luodi 的 WireGuard 网卡，速度最快。
#       网卡建好后不改服务器的默认路由（Table = off），只有打了专用标记的流量才走它。
# 无网卡模式（userspace）：WireGuard 完全在一个普通程序（sing-box）里跑，不建网卡、
#       不要 TUN、不要内核模块，OpenVZ / LXC / NAT 小鸡都能用。速度略慢一点。
# 网关：本脚本在本机 127.0.0.1 上开的一个 SOCKS5 入口（只有本机能连，外面连不上）。
#       节点把要走 WireGuard 的流量交给它，它再从 WireGuard 发出去。
# SOCKS5：一种很通用的本地代理协议，Xray、sing-box、Hysteria2 都能把流量转给它。
# 策略路由 / fwmark：Linux 可以给数据包打一个数字标记（fwmark），再按标记查另一张路由表。
#       内核网卡模式下，只有网关程序发出的、带标记的包才走 WireGuard 网卡。
# DNS 泄露：网站名字（域名）换成 IP 的查询如果从服务器本地发出，就会暴露服务器。
#       本脚本让走 WireGuard 的节点连域名解析也走 WireGuard。
# 握手（handshake）：WireGuard 两端“对暗号”。最近两三分钟内有握手，说明隧道是通的。
# Endpoint：落地机的地址和端口；AllowedIPs：哪些目标走隧道，必须包含 0.0.0.0/0 才能当落地用。
# PrivateKey / PublicKey：WireGuard 的钥匙。私钥只存在本机 /etc/wg-luodi/wg.conf（权限 600），
#       脚本里不写死任何钥匙，全部在运行时由你粘贴。
# systemd / OpenRC：Linux 管后台程序、让它开机自启的系统。Debian/Ubuntu/CentOS 用 systemd，
#       Alpine 用 OpenRC。本脚本两种都支持，重启服务器后自动恢复。
# musl / glibc：Linux 程序依赖的两种“基础库”。Alpine 用 musl，Debian/Ubuntu/CentOS 用 glibc。
#       用错了程序会报 not found 跑不起来，所以 Alpine 上下载 sing-box 的 -musl 版（静态编译，哪里都能跑）。
# 更新：换上新版脚本和新版 sing-box，重新生成网关配置；你的 WireGuard 配置和端口原样保留。
# 巡检：每 2 分钟自动检查一次的小任务。别的脚本重建了节点、或者路由规则被清掉，它会自动补回去。
# 终端 / /dev/tty：你打字的那个窗口。脚本提问时总是从这里读你的回答，
#       就算是用 curl … | sh 这种“管道”方式运行（这时普通输入是脚本内容，不是键盘）也一样。
# 终端设置（stty）：终端怎么处理回车、要不要显示你打的字。个别程序会把它改乱，
#       之后按回车没反应。本脚本每次提问前都会先把终端设置恢复正常。
# IPv4 / IPv6：两种 IP 地址。IPv4 像 23.94.180.2，IPv6 像 2001:470::1。
#       双栈：服务器两种都有。节点程序监听 [::] 时，IPv4 和 IPv6 的客户端都能连进来。
# 内网 IPv6（ULA，fd 开头）：只在服务商内部用的 IPv6，比如 fd66::5。外面的人连不到它，
#       要靠服务商把外网 IPv6 “转发”进来（NAT66）。NAT 小鸡常见这种情况。
# 入口 IP 和出口 IP 是两回事：客户端填服务器的 IPv4 还是 IPv6，只决定“从哪个门进来”；
#       进来以后，走 WireGuard 的端口一律从 WireGuard 出去，回给客户端的包照旧走服务器自己的网络。
# 只听 IPv4 的节点：配置里写 0.0.0.0 的 Hysteria2（还有个别 sing-box）只收 IPv4，客户端填 IPv6 就连不上。
#       本脚本发现走 WireGuard 的端口是这种情况、而服务器又能用 IPv6 时，会自动把它改成双栈
#       （Hysteria2 写 :端口，Xray / sing-box 写 ::），改之前先备份，节点起不来就换回原样。
# ============================================================

# shellcheck disable=SC1111,SC2046
# （注释和提示里的中文引号是故意的；有几处 set -- $(...) 就是要按空格拆开）

# 精简系统的 PATH 有时不全，先补齐（补在后面，不打乱你原来的顺序）。
PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
# 本脚本写出的文件默认只有 root 能读（里面有钥匙）。
umask 077

WGL_VERSION="1.1.19"

# ---------- 1. 文件放在哪里 ----------
# 所有路径都能用同名环境变量改（测试时用），正常使用不用管。
WGL_DIR=${WGL_DIR:-/etc/wg-luodi}                 # 配置、状态、备份
WGL_LIB=${WGL_LIB:-/usr/local/lib/wg-luodi}       # sing-box 网关程序、jq
WGL_CMD=${WGL_CMD:-/usr/local/bin/wg-luodi}       # 管理命令
WGL_SD=${WGL_SD:-/etc/systemd/system}             # systemd 服务文件
WGL_INITD=${WGL_INITD:-/etc/init.d}               # OpenRC 服务脚本
WGL_WGDIR=${WGL_WGDIR:-/etc/wireguard}            # wg setconf 的临时配置放这里（Ubuntu 的 AppArmor 只许 wg 读这个目录）
XN_NODES=${XN_NODES:-/etc/xray-node/nodes}        # VPS-dajianjiedian 的节点目录
XN_BIN_DIR=${XN_BIN_DIR:-/usr/local/bin}          # VPS-dajianjiedian 装 xray / sing-box / hysteria 的位置
WGL_IFACE=${WGL_IFACE:-wg-luodi}                  # 内核网卡模式的网卡名
WGL_MARK=${WGL_MARK:-51888}                       # 内核网卡模式的包标记
WGL_TABLE=${WGL_TABLE:-51888}                     # 内核网卡模式的专用路由表
WGL_PREF=${WGL_PREF:-5188}                        # 专用路由规则的优先级
WGL_EPMARK=${WGL_EPMARK:-51889}                   # WireGuard 自己连落地机的包的标记（首选）
WGL_EPPREF=${WGL_EPPREF:-5189}                    # “这种包走服务器自己的网卡”规则的优先级
WGL_L2TP_DIR=${WGL_L2TP_DIR:-/etc/l2tp-vless}      # L2TP-VPS 装好后的目录（用来认出它，见 _ep_cands）
WGL_TRACE_URL=${WGL_TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}                     # 试路：很小的一个网页
WGL_PROBE_URL=${WGL_PROBE_URL:-https://speed.cloudflare.com/__down?bytes=2000000}  # 试路：2MB，看大包能不能过
WGL_SPEED_URL=${WGL_SPEED_URL:-https://speed.cloudflare.com/__down?bytes=25000000} # 测速：25MB
WGL_WAIT=${WGL_WAIT:-25}                          # 等网关启动最多几秒
WGL_RAW_URL=${WGL_RAW_URL:-https://raw.githubusercontent.com/imthnio/VPS-WireGuard-luodi/main/wg-luodi.sh}
GH_MIRRORS=${GH_MIRRORS:-"https://v6.gh-proxy.org/ https://gh.llkk.cc/ https://ghproxy.net/"}
SB_FALLBACK_VER="1.14.2"

STATE="$WGL_DIR/state"
CONF="$WGL_DIR/wg.conf"
GW_JSON="$WGL_DIR/gw.json"
REG="$WGL_DIR/patched"
SB="$WGL_LIB/sing-box"
JQ=jq

# ---------- 2. 打印小工具 ----------
# info 绿色 [OK]、warn 黄色 [注意]、err 红色 [出错]；die 打印错误后结束脚本。
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi
QUIET=0
info() { [ "$QUIET" = 1 ] || printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn() { [ "$QUIET" = 1 ] || printf "${YELLOW}[注意]${NC} %s\n" "$1"; }
err()  { printf "${RED}[出错]${NC} %s\n" "$1" >&2; }
step() { [ "$QUIET" = 1 ] || printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"; }
say()  { [ "$QUIET" = 1 ] || printf "%s\n" "$1"; }
die()  { err "$1"; _unlock; exit 1; }
_has() { command -v "$1" >/dev/null 2>&1; }

# 写一行日志到 /etc/wg-luodi/log，只留最近 300 行，方便出问题时看。
log() {
  [ -d "$WGL_DIR" ] || return 0
  printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$1" >> "$WGL_DIR/log" 2>/dev/null
  if [ "$(wc -l < "$WGL_DIR/log" 2>/dev/null)" -gt 400 ] 2>/dev/null; then
    tail -n 300 "$WGL_DIR/log" > "$WGL_DIR/log.tmp" 2>/dev/null && mv -f "$WGL_DIR/log.tmp" "$WGL_DIR/log"
  fi
}

# 给耗时命令加上限时，防止网络卡住时整个脚本不动。
_to() { # _to <秒> 命令…
  _to_s="$1"; shift
  if _has timeout; then timeout "$_to_s" "$@"; else "$@"; fi
}

# ---------- 3. 提问小工具 ----------
# 键盘输入一律从终端读：用 curl … | sh 运行时，普通输入是脚本本身，不是键盘，
# 这时改从 /dev/tty（你打字的窗口）一行一行地读（TTY_IN 记着从哪里读，空 = 普通输入就是键盘）。
# 开始时记下终端原来的设置；每次提问前恢复一下，防止被别的程序改乱后“按回车没反应”。
TTY_IN=""; _TTY_SAVED=""
tty_init() {
  if [ ! -t 0 ] && (: < /dev/tty) 2>/dev/null; then TTY_IN=/dev/tty; fi
  _has stty && _can_ask && _TTY_SAVED=$(_stty -g 2>/dev/null)
  return 0
}
_can_ask() { [ -t 0 ] || [ -n "$TTY_IN" ]; }   # 能不能向你提问（有没有键盘可读）
_stty() { if [ -n "$TTY_IN" ]; then stty "$@" < "$TTY_IN"; else stty "$@"; fi; }
_readline() { # _readline <变量名>：从键盘读一行
  if [ -n "$TTY_IN" ]; then IFS= read -r "$1" < "$TTY_IN"; else IFS= read -r "$1"; fi
}
tty_fix() {
  _has stty && _can_ask || return 0
  if [ -n "$_TTY_SAVED" ]; then _stty "$_TTY_SAVED" 2>/dev/null || _stty sane 2>/dev/null; fi
  # 不管原来怎样，回车要能换行、要能看到自己打的字、要按行读
  _stty icrnl icanon echo 2>/dev/null
  return 0
}

# 一次只问一个问题。直接回车就用方括号里的推荐值。回答存到变量 ANS。
ask() { # ask "问题" "默认值"
  tty_fix
  if [ -n "$2" ]; then printf "%s [直接回车 = %s]: " "$1" "$2"; else printf "%s: " "$1"; fi
  if ! _readline ANS; then
    printf "\n"
    die "没有读到你的回答，已停止。请重新运行脚本。"
  fi
  ANS=$(printf '%s' "$ANS" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -z "$ANS" ] && ANS="$2"
  return 0
}

# 随机字符串（字母数字），用来生成本机网关的用户名和密码。
rand_str() { # rand_str <长度>
  _rs=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$1")
  [ "${#_rs}" -eq "$1" ] || _rs=$(od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n' | head -c "$1")
  printf '%s' "$_rs"
}

# ---------- 4. 状态文件 ----------
# /etc/wg-luodi/state 一行一个“名字=值”，记着模式、端口、网关端口等。
st_get() { # st_get <名字>
  [ -f "$STATE" ] || return 0
  sed -n "s/^$1=//p" "$STATE" | head -n 1
}
st_set() { # st_set <名字> <值>（值里只允许字母数字和 . : / _ - 空格）
  case "$2" in *[!A-Za-z0-9.:/_\ -]*) die "内部错误：状态值不合法：$1" ;; esac
  mkdir -p "$WGL_DIR" && chmod 700 "$WGL_DIR"
  _sf="$STATE.tmp.$$"
  { [ -f "$STATE" ] && grep -v "^$1=" "$STATE"; printf '%s=%s\n' "$1" "$2"; } > "$_sf" && mv -f "$_sf" "$STATE"
  chmod 600 "$STATE"
}
installed() { [ -f "$STATE" ] && [ -f "$CONF" ]; }

# ---------- 5. 加锁 ----------
# 巡检、节点启动时的钩子、你手动操作可能同时发生，同一时间只让一个去改节点配置。
_LOCKED=0
_lock() { # _lock <最多等几秒>
  _lw=${1:-30}
  mkdir -p "$WGL_DIR" 2>/dev/null
  while ! mkdir "$WGL_DIR/.lock" 2>/dev/null; do
    _lp=$(cat "$WGL_DIR/.lock/pid" 2>/dev/null)
    if [ -n "$_lp" ] && ! kill -0 "$_lp" 2>/dev/null; then
      rm -rf "$WGL_DIR/.lock"; continue
    fi
    [ "$_lw" -le 0 ] && return 1
    _lw=$((_lw - 1)); sleep 1
  done
  echo $$ > "$WGL_DIR/.lock/pid"
  _LOCKED=1
}
_unlock() { [ "$_LOCKED" = 1 ] && rm -rf "$WGL_DIR/.lock"; _LOCKED=0; return 0; }

# ---------- 6. 看看这是一台什么机器 ----------
# 系统（Debian/Ubuntu/CentOS/Alpine…）、开机自启系统（systemd/OpenRC）、虚拟化（母鸡/KVM/OpenVZ/LXC…）、
# 有没有 TUN、有没有 WireGuard 内核模块、有没有 IPv4/IPv6 出口。
detect_os() {
  OS_NAME="未知系统"
  if [ -r /etc/os-release ]; then
    OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"' | head -n 1)
  fi
  PKG=""
  if _has apk; then PKG=apk
  elif _has apt-get; then PKG=apt
  elif _has dnf; then PKG=dnf
  elif _has yum; then PKG=yum
  elif _has pacman; then PKG=pacman
  elif _has zypper; then PKG=zypper
  fi
}

detect_init() {
  if [ -n "$WGL_INIT" ]; then INIT="$WGL_INIT"; return; fi
  if [ -d /run/systemd/system ] && _has systemctl; then INIT=systemd
  elif _has rc-service || [ -x /sbin/openrc-run ]; then INIT=openrc
  else INIT=none
  fi
}

# Alpine 系统却跑着别家的内核（比如 6.12.x+deb13-cloud）：说明是和母鸡共用内核的容器小鸡。
# Alpine 自己的内核名字里都带 -virt / -lts / -edge / -rpi。
_alpine_foreign_kernel() {
  [ -f /etc/alpine-release ] || return 1
  case "$(uname -r)" in *-virt|*-lts|*-edge|*-rpi*|*-virt-*|*-lts-*) return 1 ;; esac
  return 0
}

# 机器类型：母鸡 / KVM / OpenVZ / LXC 等。容器的判断放在前面，因为容器里看到的硬件信息是母鸡的。
detect_virt() {
  VIRT=""
  if _has systemd-detect-virt; then
    VIRT=$(systemd-detect-virt 2>/dev/null)
    if [ "$VIRT" = none ] || [ -z "$VIRT" ]; then
      _c=$(systemd-detect-virt -c 2>/dev/null); [ -n "$_c" ] && [ "$_c" != none ] && VIRT="$_c"
    fi
  fi
  if [ -z "$VIRT" ] || [ "$VIRT" = none ]; then
    if [ -e /proc/user_beancounters ] || [ -d /proc/vz ] && [ ! -d /proc/bc ]; then VIRT=openvz
    elif tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container=lxc'; then VIRT=lxc
    elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then VIRT=lxc
    elif [ -f /.dockerenv ]; then VIRT=docker
    elif grep -q '/lxc/' /proc/1/cgroup 2>/dev/null; then VIRT=lxc
    elif grep -q 'lxcfs' /proc/mounts 2>/dev/null || [ -e /dev/.lxc-boot-id ] || [ -e /dev/.lxc ]; then VIRT=lxc
    elif [ -s /run/systemd/container ]; then VIRT=$(head -n 1 /run/systemd/container | tr -d ' \r')
    elif _alpine_foreign_kernel; then VIRT=lxc
    elif grep -qi 'kvm\|qemu' /sys/class/dmi/id/product_name 2>/dev/null || grep -qi 'kvm\|qemu' /sys/class/dmi/id/sys_vendor 2>/dev/null; then VIRT=kvm
    elif grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then VIRT=vm
    elif [ -z "$VIRT" ]; then VIRT=none
    fi
  fi
  case "$VIRT" in
    none) VIRT_CN="独立服务器 / 母鸡（没检测到虚拟化）" ;;
    kvm|qemu) VIRT_CN="KVM 小鸡" ;;
    openvz) VIRT_CN="OpenVZ 小鸡（和母鸡共用内核）" ;;
    lxc|lxc-libvirt) VIRT_CN="LXC 小鸡（和母鸡共用内核）" ;;
    docker|podman) VIRT_CN="Docker 容器" ;;
    microsoft) VIRT_CN="Hyper-V 小鸡" ;;
    vmware) VIRT_CN="VMware 小鸡" ;;
    xen) VIRT_CN="Xen 小鸡" ;;
    *) VIRT_CN="虚拟机（$VIRT）" ;;
  esac
}

detect_net() {
  HAS_TUN=0; [ -c /dev/net/tun ] && HAS_TUN=1
  HAS_KMOD=0
  if [ -d /sys/module/wireguard ]; then HAS_KMOD=1
  elif [ -f "/lib/modules/$(uname -r 2>/dev/null)/modules.dep" ] && grep -q 'wireguard' "/lib/modules/$(uname -r)/modules.dep" 2>/dev/null; then HAS_KMOD=2
  fi
  HAS_V4=0; HAS_V6=0
  if _has ip; then
    [ -n "$(ip -4 route show default 2>/dev/null)" ] && HAS_V4=1
    [ -n "$(ip -6 route show default 2>/dev/null)" ] && HAS_V6=1
  else
    awk 'NR>1 && $2=="00000000" {f=1} END {exit !f}' /proc/net/route 2>/dev/null && HAS_V4=1
    awk '$1=="00000000000000000000000000000000" && $2=="00" && $10!="lo" {f=1} END {exit !f}' /proc/net/ipv6_route 2>/dev/null && HAS_V6=1
  fi
  # 有的 LXC/OpenVZ 小鸡没有 default 路由，但有 0.0.0.0/1 这种拆开的路由，也算有 IPv4
  if [ "$HAS_V4" = 0 ] && _has ip && ip -4 route get 1.1.1.1 >/dev/null 2>&1; then HAS_V4=1; fi
  if [ "$HAS_V6" = 0 ] && _has ip && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then HAS_V6=1; fi
  # 网卡上的 IPv6 是什么样的：public = 公网地址；ula = 内网地址（fd 开头，外网要靠服务商 NAT66 转发进来）
  V6_LOCAL=$(v6_local_addr); V6_KIND=none
  case "$V6_LOCAL" in
    '') V6_KIND=none ;;
    [fF][cCdD]*) V6_KIND=ula ;;
    *) V6_KIND=public ;;
  esac
}

# 网卡上第一个“全局”IPv6 地址（跳过 lo、本脚本的 wg-luodi 网卡、fe80 这种本地链路地址）。
# 直接读 /proc/net/if_inet6，busybox 也能用。打印成常见的缩写形式（fd66::5）。
v6_local_addr() {
  [ -r /proc/net/if_inet6 ] || return 0
  awk -v skip="$WGL_IFACE" '
    $4 == "00" && $6 != "lo" && $6 != skip && tolower(substr($1, 1, 4)) != "fe80" {
      a = tolower($1)
      for (i = 1; i <= 8; i++) { g[i] = substr(a, i * 4 - 3, 4); sub(/^0+/, "", g[i]); if (g[i] == "") g[i] = "0" }
      # 找最长的一串连续 0，缩成 ::
      bs = 0; bl = 0; cs = 0; cl = 0
      for (i = 1; i <= 8; i++) {
        if (g[i] == "0") { if (cl == 0) cs = i; cl++; if (cl > bl) { bl = cl; bs = cs } } else cl = 0
      }
      out = ""
      for (i = 1; i <= 8; i++) {
        if (bl >= 2 && i == bs) { out = out "::"; i += bl - 1; continue }
        out = out ((out == "" || out ~ /:$/) ? "" : ":") g[i]
      }
      print out; exit
    }' /proc/net/if_inet6 2>/dev/null
}

print_env() {
  step "[检测] 这台服务器的情况"
  say "  系统：      ${OS_NAME}（包管理：${PKG:-没找到}）"
  say "  开机自启：  $(case $INIT in systemd) echo systemd ;; openrc) echo OpenRC ;; *) echo '没有 systemd/OpenRC（重启后要手动再运行一次）' ;; esac)"
  say "  机器类型：  ${VIRT_CN}"
  say "  TUN 设备：  $([ "$HAS_TUN" = 1 ] && echo 有 || echo '没有（不影响，本脚本不需要 TUN）')"
  say "  WG 内核模块：$(case $HAS_KMOD in 1) echo 已加载 ;; 2) echo '有（还没加载）' ;; *) echo '没检测到（可以用无网卡模式）' ;; esac)"
  say "  网络：      IPv4 $([ "$HAS_V4" = 1 ] && echo 有 || echo 没有)，IPv6 $([ "$HAS_V6" = 1 ] && echo 有 || echo 没有)$(case "$V6_KIND" in ula) echo "（网卡上是内网 IPv6 $V6_LOCAL，外网 IPv6 靠服务商转发）" ;; public) echo "（$V6_LOCAL）" ;; esac)"
}

# ---------- 7. 装需要的小工具 ----------
# jq（改 JSON 配置用）、curl（下载和测出口 IP 用）；内核网卡模式还要 wg 和完整的 ip 命令。
# 已经有的就不装。apt 只在第一次需要时 update 一次。
# 所有后台命令的输入都接到 /dev/null：不让它们碰你的终端（防止终端设置被改乱、你打的字被抢走）。
_APT_UPDATED=0
pkg_install() { # pkg_install 包名…
  [ -n "$PKG" ] || return 1
  [ "${WGL_NO_PKG:-0}" = 1 ] && return 1
  case "$PKG" in
    apk) _to 300 apk add --no-cache "$@" </dev/null >/dev/null 2>&1 ;;
    apt)
      if [ "$_APT_UPDATED" = 0 ]; then
        DEBIAN_FRONTEND=noninteractive _to 300 apt-get update -qq </dev/null >/dev/null 2>&1
        _APT_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive _to 600 apt-get install -y -qq "$@" </dev/null >/dev/null 2>&1 ;;
    dnf) _to 600 dnf install -y -q "$@" </dev/null >/dev/null 2>&1 ;;
    yum) _to 600 yum install -y -q "$@" </dev/null >/dev/null 2>&1 ;;
    pacman) _to 600 pacman -Sy --noconfirm --needed "$@" </dev/null >/dev/null 2>&1 ;;
    zypper) _to 600 zypper -n -q install "$@" </dev/null >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# CPU 架构，下载程序时用。
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; JQ_ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64; JQ_ARCH=arm64 ;;
    armv7*|armv8l) ARCH=armv7; JQ_ARCH=armhf ;;
    i386|i686) ARCH=386; JQ_ARCH=i386 ;;
    s390x) ARCH=s390x; JQ_ARCH=s390x ;;
    riscv64) ARCH=riscv64; JQ_ARCH=riscv64 ;;
    *) ARCH=""; JQ_ARCH="" ;;
  esac
}

# 下载一个文件：curl 优先，没有就用 wget。
_dl() { # _dl <网址> <保存到>
  rm -f "$2"
  if _has curl; then
    _to 300 curl -fsSL --connect-timeout 10 --retry 2 -o "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
  elif _has wget; then
    _to 300 wget -q -T 15 -O "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
  fi
  rm -f "$2"; return 1
}
_get() { # _get <网址>：直接打印内容
  if _has curl; then _to 30 curl -fsSL --connect-timeout 10 "$1" 2>/dev/null
  elif _has wget; then _to 30 wget -q -T 15 -O - "$1" 2>/dev/null
  else return 1; fi
}
# GitHub 下载：先直连，不通再走镜像（纯 IPv6 机器连不上 GitHub 时用）。
_gh_dl() { # _gh_dl <github 网址> <保存到>
  _dl "$1" "$2" && return 0
  for _m in $GH_MIRRORS; do
    info "直连 GitHub 不通，换镜像：$_m"
    _dl "${_m}$1" "$2" && return 0
  done
  return 1
}
_sha256() {
  if _has sha256sum; then sha256sum "$1" | awk '{print tolower($1)}'
  elif _has openssl; then openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'
  fi
}

ensure_tools() {
  step "[准备] 检查需要的小工具"
  _need=""
  _has curl || _need="$_need curl"
  _has tar || _need="$_need tar"
  _has gzip || _need="$_need gzip"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || [ -d /etc/pki/tls/certs ] || _need="$_need ca-certificates"
  if [ -n "$_need" ]; then
    info "正在安装：$_need"
    # shellcheck disable=SC2086
    pkg_install $_need || warn "有的工具没装上：$_need（继续试试）"
  fi
  # jq：系统里有就用；没有先用包管理器装；再不行下载官方单文件版。
  if [ -x "$WGL_LIB/jq" ] && "$WGL_LIB/jq" -n 1 >/dev/null 2>&1; then
    JQ="$WGL_LIB/jq"
  elif _has jq; then
    JQ=jq
  else
    info "正在安装 jq（改节点配置要用）"
    if pkg_install jq && _has jq; then
      JQ=jq
    else
      detect_arch
      [ -n "$JQ_ARCH" ] || die "不认识这台机器的 CPU 架构（$(uname -m)），装不了 jq。"
      mkdir -p "$WGL_LIB"
      _gh_dl "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${JQ_ARCH}" "$WGL_LIB/jq" \
        || die "jq 下载失败。请先手动装上 jq（比如 apk add jq / apt install jq）再运行本脚本。"
      chmod 755 "$WGL_LIB/jq"
      "$WGL_LIB/jq" -n 1 >/dev/null 2>&1 || die "下载的 jq 跑不起来。请手动装上 jq 再运行本脚本。"
      JQ="$WGL_LIB/jq"
    fi
  fi
  info "小工具齐了"
}

# 管理命令（巡检、钩子）运行时，只找现成的 jq，不去安装。
find_jq() {
  if [ -x "$WGL_LIB/jq" ]; then JQ="$WGL_LIB/jq"; elif _has jq; then JQ=jq; else return 1; fi
}

# ---------- 8. 准备网关程序 sing-box ----------
# 网关用 sing-box：它自带“无网卡”的 WireGuard（不需要 TUN），SOCKS5 支持 UDP，DNS 也能指定走隧道。
# 机器上已有 1.12 以上的 sing-box 就复制一份来用；没有就从 GitHub 下载最新正式版，并核对官方 SHA256。
_sb_ver_ok() { # _sb_ver_ok <程序>：版本 >= 1.12 返回 0
  _v=$("$1" version 2>/dev/null | head -n 1 | sed -n 's/.*version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
  [ -n "$_v" ] || return 1
  set -- $_v
  [ "$1" -gt 1 ] || { [ "$1" -eq 1 ] && [ "$2" -ge 12 ]; }
}

# 是不是 musl 系统（Alpine 等）：有 musl 加载器，或 ldd 自报 musl。
is_musl() {
  ls /lib/ld-musl-* >/dev/null 2>&1 && return 0
  ldd --version 2>&1 | grep -qi musl
}

# 下载一种 sing-box 包、核对 SHA256、解压，并确认能运行。成功就留下 "$SB.new"。
_sb_fetch() { # _sb_fetch <版本> <包类型，如 amd64-musl> <发布接口内容>
  _asset="sing-box-$1-linux-$2.tar.gz"
  # 临时文件放在硬盘上（和 sing-box 同一个目录），不放 /tmp：
  # 很多小内存小鸡的 /tmp 是内存盘，几十 MB 的程序写进去会把内存撑爆，整台小鸡被重启。
  mkdir -p "$WGL_LIB"
  _tmp=$(mktemp -d "$WGL_LIB/.dl-sb.XXXXXX") || die "建不了临时目录（$WGL_LIB）"
  info "下载 sing-box $1（$2）…"
  if ! _gh_dl "https://github.com/SagerNet/sing-box/releases/download/v$1/${_asset}" "$_tmp/sb.tgz"; then
    rm -rf "$_tmp"; warn "这个包没下载下来：${_asset}"; return 1
  fi
  # GitHub 的发布接口会给每个文件附上 sha256（digest），拿到了就核对
  _want=$(printf '%s' "$3" | tr ',{}' '\n\n\n' | awk -v a="\"${_asset}\"" '
      index($0, "\"name\"") && index($0, a) { hit = 1; next }
      hit && index($0, "\"digest\"") { sub(/.*sha256:/, ""); gsub(/[" \r]/, ""); print tolower($0); exit }')
  if [ -n "$_want" ]; then
    _have=$(_sha256 "$_tmp/sb.tgz")
    if [ -n "$_have" ] && [ "$_have" != "$_want" ]; then
      rm -rf "$_tmp"; die "下载的 sing-box 和官方校验值对不上，已删除，不安装。请稍后重试。"
    fi
    info "SHA256 校验通过"
  else
    warn "没拿到官方校验值，改为只检查程序能不能运行"
  fi
  tar -xzf "$_tmp/sb.tgz" -C "$_tmp" 2>/dev/null || { rm -rf "$_tmp"; warn "安装包解压失败：${_asset}"; return 1; }
  _bin=$(find "$_tmp" -type f -name sing-box | head -n 1)
  [ -n "$_bin" ] || { rm -rf "$_tmp"; warn "安装包里没找到 sing-box：${_asset}"; return 1; }
  mv -f "$_bin" "$SB.new" && chmod 755 "$SB.new"
  rm -rf "$_tmp"
  if ! _sb_ver_ok "$SB.new"; then
    rm -f "$SB.new"; warn "这个包在本机跑不起来（多半是系统 C 库不匹配），换另一个包试试"; return 1
  fi
  return 0
}

# 按本机的 C 库挑包下载，成功就留下 "$SB.new"。
# Alpine 用 musl，Debian/Ubuntu/CentOS 用 glibc。官方 -musl 包是静态编译的（不依赖系统库），glibc 系统也能跑；
# 普通包要 glibc 加载器，Alpine 上跑不了。所以 musl 系统先试 -musl 包，glibc 系统先试普通包，跑不起来就换另一个。
_sb_get() { # _sb_get <版本> <发布接口内容>
  detect_arch
  [ -n "$ARCH" ] || return 1
  # 先看硬盘够不够：安装包加解压出来的程序，大约要 150MB 空间
  mkdir -p "$WGL_LIB"
  _free=$(df -Pk "$WGL_LIB" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')
  if [ -n "$_free" ] && [ "$_free" -lt 150 ] 2>/dev/null; then
    die "硬盘剩余空间不够：$WGL_LIB 所在的盘只剩 ${_free}MB，下载 sing-box 大约要 150MB。请先清理一下硬盘再运行。"
  fi
  if is_musl; then _cands="${ARCH}-musl ${ARCH}"; else _cands="${ARCH} ${ARCH}-musl"; fi
  for _flavor in $_cands; do
    _sb_fetch "$1" "$_flavor" "$2" && return 0
  done
  return 1
}

# 从 GitHub 查 sing-box 最新正式版的版本号（查不到就打印空）
_sb_latest_ver() { # 用法：_api=$(_get 发布接口); _sb_latest_ver "$_api"
  printf '%s' "$1" | tr ',' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1
}

ensure_singbox() {
  step "[准备] 网关程序 sing-box"
  mkdir -p "$WGL_LIB" && chmod 755 "$WGL_LIB"
  if [ -x "$SB" ] && _sb_ver_ok "$SB" && [ "${WGL_UPDATE_SB:-0}" != 1 ]; then
    info "已有：$("$SB" version | head -n 1)"
    return 0
  fi
  for _c in /usr/local/bin/sing-box /usr/bin/sing-box "$(command -v sing-box 2>/dev/null)"; do
    [ -n "$_c" ] && [ -x "$_c" ] || continue
    if _sb_ver_ok "$_c" && [ "${WGL_UPDATE_SB:-0}" != 1 ]; then
      cp -f "$_c" "$SB.new" && chmod 755 "$SB.new" && mv -f "$SB.new" "$SB"
      info "复制了机器上已有的 sing-box：$("$SB" version | head -n 1)"
      return 0
    fi
  done
  detect_arch
  [ -n "$ARCH" ] || die "不认识这台机器的 CPU 架构（$(uname -m)），没法下载 sing-box。"
  _api=$(_get "https://api.github.com/repos/SagerNet/sing-box/releases/latest")
  _ver=$(_sb_latest_ver "$_api")
  case "$_ver" in ''|*[!0-9.]*) _ver="$SB_FALLBACK_VER"; _api="" ;; esac
  _sb_get "$_ver" "$_api" || die "sing-box 下载失败，或下载的程序在这台机器上跑不起来（C 库不匹配）。请把上面的提示发出来。"
  mv -f "$SB.new" "$SB"
  info "sing-box 装好了：$("$SB" version | head -n 1)"
}

# ---------- 9. 读懂并检查 WireGuard 配置 ----------
# 支持 Windows 换行（CRLF）、前后空格、大小写不同的写法（PrivateKey / privatekey）。
# 只用第一个 [Peer]。检查必填项：PrivateKey、Address、PublicKey、Endpoint、AllowedIPs。
parse_conf() { # parse_conf <文件>：成功后设置 WG_* 变量；失败返回 1，原因在 PARSE_ERR
  PARSE_ERR=""
  _p=$(tr -d '\r' < "$1" | awk -v bom="$(printf '\357\273\277')" '
    {
      line = $0
      if (NR == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      if (substr(line, 1, 1) == "[") {
        s = tolower(line); gsub(/[ \t]/, "", s)
        if (s == "[interface]") { sec = "i"; ni++ }
        else if (s == "[peer]") { sec = "p"; np++ }
        else sec = "x"
        next
      }
      eq = index(line, "=")
      if (eq == 0) { bad++; next }
      k = tolower(substr(line, 1, eq - 1)); v = substr(line, eq + 1)
      gsub(/[ \t]/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k == "address" || k == "dns" || k == "allowedips") gsub(/[ \t]/, "", v)
      if (sec == "i") {
        if ((k == "address" || k == "dns") && I[k] != "") I[k] = I[k] "," v; else I[k] = v
      } else if (sec == "p" && np == 1) {
        if (k == "allowedips" && P[k] != "") P[k] = P[k] "," v; else P[k] = v
      }
    }
    END {
      print "NI=" ni + 0; print "NP=" np + 0
      print "PRIV=" I["privatekey"]; print "ADDR=" I["address"]; print "DNS=" I["dns"]; print "MTU=" I["mtu"]
      print "PUB=" P["publickey"]; print "PSK=" P["presharedkey"]; print "EP=" P["endpoint"]
      print "ALLOWED=" P["allowedips"]; print "KA=" P["persistentkeepalive"]
    }')
  _pv() { printf '%s\n' "$_p" | sed -n "s/^$1=//p" | head -n 1; }
  _ni=$(_pv NI); _np=$(_pv NP)
  WG_PRIV=$(_pv PRIV); WG_ADDR=$(_pv ADDR); WG_DNS=$(_pv DNS); WG_MTU=$(_pv MTU)
  WG_PUB=$(_pv PUB); WG_PSK=$(_pv PSK); WG_EP=$(_pv EP); WG_ALLOWED=$(_pv ALLOWED); WG_KA=$(_pv KA)
  [ "$_ni" -ge 1 ] || { PARSE_ERR="没有找到 [Interface] 这一段。"; return 1; }
  [ "$_np" -ge 1 ] || { PARSE_ERR="没有找到 [Peer] 这一段。"; return 1; }
  [ "$_np" -gt 1 ] && warn "配置里有 $_np 个 [Peer]，只用第一个。"
  _is_key "$WG_PRIV" || { PARSE_ERR="[Interface] 里的 PrivateKey 缺失或格式不对（应该是 44 个字符、以 = 结尾）。"; return 1; }
  _is_key "$WG_PUB" || { PARSE_ERR="[Peer] 里的 PublicKey 缺失或格式不对（应该是 44 个字符、以 = 结尾）。"; return 1; }
  if [ -n "$WG_PSK" ] && ! _is_key "$WG_PSK"; then PARSE_ERR="[Peer] 里的 PresharedKey 格式不对。"; return 1; fi
  [ "$WG_PRIV" = "$WG_PUB" ] && { PARSE_ERR="PrivateKey 和 PublicKey 一样，配置不对。"; return 1; }
  [ -n "$WG_ADDR" ] || { PARSE_ERR="[Interface] 里缺少 Address（隧道里你这一端的 IP）。"; return 1; }
  WG_ADDR4=""; WG_ADDR6=""
  for _a in $(printf '%s' "$WG_ADDR" | tr ',' ' '); do
    _ip=${_a%%/*}
    if _is_ip4 "$_ip"; then WG_ADDR4="$WG_ADDR4 $_a"
    elif _is_ip6 "$_ip"; then WG_ADDR6="$WG_ADDR6 $_a"
    else PARSE_ERR="Address 里的 $_a 不是正确的 IP。"; return 1
    fi
  done
  [ -n "$WG_EP" ] || { PARSE_ERR="[Peer] 里缺少 Endpoint（落地机的地址:端口）。"; return 1; }
  case "$WG_EP" in
    \[*\]:*) WG_EP_HOST=${WG_EP#\[}; WG_EP_HOST=${WG_EP_HOST%%\]*}; WG_EP_PORT=${WG_EP##*\]:} ;;
    *:*:*) PARSE_ERR="Endpoint 是 IPv6 地址时要加方括号，比如 [2001:db8::1]:51820，现在是 $WG_EP"; return 1 ;;
    *:*) WG_EP_HOST=${WG_EP%:*}; WG_EP_PORT=${WG_EP##*:} ;;
    *) PARSE_ERR="Endpoint 要写成“地址:端口”，现在是 $WG_EP"; return 1 ;;
  esac
  _port_ok "$WG_EP_PORT" || { PARSE_ERR="Endpoint 的端口 $WG_EP_PORT 不对。"; return 1; }
  WG_EP_PORT=$(printf '%s' "$WG_EP_PORT" | sed 's/^0*//')
  if _is_ip4 "$WG_EP_HOST"; then WG_EP_KIND=4
  elif _is_ip6 "$WG_EP_HOST"; then WG_EP_KIND=6
  elif printf '%s' "$WG_EP_HOST" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'; then WG_EP_KIND=name
  else PARSE_ERR="Endpoint 的地址 $WG_EP_HOST 不对（IPv6 地址要用方括号，比如 [2001:db8::1]:51820）。"; return 1
  fi
  [ -n "$WG_ALLOWED" ] || { PARSE_ERR="[Peer] 里缺少 AllowedIPs。"; return 1; }
  _al4=0; _al6=0
  for _a in $(printf '%s' "$WG_ALLOWED" | tr ',' ' '); do
    case "$_a" in 0.0.0.0/0) _al4=1 ;; ::/0) _al6=1 ;; esac
    _ip=${_a%%/*}
    _is_ip4 "$_ip" || _is_ip6 "$_ip" || { PARSE_ERR="AllowedIPs 里的 $_a 不对。"; return 1; }
  done
  # 能当落地用，必须“所有流量都进隧道”：AllowedIPs 至少要有 0.0.0.0/0 或 ::/0
  WG_HAS4=0; WG_HAS6=0
  [ -n "$WG_ADDR4" ] && [ "$_al4" = 1 ] && WG_HAS4=1
  [ -n "$WG_ADDR6" ] && [ "$_al6" = 1 ] && WG_HAS6=1
  if [ "$WG_HAS4" = 0 ] && [ "$WG_HAS6" = 0 ]; then
    PARSE_ERR="AllowedIPs 里没有 0.0.0.0/0（或 Address 里没有 IPv4）。这不是“全部流量走隧道”的落地配置，请向提供商要一份全局（0.0.0.0/0）的配置。"
    return 1
  fi
  case "$WG_MTU" in ''|*[!0-9]*) WG_MTU="" ;; esac
  if [ -n "$WG_MTU" ] && { [ "$WG_MTU" -lt 1280 ] || [ "$WG_MTU" -gt 9000 ]; }; then WG_MTU=""; fi
  case "$WG_KA" in ''|*[!0-9]*) WG_KA=25 ;; esac
  [ "$WG_KA" -eq 0 ] && WG_KA=25
  # DNS：选第一个能用的。只有 IPv4 隧道时选 IPv4 的 DNS；没写就用 1.1.1.1。
  WG_DNS1=""
  for _d in $(printf '%s' "$WG_DNS" | tr ',' ' '); do
    if _is_ip4 "$_d" && [ "$WG_HAS4" = 1 ]; then WG_DNS1="$_d"; break; fi
    if _is_ip6 "$_d" && [ "$WG_HAS6" = 1 ]; then WG_DNS1="$_d"; break; fi
  done
  if [ -z "$WG_DNS1" ]; then
    if [ "$WG_HAS4" = 1 ]; then WG_DNS1=1.1.1.1; else WG_DNS1=2606:4700:4700::1111; fi
  fi
  if [ "$WG_HAS4" = 1 ] && [ "$WG_HAS6" = 1 ]; then WG_STRAT=prefer_ipv4
  elif [ "$WG_HAS4" = 1 ]; then WG_STRAT=ipv4_only
  else WG_STRAT=ipv6_only
  fi
  return 0
}
_is_key() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; }
_is_ip4() {
  printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
  printf '%s' "$1" | awk -F. '{ for (i = 1; i <= 4; i++) if ($i + 0 > 255) exit 1 }'
}
_is_ip6() {
  case "$1" in *:*:*) ;; *) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f:.]+$'
}
_port_ok() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 把配置里的地址补上前缀长度，给 sing-box 用（10.0.0.2 -> 10.0.0.2/32）。
_cidr_list() { # _cidr_list "a,b" -> 空格分隔
  for _a in $(printf '%s' "$1" | tr ',' ' '); do
    case "$_a" in */*) printf '%s ' "$_a" ;; *:*) printf '%s/128 ' "$_a" ;; *) printf '%s/32 ' "$_a" ;; esac
  done
}

# ---------- 10. 让你粘贴配置 ----------
# 粘贴完按一次回车（空行）就结束；也可以按 Ctrl+D。配置中间本来就有的空行不会被当成结束：
# 只有 [Interface] 和 [Peer] 的必填项都出现之后，空行才算“粘贴完了”。
# 也可以直接输入一个文件路径（比如 /root/wg0.conf）。
read_conf_paste() { # read_conf_paste <保存到>
  _out="$1"; : > "$_out"; chmod 600 "$_out"
  tty_fix
  _f_i=0; _f_pk=0; _f_p=0; _f_pub=0; _f_ep=0; _f_al=0; _n=0
  while _readline _l || [ -n "$_l" ]; do
    _l=$(printf '%s' "$_l" | tr -d '\r')
    _t=$(printf '%s' "$_l" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ "$_n" = 0 ] && [ -z "$_t" ]; then continue; fi
    if [ "$_n" = 0 ]; then
      case "$_t" in /*|./*|\~/*)
        _fp=$(printf '%s' "$_t" | sed "s#^~/#$HOME/#")
        if [ -f "$_fp" ]; then tr -d '\r' < "$_fp" > "$_out"; info "已读取文件 $_fp"; return 0; fi
        warn "找不到文件 $_fp，请直接粘贴配置内容。"; continue ;;
      esac
    fi
    if [ -z "$_t" ]; then
      if [ "$_f_i$_f_pk$_f_p$_f_pub$_f_ep$_f_al" = 111111 ]; then break; fi
      printf '\n' >> "$_out"; continue
    fi
    _n=$((_n + 1))
    printf '%s\n' "$_l" >> "$_out"
    _tl=$(printf '%s' "$_t" | tr 'A-Z' 'a-z' | tr -d ' \t')
    case "$_tl" in
      "[interface]") _f_i=1 ;;
      "[peer]") _f_p=1 ;;
      privatekey=*) _f_pk=1 ;;
      publickey=*) _f_pub=1 ;;
      endpoint=*) _f_ep=1 ;;
      allowedips=*) _f_al=1 ;;
    esac
  done
  [ "$_n" -gt 0 ]
}

# 问配置：最多试 3 次。WG_CONF_FILE 环境变量给了就直接读文件。
get_conf() { # get_conf <保存到>
  _dst="$1"
  if [ -n "$WG_CONF_FILE" ]; then
    [ -f "$WG_CONF_FILE" ] || die "WG_CONF_FILE 指向的文件不存在：$WG_CONF_FILE"
    tr -d '\r' < "$WG_CONF_FILE" > "$_dst"; chmod 600 "$_dst"
    parse_conf "$_dst" || die "WireGuard 配置有问题：$PARSE_ERR"
    return 0
  fi
  _can_ask || die "现在不是交互终端，又没有给 WG_CONF_FILE。请用：WG_CONF_FILE=/root/wg.conf WG_PORTS=\"端口\" sh wg-luodi.sh"
  _try=0
  while :; do
    _try=$((_try + 1))
    say ""
    say "请把 WireGuard 配置整段粘贴进来（从 [Interface] 到 [Peer] 最后一行）。"
    say "粘贴完按一次回车；如果没反应，再按一次回车或按 Ctrl+D。"
    say "（也可以直接输入配置文件的路径，比如 /root/wg0.conf）"
    if read_conf_paste "$_dst" && parse_conf "$_dst"; then
      info "配置检查通过：本端地址 $(printf '%s' "$WG_ADDR" | tr ',' ' ')，落地机 ${WG_EP_HOST}:${WG_EP_PORT}"
      return 0
    fi
    [ -n "$PARSE_ERR" ] || PARSE_ERR="没有读到内容。"
    err "配置不对：$PARSE_ERR"
    [ "$_try" -ge 3 ] && die "试了 3 次都不对，已停止。请检查配置后重新运行。"
    say "请重新粘贴。"
  done
}

# ---------- 11. 端口 ----------
# 端口可以一次填好几个，用空格或逗号隔开；也可以写一小段范围，比如 50000-50010。
parse_ports() { # parse_ports "输入" -> PORTS_OUT（空格分隔、去重、从小到大）；失败返回 1，原因在 PARSE_ERR
  PARSE_ERR=""; PORTS_OUT=""
  _list=""
  for _t in $(printf '%s' "$1" | sed 's/，/ /g; s/、/ /g; s/；/ /g' | tr ',;/' '   '); do
    case "$_t" in
      *-*)
        _a=$(printf '%s' "${_t%-*}" | sed 's/^0*//'); _b=$(printf '%s' "${_t#*-}" | sed 's/^0*//')
        _port_ok "$_a" && _port_ok "$_b" || { PARSE_ERR="$_t 不是正确的端口范围"; return 1; }
        [ "$_a" -le "$_b" ] || { PARSE_ERR="$_t 前面的数要比后面的小"; return 1; }
        [ $((_b - _a)) -le 200 ] || { PARSE_ERR="$_t 范围太大（一次最多 200 个端口）"; return 1; }
        _i=$_a; while [ "$_i" -le "$_b" ]; do _list="$_list $_i"; _i=$((_i + 1)); done ;;
      *)
        _n0=$(printf '%s' "$_t" | sed 's/^0*//')
        _port_ok "$_n0" || { PARSE_ERR="$_t 不是 1-65535 之间的端口"; return 1; }
        _list="$_list $_n0" ;;
    esac
  done
  [ -n "$_list" ] || { PARSE_ERR="没有填端口"; return 1; }
  PORTS_OUT=$(printf '%s\n' $_list | sort -n -u | tr '\n' ' ' | sed 's/ $//')
}

get_ports() {
  if [ -n "$WG_PORTS" ]; then
    parse_ports "$WG_PORTS" || die "WG_PORTS 不对：$PARSE_ERR"
    PORTS="$PORTS_OUT"; return 0
  fi
  _can_ask || die "现在不是交互终端，又没有给 WG_PORTS。"
  say ""
  say "请输入你要用来搭节点的端口。之后你自己在这些端口上搭节点，节点会自动走 WireGuard。"
  _def=$(st_get PORTS)
  while :; do
    ask "要设置的端口是？可以填多个，用空格隔开（例如 45192 50000）" "$_def"
    if parse_ports "$ANS"; then PORTS="$PORTS_OUT"; break; fi
    err "$PARSE_ERR，请重新输入。"
  done
  info "走 WireGuard 的端口：$PORTS"
}

# ---------- 12. 找到这台服务器上的节点 ----------
# 三个来源：① VPS-dajianjiedian 的节点目录 /etc/xray-node/nodes/<编号>/；
# ② 正在运行的 xray / sing-box / hysteria 进程（看它的 -c 参数用的哪个配置）；
# ③ 常见的默认配置位置（/usr/local/etc/xray/config.json 等）。
# 每行输出：类型|配置文件|服务类型|服务名|程序路径|别名端口（NAT 公网端口、端口跳跃端口）
kind_cn() { case "$1" in xray) echo Xray ;; sing-box) echo sing-box ;; hysteria) echo Hysteria2 ;; *) echo "$1" ;; esac; }

_svc_of_pid() { # _svc_of_pid <pid> -> "systemd 单元名" 或 "openrc 名字" 或 "none -"
  _u=$(sed -n 's#.*/\([^/]*\.service\).*#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -n 1)
  if [ -n "$_u" ] && [ "$INIT" = systemd ]; then echo "systemd $_u"; return; fi
  echo "none -"
}
_svc_of_cfg() { # _svc_of_cfg <配置路径> -> 在服务文件里找引用了这个配置的服务
  if [ "$INIT" = systemd ]; then
    for _f in /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service; do
      [ -f "$_f" ] && grep -qF "$1" "$_f" 2>/dev/null && { echo "systemd $(basename "$_f")"; return; }
    done
  elif [ "$INIT" = openrc ]; then
    for _f in "$WGL_INITD"/*; do
      [ -f "$_f" ] && grep -qF "$1" "$_f" 2>/dev/null && { echo "openrc $(basename "$_f")"; return; }
    done
  fi
  echo "none -"
}
_is_panel_path() { # 面板（x-ui、3x-ui、s-ui、marzban、hiddify…）每次启动会重新生成配置，改了也白改
  case "$1" in *x-ui*|*s-ui*|*marzban*|*hiddify*|*v2board*|*xrayr*|*XrayR*|*v2bx*|*V2bX*) return 0 ;; esac
  return 1
}

discover_nodes() {
  _seen=" "
  # ① VPS-dajianjiedian 的节点
  for _d in "$XN_NODES"/*/; do
    [ -d "$_d" ] || continue
    _id=$(basename "$_d")
    case "$_id" in ''|*[!0-9]*) continue ;; esac
    _core=$(tr -d ' \r\n' < "${_d}core" 2>/dev/null)
    case "$_core" in
      hysteria) _cfg="${_d}config.yaml"; _bin="$XN_BIN_DIR/hysteria"; _unit="hysteria-node@${_id}" ;;
      sing-box) _cfg="${_d}config.json"; _bin="$XN_BIN_DIR/sing-box"; _unit="singbox-node@${_id}" ;;
      *) _core=xray; _cfg="${_d}config.json"; _bin="$XN_BIN_DIR/xray"; _unit="xray-node@${_id}" ;;
    esac
    [ -f "$_cfg" ] || continue
    case "$INIT" in
      systemd) _st=systemd; _sn="$_unit" ;;
      openrc) _st=openrc; _sn="xray-node-${_id}" ;;
      *) _st=none; _sn=- ;;
    esac
    # 别名端口：NAT 小鸡的公网端口（link_port 文件或 node.txt 里的链接），Hysteria2 端口跳跃的端口
    _al=""
    [ -f "${_d}link_port" ] && _al="$_al $(tr -dc '0-9' < "${_d}link_port")"
    [ -f "${_d}node.txt" ] && _al="$_al $(grep -o '@[^ /?#]*:[0-9][0-9]*' "${_d}node.txt" 2>/dev/null | sed 's/.*://' | tr '\n' ' ')"
    [ -f "${_d}hop" ] && _al="$_al $(sed -n 's/^ports=//p' "${_d}hop" | tr ',' ' ')"
    _al=$(printf '%s\n' $_al | grep -E '^[0-9]+(-[0-9]+)?$' | sort -u | tr '\n' ',' | sed 's/,$//')
    printf '%s|%s|%s|%s|%s|%s\n' "$_core" "$_cfg" "$_st" "$_sn" "$_bin" "$_al"
    _seen="$_seen$_cfg "
  done
  [ "${DISCOVER_XN_ONLY:-0}" = 1 ] && return 0
  # ② 正在运行的进程（WGL_NO_PROC_SCAN=1 时不看，测试用）
  for _pd in /proc/[0-9]*; do
    [ "${WGL_NO_PROC_SCAN:-0}" = 1 ] && break
    _exe=$(readlink "$_pd/exe" 2>/dev/null) || continue
    _base=$(basename "$_exe" 2>/dev/null | sed 's/ (deleted)$//')
    case "$_base" in
      xray*) _k=xray ;; sing-box*) _k=sing-box ;; hysteria*) _k=hysteria ;; *) continue ;;
    esac
    _args=$(tr '\0' '\n' < "$_pd/cmdline" 2>/dev/null)
    printf '%s' "$_args" | grep -qF "$WGL_DIR" && continue        # 我们自己的网关
    printf '%s' "$_args" | grep -q 'wgl-test' && continue          # 测出口时临时起的客户端
    _cfg=$(printf '%s\n' "$_args" | awk '
      p { print; exit }
      $0 == "-c" || $0 == "-config" || $0 == "--config" { p = 1; next }
      /^-config=/ || /^--config=/ || /^-c=/ { sub(/^[^=]*=/, ""); print; exit }')
    if [ -z "$_cfg" ]; then
      [ "$_k" = xray ] && _cfg=/usr/local/etc/xray/config.json || continue
    fi
    case "$_cfg" in /*) ;; *) _cfg="$(readlink "$_pd/cwd" 2>/dev/null)/$_cfg" ;; esac
    case "$_seen" in *" $_cfg "*) continue ;; esac
    [ -f "$_cfg" ] || continue
    if [ "$_k" = hysteria ]; then case "$_cfg" in *.yaml|*.yml) ;; *) continue ;; esac
    else case "$_cfg" in *.json) ;; *) continue ;; esac
    fi
    _is_panel_path "$_cfg$_exe" && { _seen="$_seen$_cfg "; printf 'panel|%s|none|-|%s|\n' "$_cfg" "$_exe"; continue; }
    set -- $(_svc_of_pid "${_pd#/proc/}")
    if [ "$1" = none ]; then set -- $(_svc_of_cfg "$_cfg"); fi
    printf '%s|%s|%s|%s|%s|\n' "$_k" "$_cfg" "$1" "$2" "$_exe"
    _seen="$_seen$_cfg "
  done
  # ③ 常见默认位置（服务没在跑也算，下次启动就生效）
  for _pair in ${WGL_KNOWN_PATHS-xray:/usr/local/etc/xray/config.json xray:/etc/xray/config.json \
               sing-box:/etc/sing-box/config.json sing-box:/usr/local/etc/sing-box/config.json \
               hysteria:/etc/hysteria/config.yaml}; do
    _k=${_pair%%:*}; _cfg=${_pair#*:}
    [ -f "$_cfg" ] || continue
    case "$_seen" in *" $_cfg "*) continue ;; esac
    _bin=$(command -v "$_k" 2>/dev/null); [ -n "$_bin" ] || _bin="/usr/local/bin/$_k"
    set -- $(_svc_of_cfg "$_cfg")
    printf '%s|%s|%s|%s|%s|\n' "$_k" "$_cfg" "$1" "$2" "$_bin"
    _seen="$_seen$_cfg "
  done
  # ④ 以前改过、但现在找不到进程的配置（比如服务停着），从记录里补上
  if [ -f "$REG" ]; then
    while IFS='|' read -r _k _cfg _st _sn _bin _al; do
      [ -f "$_cfg" ] || continue
      case "$_seen" in *" $_cfg "*) continue ;; esac
      printf '%s|%s|%s|%s|%s|%s\n' "$_k" "$_cfg" "$_st" "$_sn" "$_bin" "$_al"
      _seen="$_seen$_cfg "
    done < "$REG"
  fi
}

# 配置里节点的主端口（只看第一个入站，用来显示和测出口）
cfg_main_port() { # cfg_main_port <类型> <配置>
  case "$1" in
    xray) "$JQ" -r '[.inbounds[]? | select(.port != null) | .port][0] // empty' "$2" 2>/dev/null ;;
    sing-box) "$JQ" -r '[.inbounds[]? | select(.listen_port != null) | .listen_port][0] // empty' "$2" 2>/dev/null ;;
    hysteria) hy_listen_port "$2" ;;
  esac
}
cfg_ports() { # cfg_ports <类型> <配置>：配置里所有入站端口
  case "$1" in
    xray) "$JQ" -r '.inbounds[]? | .port // empty | tostring' "$2" 2>/dev/null ;;
    sing-box) "$JQ" -r '.inbounds[]? | .listen_port // empty | tostring' "$2" 2>/dev/null ;;
    hysteria) hy_listen_port "$2" ;;
  esac
}
hy_listen_port() { # Hysteria2 的 listen：":443" "0.0.0.0:443" "[::]:443" ":20000-50000"（取第一个）；没写就是 443
  _hl=$(awk -v q="'" '/^listen:/ { sub(/\r$/, ""); sub(/^listen:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub("^[\"" q "]|[\"" q "]$", ""); print; exit }' "$1" 2>/dev/null)
  [ -z "$_hl" ] && { echo 443; return; }
  _hp=${_hl##*:}; _hp=${_hp%%-*}; _hp=${_hp%%,*}
  case "$_hp" in ''|*[!0-9]*) return ;; esac
  echo "$_hp"
}

# 这个配置里，哪些入站端口要走 WireGuard（考虑 NAT 公网端口和端口跳跃别名）
cfg_wg_ports() { # cfg_wg_ports <类型> <配置> <别名端口,…> -> 空格分隔
  _cp=$(cfg_ports "$1" "$2" | tr '\n' ' ')
  _hit=""
  for _x in $_cp; do
    case " $PORTS " in *" $_x "*) _hit="$_hit $_x" ;; esac
  done
  if [ -n "$3" ]; then
    _main=$(cfg_main_port "$1" "$2")
    for _a in $(printf '%s' "$3" | tr ',' ' '); do
      case "$_a" in
        *-*) _s=${_a%-*}; _e=${_a#*-}
             for _p in $PORTS; do [ "$_p" -ge "$_s" ] && [ "$_p" -le "$_e" ] && _hit="$_hit $_main"; done ;;
        *) case " $PORTS " in *" $_a "*) _hit="$_hit $_main" ;; esac ;;
      esac
    done
  fi
  printf '%s\n' $_hit | grep -E '^[0-9]+$' | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}

# ---------- 13. 落地机地址怎么连 ----------
# 纯 IPv6 的服务器连不上只有 IPv4 的落地机，这里先查清楚，说人话解释。
_resolve() { # _resolve <域名> <4|6> -> 打印第一个地址
  if _has getent; then
    if [ "$2" = 4 ]; then getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'
    else getent ahostsv6 "$1" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1; exit}'; fi
    return
  fi
  if _has nslookup; then
    _t=A; [ "$2" = 6 ] && _t=AAAA
    nslookup -type="$_t" "$1" 2>/dev/null | awk -v six="$2" '
      /^Name:/ { n = 1; next }
      n && /^Address/ { a = $NF; if ((six == "6") == (index(a, ":") > 0)) { print a; exit } }'
  fi
}

check_endpoint() {
  EP_FAM=""
  case "$WG_EP_KIND" in
    4) EP_FAM=4 ;;
    6) EP_FAM=6 ;;
    name)
      _a4=$(_resolve "$WG_EP_HOST" 4); _a6=$(_resolve "$WG_EP_HOST" 6)
      if [ "$HAS_V4" = 1 ] && [ -n "$_a4" ]; then EP_FAM=4
      elif [ "$HAS_V6" = 1 ] && [ -n "$_a6" ]; then EP_FAM=6
      elif [ -z "$_a4$_a6" ]; then
        warn "现在解析不出落地机域名 $WG_EP_HOST 的 IP，先按 IPv4 处理，网关启动后会再试。"
        EP_FAM=4; [ "$HAS_V4" = 1 ] || EP_FAM=6
      fi ;;
  esac
  if [ "$EP_FAM" = 4 ] && [ "$HAS_V4" = 0 ]; then EP_FAM=""; fi
  if [ "$EP_FAM" = 6 ] && [ "$HAS_V6" = 0 ]; then EP_FAM=""; fi
  if [ -z "$EP_FAM" ]; then
    err "这台服务器连不上落地机 $WG_EP_HOST："
    if [ "$HAS_V4" = 0 ]; then
      say "  你的服务器只有 IPv6，没有 IPv4；而落地机的地址只有 IPv4。两边“说的不是同一种话”，连不上。"
      say "  解决办法（任选一个）："
      say "  1. 向 WireGuard 提供商要一个 IPv6 的 Endpoint（地址写成 [IPv6地址]:端口），换上再运行本脚本；"
      say "  2. 给这台服务器加一个 IPv4 出口（比如 WARP 的“IPv6 only 机器添加 IPv4”），再运行本脚本；"
      say "  3. 问服务商这台机器能不能分配 IPv4，或者有没有 NAT64。"
    else
      say "  落地机地址只有 IPv6，而你的服务器没有 IPv6 出口。请向提供商要一个 IPv4 的 Endpoint。"
    fi
    die "落地机连不上，已停止，什么都没改。"
  fi
  if [ "$EP_FAM" = 4 ]; then EP_STRAT=ipv4_only; else EP_STRAT=ipv6_only; fi
}

# ---------- 14. 选模式 ----------
# auto：能建内核 WireGuard 网卡就用内核网卡模式，不能就用无网卡模式。
# kernel：只用内核网卡模式，做不到就说明原因并停止。userspace：强制无网卡模式（不要 TUN、不要模块）。
kernel_probe() { # 能建 WireGuard 网卡返回 0，原因写在 KPROBE_ERR
  KPROBE_ERR=""
  if [ "$VIRT" = openvz ]; then KPROBE_ERR="OpenVZ 小鸡和母鸡共用内核，不能自己加载 WireGuard 模块"; return 1; fi
  _has ip || pkg_install iproute2 || pkg_install iproute
  # busybox 的 ip 不支持 WireGuard 网卡和策略路由，Alpine 上要装完整的 iproute2
  if ip -V 2>&1 | grep -qi busybox || ! ip -V >/dev/null 2>&1; then pkg_install iproute2 >/dev/null 2>&1; fi
  if ! _has wg; then
    case "$PKG" in apk) pkg_install wireguard-tools-wg || pkg_install wireguard-tools ;; *) pkg_install wireguard-tools ;; esac
    if ! _has wg && { [ "$PKG" = dnf ] || [ "$PKG" = yum ]; }; then pkg_install epel-release && pkg_install wireguard-tools; fi
  fi
  _has wg || { KPROBE_ERR="装不上 wg 命令（wireguard-tools）"; return 1; }
  _has modprobe && modprobe wireguard >/dev/null 2>&1
  ip link del dev wgl-probe0 >/dev/null 2>&1
  if ip link add dev wgl-probe0 type wireguard >/dev/null 2>&1; then
    ip link del dev wgl-probe0 >/dev/null 2>&1
    return 0
  fi
  case "$VIRT" in
    lxc*|docker|podman) KPROBE_ERR="这是容器小鸡（${VIRT}），母鸡没有给它开 WireGuard（需要母鸡加载 wireguard 模块并允许容器建网卡）" ;;
    *) KPROBE_ERR="内核里没有 WireGuard 模块（内核太老，或者被精简掉了）" ;;
  esac
  return 1
}

choose_mode() { # choose_mode <auto|kernel|userspace> -> MODE
  case "$1" in
    userspace)
      MODE=userspace
      info "模式：无网卡模式（按你的要求强制使用，不需要 TUN 和内核模块）" ;;
    kernel)
      if kernel_probe; then MODE=kernel; info "模式：内核网卡模式"
      else
        err "用不了内核网卡模式：$KPROBE_ERR。"
        say "  想用内核网卡模式，可以这样问服务商：“请在母鸡上加载 wireguard 内核模块，并给我的小鸡开 NET_ADMIN 权限”。"
        say "  不想麻烦的话，用无网卡模式就行：WG_MODE=userspace 重新运行，或者 wg-luodi 菜单里切换。"
        die "已停止，什么都没改。"
      fi ;;
    *)
      if kernel_probe; then MODE=kernel; info "模式：内核网卡模式（自动选择：这台机器能建 WireGuard 网卡，速度最快）"
      else MODE=userspace; info "模式：无网卡模式（自动选择：$KPROBE_ERR。这个模式不需要 TUN 和内核模块）"
      fi ;;
  esac
}

# ---------- 15. 生成网关配置 ----------
# 网关 = 本机 127.0.0.1 上的 SOCKS5 入口（带随机用户名密码）+ 一个 DNS 入口，出口全部走 WireGuard。
# 内核网卡模式：出口绑定 wg-luodi 网卡并打标记；无网卡模式：sing-box 自己跑 WireGuard（不需要 TUN）。
pick_free_port() { # pick_free_port <排除的端口…> -> 一个 TCP/UDP 都空闲的端口
  _try=0
  while [ "$_try" -lt 100 ]; do
    _try=$((_try + 1))
    _p=$(od -An -tu2 -N2 /dev/urandom | tr -d ' '); _p=$((20000 + _p % 40000))
    case " $* $PORTS " in *" $_p "*) continue ;; esac
    port_listening "$_p" tcp && continue
    port_listening "$_p" udp && continue
    echo "$_p"; return 0
  done
  return 1
}
port_listening() { # port_listening <端口> <tcp|udp>：直接读 /proc，busybox 也能用
  _hex=$(printf '%04X' "$1")
  if [ "$2" = udp ]; then _fs="/proc/net/udp /proc/net/udp6"; _stt=07; else _fs="/proc/net/tcp /proc/net/tcp6"; _stt=0A; fi
  for _f in $_fs; do
    [ -r "$_f" ] || continue
    awk -v port="$_hex" -v st="$_stt" 'NR > 1 { n = split($2, a, ":"); if (toupper(a[n]) == port && toupper($4) == st) f = 1 } END { exit !f }' "$_f" && return 0
  done
  return 1
}
# 这个端口在哪种 IP 上有程序监听：打印 "v4"、"v6"、"v4 v6" 或空。
# 节点程序监听 [::]（Xray / sing-box / Hysteria2 写 0.0.0.0 或不写，默认也是这样）时只出现在 tcp6/udp6 里，
# 这种“双栈”监听 IPv4 和 IPv6 的客户端都能连进来。
port_fams() { # port_fams <端口>
  _hex=$(printf '%04X' "$1"); _r4=""; _r6=""
  for _f in tcp udp tcp6 udp6; do
    [ -r "/proc/net/$_f" ] || continue
    case "$_f" in udp*) _stt=07 ;; *) _stt=0A ;; esac
    if awk -v port="$_hex" -v st="$_stt" 'NR > 1 { n = split($2, a, ":"); if (toupper(a[n]) == port && toupper($4) == st) f = 1 } END { exit !f }' "/proc/net/$_f"; then
      case "$_f" in *6) _r6=v6 ;; *) _r4=v4 ;; esac
    fi
  done
  printf '%s' "$_r4${_r4:+${_r6:+ }}$_r6"
}

# 隧道 MTU：配置里写了就用它，没写用默认值（内核网卡 1420、无网卡 1408）；
# 但不能超过“服务器出网网卡的 MTU − WireGuard 包头”（IPv4 落地 60、IPv6 落地 80）。
# 很多 NAT 小鸡、云服务器网卡 MTU 不到 1500，隧道 MTU 还按 1420 设，大包就被丢：
# 延迟测试正常，网页却打不开或特别慢。
wg_mtu() {
  _m="$WG_MTU"
  if [ -z "$_m" ]; then if [ "$MODE" = kernel ]; then _m=1420; else _m=1408; fi; fi
  _epip="$WG_EP_HOST"
  [ "$WG_EP_KIND" = name ] && _epip=$(_resolve "$WG_EP_HOST" "${EP_FAM:-4}")
  _dev=""
  [ -n "$_epip" ] && _has ip && _dev=$(ip route get "$_epip" $(_epm_arg) 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  _nic=""
  [ -n "$_dev" ] && [ "$_dev" != "$WGL_IFACE" ] && _nic=$(cat "/sys/class/net/$_dev/mtu" 2>/dev/null)
  case "$_nic" in ''|*[!0-9]*) _nic=1500 ;; esac
  case "$_epip" in *:*) _hd=80 ;; *) _hd=60 ;; esac
  [ $((_nic - _hd)) -lt "$_m" ] && _m=$((_nic - _hd))
  # 这条路实测过大包能过的最大 MTU（见 _mtu_probe），记成“标记:MTU”，只对同一条路有效
  if [ "$MODE" = kernel ]; then
    _pin=$(st_get EP_MTU)
    case "$_pin" in "$(_epm):"*) _pin=${_pin#*:}; [ "$_pin" -lt "$_m" ] 2>/dev/null && _m=$_pin ;; esac
  fi
  [ "$_m" -lt 1280 ] && _m=1280
  printf '%s' "$_m"
}

_ep_dev_show() { # 状态页用：WireGuard 连落地机实际走哪张网卡
  _epip="$WG_EP_HOST"
  [ "$WG_EP_KIND" = name ] && _epip=$(_resolve "$WG_EP_HOST" "${EP_FAM:-4}")
  _d=""
  [ -n "$_epip" ] && _has ip && _d=$(ip route get "$_epip" $(_epm_arg) 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  printf '%s' "${_d:-没查到}"
}
# 内核网卡模式：不重建网卡，原地补齐“连落地机走服务器自己网卡”的规则，MTU 不对就改（不断流）。
# 网关配置里不含这些，更新时网关不重启，只靠这里跟上；巡检也会调用（出网网卡 MTU 变了能自动跟上）。
_live_sync() {
  [ "$MODE" = kernel ] || return 0
  [ "$(_epm)" = "$WGL_EPMARK" ] && _ep_rule_sync
  _cur=$(cat "/sys/class/net/$WGL_IFACE/mtu" 2>/dev/null); _want=$(wg_mtu)
  [ -n "$_cur" ] && [ "$_cur" != "$_want" ] || return 0
  ip link set dev "$WGL_IFACE" mtu "$_want" 2>/dev/null && log "网卡 MTU $_cur → $_want"
  return 0
}

write_gw_json() { # write_gw_json <输出文件>
  _mtu=$(wg_mtu)
  # 无网卡模式里，sing-box 自己连落地机：域名用系统 DNS 解析，按服务器有的网络选 IPv4/IPv6
  "$JQ" -n \
    --arg mode "$MODE" --arg iface "$WGL_IFACE" --argjson mark "$WGL_MARK" \
    --arg priv "$WG_PRIV" --arg pub "$WG_PUB" --arg psk "$WG_PSK" \
    --arg host "$WG_EP_HOST" --argjson port "$WG_EP_PORT" \
    --arg addrs "$(_cidr_list "$WG_ADDR")" --arg allowed "$(_cidr_list "$WG_ALLOWED")" \
    --argjson mtu "$_mtu" --argjson ka "$WG_KA" \
    --arg dns "$WG_DNS1" --arg strat "$WG_STRAT" --arg epstrat "$EP_STRAT" \
    --argjson sp "$(st_get SOCKS_PORT)" --argjson dp "$(st_get DNS_PORT)" \
    --arg su "$(st_get SOCKS_USER)" --arg spw "$(st_get SOCKS_PASS)" '
    def words: split(" ") | map(select(length > 0));
    {
      log: { level: "warn", timestamp: true },
      dns: {
        servers: (
          [ ({ type: "udp", tag: "wg-dns", server: $dns }
             + (if $mode == "kernel" then { bind_interface: $iface, routing_mark: $mark } else { detour: "wg" } end)) ]
          + (if $mode == "kernel" then [] else [ { type: "local", tag: "local" } ] end)
        ),
        final: "wg-dns",
        strategy: $strat
      },
      inbounds: [
        { type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: $sp,
          users: [ { username: $su, password: $spw } ] },
        { type: "direct", tag: "dns-in", listen: "127.0.0.1", listen_port: $dp }
      ],
      route: {
        rules: (
          [ { inbound: [ "dns-in" ], action: "hijack-dns" } ]
          # 隧道只支持一种 IP 时，另一种 IP 的目标直接拒绝（客户端会马上改用能用的那种），不会走服务器自己的 IP
          # no_drop：sing-box 默认 30 秒里拒绝超过 50 次就改成“悄悄丢掉”，连接要等超时才失败，
          # 爱用 IPv6 的设备（比如连着有 IPv6 的 Wi-Fi 的 iPad）就会卡得特别慢；加上它就一直马上拒绝
          + (if $strat == "ipv4_only" then [ { ip_cidr: [ "::/0" ], action: "reject", no_drop: true } ]
             elif $strat == "ipv6_only" then [ { ip_cidr: [ "0.0.0.0/0" ], action: "reject", no_drop: true } ]
             else [] end)
        ),
        final: (if $mode == "kernel" then "wg-out" else "wg" end),
        default_domain_resolver: { server: "wg-dns", strategy: $strat }
      }
    }
    + (if $mode == "kernel" then
        { outbounds: [ { type: "direct", tag: "wg-out", bind_interface: $iface, routing_mark: $mark } ] }
      else
        { endpoints: [ {
            type: "wireguard", tag: "wg", system: false, mtu: $mtu,
            address: ($addrs | words), private_key: $priv,
            peers: [ ({ address: $host, port: $port, public_key: $pub,
                        allowed_ips: ($allowed | words), persistent_keepalive_interval: $ka }
                      + (if $psk != "" then { pre_shared_key: $psk } else {} end)) ],
            domain_resolver: { server: "local", strategy: $epstrat }
          } ] }
      end)' > "$1" || return 1
  chmod 600 "$1"
}

# 从保存的状态和配置文件重新读出所有变量（管理命令用）
load_all() {
  installed || die "还没有安装。请先运行安装脚本。"
  parse_conf "$CONF" || die "保存的 WireGuard 配置坏了：$PARSE_ERR 请用 wg-luodi set-conf 换一份。"
  MODE=$(st_get MODE); PORTS=$(st_get PORTS); EP_FAM=$(st_get EP_FAM)
  [ "$EP_FAM" = 6 ] && EP_STRAT=ipv6_only || EP_STRAT=ipv4_only
}

# ---------- 16. 内核网卡模式：建网卡、加专用路由 ----------
# 关键点：Table = off 的效果——不往主路由表加任何东西，服务器默认路由和 SSH 完全不动。
# 只加一条规则：“带标记 51888 的包查 51888 号路由表”，那张表里只有一条“全部走 wg-luodi 网卡”。
# 只有网关程序发出的包带这个标记。
_wg_setconf_file() { # _wg_setconf_file <标记|off>：生成 wg 命令认识的精简配置（去掉 Address、DNS 等 wg-quick 才认识的项）
  _epip="$WG_EP_HOST"
  if [ "$WG_EP_KIND" = name ]; then
    _r=$(_resolve "$WG_EP_HOST" "${EP_FAM:-4}"); [ -n "$_r" ] && _epip="$_r"
  fi
  case "$_epip" in *:*) _epfmt="[$_epip]:$WG_EP_PORT" ;; *) _epfmt="$_epip:$WG_EP_PORT" ;; esac
  printf '[Interface]\nPrivateKey = %s\n' "$WG_PRIV"
  # 不打标记时也要明写 off：setconf 不写这一项就保留网卡上原来的标记（试路时上一个候选的）
  printf 'FwMark = %s\n' "${1:-off}"
  printf '\n[Peer]\nPublicKey = %s\n' "$WG_PUB"
  [ -n "$WG_PSK" ] && printf 'PresharedKey = %s\n' "$WG_PSK"
  printf 'AllowedIPs = %s\nEndpoint = %s\nPersistentKeepalive = %s\n' "$WG_ALLOWED" "$_epfmt" "$WG_KA"
}

# IPv4 和 IPv6 各一份：隧道支持这种 IP，专用表里就是“全部走 wg-luodi 网卡”；
# 隧道不支持（比如落地只给了 IPv4），专用表里就是“此路不通”（unreachable），
# 让带标记的包马上失败，绝不会从服务器自己的 IP 偷偷出去。没带标记的包（SSH、节点回给客户端的包）完全不受影响。
_rules_add() {
  for _f in 4 6; do
    if [ "$_f" = 4 ]; then _on="$WG_HAS4"; else _on="$WG_HAS6"; fi
    if [ "$_on" = 1 ]; then
      ip -$_f route replace default dev "$WGL_IFACE" table "$WGL_TABLE" 2>/dev/null
    else
      ip -$_f route replace unreachable default table "$WGL_TABLE" 2>/dev/null
    fi
    while ip -$_f rule del fwmark "$WGL_MARK" lookup "$WGL_TABLE" pref "$WGL_PREF" 2>/dev/null; do :; done
    ip -$_f rule add fwmark "$WGL_MARK" lookup "$WGL_TABLE" pref "$WGL_PREF" 2>/dev/null
  done
  return 0
}

# 不打断流量地把专用路由补齐：路由用 replace（原地替换），规则只在缺的时候才加。
# 更新时网关不重启，就用它代替“删了重建”。
_rules_sync() {
  for _f in 4 6; do
    if [ "$_f" = 4 ]; then _on="$WG_HAS4"; else _on="$WG_HAS6"; fi
    if [ "$_on" = 1 ]; then
      ip -$_f route replace default dev "$WGL_IFACE" table "$WGL_TABLE" 2>/dev/null
    else
      ip -$_f route replace unreachable default table "$WGL_TABLE" 2>/dev/null
    fi
    ip -$_f rule show 2>/dev/null | grep -q "lookup $WGL_TABLE" \
      || ip -$_f rule add fwmark "$WGL_MARK" lookup "$WGL_TABLE" pref "$WGL_PREF" 2>/dev/null
  done
  return 0
}

# WireGuard 自己连落地机的包（加密后的 UDP）打一个标记，让它从服务器自己的网卡直接出去。
# 服务器上要是装了 L2TP / WARP 之类“全局出口”（策略路由把所有流量拉走，有的还用防火墙封住直连），
# WireGuard 的包会被拉进它们，MTU 变小、多绕一层。所以建网卡时先试：
#   ① 本脚本的标记 51889 + 一条“带它的查主路由表”的规则（优先级 5189，排在它们前面）；
#      服务器装了 L2TP-VPS 时改用它专门留给别的程序直连的标记 0x24682（它的防火墙只放行这个，51889 一定被拦）；
#   ② 都不行：不打标记，走服务器默认的路（和以前一样），MTU 按那条路自动调小。
# 一条路“能用”要同时满足：能握手，而且大包也能过（见 _mtu_probe）。只看握手不够：握手包只有 148 字节，
# 以前就出现过借用 L2TP 的直连标记握手成功、延迟正常、网页却打不开的情况。
# 选好的记在状态里（EP_MARK），以后直接用；别的程序的规则和防火墙一条都不动。
# EP_MARK：空 = 还没选；数字 = 用这个标记；off = 直连都不通，走默认的路；
#          retry = 试的时候落地机怎么都握不上手（多半是落地机暂时不在线），先走默认的路，巡检时再试。
_epm() { # 现在用的标记：数字或 off（试的时候用 EPM_TRY）
  _x=${EPM_TRY:-$(st_get EP_MARK)}
  [ "$MODE" = kernel ] || _x=off
  case "$_x" in '') _x=$WGL_EPMARK ;; *[!0-9]*) _x=off ;; esac
  printf '%s' "$_x"
}
_epm_arg() { _x=$(_epm); [ "$_x" != off ] && printf 'mark %s' "$_x"; }
_ep_rule_sync() {
  _has ip || return 0
  for _f in 4 6; do
    ip -$_f rule show 2>/dev/null | grep -q "^$WGL_EPPREF:" \
      || ip -$_f rule add fwmark "$WGL_EPMARK" lookup main pref "$WGL_EPPREF" 2>/dev/null
  done
  return 0
}
_ep_rule_del() {
  for _f in 4 6; do
    while ip -$_f rule del fwmark "$WGL_EPMARK" lookup main pref "$WGL_EPPREF" 2>/dev/null; do :; done
  done
  return 0
}
# 要试的标记。装了 L2TP-VPS 的服务器只试它的直连标记 0x24682（十进制 149122）：
# 它的路由规则 8906 一直都在、防火墙放行带这个标记的包；本脚本的 51889 会被它的断线保护拦下，白等 8 秒。
_ep_cands() {
  if [ -f "$WGL_L2TP_DIR/v2-owned" ] && ip -"${EP_FAM:-4}" rule show pref 8906 2>/dev/null | grep -q 'fwmark 0x24682 lookup main'; then
    echo 149122
  else
    echo "$WGL_EPMARK"
  fi
}
# 经隧道 ping（带专用标记，走 wg-luodi 网卡；-M do 禁止分片），包大小 = $1 字节的数据。
# 隧道有 IPv4 就 ping 1.1.1.1，只有 IPv6 就 ping 2606:4700:4700::1111（_mtu_probe 里选好 _pt/_pf）。
_ping_tun() { ping $_pf -c 3 -i 0.2 -W 1 -m "$WGL_MARK" -M "do" -s "$1" "$_pt" >/dev/null 2>&1; }
# 这条路大包能不能过。从按网卡算出的 MTU 往下试，找出真能过的最大 MTU，记在 EP_MTU（“标记:MTU”）。
# 返回 0：找到了；1：小包能过、大包都过不去（这条路传不了网页）；
#      2：判断不了（没有支持 -M/-m 的 ping，比如 Alpine 的 busybox；落地不回 ping）。
# IP 包头：IPv4 + ICMP 是 28 字节，IPv6 + ICMPv6 是 48 字节，MTU = 数据大小 + 包头。
_mtu_probe() {
  _has ping || { _tcp_probe; return $?; }
  if [ "$WG_HAS4" = 1 ]; then _pt=1.1.1.1; _pf=""; _ph=28
  elif [ "$WG_HAS6" = 1 ]; then _pt=2606:4700:4700::1111; _pf=-6; _ph=48
  else return 2; fi
  ping -c 1 -W 1 -M "do" -s 16 127.0.0.1 >/dev/null 2>&1 || { _tcp_probe; return $?; }
  _pm=$(_epm); _top=$(wg_mtu)
  ip link set dev "$WGL_IFACE" mtu "$_top" 2>/dev/null
  # 很多落地机不回 ping：这时改用真的下载来判断，免得能直连也被当成“判断不了”、被迫套在别的隧道里走（慢）
  _ping_tun 56 || { _tcp_probe; return $?; }
  for _s in "$_top" 1400 1380 1340 1300 1280; do
    [ "$_s" -le "$_top" ] || continue
    if _ping_tun $((_s - _ph)); then
      st_set EP_MTU "$_pm:$_s"
      [ "$_s" = "$_top" ] || log "这条路大包只能过 $_s，隧道 MTU 调成 $_s"
      return 0
    fi
  done
  return 1
}
# 把 WireGuard 配置（带标记）装进网卡。setconf 会把对端重建一遍，马上重新握手，正好用来试一条路。
_wg_load() { # _wg_load <标记|off>
  mkdir -p "$WGL_WGDIR" && chmod 700 "$WGL_WGDIR"
  _sc="$WGL_WGDIR/$WGL_IFACE-setconf.conf"
  _wg_setconf_file "$1" > "$_sc"; chmod 600 "$_sc"
  wg setconf "$WGL_IFACE" "$_sc"; _rc=$?
  rm -f "$_sc"
  return $_rc
}
_hs_wait() { # _hs_wait <秒>：这么多秒内和落地机握上手返回 0
  _i=0
  while [ "$_i" -lt "$1" ]; do
    _hs=$(wg show "$WGL_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    [ -n "$_hs" ] && [ "$_hs" != 0 ] && return 0
    _i=$((_i + 1)); sleep 1
  done
  return 1
}
_ep_pick() {
  st_set EP_MTU ""
  for EPM_TRY in $(_ep_cands); do
    [ "$EPM_TRY" = "$WGL_EPMARK" ] && _ep_rule_sync
    _wg_load "$EPM_TRY" >/dev/null 2>&1 || continue
    _hs_wait 8 || continue
    _mtu_probe; _pr=$?
    # 本脚本自己的标记：判断不了大包时照旧用（和以前一样）；借用 L2TP 的直连标记：必须确认大包能过才用。
    if [ "$_pr" = 0 ] || { [ "$_pr" = 2 ] && [ "$EPM_TRY" = "$WGL_EPMARK" ]; }; then
      [ "$EPM_TRY" = "$WGL_EPMARK" ] || _ep_rule_del
      st_set EP_MARK "$EPM_TRY"; st_set EP_CHECK 3; log "连落地机用标记 $EPM_TRY（走 $(_ep_dev_show)）"
      EPM_TRY=""; return 0
    fi
    st_set EP_MTU ""
    if [ "$_pr" = 1 ]; then log "标记 $EPM_TRY 能握手，但大包过不去，不用这条路"
    else log "标记 $EPM_TRY 能握手，但没法确认大包能过（落地不回 ping），不用这条路"; fi
  done
  _ep_rule_del
  EPM_TRY=off; _wg_load off
  if _hs_wait 8; then
    _mtu_probe
    st_set EP_MARK off; log "直连不可用，连落地机走服务器默认的路（$(_ep_dev_show)）"
  else
    st_set EP_MARK retry; log "落地机怎么都握不上手（可能暂时不在线），先走默认的路，巡检时再试"
  fi
  st_set EP_CHECK 3
  EPM_TRY=""
  return 0
}

# 不靠 ping 的办法：curl 绑在 wg-luodi 网卡上经隧道下载。TCP 会按网卡 MTU 把包塞满，
# 能完整下载 2MB 就说明这么大的包过得去。先用 MTU 1280 访问一个很小的网页，确认隧道本身能上网，
# 再从当前 MTU 往下试 1340、1280。返回值和 _mtu_probe 一样（0 找到 / 1 大包过不去 / 2 判断不了）。
_curl_tun() { _to 25 curl -4 -fsS -o /dev/null --interface "$WGL_IFACE" --connect-timeout 8 --max-time 20 "$1" 2>/dev/null; }
_tcp_probe() {
  [ "$WG_HAS4" = 1 ] && _has curl || return 2
  _pm=$(_epm); _top=$(wg_mtu)
  ip link set dev "$WGL_IFACE" mtu 1280 2>/dev/null
  if ! _curl_tun "$WGL_TRACE_URL"; then ip link set dev "$WGL_IFACE" mtu "$_top" 2>/dev/null; return 2; fi
  for _s in "$_top" 1340 1280; do
    [ "$_s" -le "$_top" ] || continue
    ip link set dev "$WGL_IFACE" mtu "$_s" 2>/dev/null
    if _curl_tun "$WGL_PROBE_URL"; then
      st_set EP_MTU "$_pm:$_s"
      [ "$_s" = "$_top" ] || log "这条路大包只能过 $_s（下载实测），隧道 MTU 调成 $_s"
      return 0
    fi
  done
  ip link set dev "$WGL_IFACE" mtu "$_top" 2>/dev/null
  return 1
}

kernel_up() {
  _has modprobe && modprobe wireguard >/dev/null 2>&1
  ip link del dev "$WGL_IFACE" >/dev/null 2>&1
  ip link add dev "$WGL_IFACE" type wireguard || { err "建不了 WireGuard 网卡"; return 1; }
  # 回来的包从 wg-luodi 进来，严格的“反向路径检查”会把它当成假包丢掉，这张网卡单独改成宽松模式
  echo 2 > "/proc/sys/net/ipv4/conf/$WGL_IFACE/rp_filter" 2>/dev/null
  # Ubuntu 新版自带 wg 的 AppArmor 规则：wg 只能读 /etc/wireguard/ 里的文件，
  # 放别处会报 “fopen: Permission denied”，所以临时配置写到这个目录里（_wg_load 里）
  if [ "$(_epm)" = "$WGL_EPMARK" ]; then _ep_rule_sync; else _ep_rule_del; fi
  if ! _wg_load "$(_epm)"; then
    ip link del dev "$WGL_IFACE" >/dev/null 2>&1; err "WireGuard 配置装不进网卡"; return 1
  fi
  for _a in $WG_ADDR4; do ip -4 addr add "$_a" dev "$WGL_IFACE" || { ip link del dev "$WGL_IFACE"; return 1; }; done
  for _a in $WG_ADDR6; do ip -6 addr add "$_a" dev "$WGL_IFACE" 2>/dev/null; done
  ip link set dev "$WGL_IFACE" mtu "$(wg_mtu)" up || { ip link del dev "$WGL_IFACE"; return 1; }
  _rules_add
  # 还没选过连落地机的路：现在试（第一次装、更新、换配置、换模式后）
  # 选路时留一个标记文件（里面是进程号）：状态页能显示“正在选路”，巡检也不会把正在启动的网关当成挂了去重启。
  case "$(st_get EP_MARK)" in ''|retry)
    echo $$ > "$WGL_DIR/picking"
    _ep_pick; ip link set dev "$WGL_IFACE" mtu "$(wg_mtu)" 2>/dev/null
    rm -f "$WGL_DIR/picking" ;;
  esac
  log "内核网卡 $WGL_IFACE 已建好"
}

kernel_down() {
  for _f in 4 6; do
    while ip -$_f rule del fwmark "$WGL_MARK" lookup "$WGL_TABLE" pref "$WGL_PREF" 2>/dev/null; do :; done
    ip -$_f route flush table "$WGL_TABLE" 2>/dev/null
  done
  _ep_rule_del
  ip link del dev "$WGL_IFACE" 2>/dev/null
  return 0
}

# 巡检用：网卡在、规则在就什么都不做；规则被别的程序清掉了就补上；网卡没了返回 1（让服务重启）
kernel_ensure() {
  ip link show dev "$WGL_IFACE" >/dev/null 2>&1 || return 1
  if ! ip -4 rule show 2>/dev/null | grep -q "lookup $WGL_TABLE"; then _rules_add; log "专用路由规则丢了，已补回"; fi
  if ! ip -4 route show table "$WGL_TABLE" 2>/dev/null | grep -q default; then _rules_add; log "专用路由表丢了，已补回"; fi
  # IPv6 那一份（机器有 IPv6 才查；没有 IPv6 的内核会直接报错，不用管）
  if [ -e /proc/net/if_inet6 ] && ! ip -6 rule show 2>/dev/null | grep -q "lookup $WGL_TABLE"; then _rules_add; log "IPv6 专用路由规则丢了，已补回"; fi
  _live_sync
  # 用着直连标记却很久没握手（比如别的程序改了防火墙）：清掉选择，让网关重启时重新试
  _hs=$(wg show "$WGL_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  # 选路办法升级后重新选一次（网关重启，隧道会短暂重连一次）：
  #   1.1.13 及以前只看握手、没试过大包（EP_CHECK 不是 2/3）；
  #   1.1.16 及以前只会用 ping 试大包，落地不回 ping 时被迫套在别的隧道里走（off 且 EP_CHECK 不是 3）。
  _ck=$(st_get EP_CHECK)
  case "$(st_get EP_MARK)" in
    ''|retry) ;;
    off) if [ "$_ck" != 3 ]; then st_set EP_MARK ""; log "按新办法（ping 不通就实际下载试）重新选一次连落地机的路"; return 1; fi ;;
    *) if [ "$_ck" != 2 ] && [ "$_ck" != 3 ]; then st_set EP_MARK ""; log "按新办法（握手 + 大包都要通）重新选一次连落地机的路"; return 1; fi ;;
  esac
  # 上次没选成（retry）也在这里重试：这时隧道本来就不通，重启网关不影响什么
  case "$(st_get EP_MARK)" in off) ;; *)
    if [ -n "$_hs" ] && { [ "$_hs" = 0 ] || [ $(($(date +%s) - _hs)) -gt 300 ]; }; then
      st_set EP_MARK ""; log "连落地机很久没握手，重新选路"; return 1
    fi ;;
  esac
  # 落地机是域名、而且很久没握手：重新解析一次（落地机换了 IP 时自动跟上）
  if [ "$WG_EP_KIND" = name ] && _has wg; then
    _hs=$(wg show "$WGL_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    _now=$(date +%s)
    if [ -z "$_hs" ] || [ "$_hs" = 0 ] || [ $((_now - _hs)) -gt 300 ]; then
      _r=$(_resolve "$WG_EP_HOST" "${EP_FAM:-4}")
      if [ -n "$_r" ]; then
        case "$_r" in *:*) _r="[$_r]" ;; esac
        wg set "$WGL_IFACE" peer "$WG_PUB" endpoint "$_r:$WG_EP_PORT" 2>/dev/null
      fi
    fi
  fi
  return 0
}

# ---------- 17. 改节点配置（核心） ----------
# 做法：给“监听在 WireGuard 端口上的入站”加一个标签，再加一条路由规则“这些入站 → 出站 wg-luodi”，
# 出站 wg-luodi 就是本机网关（127.0.0.1 上的 SOCKS5）。其它入站一个字都不动。
# 每次都是“先删掉我们以前加的，再按现在的端口重新加”，所以重复运行结果一样，删端口也是同一套逻辑。
# 我们加的东西都带 wg-luodi 字样，卸载时只删这些。
JQ_COMMON='
def wgp: $ports | map(tostring);
def inlist($p): (wgp | map(select(. == $p)) | length) > 0;
def ours: ((. // "") | tostring | startswith("wg-luodi-in-"));
'
JQ_XRAY="$JQ_COMMON"'
def hit: ((.port // "") | tostring) as $p | inlist($p);
def strip:
  (if (.inbounds | type) == "array" then .inbounds |= map(if (.tag | ours) then del(.tag) else . end) else . end)
  | (if (.outbounds | type) == "array" then .outbounds |= map(select((.tag // "") != "wg-luodi")) else . end)
  | (if (.routing.rules | type) == "array" then .routing.rules |= map(select((.outboundTag // "") != "wg-luodi")) else . end)
  | (if .routing == {"rules": []} then del(.routing) else . end);
strip
| if ([.inbounds[]? | select(hit)] | length) == 0 then .
  else
    .inbounds |= map(if hit then .tag = (.tag // ("wg-luodi-in-" + (.port | tostring))) else . end)
    | ([.inbounds[] | select(hit) | .tag]) as $tags
    | .outbounds = ((.outbounds // []) | if length == 0 then [{protocol: "freedom", tag: "direct"}] else . end) + [$ob]
    | .routing = ((.routing // {}) | .rules = ([{type: "field", inboundTag: $tags, outboundTag: "wg-luodi"}] + (.rules // [])))
  end'
JQ_SB="$JQ_COMMON"'
def hit: ((.listen_port // "") | tostring) as $p | inlist($p);
def strip:
  (if (.inbounds | type) == "array" then .inbounds |= map(if (.tag | ours) then del(.tag) else . end) else . end)
  | (if (.outbounds | type) == "array" then .outbounds |= map(select((.tag // "") != "wg-luodi")) else . end)
  | (if (.route.rules | type) == "array" then .route.rules |= map(select((.outbound // "") != "wg-luodi")) else . end)
  | (if .route == {"rules": []} then del(.route) else . end);
strip
| if ([.inbounds[]? | select(hit)] | length) == 0 then .
  else
    .inbounds |= map(if hit then .tag = (.tag // ("wg-luodi-in-" + (.listen_port | tostring))) else . end)
    | ([.inbounds[] | select(hit) | .tag]) as $tags
    | .outbounds = ((.outbounds // []) | if length == 0 then [{type: "direct", tag: "direct"}] else . end) + [$ob]
    | .route = ((.route // {}) | .rules = ((.rules // []) as $r
        | ([range(0; $r | length) | select(($r[.].action // "") != "sniff")] | .[0] // ($r | length)) as $i
        | $r[:$i] + [{inbound: $tags, outbound: "wg-luodi"}] + $r[$i:]))
  end'

# 网关的 SOCKS5 出站，三种程序各写各的格式
_ob_xray() { # _ob_xray new|old
  if [ "$1" = new ]; then
    "$JQ" -nc --argjson sp "$(st_get SOCKS_PORT)" --arg u "$(st_get SOCKS_USER)" --arg p "$(st_get SOCKS_PASS)" \
      '{tag: "wg-luodi", protocol: "socks", settings: {address: "127.0.0.1", port: $sp, user: $u, pass: $p}}'
  else
    "$JQ" -nc --argjson sp "$(st_get SOCKS_PORT)" --arg u "$(st_get SOCKS_USER)" --arg p "$(st_get SOCKS_PASS)" \
      '{tag: "wg-luodi", protocol: "socks", settings: {servers: [{address: "127.0.0.1", port: $sp, users: [{user: $u, pass: $p}]}]}}'
  fi
}
_ob_sb() {
  "$JQ" -nc --argjson sp "$(st_get SOCKS_PORT)" --arg u "$(st_get SOCKS_USER)" --arg p "$(st_get SOCKS_PASS)" \
    '{type: "socks", tag: "wg-luodi", server: "127.0.0.1", server_port: $sp, version: "5", username: $u, password: $p}'
}
_ports_json() { # "a b" -> [a,b]
  printf '%s\n' $1 | awk 'BEGIN { printf "[" } /^[0-9]+$/ { printf "%s%s", (n++ ? "," : ""), $1 } END { printf "]" }'
}

# Hysteria2（YAML）：在文件末尾加一段带标记的 outbounds + resolver；删的时候按标记整段删。
# Hysteria2 不能按“入站端口”分流，所以这个实例（一个端口）整个走 WireGuard。
hy_strip() { awk '/^# wg-luodi begin/ { skip = 1 } !skip { print } /^# wg-luodi end/ { skip = 0 }' "$1"; }
hy_block() { # hy_block <是否加 resolver 1|0>
  printf '# wg-luodi begin（WireGuard 落地：wg-luodi 自动加的，卸载时会自动删掉，请不要手动改这一段）\n'
  printf 'outbounds:\n  - name: wg-luodi\n    type: socks5\n    socks5:\n      addr: 127.0.0.1:%s\n      username: %s\n      password: %s\n' \
    "$(st_get SOCKS_PORT)" "$(st_get SOCKS_USER)" "$(st_get SOCKS_PASS)"
  if [ "$1" = 1 ]; then
    printf 'resolver:\n  type: udp\n  udp:\n    addr: 127.0.0.1:%s\n    timeout: 4s\n' "$(st_get DNS_PORT)"
  fi
  printf '# wg-luodi end\n'
}

# transform <类型> <配置> <要走 WG 的端口> <输出文件> [xray 出站格式 new|old]
# 返回 0 = 生成成功；2 = 不能自动改（原因在 TF_ERR）
transform() {
  TF_ERR=""
  case "$1" in
    xray)
      "$JQ" --argjson ports "$(_ports_json "$3")" --argjson ob "$(_ob_xray "${5:-old}")" "$JQ_XRAY" "$2" > "$4" 2>/dev/null \
        || { TF_ERR="不是标准 JSON（可能带注释），jq 读不了"; return 2; } ;;
    sing-box)
      "$JQ" --argjson ports "$(_ports_json "$3")" --argjson ob "$(_ob_sb)" "$JQ_SB" "$2" > "$4" 2>/dev/null \
        || { TF_ERR="不是标准 JSON（可能带注释），jq 读不了"; return 2; } ;;
    hysteria)
      hy_strip "$2" > "$4"
      if [ -n "$3" ]; then
        if grep -q '^outbounds:' "$4"; then TF_ERR="配置里已经有你自己写的 outbounds，为了不弄坏它，没有自动改"; return 2; fi
        _res=1; grep -q '^resolver:' "$4" && _res=0
        [ -s "$4" ] && [ "$(tail -c 1 "$4" | od -An -c | tr -d ' ')" != '\n' ] && printf '\n' >> "$4"
        hy_block "$_res" >> "$4"
      fi ;;
    *) TF_ERR="不认识的类型"; return 2 ;;
  esac
  return 0
}

# 两份配置意思一样吗（JSON 比较内容，不管空格和顺序；YAML 逐字节比较）
same_cfg() { # same_cfg <类型> <a> <b>
  if [ "$1" = hysteria ]; then cmp -s "$2" "$3"; return; fi
  _ha=$("$JQ" -S -c . "$2" 2>/dev/null) || return 1
  _hb=$("$JQ" -S -c . "$3" 2>/dev/null) || return 1
  [ "$_ha" = "$_hb" ]
}

# 用节点自己的程序检查配置（xray -test / sing-box check）。Hysteria2 没有检查命令，靠重启后看服务是否正常。
validate_cfg() { # validate_cfg <类型> <配置> <程序>
  VAL_ERR=""
  case "$1" in
    xray)
      [ -x "$3" ] || return 3
      VAL_ERR=$(_to 30 "$3" -test -config "$2" </dev/null 2>&1) && return 0
      VAL_ERR=$(printf '%s' "$VAL_ERR" | grep -iv 'reading config' | tail -n 3 | tr '\n' ' '); return 1 ;;
    sing-box)
      [ -x "$3" ] || return 3
      VAL_ERR=$(_to 30 "$3" check -c "$2" </dev/null 2>&1) && return 0
      VAL_ERR=$(printf '%s' "$VAL_ERR" | tail -n 3 | tr '\n' ' '); return 1 ;;
    *) return 3 ;;
  esac
}

_bkey() { printf '%s' "$1" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g'; }
backup_cfg() { # 第一次改之前存一份原样（.orig），每次改之前再存一份（.last）
  mkdir -p "$WGL_DIR/backup"; chmod 700 "$WGL_DIR/backup"
  _bk="$WGL_DIR/backup/$(_bkey "$1")"
  [ -f "$_bk.orig" ] || cp -p "$1" "$_bk.orig"
  cp -p "$1" "$_bk.last"
}
# 写回配置：用 cat > 原文件，保留原来的属主和权限（Hysteria2 节点可能是普通用户在跑）
put_cfg() { cat "$2" > "$1"; }

reg_add() { # 记下改过的配置，卸载时一个不漏
  touch "$REG"; chmod 600 "$REG"
  grep -qF "|$2|" "$REG" 2>/dev/null && return 0
  printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$REG"
}

svc_restart() { # svc_restart <服务类型> <服务名>：重启并确认起来了。返回 3 = 没法自动重启
  case "$1" in
    systemd)
      systemctl restart "$2" </dev/null >/dev/null 2>&1
      sleep 3
      systemctl is-active --quiet "$2" ;;
    openrc)
      rc-service "$2" restart </dev/null >/dev/null 2>&1
      sleep 3
      rc-service "$2" status </dev/null >/dev/null 2>&1 ;;
    *) return 3 ;;
  esac
}

# 巡检时：同一个配置一小时内被别的程序改回去 5 次以上，就不再自动改它（防止和别的脚本“打架”反复重启节点）。
# 只在巡检（wg-luodi check）里计数；你手动加减端口、重新应用不算。
_flap_ok() {
  [ "${_IN_CHECK:-0}" = 1 ] || return 0
  _ff="$WGL_DIR/backup/$(_bkey "$1").flap"; _now=$(date +%s)
  _cnt=0; _t0=$_now
  [ -f "$_ff" ] && read -r _t0 _cnt < "$_ff"
  [ $((_now - _t0)) -gt 3600 ] && { _t0=$_now; _cnt=0; }
  [ "$_cnt" -ge 5 ] && return 1
  mkdir -p "$WGL_DIR/backup"; echo "$_t0 $((_cnt + 1))" > "$_ff"
}
_failed_mark() { mkdir -p "$WGL_DIR"; echo "$(_sha256 "$1") $1" >> "$WGL_DIR/failed"; }
_failed_skip() { [ -f "$WGL_DIR/failed" ] && grep -qF "$(_sha256 "$1") $1" "$WGL_DIR/failed"; }

# apply_one：让一个配置和现在的端口列表一致。
# 参数：类型 配置 服务类型 服务名 程序 别名端口 动作(apply|strip) 是否重启(1|0)
# 结果写在 AP_MSG；返回 0 = 已经是对的或改好了；1 = 失败（已还原）；2 = 跳过
apply_one() {
  _k="$1"; _c="$2"; _st="$3"; _sn="$4"; _b="$5"; _al="$6"; _act="$7"; _rs="$8"
  AP_MSG=""; AP_CHANGED=0; _ok=0
  if [ "$_k" = panel ]; then
    AP_MSG="这是面板（x-ui / 3x-ui 等）管理的配置，面板每次都会重新生成，脚本改不了。请在面板里给这个入站加一条路由：出站用 SOCKS5 127.0.0.1:$(st_get SOCKS_PORT)，用户名 $(st_get SOCKS_USER)，密码见 /etc/wg-luodi/state"
    return 2
  fi
  [ -f "$_c" ] || { AP_MSG="配置文件不见了"; return 2; }
  if [ "$_act" = strip ]; then _wp=""; else _wp=$(cfg_wg_ports "$_k" "$_c" "$_al"); fi
  _new="$_c.wgl-new"; [ "$_k" != hysteria ] && _new="$_c.wgl-new.json"
  _fmts="old"; [ "$_k" = xray ] && [ -n "$_wp" ] && [ -x "$_b" ] && _fmts="new old"
  # 第一遍：任何一种写法和现在的配置一样，就说明已经是对的，什么都不用做
  for _fmt in $_fmts; do
    transform "$_k" "$_c" "$_wp" "$_new" "$_fmt" || { rm -f "$_new"; AP_MSG="$TF_ERR"; return 2; }
    if same_cfg "$_k" "$_c" "$_new"; then
      rm -f "$_new"
      if [ -n "$_wp" ]; then AP_MSG="已经在走 WireGuard（端口 $_wp）"; else AP_MSG="不涉及"; fi
      return 0
    fi
  done
  [ "$_rs" = 1 ] && _failed_skip "$_c" && { rm -f "$_new"; AP_MSG="上次改这个配置失败过，配置没变化，先跳过（改了配置后会再试）"; return 2; }
  # 卸载时：如果除了我们加的东西以外，配置和第一次改之前一模一样，就把原文件逐字节放回去
  _orig="$WGL_DIR/backup/$(_bkey "$_c").orig"
  if [ "$_act" = strip ] && [ -f "$_orig" ]; then
    _o2="$_c.wgl-orig"; [ "$_k" != hysteria ] && _o2="$_c.wgl-orig.json"
    transform "$_k" "$_c" "" "$_new" old && transform "$_k" "$_orig" "" "$_o2" old && same_cfg "$_k" "$_new" "$_o2" \
      && cat "$_orig" > "$_new"
    rm -f "$_o2"
    validate_cfg "$_k" "$_new" "$_b"
    case $? in 0|3) _fmts="" ; _ok=1 ;; *) _fmts="old" ;; esac
  fi
  # 第二遍：生成新配置并检查，通过了才用（Xray 新版出站写法不认就换老写法）
  for _fmt in $_fmts; do
    transform "$_k" "$_c" "$_wp" "$_new" "$_fmt" || { rm -f "$_new"; AP_MSG="$TF_ERR"; return 2; }
    validate_cfg "$_k" "$_new" "$_b"
    case $? in
      0|3) _ok=1; break ;;
    esac
  done
  if [ "$_ok" = 0 ]; then
    rm -f "$_new"; _failed_mark "$_c"
    AP_MSG="改完的配置没通过检查，原配置没动：$VAL_ERR"
    log "校验失败 $_c：$VAL_ERR"
    return 1
  fi
  [ "$_rs" = 1 ] && [ "$_act" != strip ] && { _flap_ok "$_c" || { rm -f "$_new"; AP_MSG="这个配置一小时内被别的程序改回去太多次了，暂停自动修改"; return 2; }; }
  backup_cfg "$_c"
  put_cfg "$_c" "$_new"; rm -f "$_new"
  AP_CHANGED=1
  [ -n "$_wp" ] && reg_add "$_k" "$_c" "$_st" "$_sn" "$_b" "$_al"
  if [ "$_rs" = 1 ]; then
    svc_restart "$_st" "$_sn"
    case $? in
      0) ;;
      3) AP_MSG="配置已改好，但找不到它的服务，没法自动重启：请你手动重启这个节点程序"; log "已改 $_c（需手动重启）"; return 0 ;;
      *)
        # 重启失败：换回改之前的配置，再重启一次，保证节点不被弄坏
        cat "$WGL_DIR/backup/$(_bkey "$_c").last" > "$_c"
        svc_restart "$_st" "$_sn"
        _failed_mark "$_c"
        AP_MSG="改完后节点起不来，已经换回原来的配置并重启"
        log "重启失败已还原 $_c"
        return 1 ;;
    esac
  fi
  if [ -n "$_wp" ]; then AP_MSG="已改好：端口 $_wp 走 WireGuard"; else AP_MSG="已去掉 WireGuard 设置"; fi
  log "$AP_MSG $_c"
  return 0
}

# 对所有找到的节点做一遍 apply_one，并打印结果
apply_all() { # apply_all <apply|strip> <是否重启 1|0>
  _list=$(discover_nodes)
  if [ -z "$_list" ]; then
    say "  这台服务器上暂时没有找到节点。以后在这些端口上搭的节点会自动走 WireGuard。"
    return 0
  fi
  printf '%s\n' "$_list" | while IFS='|' read -r k c st sn b al; do
    [ -n "$k" ] || continue
    apply_one "$k" "$c" "$st" "$sn" "$b" "$al" "$1" "$2"; _r=$?
    _mp=$(cfg_main_port "$k" "$c" 2>/dev/null)
    _label="$(kind_cn "$k") 端口 ${_mp:-?}（$c）"
    case $_r in
      0) [ "$AP_CHANGED" = 1 ] && info "$_label：$AP_MSG" || { [ "$QUIET" = 1 ] || say "  - $_label：$AP_MSG"; } ;;
      1) err "$_label：$AP_MSG" ;;
      *) warn "$_label：$AP_MSG" ;;
    esac
  done
}

# ---------- 17b. 只听 IPv4 的节点改成双栈 ----------
# 走 WireGuard 的端口上，节点要是只听 IPv4（Hysteria2 写了 0.0.0.0:端口、sing-box 写了 0.0.0.0），
# 客户端填服务器的 IPv6 就连不进来。服务器能用 IPv6 时，自动把它改成双栈：
#   Hysteria2：listen 0.0.0.0:端口 → :端口；Xray / sing-box：这些端口的入站 listen "0.0.0.0" → "::"。
# 只改“端口正在 IPv4 上听、IPv6 上没人听”的节点（停着的节点不碰）。改之前备份，改完重启这个节点，
# 确认 IPv6 上也在听了才算成功；起不来就换回原配置再重启，并记下来，配置没变就不再试。

# 服务器能不能“听” IPv6：网卡上有全局 IPv6（公网的、fd 开头的内网地址都算：NAT 小鸡的外网 IPv6
# 转发进来时落在内网地址上），IPv6 没被关掉，系统也没设 bindv6only=1（那样 :: 收不到 IPv4）。
_v6_listen_ok() {
  [ -r /proc/net/if_inet6 ] || return 1
  [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 1 ] && return 1
  [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)" = 1 ] && return 1
  awk -v skip="$WGL_IFACE" '$4 == "00" && $6 != "lo" && $6 != skip { f = 1 } END { exit !f }' /proc/net/if_inet6 2>/dev/null
}

# 生成“改成双栈”的配置：v6_dual_cfg <类型> <配置> <端口…> <输出>；没有能改的地方返回 1
v6_dual_cfg() {
  case "$1" in
    hysteria)
      grep -Eq "^listen:[[:space:]]*[\"']?0\.0\.0\.0:" "$2" || return 1
      # 整行重写成 listen: ":端口"（带引号，冒号开头的值不加引号有的 YAML 读不了）
      awk -v q="'" '/^listen:/ && !done {
          v = $0; sub(/\r$/, "", v); sub(/^listen:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v)
          gsub("^[\"" q "]|[\"" q "]$", "", v); sub(/^0\.0\.0\.0:/, ":", v)
          print "listen: \"" v "\""; done = 1; next }
        { print }' "$2" > "$4" || return 1 ;;
    xray|sing-box)
      if [ "$1" = xray ]; then _pk=port; else _pk=listen_port; fi
      "$JQ" --argjson ports "$(_ports_json "$3")" --arg pk "$_pk" '
        ($ports | map(tostring)) as $p
        | .inbounds |= map(
            ((.[$pk] // "") | tostring) as $x
            | if ([$p[] | select(. == $x)] | length) > 0 and (.listen // "") == "0.0.0.0" then .listen = "::" else . end)' \
        "$2" > "$4" 2>/dev/null || return 1
      same_cfg "$1" "$2" "$4" && return 1 ;;
    *) return 1 ;;
  esac
  return 0
}
_v6_failed() { [ -f "$WGL_DIR/v6failed" ] && grep -qF "$(_sha256 "$1") $1" "$WGL_DIR/v6failed"; }
_v6_mark()   { mkdir -p "$WGL_DIR"; echo "$(_sha256 "$1") $1" >> "$WGL_DIR/v6failed"; }

v6_fix_all() {
  _v6_listen_ok || return 0
  discover_nodes | while IFS='|' read -r k c st sn b al; do
    [ -n "$k" ] && [ "$k" != panel ] && [ -f "$c" ] || continue
    _wp=$(cfg_wg_ports "$k" "$c" "$al"); [ -n "$_wp" ] || continue
    _need=""
    for _p in $_wp; do [ "$(port_fams "$_p")" = v4 ] && _need="$_need $_p"; done
    [ -n "$_need" ] || continue
    _v6_failed "$c" && continue
    _label="$(kind_cn "$k") 端口$_need"
    _n="$c.wgl-v6"; [ "$k" != hysteria ] && _n="$c.wgl-v6.json"
    if ! v6_dual_cfg "$k" "$c" "$_need" "$_n"; then
      rm -f "$_n"; _v6_mark "$c"
      warn "$_label 只听 IPv4，但配置里的监听地址不是 0.0.0.0，没法自动改。想让 IPv6 也能连，请手动把监听地址改成 ::（Hysteria2 写 :端口）"
      log "双栈：没法自动改 $c"
      continue
    fi
    validate_cfg "$k" "$_n" "$b"
    case $? in 0|3) ;; *)
      rm -f "$_n"; _v6_mark "$c"
      warn "$_label：改成双栈的配置没通过检查，原配置没动：$VAL_ERR"
      continue ;;
    esac
    mkdir -p "$WGL_DIR/backup"; chmod 700 "$WGL_DIR/backup"
    _vb="$WGL_DIR/backup/$(_bkey "$c").v6bak"
    cp -p "$c" "$_vb" || { rm -f "$_n"; continue; }
    put_cfg "$c" "$_n"; rm -f "$_n"
    svc_restart "$st" "$sn"; _rc=$?
    _ok=0
    if [ "$_rc" = 0 ]; then
      _i=0
      while [ "$_i" -lt 10 ]; do
        _ok=1; for _p in $_need; do case "$(port_fams "$_p")" in *v6*) ;; *) _ok=0 ;; esac; done
        [ "$_ok" = 1 ] && break
        _i=$((_i + 1)); sleep 1
      done
    fi
    if [ "$_ok" = 1 ]; then
      info "$_label：原来只听 IPv4（客户端填 IPv6 连不上），已改成同时听 IPv4 和 IPv6，并重启了这个节点。原配置备份在 $_vb"
      log "双栈：已改 $c（$_need）"
    else
      cat "$_vb" > "$c"
      [ "$_rc" = 3 ] || svc_restart "$st" "$sn"
      _v6_mark "$c"
      if [ "$_rc" = 3 ]; then
        warn "$_label 只听 IPv4。找不到这个节点的服务、没法自动重启，所以没改。想让 IPv6 也能连，请手动把监听地址改成 :: 再重启它"
      else
        err "$_label：改成双栈后节点没起来（或 IPv6 上还是没在听），已换回原来的配置并重启"
      fi
      log "双栈：失败已还原 $c"
    fi
  done
}

# 节点启动时的钩子（VPS-dajianjiedian 的节点服务启动前会调用 wg-luodi hook 编号）。
# 只改配置、不重启（服务马上就要启动）。任何情况下都返回 0，绝不拖累节点启动。
do_hook() {
  QUIET=1
  installed || exit 0
  find_jq || exit 0
  PORTS=$(st_get PORTS)
  case "$1" in ''|*[!0-9]*) exit 0 ;; esac
  INIT=$(st_get INIT)
  _line=$(DISCOVER_XN_ONLY=1 discover_nodes 2>/dev/null | grep -F "$XN_NODES/$1/" | head -n 1)
  [ -n "$_line" ] || exit 0
  IFS='|' read -r k c st sn b al <<EOF_HOOK
$_line
EOF_HOOK
  # 先不加锁看一眼：已经是对的就马上退出（最常见的情况）
  _wp=$(cfg_wg_ports "$k" "$c" "$al")
  _tmp="$c.wgl-chk"; [ "$k" != hysteria ] && _tmp="$c.wgl-chk.json"
  for _fmt in new old; do
    if transform "$k" "$c" "$_wp" "$_tmp" "$_fmt" && same_cfg "$k" "$c" "$_tmp"; then rm -f "$_tmp"; exit 0; fi
    [ "$k" = xray ] || break
  done
  rm -f "$_tmp"
  _lock 5 || exit 0
  apply_one "$k" "$c" "$st" "$sn" "$b" "$al" apply 0
  _unlock
  exit 0
}

# ---------- 18. 开机自启 ----------
# 网关服务 wg-luodi：启动前（内核网卡模式）建网卡和专用路由，然后运行 sing-box 网关；停止后拆掉网卡。
# 巡检 wg-luodi-watch：每 2 分钟跑一次 wg-luodi check。
# systemd 用 service + timer；Alpine 的 OpenRC 用 supervise-daemon（程序挂了自动拉起）。
# 另外给 VPS-dajianjiedian 的节点服务加一个“启动前钩子”（systemd drop-in），以后重建的节点启动时自动走 WG。
_sd_ver() { systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 + 0 }'; }

install_services() {
  case "$INIT" in
    systemd)
      cat > "$WGL_SD/wg-luodi.service" <<EOF
[Unit]
Description=wg-luodi WireGuard landing gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$WGL_CMD up
ExecStart=$SB run -c $GW_JSON
ExecStopPost=-$WGL_CMD down
Restart=always
RestartSec=5
# 启动前要选连落地机的路（握手 + 试大包），网络慢时可能超过默认的 90 秒
TimeoutStartSec=180
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      cat > "$WGL_SD/wg-luodi-watch.service" <<EOF
[Unit]
Description=wg-luodi check (re-apply WireGuard routes to nodes)

[Service]
Type=oneshot
ExecStart=$WGL_CMD check
EOF
      cat > "$WGL_SD/wg-luodi-watch.timer" <<EOF
[Unit]
Description=wg-luodi check every 2 minutes

[Timer]
OnBootSec=90s
OnUnitActiveSec=2min
AccuracySec=20s

[Install]
WantedBy=timers.target
EOF
      chmod 644 "$WGL_SD/wg-luodi.service" "$WGL_SD/wg-luodi-watch.service" "$WGL_SD/wg-luodi-watch.timer"
      # VPS-dajianjiedian 节点的启动前钩子。“+”表示用 root 身份跑（Hysteria2 节点是普通用户）；老 systemd（<231）不认“+”。
      _plus=""; [ "$(_sd_ver)" -ge 231 ] 2>/dev/null && _plus="+"
      for _t in xray-node singbox-node hysteria-node; do
        mkdir -p "$WGL_SD/$_t@.service.d"; chmod 755 "$WGL_SD/$_t@.service.d"
        printf '[Service]\nExecStartPre=-%s%s hook %%i\n' "$_plus" "$WGL_CMD" > "$WGL_SD/$_t@.service.d/wg-luodi.conf"
        chmod 644 "$WGL_SD/$_t@.service.d/wg-luodi.conf"
      done
      systemctl daemon-reload >/dev/null 2>&1
      systemctl enable wg-luodi.service >/dev/null 2>&1
      systemctl enable wg-luodi-watch.timer >/dev/null 2>&1
      systemctl restart wg-luodi-watch.timer </dev/null >/dev/null 2>&1
      ;;
    openrc)
      cat > "$WGL_INITD/wg-luodi" <<EOF
#!/sbin/openrc-run
# wg-luodi：WireGuard 落地网关（由 wg-luodi 脚本生成）
name="wg-luodi"
description="wg-luodi WireGuard landing gateway"
supervisor="supervise-daemon"
command="$SB"
command_args="run -c $GW_JSON"
pidfile="/run/wg-luodi.pid"
respawn_delay=5
respawn_max=0
output_log="/var/log/wg-luodi.log"
error_log="/var/log/wg-luodi.log"

depend() {
    need net
    after firewall
}

start_pre() {
    $WGL_CMD up
}

stop_post() {
    $WGL_CMD down >/dev/null 2>&1 || true
}
EOF
      cat > "$WGL_LIB/watch-loop" <<EOF
#!/bin/sh
# wg-luodi 巡检：每 2 分钟检查一次
sleep 60
while :; do
  $WGL_CMD check >/dev/null 2>&1
  sleep 120
done
EOF
      chmod 755 "$WGL_LIB/watch-loop"
      cat > "$WGL_INITD/wg-luodi-watch" <<EOF
#!/sbin/openrc-run
# wg-luodi 巡检（由 wg-luodi 脚本生成）
name="wg-luodi-watch"
description="wg-luodi check every 2 minutes"
supervisor="supervise-daemon"
command="$WGL_LIB/watch-loop"
pidfile="/run/wg-luodi-watch.pid"

depend() {
    after wg-luodi
}
EOF
      chmod 755 "$WGL_INITD/wg-luodi" "$WGL_INITD/wg-luodi-watch"
      rc-update add wg-luodi default >/dev/null 2>&1
      rc-update add wg-luodi-watch default >/dev/null 2>&1
      rc-service wg-luodi-watch restart </dev/null >/dev/null 2>&1 || rc-service wg-luodi-watch start </dev/null >/dev/null 2>&1
      ;;
    *)
      warn "没有 systemd，也没有 OpenRC：网关先在后台跑起来，但服务器重启后要手动运行一次：wg-luodi restart"
      ;;
  esac
}

# 开机服务文件的“指纹”：更新前后一比，就知道服务有没有变（没变就不用重启网关）
_svc_sum() {
  cat "$WGL_SD/wg-luodi.service" "$WGL_SD/wg-luodi-watch.service" "$WGL_SD/wg-luodi-watch.timer" \
      "$WGL_INITD/wg-luodi" "$WGL_INITD/wg-luodi-watch" "$WGL_LIB/watch-loop" 2>/dev/null | cksum
}

remove_services() {
  case "$INIT" in
    systemd)
      systemctl disable --now wg-luodi-watch.timer >/dev/null 2>&1
      systemctl disable --now wg-luodi.service >/dev/null 2>&1
      rm -f "$WGL_SD/wg-luodi.service" "$WGL_SD/wg-luodi-watch.service" "$WGL_SD/wg-luodi-watch.timer"
      for _t in xray-node singbox-node hysteria-node; do
        rm -f "$WGL_SD/$_t@.service.d/wg-luodi.conf"
        rmdir "$WGL_SD/$_t@.service.d" 2>/dev/null
      done
      systemctl daemon-reload >/dev/null 2>&1 ;;
    openrc)
      rc-service wg-luodi-watch stop >/dev/null 2>&1
      rc-service wg-luodi stop >/dev/null 2>&1
      rc-update del wg-luodi-watch default >/dev/null 2>&1
      rc-update del wg-luodi default >/dev/null 2>&1
      rm -f "$WGL_INITD/wg-luodi" "$WGL_INITD/wg-luodi-watch" ;;
    *)
      _gw_kill ;;
  esac
}

_gw_kill() {
  [ -f "$WGL_DIR/gw.pid" ] && kill "$(cat "$WGL_DIR/gw.pid")" 2>/dev/null
  rm -f "$WGL_DIR/gw.pid"
}

# 启动 / 重启网关
gw_restart() {
  case "$INIT" in
    systemd) systemctl restart wg-luodi.service </dev/null >/dev/null 2>&1 ;;
    openrc) rc-service wg-luodi restart </dev/null >/dev/null 2>&1 || { rc-service wg-luodi zap </dev/null >/dev/null 2>&1; rc-service wg-luodi start </dev/null >/dev/null 2>&1; } ;;
    *)
      _gw_kill; [ "$MODE" = kernel ] && kernel_down
      [ "$MODE" = kernel ] && { kernel_up || return 1; }
      nohup "$SB" run -c "$GW_JSON" </dev/null >> "$WGL_DIR/gw.log" 2>&1 &
      echo $! > "$WGL_DIR/gw.pid" ;;
  esac
}
# 网关正在启动、还在选连落地机的路（kernel_up 里，最多一分钟左右）
gw_picking() { [ -f "$WGL_DIR/picking" ] && kill -0 "$(cat "$WGL_DIR/picking" 2>/dev/null)" 2>/dev/null; }
gw_active() {
  case "$INIT" in
    systemd) systemctl is-active --quiet wg-luodi.service ;;
    openrc) rc-service wg-luodi status >/dev/null 2>&1 ;;
    *) [ -f "$WGL_DIR/gw.pid" ] && kill -0 "$(cat "$WGL_DIR/gw.pid")" 2>/dev/null ;;
  esac
}
gw_wait() { # 等网关的 SOCKS5 端口开始监听
  _sp=$(st_get SOCKS_PORT); _i=0
  while [ "$_i" -lt "$WGL_WAIT" ]; do
    port_listening "$_sp" tcp && return 0
    _i=$((_i + 1)); sleep 1
  done
  return 1
}

# ---------- 19. 测出口 IP ----------
# 直接从服务器访问 = 服务器自己的 IP；通过本机网关访问 = WireGuard 落地 IP。两个不一样就说明分流成功。
IP_URLS=${WGL_IP_URLS:-"https://api.ip.sb/ip https://api64.ipify.org https://ifconfig.co/ip https://icanhazip.com"}
ip_via() { # ip_via [curl 参数…] -> 打印 IP
  _has curl || return 1
  for _u in $IP_URLS; do
    _r=$(_to 20 curl -fsS -A 'Mozilla/5.0' --connect-timeout 8 --max-time 15 "$@" "$_u" 2>/dev/null | tr -d ' \r\n')
    if _is_ip4 "$_r" || _is_ip6 "$_r"; then printf '%s' "$_r"; return 0; fi
  done
  return 1
}
wg_exit_ip() {
  ip_via -x "socks5h://$(st_get SOCKS_USER):$(st_get SOCKS_PASS)@127.0.0.1:$(st_get SOCKS_PORT)"
}
server_ip() { ip_via -4 || ip_via -6; }
# 测下载速度（Mbps）。超时（20 秒）也照样用已经下载的部分算平均速度。
_speed() { # _speed [curl 参数…]
  _has curl || return 1
  _b=$(_to 30 curl -sS -o /dev/null -w '%{speed_download}' --connect-timeout 8 --max-time 20 "$@" "$WGL_SPEED_URL" 2>/dev/null)
  awk -v b="$_b" 'BEGIN { if (b + 0 <= 0) exit 1; printf "%.1f", b * 8 / 1000000 }'
}
# 同时开 N 个连接下载，速度加起来（Mbps）。单个连接受延迟、丢包限制跑不满时，多个连接加起来会明显更快。
_speed_par() { # _speed_par <N> [curl 参数…]
  _pn=$1; shift; _pi=0; _pf="$WGL_DIR/speed.$$"
  rm -f "$_pf".*
  # 每个结果后面补一个换行：_speed 打印的数字不带换行，几个文件直接连起来会粘成一个数
  while [ "$_pi" -lt "$_pn" ]; do ( _speed "$@"; echo ) > "$_pf.$_pi" & _pi=$((_pi + 1)); done
  wait
  cat "$_pf".* 2>/dev/null | awk '{ s += $1 } END { if (s <= 0) exit 1; printf "%.1f", s }'; _pr=$?
  rm -f "$_pf".*
  return $_pr
}
# 到 1.1.1.1 的平均延迟（毫秒），ping 的参数（比如 -m 标记）原样传进去。iputils 和 busybox 的输出都认。
_rtt() { # _rtt [ping 参数…]
  _has ping || return 1
  ping -c 4 -i 0.3 -W 2 "$@" 1.1.1.1 2>/dev/null | awk '/min\/avg/ { sub(/.*= */, ""); split($0, a, "/"); if (a[2] + 0 > 0) { printf "%.0f", a[2]; f = 1 } } END { exit !f }'
}
# 按测出来的几个数字说清楚瓶颈在哪一段（只做比较，不联网，方便测试）。
#   参数：直接经 WireGuard 网卡（1 个连接）、同上（4 个连接）、经网关（节点实际走的路）、服务器平时的出口
_speed_verdict() { # _speed_verdict <raw> <raw4> <gw> <direct>
  awk -v r="$1" -v r4="$2" -v g="$3" -v d="$4" 'BEGIN {
    if (g == "" && r == "") { print "经 WireGuard 完全下载不了：先运行 wg-luodi status 看握手和出口"; exit }
    if (r != "" && g != "" && g < r * 0.7) {
      print "直接用 WireGuard 网卡快、经网关慢：拖慢的是本机网关程序这一段，多半是 CPU 不够（看上面的负载）"; exit }
    base = (r != "") ? r : g
    if (d != "" && base != "" && base > d * 1.5) {
      print "服务器上 WireGuard 比平时的出口快很多，WireGuard 和网关这一段都没问题。"
      print "    如果手机上用走 WireGuard 的节点还是觉得慢，慢在手机到服务器这一段或节点程序本身（两种节点共用），和 WireGuard 无关"; exit }
    if (r4 != "" && base != "" && r4 > base * 1.5) {
      print "单个连接跑不满、4 个连接加起来快很多：是服务器到落地机这段的延迟或丢包限制了每个连接的速度，"
      print "    落地机本身带宽还有余量。网页、测速软件开多个连接时会快一些，脚本这边没法再提速"; exit }
    if (d != "" && base != "" && base < d * 0.5) {
      print "不经过节点和网关、直接用 WireGuard 网卡下载也只有这么快，多开连接也不变："
      print "    瓶颈在落地机本身的带宽（或服务器到落地机的线路），不是本脚本或 L2TP 造成的，可以找落地机商家确认带宽"; exit }
    print "WireGuard 和服务器平时的出口速度差不多，这一段没有明显瓶颈"
  }'
}
# 服务器装了 L2TP-VPS（而且没关掉）时，“平时的出口”是 L2TP 的 IP，不是服务器自己的 IP，提示一句免得看糊涂。
_l2tp_active() { [ -f "$WGL_L2TP_DIR/v2-owned" ] && [ ! -f "$WGL_L2TP_DIR/disabled" ]; }
_l2tp_note() {
  _l2tp_active || return 0
  printf '\n  （这台服务器装了 L2TP-VPS：不走 WireGuard 的流量走 L2TP；L2TP 排除端口上的节点用服务器自己的 IP）'
}
# 服务器的外网 IPv4 / IPv6（客户端填的“服务器地址”）。每种最多等十几秒，没有就打印空。
# 装了 L2TP-VPS 时，普通的 curl 走 L2TP，查到的是 L2TP 的出口 IP。客户端填它连不进来（L2TP 只出站），
# 所以改用 L2TP-VPS 的维护账号 l2tp-fetch 去查：L2TP-VPS 只允许这个账号走服务器自己的网络访问 HTTPS，
# 查到的就是服务器自己的公网 IP（NAT 小鸡也一样，比读网卡地址准）。
pub_ip() { # pub_ip <4|6>
  _has curl || return 1
  _via_fetch=""
  _l2tp_active && _has su && id l2tp-fetch >/dev/null 2>&1 && _via_fetch=1
  for _u in https://api64.ipify.org https://icanhazip.com; do
    if [ -n "$_via_fetch" ]; then
      _r=$(_to 10 su -s /bin/sh -c "curl -$1 -fsS -A Mozilla/5.0 --connect-timeout 5 --max-time 8 $_u" l2tp-fetch 2>/dev/null | tr -d ' \r\n')
    else
      _r=$(_to 10 curl -"$1" -fsS -A 'Mozilla/5.0' --connect-timeout 5 --max-time 8 "$_u" 2>/dev/null | tr -d ' \r\n')
    fi
    if [ "$1" = 4 ] && _is_ip4 "$_r"; then printf '%s' "$_r"; return 0; fi
    if [ "$1" = 6 ] && _is_ip6 "$_r"; then printf '%s' "$_r"; return 0; fi
  done
  return 1
}

# ---------- 19b. IPv4 / IPv6 入口检查 ----------
# 说人话告诉你：客户端填服务器的 IPv4 还是 IPv6 都能不能连进来。
# 设计：客户端从哪种 IP 连进来都行（入口）；进来以后，走 WireGuard 的端口一律从 WireGuard 出去（出口）；
# 回给客户端的包照旧走服务器自己的网络（没有标记，不进 WireGuard），所以 IPv6 连进来也能正常回包。
v6_report() {
  [ -n "$V6_KIND" ] || detect_net
  _p4=$(pub_ip 4); _p6=""
  [ "$HAS_V6" = 1 ] && _p6=$(pub_ip 6)
  say "  客户端里“服务器地址”可以填："
  say "    IPv4：${_p4:-（没测到外网 IPv4）}"
  if [ -n "$_p6" ]; then say "    IPv6：$_p6"
  elif [ "$HAS_V6" = 1 ]; then say "    IPv6：（服务器有 IPv6，但没测到外网 IPv6 地址，IPv6 可能出不去也进不来）"
  else say "    IPv6：（这台服务器没有 IPv6）"; fi
  _v6only=0; [ -r /proc/sys/net/ipv6/bindv6only ] && [ "$(cat /proc/sys/net/ipv6/bindv6only)" = 1 ] && _v6only=1
  for _p in $PORTS; do
    case "$(port_fams "$_p")" in
      "v4 v6") say "    端口 $_p：IPv4、IPv6 都在监听 ✔" ;;
      v6) if [ "$_v6only" = 1 ]; then say "    端口 $_p：只在 IPv6 上监听（系统设置了 bindv6only=1），填 IPv4 可能连不上"
          else say "    端口 $_p：IPv4、IPv6 都在监听 ✔（双栈）"; fi ;;
      v4) if _v6_listen_ok; then say "    端口 $_p：只在 IPv4 上监听 ✘ 填 IPv6 连不上（自动改成双栈没成功，看上面的提示；可以运行 wg-luodi reapply 再试）"
          else say "    端口 $_p：只在 IPv4 上监听（这台服务器现在用不了 IPv6，不用改）"; fi ;;
      *) say "    端口 $_p：现在没有程序在监听（节点还没搭好或没启动）" ;;
    esac
  done
  if [ -n "$_p6" ] && [ "$V6_KIND" = ula ]; then
    say "  提示：这台服务器网卡上的 IPv6 是内网地址 $V6_LOCAL，外网 IPv6 $_p6 是服务商转发过来的。"
    say "        填 IPv6 能不能连上，还要看服务商有没有把这个端口的 IPv6 也转发进来。"
    say "        如果连“不走 WireGuard 的节点”填 IPv6 也连不上，就是服务商没转发，脚本改不了，客户端请填 IPv4。"
  fi
  say "  不管填 IPv4 还是 IPv6 连进来，走 WireGuard 的端口出口都是 WireGuard 的 IP。"
}

# ---------- 20. 状态 ----------
do_status() {
  load_all; find_jq || die "找不到 jq"
  INIT=$(st_get INIT)
  step "wg-luodi 状态（版本 $WGL_VERSION）"
  case "$MODE" in
    kernel) say "  模式：内核网卡模式（网卡 $WGL_IFACE，Table = off，只有带标记的流量走它）" ;;
    *) say "  模式：无网卡模式（sing-box 里跑 WireGuard，不需要 TUN）" ;;
  esac
  say "  落地机：${WG_EP_HOST}:${WG_EP_PORT}    本端地址：$(printf '%s' "$WG_ADDR" | tr ',' ' ')"
  say "  隧道 MTU：$(wg_mtu)    连落地机走的网卡：$(_ep_dev_show)$( [ "$MODE" = kernel ] && case "$(st_get EP_MARK)" in
      off) if [ -n "$(_l2tp_note)" ]; then echo "（直连没通过检查：WireGuard 套在 L2TP 里面走，速度会比 L2TP 本身慢）"; else echo "（直连不通，走服务器默认的路）"; fi ;; ''|retry) if gw_picking; then echo "（正在选路）"; else echo "（还没选好，巡检时会再试）"; fi ;; *) echo "（直连，不经过别的全局出口）" ;; esac)"
  say "  隧道里的 DNS：$WG_DNS1    IP 类型：$(case $WG_STRAT in ipv4_only) echo 只用 IPv4 ;; ipv6_only) echo 只用 IPv6 ;; *) echo IPv4 优先，也支持 IPv6 ;; esac)"
  if gw_active; then say "  网关服务：运行中"
  elif gw_picking; then say "  网关服务：正在启动（正在选连落地机的路，最多一分钟左右）"
  else printf "  网关服务：${RED}没在运行${NC}（试试 wg-luodi restart）\n"; fi
  if [ "$MODE" = kernel ] && _has wg; then
    _hs=$(wg show "$WGL_IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    if [ -n "$_hs" ] && [ "$_hs" != 0 ]; then say "  最近握手：$(( $(date +%s) - _hs )) 秒前（3 分钟内都正常）"
    else say "  最近握手：还没有握手（落地机没回应：检查配置、或服务器能不能连到落地机的 UDP 端口）"; fi
  fi
  say "  走 WireGuard 的端口：$PORTS"
  detect_net
  v6_report
  say ""
  if gw_picking && ! gw_active; then
    say "  网关正在启动，出口 IP 等它好了再测：过一分钟再运行 wg-luodi status"
  else
  say "  正在测出口 IP（要十几秒）…"
  _sip=$(server_ip); _wip=$(wg_exit_ip)
  say "  服务器平时的出口 IP（不走 WireGuard 的流量）：${_sip:-没测出来}"$(_l2tp_note)
  if [ -n "$_wip" ]; then
    say "  WireGuard 出口 IP：$_wip"
    if [ "$_wip" != "$_sip" ]; then info "WireGuard 是通的，出口 IP 和服务器 IP 不一样，分流正常。"
    else warn "WireGuard 出口 IP 和服务器 IP 一样，请检查落地配置。"; fi
  else
    err "通过 WireGuard 访问不了外网。可能原因：配置失效（换了钥匙？）、落地机连不上、或服务器屏蔽了 UDP。"
  fi
  fi
  say ""
  say "  节点情况："
  QUIET=0
  discover_nodes | while IFS='|' read -r k c st sn b al; do
    [ -n "$k" ] || continue
    if [ "$k" = panel ]; then say "  - 面板配置 $c：面板会覆盖改动，脚本不改。请在面板里给这个入站加一个 SOCKS5 出站：127.0.0.1:$(st_get SOCKS_PORT)，用户名 $(st_get SOCKS_USER)，密码 $(st_get SOCKS_PASS)"; continue; fi
    _mp=$(cfg_main_port "$k" "$c"); _wp=$(cfg_wg_ports "$k" "$c" "$al")
    _ok="不走 WireGuard（用服务器平时的出口）"
    if [ -n "$_wp" ]; then
      if [ "$k" = hysteria ]; then grep -q '^# wg-luodi begin' "$c" && _ok="走 WireGuard ✔" || _ok="应该走 WireGuard，但还没改好 ✘"
      else "$JQ" -e '[.outbounds[]? | select(.tag == "wg-luodi")] | length > 0' "$c" >/dev/null 2>&1 && _ok="走 WireGuard ✔" || _ok="应该走 WireGuard，但还没改好 ✘"; fi
    fi
    say "  - $(kind_cn "$k") 端口 ${_mp:-?}：$_ok    （$c）"
  done
  say ""
  say "  想逐个节点实测出口 IP：wg-luodi test"
}

# ---------- 21. 逐个节点实测出口 ----------
# 在服务器上临时起一个 sing-box 客户端，连本机的节点（127.0.0.1:端口），再通过它访问 ip.sb，
# 看到的就是“客户端连这个节点时网站看到的 IP”。测完马上关掉，不留任何东西。
_b64url_dec() { # base64url -> 原始字节
  _s=$(printf '%s' "$1" | tr '_-' '/+')
  case $(( ${#_s} % 4 )) in 2) _s="$_s==" ;; 3) _s="$_s=" ;; esac
  printf '%s' "$_s" | base64 -d 2>/dev/null
}
x25519_pub() { # REALITY 私钥 -> 公钥（优先用 xray x25519 -i；没有 xray 就用 openssl）
  if [ -x "$XN_BIN_DIR/xray" ]; then
    _o=$("$XN_BIN_DIR/xray" x25519 -i "$1" </dev/null 2>/dev/null)
    _pk=$(printf '%s\n' "$_o" | sed -n 's/^Public key: *//p; s/^PublicKey: *//p; s/^Password[^:]*: *//p' | head -n 1 | tr -d ' \r')
    [ -n "$_pk" ] && { printf '%s' "$_pk"; return 0; }
  fi
  _has openssl || return 1
  _t=$(mktemp) || return 1
  { printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'; _b64url_dec "$1"; } > "$_t"
  openssl pkey -inform DER -in "$_t" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n'
  rm -f "$_t"
}

# 根据服务器端配置生成 sing-box 客户端的出站（只支持本脚本常见的几种节点）
client_outbound() { # client_outbound <类型> <配置> <端口> [连哪个地址，默认 127.0.0.1；::1 = 从 IPv6 连进去]
  case "$1" in
    xray)
      _in=$("$JQ" -c --arg p "$3" '[.inbounds[]? | select((.port | tostring) == $p)][0]' "$2")
      _proto=$(printf '%s' "$_in" | "$JQ" -r '.protocol // empty')
      _sec=$(printf '%s' "$_in" | "$JQ" -r '.streamSettings.security // "none"')
      _net=$(printf '%s' "$_in" | "$JQ" -r '.streamSettings.network // "tcp"')
      _pub=""
      if [ "$_sec" = reality ]; then
        _pub=$(x25519_pub "$(printf '%s' "$_in" | "$JQ" -r '.streamSettings.realitySettings.privateKey')") || return 1
        [ -n "$_pub" ] || return 1
      fi
      printf '%s' "$_in" | "$JQ" -c --arg pub "$_pub" --argjson port "$3" --arg srv "${4:-127.0.0.1}" '
        def tls:
          if .streamSettings.security == "reality" then
            {tls: {enabled: true, server_name: .streamSettings.realitySettings.serverNames[0],
                   utls: {enabled: true, fingerprint: "chrome"},
                   reality: {enabled: true, public_key: $pub, short_id: (.streamSettings.realitySettings.shortIds[0] // "")}}}
          elif .streamSettings.security == "tls" then {tls: {enabled: true, insecure: true, server_name: (.streamSettings.tlsSettings.serverName // "localhost")}}
          else {} end;
        def transport:
          if (.streamSettings.network // "tcp") == "ws" then {transport: {type: "ws", path: (.streamSettings.wsSettings.path // "/")}}
          else {} end;
        {server: $srv, server_port: $port} +
        (if .protocol == "vless" then {type: "vless", uuid: .settings.clients[0].id} + (if (.settings.clients[0].flow // "") != "" then {flow: .settings.clients[0].flow} else {} end)
         elif .protocol == "trojan" then {type: "trojan", password: .settings.clients[0].password}
         elif .protocol == "vmess" then {type: "vmess", uuid: .settings.clients[0].id, security: "auto"}
         elif .protocol == "shadowsocks" then {type: "shadowsocks",
               method: (.settings.method // .settings.clients[0].method),
               password: (if (.settings.clients // []) | length > 0 and (.settings.password // "") != "" then .settings.password + ":" + .settings.clients[0].password else (.settings.password // .settings.clients[0].password) end)}
         elif .protocol == "socks" or .protocol == "mixed" then {type: "socks"} + (if .settings.accounts then {username: .settings.accounts[0].user, password: .settings.accounts[0].pass} else {} end)
         elif .protocol == "http" then {type: "http"} + (if .settings.accounts then {username: .settings.accounts[0].user, password: .settings.accounts[0].pass} else {} end)
         else error("unsupported") end)
        + tls + transport' 2>/dev/null ;;
    sing-box)
      _in=$("$JQ" -c --arg p "$3" '[.inbounds[]? | select((.listen_port | tostring) == $p)][0]' "$2")
      _pub=""
      if [ "$(printf '%s' "$_in" | "$JQ" -r '.tls.reality.enabled // false')" = true ]; then
        _pub=$(x25519_pub "$(printf '%s' "$_in" | "$JQ" -r '.tls.reality.private_key')") || return 1
        [ -n "$_pub" ] || return 1
      fi
      printf '%s' "$_in" | "$JQ" -c --arg pub "$_pub" --argjson port "$3" --arg srv "${4:-127.0.0.1}" '
        def tls:
          if (.tls.enabled // false) | not then {}
          elif (.tls.reality.enabled // false) then
            {tls: {enabled: true, server_name: (.tls.server_name // .tls.reality.handshake.server),
                   utls: {enabled: true, fingerprint: "chrome"},
                   reality: {enabled: true, public_key: $pub, short_id: ((.tls.reality.short_id // [""]) | if type == "array" then .[0] else . end)}}}
          else {tls: ({enabled: true, insecure: true, server_name: (.tls.server_name // "localhost")} + (if .tls.alpn then {alpn: .tls.alpn} else {} end))} end;
        {server: $srv, server_port: $port} +
        (if .type == "vless" then {type: "vless", uuid: .users[0].uuid} + (if (.users[0].flow // "") != "" then {flow: .users[0].flow} else {} end)
         elif .type == "trojan" then {type: "trojan", password: .users[0].password}
         elif .type == "vmess" then {type: "vmess", uuid: .users[0].uuid}
         elif .type == "anytls" then {type: "anytls", password: .users[0].password}
         elif .type == "tuic" then {type: "tuic", uuid: .users[0].uuid, password: .users[0].password, congestion_control: (.congestion_control // "bbr")}
         elif .type == "hysteria2" then {type: "hysteria2", password: .users[0].password} + (if .obfs then {obfs: .obfs} else {} end)
         elif .type == "shadowsocks" then {type: "shadowsocks", method: .method, password: (if .users then .password + ":" + .users[0].password else .password end)}
         elif .type == "socks" or .type == "mixed" then {type: "socks"}
         else error("unsupported") end)
        + tls
        + (if .transport.type == "ws" then {transport: {type: "ws", path: (.transport.path // "/")}} else {} end)' 2>/dev/null ;;
    hysteria)
      _pw=$(awk '/^auth:/ { a = 1; next } /^[^ #]/ { a = 0 } a && /^[[:space:]]+password:/ { sub(/^[[:space:]]+password:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$2")
      _ob=$(awk '/^obfs:/ { a = 1; next } /^[^ #]/ { a = 0 } a && /^[[:space:]]+password:/ { sub(/^[[:space:]]+password:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$2")
      _sn=$(awk '/^acme:/ { a = 1; next } /^[^ #]/ { a = 0 } a && /^[[:space:]]+- / { sub(/^[[:space:]]+- */, ""); print; exit }' "$2")
      if [ -z "$_sn" ] && _has openssl; then
        _crt=$(awk '/^tls:/ { a = 1; next } /^[^ #]/ { a = 0 } a && /^[[:space:]]+cert:/ { sub(/^[[:space:]]+cert:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$2")
        [ -f "$_crt" ] && _sn=$(openssl x509 -in "$_crt" -noout -text 2>/dev/null | grep -o 'DNS:[^,]*' | head -n 1 | sed 's/DNS://')
      fi
      [ -n "$_pw" ] || return 1
      "$JQ" -nc --arg pw "$_pw" --arg ob "$_ob" --arg sn "${_sn:-www.samsung.com}" --argjson port "$3" --arg srv "${4:-127.0.0.1}" '
        {type: "hysteria2", server: $srv, server_port: $port, password: $pw,
         tls: {enabled: true, insecure: true, server_name: $sn}}
        + (if $ob != "" then {obfs: {type: "salamander", password: $ob}} else {} end)' ;;
  esac
}

do_test() { # do_test [端口]
  load_all; find_jq || die "找不到 jq"
  INIT=$(st_get INIT)
  step "逐个节点实测出口 IP（每个节点要几秒）"
  _sip=$(server_ip); _wip=$(wg_exit_ip)
  say "  服务器平时的出口 IP（不走 WireGuard 的流量）：${_sip:-没测出来}"$(_l2tp_note)
  say "  WireGuard 出口 IP：${_wip:-没测出来（WireGuard 不通）}"
  say ""
  _tdir=$(mktemp -d "${TMPDIR:-/tmp}/wgl-test.XXXXXX") || die "建不了临时目录"
  discover_nodes > "$_tdir/list"
  while IFS='|' read -r k c st sn b al; do
    [ -n "$k" ] && [ "$k" != panel ] || continue
    for _p in $(cfg_ports "$k" "$c" | sort -n -u); do
      [ -n "$1" ] && [ "$1" != "$_p" ] && continue
      _wp=$(cfg_wg_ports "$k" "$c" "$al")
      _should="直连"; case " $_wp " in *" $_p "*) _should="WireGuard" ;; esac
      # 先从 IPv4（127.0.0.1）连进节点测一次；节点也在 IPv6 上监听的话，再从 IPv6（::1）连进去测一次，
      # 确认“客户端填 IPv6 连进来”时出口也对。
      _srvs="127.0.0.1"
      case "$(port_fams "$_p")" in *v6*) grep -q '^0\{31\}1 ' /proc/net/if_inet6 2>/dev/null && _srvs="127.0.0.1 ::1" ;; esac
      for _srv in $_srvs; do
        if [ "$_srv" = "::1" ]; then _via="IPv6 连入"; else _via="IPv4 连入"; fi
        _ob=$(client_outbound "$k" "$c" "$_p" "$_srv")
        if [ -z "$_ob" ]; then say "  - $(kind_cn "$k") 端口 $_p：这种节点脚本测不了，请用手机客户端连上它，打开 ip.sb 看。"; break; fi
        _lp=$(pick_free_port "$_p")
        "$JQ" -n --argjson ob "$_ob" --argjson lp "$_lp" \
          '{log: {level: "error"}, inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: $lp}], outbounds: [$ob + {tag: "node"}]}' > "$_tdir/c.json"
        "$SB" run -c "$_tdir/c.json" </dev/null > "$_tdir/c.log" 2>&1 &
        _cp=$!
        _i=0; while [ "$_i" -lt 10 ] && ! port_listening "$_lp" tcp; do _i=$((_i + 1)); sleep 1; done
        _got=$(ip_via -x "http://127.0.0.1:$_lp")
        kill "$_cp" 2>/dev/null; wait "$_cp" 2>/dev/null
        if [ -z "$_got" ]; then
          _res="${RED}没测通${NC}（节点没响应或这条路不通）"
        elif [ "$_should" = WireGuard ] && [ "$_got" = "$_wip" ]; then _res="${GREEN}出口 $_got = WireGuard ✔${NC}"
        elif [ "$_should" = 直连 ] && [ "$_got" != "$_wip" ]; then _res="${GREEN}出口 $_got = 服务器平时的出口 IP ✔${NC}"
        else _res="${RED}出口 $_got，和预期（$_should）不符 ✘${NC}"; fi
        printf '  - %s 端口 %s，%s（应该走%s）：%b\n' "$(kind_cn "$k")" "$_p" "$_via" "$_should" "$_res"
      done
    done
  done < "$_tdir/list"
  rm -rf "$_tdir"
}

# ---------- 22. 安装 ----------
need_root() {
  [ "$(id -u)" = 0 ] || [ "${WGL_ALLOW_NONROOT:-0}" = 1 ] || die "请用 root 用户运行（先输入 sudo -i 或 su - 切换到 root）。"
}

# 把本脚本装成管理命令 wg-luodi（以后直接输入 wg-luodi 就能管理）
self_install() {
  _me=$(readlink -f "$0" 2>/dev/null || echo "$0")
  _dst=$(readlink -f "$WGL_CMD" 2>/dev/null || echo "$WGL_CMD")
  [ "$_me" = "$_dst" ] && return 0
  mkdir -p "$(dirname "$WGL_CMD")"
  if [ -f "$_me" ] && grep -q '^WGL_VERSION=' "$_me"; then
    cp -f "$_me" "$WGL_CMD.new"
  else
    _dl "$WGL_RAW_URL" "$WGL_CMD.new" || die "下载管理命令失败。请把脚本下载成文件再运行：curl -fsSL -o /root/wg-luodi.sh $WGL_RAW_URL && sh /root/wg-luodi.sh"
  fi
  chmod 755 "$WGL_CMD.new" && mv -f "$WGL_CMD.new" "$WGL_CMD"
}

# 网关端口：重装时尽量沿用（节点配置里已经写着这个端口），和你选的端口冲突才换
pick_gateway_ports() {
  _sp=$(st_get SOCKS_PORT); _dp=$(st_get DNS_PORT)
  case " $PORTS " in *" $_sp "*|*" $_dp "*) _sp=""; _dp="" ;; esac
  if [ -z "$_sp" ] || [ -z "$_dp" ]; then
    _sp=$(pick_free_port) || die "找不到空闲端口给本机网关用"
    _dp=$(pick_free_port "$_sp") || die "找不到空闲端口给本机网关用"
  fi
  st_set SOCKS_PORT "$_sp"; st_set DNS_PORT "$_dp"
  [ -n "$(st_get SOCKS_USER)" ] || st_set SOCKS_USER "wgl$(rand_str 8)"
  [ -n "$(st_get SOCKS_PASS)" ] || st_set SOCKS_PASS "$(rand_str 24)"
}

# 生成网关配置并用 sing-box 自己检查一遍，通过了才替换
gen_gateway() {
  write_gw_json "$GW_JSON.new" || die "生成网关配置失败"
  _ce=$("$SB" check -c "$GW_JSON.new" 2>&1) || { rm -f "$GW_JSON.new"; die "网关配置没通过检查：$(printf '%s' "$_ce" | tail -n 3 | tr '\n' ' ')"; }
  mv -f "$GW_JSON.new" "$GW_JSON"; chmod 600 "$GW_JSON"
}

start_and_check_gateway() {
  step "[启动] 启动网关并测试 WireGuard"
  gw_restart
  if ! gw_wait; then
    err "网关没有启动起来。"
    case "$INIT" in
      systemd) say "  看原因：journalctl -u wg-luodi -n 30 --no-pager" ;;
      openrc) say "  看原因：tail -n 30 /var/log/wg-luodi.log" ;;
    esac
    return 1
  fi
  info "网关已启动（只在本机 127.0.0.1 上，外面连不上）"
  WIP=$(wg_exit_ip)
  if [ -n "$WIP" ]; then
    info "WireGuard 通了，出口 IP：$WIP"
  else
    warn "网关起来了，但通过 WireGuard 访问不了外网。走 WireGuard 的端口暂时会上不了网（不会偷偷改用服务器 IP）。"
    say "  常见原因：配置过期/钥匙换了、落地机不在线、服务器到落地机的 UDP 被屏蔽。修好后运行 wg-luodi set-conf 换配置。"
  fi
  return 0
}

# ---------- 22b. 更新 ----------
# 再运行一次安装命令、或者运行 wg-luodi update，就会更新：
# 换上新版脚本（管理命令）、有新版 sing-box 就换上、用新版重新生成网关配置和开机服务、重新检查节点。
# WireGuard 配置、端口、模式、网关端口和密码都保留。更新后网关起不来（或者更新前通、更新后不通），自动换回旧版。

# 版本号比较：_ver_gt 1.14.2 1.13.9 → a 比 b 新返回 0
_ver_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0; if (p > q) exit 0; if (p < q) exit 1 }
    exit 1 }'
}

# 先换成临时文件再改名，正在运行的程序也能安全替换
_put() { # _put <来源> <目标>
  cp -p "$1" "$2.tmp" 2>/dev/null && mv -f "$2.tmp" "$2"
}

# 看看 sing-box 有没有新正式版；有就下载好放在 "$SB.new"（先不替换）。下载失败不要紧，继续用旧的。
_sb_prepare_update() {
  rm -f "$SB.new"
  _cur=$("$SB" version 2>/dev/null | head -n 1 | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')
  _api=$(_get "https://api.github.com/repos/SagerNet/sing-box/releases/latest")
  _ver=$(_sb_latest_ver "$_api")
  case "$_ver" in
    ''|*[!0-9.]*)
      if [ -n "$_cur" ]; then info "查不到 sing-box 最新版本号（可能连不上 GitHub），继续用现在的 $_cur"; return 0; fi
      _ver="$SB_FALLBACK_VER"; _api="" ;;
  esac
  if [ -n "$_cur" ] && ! _ver_gt "$_ver" "$_cur"; then
    info "sing-box 已经是最新：$_cur"; return 0
  fi
  if _sb_get "$_ver" "$_api"; then
    info "sing-box 新版 $_ver 已下载好（${_cur:-原来的跑不起来} → $_ver）"
  else
    rm -f "$SB.new"
    [ -n "$_cur" ] || die "sing-box 下载失败，或在这台机器上跑不起来。请把上面的提示发出来。"
    warn "sing-box 新版没下载下来，继续用现在的 $_cur"
  fi
  return 0
}

# 出问题时把更新前的文件放回去
_update_rollback() { # _update_rollback <备份目录>
  [ -f "$1/wg-luodi" ] && _put "$1/wg-luodi" "$WGL_CMD"
  [ -f "$1/sing-box" ] && _put "$1/sing-box" "$SB"
  [ -f "$1/gw.json" ] && _put "$1/gw.json" "$GW_JSON"
  [ -f "$1/state" ] && _put "$1/state" "$STATE"
  load_all
}

do_update() {
  need_root
  installed || { warn "这台服务器还没装过 wg-luodi，改为全新安装。"; WGL_FORCE_REINSTALL=1; do_install; return; }
  load_all
  detect_os; detect_init; detect_virt; detect_net
  _sinit=$(st_get INIT); [ -n "$_sinit" ] && INIT="$_sinit"
  _old_ver=$(st_get VERSION)
  step "[更新] wg-luodi ${_old_ver:-旧版} → $WGL_VERSION（WireGuard 配置、端口、模式都保留，不用重新填）"
  ensure_tools
  ensure_singbox_present
  _sb_prepare_update
  _lock 60 || { rm -f "$SB.new"; die "另一个 wg-luodi 正在运行，请稍后再试。"; }
  # 记下更新前的样子：隧道通不通、旧文件备份一份
  _old_ok=""; gw_active && _old_ok=$(wg_exit_ip)
  _bk="$WGL_DIR/update-backup"; rm -rf "$_bk"; mkdir -p "$_bk"; chmod 700 "$_bk"
  [ -f "$WGL_CMD" ] && cp -p "$WGL_CMD" "$_bk/wg-luodi"
  # sing-box 要换新版时才备份旧的；用硬链接，不多占硬盘（小鸡硬盘可能很小）
  if [ -f "$SB.new" ] && [ -x "$SB" ]; then ln "$SB" "$_bk/sing-box" 2>/dev/null || cp -p "$SB" "$_bk/sing-box"; fi
  [ -f "$GW_JSON" ] && cp -p "$GW_JSON" "$_bk/gw.json"
  cp -p "$STATE" "$_bk/state"
  # 1. 换上新版管理命令和 sing-box
  self_install
  _gw_changed=0
  [ -f "$SB.new" ] && { mv -f "$SB.new" "$SB"; _gw_changed=1; }
  # 2. 用新版重新生成网关配置（先检查，通过了才换）和开机服务
  if ! write_gw_json "$GW_JSON.new" || ! "$SB" check -c "$GW_JSON.new" >/dev/null 2>&1; then
    rm -f "$GW_JSON.new"; _update_rollback "$_bk"; rm -rf "$_bk"
    die "新版生成的网关配置没通过检查，已换回旧版，什么都没改。请把这条提示发出来。"
  fi
  cmp -s "$GW_JSON.new" "$GW_JSON" || _gw_changed=1
  mv -f "$GW_JSON.new" "$GW_JSON"; chmod 600 "$GW_JSON"
  st_set VERSION "$WGL_VERSION"
  _svc_before=$(_svc_sum)
  install_services
  [ "$(_svc_sum)" = "$_svc_before" ] || _gw_changed=1
  # 内核网卡模式还没选过连落地机的路：要重建网卡才能试，这次重启网关
  [ "$MODE" = kernel ] && case "$(st_get EP_MARK)" in ''|retry) true ;; *) false ;; esac && _gw_changed=1
  # 3. 网关程序、网关配置、开机服务都没变，而且网关现在是通的：不重启网关，走 WireGuard 的节点一秒都不断。
  #    内核网卡模式只把专用路由规则补齐（缺了才加，不删不重建）。
  #    有变化才重启网关并测试；起不来、或者更新前通更新后不通，就换回旧版。
  WIP=""
  if [ "$_gw_changed" = 0 ] && [ -n "$_old_ok" ]; then
    [ "$MODE" = kernel ] && { _rules_sync; _live_sync; }
    WIP=$(wg_exit_ip)
    if [ -z "$WIP" ]; then
      warn "更新后 WireGuard 没测通（更新前是好的），自动换回旧版。"
      _update_rollback "$_bk"; install_services; start_and_check_gateway; rm -rf "$_bk"
      die "已换回旧版 ${_old_ver:-}，节点照常能用。请把上面的提示发出来。"
    fi
    info "网关没有变化，不用重启（WireGuard 出口 IP：$WIP）"
  elif ! start_and_check_gateway || { [ -z "$WIP" ] && [ -n "$_old_ok" ]; }; then
    warn "更新后网关没测通（更新前是好的），自动换回旧版。"
    _update_rollback "$_bk"; install_services; start_and_check_gateway; rm -rf "$_bk"
    die "已换回旧版 ${_old_ver:-}，节点照常能用。请把上面的提示发出来。"
  fi
  # 4. 用新版重新检查节点（已经改好的不会重复改），再把只听 IPv4 的节点改成双栈
  step "[节点] 重新检查走 WireGuard 的节点"
  rm -f "$WGL_DIR/failed" "$WGL_DIR/v6failed"
  apply_all apply 1
  v6_fix_all
  _unlock
  rm -rf "$_bk"
  log "更新完成：${_old_ver:-?} → $WGL_VERSION"
  step "更新好了！现在是 $WGL_VERSION 版"
  say "  走 WireGuard 的端口：$(st_get PORTS)"
  say "  WireGuard 出口 IP：${WIP:-（暂时没测通）}"
  v6_report
  say "  以后管理直接输入：wg-luodi"
}

# 更新时如果 sing-box 不见了或跑不起来（比如被误删），先按正常流程装上
ensure_singbox_present() {
  [ -x "$SB" ] && _sb_ver_ok "$SB" && return 0
  ensure_singbox
}

# wg-luodi update：下载 GitHub 上的最新版脚本，用它来更新
do_self_update() {
  need_root
  installed || die "还没有安装。请先运行安装命令。"
  _nf=$(mktemp "${TMPDIR:-/tmp}/wg-luodi-new.XXXXXX") || die "建不了临时文件"
  info "下载最新版脚本…"
  _gh_dl "$WGL_RAW_URL" "$_nf" || { rm -f "$_nf"; die "下载最新版失败（连不上 GitHub），请稍后再试。"; }
  if ! grep -q '^WGL_VERSION=' "$_nf" || ! sh -n "$_nf" 2>/dev/null; then
    rm -f "$_nf"; die "下载的脚本不完整，请稍后再试。"
  fi
  _nv=$(sed -n 's/^WGL_VERSION="\([^"]*\)".*/\1/p' "$_nf" | head -n 1)
  info "GitHub 上的最新版：${_nv:-?}（现在装的：$(st_get VERSION)）"
  sh "$_nf" apply-update; _rc=$?
  rm -f "$_nf"
  return $_rc
}

do_install() {
  need_root
  detect_os; detect_init; detect_virt; detect_net
  printf "\n${BOLD}wg-luodi：WireGuard 落地一键脚本（版本 %s）${NC}\n" "$WGL_VERSION"
  print_env
  # 已经装过、又没给新配置/新端口：直接更新到这个版本（配置、端口、模式都保留）
  if installed && [ -z "$WG_CONF_FILE$WG_PORTS" ] && [ "${WGL_FORCE_REINSTALL:-0}" != 1 ]; then
    say ""
    say "这台服务器已经装过 wg-luodi（版本 $(st_get VERSION)），现在自动更新到 $WGL_VERSION。"
    do_update || return 1
    _can_ask || return 0
    say ""
    say "  1) 完成，退出"
    say "  2) 打开管理菜单（看状态、加减端口、换配置）"
    say "  3) 重新安装（重新粘贴配置、重新选端口）"
    ask "请选择" 1
    case "$ANS" in
      2) do_menu; return ;;
      3) ;;
      *) return 0 ;;
    esac
  fi
  ensure_tools
  mkdir -p "$WGL_DIR"; chmod 700 "$WGL_DIR"
  _tc="$WGL_DIR/wg.conf.new"
  step "[1/2] WireGuard 配置"
  get_conf "$_tc"
  step "[2/2] 端口"
  get_ports
  _req="${WG_MODE:-$(st_get REQ_MODE)}"; _req="${_req:-auto}"
  case "$_req" in auto|kernel|userspace) ;; *) die "WG_MODE 只能是 auto、kernel 或 userspace" ;; esac
  step "[自动] 后面不用你操作了"
  check_endpoint
  ensure_singbox
  choose_mode "$_req"
  _lock 60 || die "另一个 wg-luodi 正在运行，请稍后再试。"
  [ -f "$CONF" ] && cp -p "$CONF" "$CONF.prev"
  mv -f "$_tc" "$CONF"; chmod 600 "$CONF"
  st_set MODE "$MODE"; st_set REQ_MODE "$_req"; st_set PORTS "$PORTS"; st_set EP_FAM "$EP_FAM"; st_set EP_MARK ""
  st_set INIT "$INIT"; st_set VERSION "$WGL_VERSION"
  pick_gateway_ports
  gen_gateway
  self_install
  install_services
  start_and_check_gateway || { _unlock; die "网关启动失败，节点配置没有改动。"; }
  step "[节点] 给走 WireGuard 的端口改路由"
  rm -f "$WGL_DIR/failed" "$WGL_DIR/v6failed"
  apply_all apply 1
  v6_fix_all
  _unlock
  log "安装完成：模式 $MODE，端口 $PORTS"
  step "装好了！"
  say "  走 WireGuard 的端口：$PORTS"
  say "  WireGuard 出口 IP：${WIP:-（暂时没测通）}"
  v6_report
  say ""
  say "  怎么确认生效："
  say "  1. 手机/电脑客户端连上“端口在上面列表里”的节点，浏览器打开 ip.sb，显示的应该是 WireGuard 出口 IP；"
  say "  2. 连其它端口的节点打开 ip.sb，显示的还是服务器平时的出口 IP；"
  say "  3. 或者直接在服务器上运行：wg-luodi test   （逐个节点自动实测）"
  say ""
  say "  以后管理：输入 wg-luodi 打开中文菜单。以后在这些端口新搭的节点，会自动走 WireGuard。"
}

# ---------- 23. 管理命令 ----------
do_up() { # 网关服务启动前调用：内核网卡模式建网卡，无网卡模式清掉可能残留的网卡
  load_all
  if [ "$MODE" = kernel ]; then kernel_up || exit 1
  else
    _has ip && ip link show dev "$WGL_IFACE" >/dev/null 2>&1 && kernel_down
    _has ip && _ep_rule_del
  fi
  exit 0
}
do_down() { _has ip && kernel_down; exit 0; }

do_check() {
  QUIET=1
  installed || exit 0
  find_jq || exit 0
  load_all
  INIT=$(st_get INIT)
  _IN_CHECK=1
  _lock 0 || exit 0
  if gw_active; then
    if [ "$MODE" = kernel ] && ! kernel_ensure; then log "要重建网卡（网卡不见了或要重新选路），重启网关"; gw_restart; fi
  elif gw_picking; then
    log "网关正在启动（选路中），这次巡检不重启它"
  else
    log "网关没在运行，重新启动"; gw_restart
  fi
  apply_all apply 1 >/dev/null 2>&1
  v6_fix_all >/dev/null 2>&1
  _unlock
  exit 0
}

_ports_change() { # _ports_change add|del 端口…
  load_all; find_jq || die "找不到 jq"; INIT=$(st_get INIT)
  shift_act="$1"; shift
  _in="$*"
  if [ -z "$_in" ]; then
    say "现在走 WireGuard 的端口：$PORTS"
    if [ "$shift_act" = add ]; then ask "要加哪些端口？可以填多个，用空格隔开" ""; else ask "要去掉哪些端口？可以填多个，用空格隔开" ""; fi
    _in="$ANS"
  fi
  parse_ports "$_in" || die "$PARSE_ERR"
  _new=""
  if [ "$shift_act" = add ]; then
    _new="$PORTS $PORTS_OUT"
  else
    for _p in $PORTS; do case " $PORTS_OUT " in *" $_p "*) ;; *) _new="$_new $_p" ;; esac; done
  fi
  _new=$(printf '%s\n' $_new | grep -E '^[0-9]+$' | sort -n -u | tr '\n' ' ' | sed 's/ $//')
  _sp=$(st_get SOCKS_PORT); _dp=$(st_get DNS_PORT)
  case " $_new " in *" $_sp "*|*" $_dp "*) die "端口 $_sp / $_dp 是本机网关自己在用的，不能当节点端口。" ;; esac
  [ -n "$_new" ] || die "至少要留一个端口。想全部去掉请用卸载：wg-luodi uninstall"
  _lock 60 || die "另一个 wg-luodi 正在运行，请稍后再试。"
  PORTS="$_new"; st_set PORTS "$PORTS"
  rm -f "$WGL_DIR/failed"
  step "更新节点"
  apply_all apply 1
  v6_fix_all
  _unlock
  info "现在走 WireGuard 的端口：$PORTS"
}

do_set_conf() { # do_set_conf [文件]：换一份 WireGuard 配置（换钥匙时用）。节点配置不用动。
  load_all; find_jq || die "找不到 jq"
  detect_os; detect_virt; detect_net; INIT=$(st_get INIT)
  [ -n "$1" ] && WG_CONF_FILE="$1"
  _tc="$WGL_DIR/wg.conf.new"
  get_conf "$_tc"
  check_endpoint
  _new_fam="$EP_FAM"
  _lock 60 || die "另一个 wg-luodi 正在运行，请稍后再试。"
  # 先看看旧配置现在通不通：通的话，新配置测不通就自动换回旧的（防止贴错配置把好好的隧道弄断）
  _old_ok=""; _old_fam=$(st_get EP_FAM)
  gw_active && _old_ok=$(wg_exit_ip)
  cp -p "$CONF" "$CONF.prev"
  mv -f "$_tc" "$CONF"; chmod 600 "$CONF"
  st_set EP_FAM "$_new_fam"; st_set EP_MARK ""
  if ! write_gw_json "$GW_JSON.new" || ! "$SB" check -c "$GW_JSON.new" >/dev/null 2>&1; then
    mv -f "$CONF.prev" "$CONF"; st_set EP_FAM "$_old_fam"; rm -f "$GW_JSON.new"; _unlock
    die "新配置生成的网关配置没通过检查，已换回旧配置。"
  fi
  cp -p "$GW_JSON" "$GW_JSON.prev" 2>/dev/null
  mv -f "$GW_JSON.new" "$GW_JSON"
  start_and_check_gateway
  if [ -z "$WIP" ] && [ -n "$_old_ok" ] && [ "${WG_KEEP_NEW:-0}" != 1 ]; then
    warn "新配置测不通，旧配置刚才是通的，自动换回旧配置。"
    cp -p "$CONF" "$CONF.bad"; chmod 600 "$CONF.bad"
    mv -f "$CONF.prev" "$CONF"; st_set EP_FAM "$_old_fam"
    if [ -f "$GW_JSON.prev" ]; then mv -f "$GW_JSON.prev" "$GW_JSON"; else load_all; write_gw_json "$GW_JSON"; fi
    start_and_check_gateway
    _unlock
    say "  测不通的新配置留在 $CONF.bad（权限 600）。确定要用它（比如落地机还没开好），运行：WG_KEEP_NEW=1 wg-luodi set-conf $CONF.bad"
    return 1
  fi
  rm -f "$GW_JSON.prev"
  # 隧道支持的 IP 类型变了（比如新配置没有 IPv6），节点不用改：网关自己处理
  _unlock
  info "WireGuard 配置已更换。旧配置留在 $CONF.prev（权限 600）。"
}

do_mode() { # do_mode auto|kernel|userspace
  load_all; find_jq || die "找不到 jq"
  detect_os; detect_virt; detect_net; INIT=$(st_get INIT)
  _req="$1"
  if [ -z "$_req" ]; then
    say "现在的模式：$(st_get MODE)（$( [ "$(st_get MODE)" = kernel ] && echo 内核网卡模式 || echo 无网卡模式 )）"
    say "  1) 自动（能用内核网卡就用，推荐）"
    say "  2) 内核网卡模式（kernel，需要 WireGuard 内核模块）"
    say "  3) 无网卡模式（userspace，不需要 TUN 和内核模块）"
    ask "请选择" 1
    case "$ANS" in 2) _req=kernel ;; 3) _req=userspace ;; *) _req=auto ;; esac
  fi
  case "$_req" in auto|kernel|userspace) ;; *) die "模式只能是 auto、kernel 或 userspace" ;; esac
  check_endpoint
  choose_mode "$_req"
  _lock 60 || die "另一个 wg-luodi 正在运行，请稍后再试。"
  # 先按旧模式停掉网关（会拆掉旧网卡），再换配置启动
  case "$INIT" in systemd) systemctl stop wg-luodi.service >/dev/null 2>&1 ;; openrc) rc-service wg-luodi stop >/dev/null 2>&1 ;; *) _gw_kill ;; esac
  _has ip && kernel_down
  st_set MODE "$MODE"; st_set REQ_MODE "$_req"; st_set EP_MARK ""
  gen_gateway
  start_and_check_gateway; _rc=$?
  _unlock
  if [ "$MODE" = kernel ] && [ -z "$WIP" ]; then
    say "  内核网卡模式没测通的话，可以先换回无网卡模式：wg-luodi mode userspace"
  fi
  return $_rc
}

do_reapply() {
  load_all; find_jq || die "找不到 jq"; INIT=$(st_get INIT)
  _lock 60 || die "另一个 wg-luodi 正在运行，请稍后再试。"
  rm -f "$WGL_DIR/failed" "$WGL_DIR/v6failed" "$WGL_DIR"/backup/*.flap
  gw_active || start_and_check_gateway
  step "重新检查所有节点"
  apply_all apply 1
  v6_fix_all
  _unlock
}

do_restart() {
  load_all; INIT=$(st_get INIT)
  start_and_check_gateway
}

do_uninstall() {
  need_root
  installed || [ -d "$WGL_DIR" ] || die "没有安装 wg-luodi。"
  find_jq || ensure_tools
  INIT=$(st_get INIT); [ -n "$INIT" ] || detect_init
  PORTS=""
  if [ "$1" != "-y" ] && [ "${WG_YES:-0}" != 1 ]; then
    say "卸载会：把所有节点配置恢复成原来的样子（端口不再走 WireGuard）、删掉网关和 WireGuard 配置。"
    ask "确定要卸载吗？输入 y 确认" "N"
    case "$ANS" in y|Y|yes|YES) ;; *) say "已取消。"; return 0 ;; esac
  fi
  _lock 60 || die "另一个 wg-luodi 正在运行，请稍后再试。"
  step "[1/3] 恢复节点配置"
  rm -f "$WGL_DIR/failed"
  apply_all strip 1
  _bad=0
  discover_nodes | while IFS='|' read -r k c st sn b al; do
    [ "$k" = hysteria ] && grep -q '^# wg-luodi begin' "$c" 2>/dev/null && exit 1
    [ "$k" = xray ] || [ "$k" = sing-box ] || continue
    "$JQ" -e '[.outbounds[]? | select(.tag == "wg-luodi")] | length > 0' "$c" >/dev/null 2>&1 && exit 1
    true   # 这个节点已经干净了（没有这行，最后一个节点干净时循环会返回 1，被误判成“没恢复”）
  done || _bad=1
  step "[2/3] 删除网关服务"
  remove_services
  _has ip && kernel_down
  step "[3/3] 删除文件"
  rm -f "$WGL_CMD"
  rm -rf "$WGL_LIB"
  if [ "$_bad" = 1 ]; then
    _keep="/root/wg-luodi-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$_keep" && cp -rp "$WGL_DIR/backup" "$_keep/" 2>/dev/null
    warn "有的节点配置没能自动恢复，原始备份留在 $_keep，可以手动还原。"
  fi
  _unlock
  rm -rf "$WGL_DIR"
  info "卸载完成。系统里装的 jq、curl、wireguard-tools 这些通用小工具没有删（别的程序可能也在用）。"
}

# 测速：同一个文件，经 WireGuard 和经服务器平时的出口各下载一次，对比速度，顺便说明 WireGuard 走的是哪条路。
# 测速：一段一段分开测，最后用一句话说清楚慢在哪：
#   ① 直接用 WireGuard 网卡下载（不经过节点、不经过网关）= 落地机 + 线路本身能跑多快；
#   ② 同上开 4 个连接 = 落地机总带宽还有没有余量（单个连接是不是被延迟/丢包卡住）；
#   ③ 经本机网关下载 = 节点实际走的路；④ 服务器平时的出口（装了 L2TP 就是 L2TP）用来对比。
do_speed() {
  load_all; find_jq || die "找不到 jq"; INIT=$(st_get INIT)
  step "测速（每项下载 25MB，最多 20 秒，全部测完一两分钟）"
  if [ "$MODE" = kernel ]; then
    say "  WireGuard 连落地机走的网卡：$(_ep_dev_show)    隧道 MTU：$(wg_mtu)"
    [ "$(st_get EP_MARK)" = off ] && [ -n "$(_l2tp_note)" ] && \
      warn "WireGuard 现在套在 L2TP 里面走（每个包包两层），速度不会超过 L2TP。直连没通过检查，详情看 /etc/wg-luodi/log"
  fi
  say "  CPU：$(nproc 2>/dev/null || echo '?') 核    当前负载：$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
  if [ "$MODE" = kernel ]; then _rw=$(_rtt -m "$WGL_MARK"); else _rw=""; fi
  _rd=$(_rtt)
  say "  到 1.1.1.1 的延迟：经 WireGuard ${_rw:-测不出来} ms，经服务器平时的出口 ${_rd:-测不出来} ms"
  gw_active || { err "网关没在运行，测不了 WireGuard 的速度（试试 wg-luodi restart）"; return 1; }
  _raw=""; _raw4=""
  if [ "$MODE" = kernel ]; then
    if [ "$WG_HAS4" = 1 ]; then _fam=-4; else _fam=-6; fi
    say "  ① 直接用 WireGuard 网卡下载（不经过节点和网关）…"
    _raw=$(_speed "$_fam" --interface "$WGL_IFACE")
    say "  ② 同上，同时开 4 个连接…"
    _raw4=$(_speed_par 4 "$_fam" --interface "$WGL_IFACE")
  fi
  say "  ③ 经本机网关下载（节点实际走的路）…"
  _w=$(_speed -x "socks5h://$(st_get SOCKS_USER):$(st_get SOCKS_PASS)@127.0.0.1:$(st_get SOCKS_PORT)")
  say "  ④ 经服务器平时的出口下载…"
  _d=$(_speed)
  say ""
  [ "$MODE" = kernel ] && say "  ① WireGuard 网卡，1 个连接：${_raw:-测不出来} Mbps" && say "  ② WireGuard 网卡，4 个连接：${_raw4:-测不出来} Mbps"
  say "  ③ 经网关（节点实际走的路）：${_w:-测不出来} Mbps"
  say "  ④ 服务器平时的出口：${_d:-测不出来} Mbps$(_l2tp_note)"
  say ""
  _speed_verdict "$_raw" "$_raw4" "$_w" "$_d" | sed 's/^/  结论：/; s/^  结论：    /        /'
}

# ---------- 24. 中文菜单 ----------
do_menu() {
  need_root
  installed || { do_install; return; }
  while :; do
    printf "\n${BOLD}wg-luodi 管理菜单${NC}（模式：%s，端口：%s）\n" "$(st_get MODE)" "$(st_get PORTS)"
    say "  1) 查看状态（握手、出口 IP、节点情况）"
    say "  2) 逐个节点实测出口 IP"
    say "  3) 添加走 WireGuard 的端口"
    say "  4) 去掉走 WireGuard 的端口"
    say "  5) 更换 WireGuard 配置（换钥匙 / 换落地机）"
    say "  6) 切换模式（内核网卡 / 无网卡）"
    say "  7) 重新应用（节点被别的脚本重建后用）"
    say "  8) 重启网关"
    say "  9) 卸载（恢复所有节点、删除全部）"
    say "  10) 更新 wg-luodi 到最新版（配置、端口都保留）"
    say "  11) 测速（WireGuard 和服务器平时的出口对比）"
    say "  0) 退出"
    ask "请选择" 1
    case "$ANS" in
      1) ( do_status ) ;;
      2) ( do_test ) ;;
      3) ( _ports_change add ) ;;
      4) ( _ports_change del ) ;;
      5) ( do_set_conf ) ;;
      6) ( do_mode ) ;;
      7) ( do_reapply ) ;;
      8) ( do_restart ) ;;
      9) do_uninstall; return 0 ;;
      10) ( do_self_update ) && say "  请重新输入 wg-luodi 打开新版菜单。"; return 0 ;;
      11) ( do_speed ) ;;
      0|q|Q) return 0 ;;
      *) warn "没有这个选项" ;;
    esac
  done
}

usage() {
  cat <<EOF
wg-luodi $WGL_VERSION —— WireGuard 落地管理
  wg-luodi                 打开中文菜单
  wg-luodi status          查看状态和出口 IP
  wg-luodi test [端口]      逐个节点实测出口 IP
  wg-luodi speed           测速：WireGuard 和服务器平时的出口对比
  wg-luodi add-port 端口…   添加走 WireGuard 的端口
  wg-luodi del-port 端口…   去掉走 WireGuard 的端口
  wg-luodi set-conf [文件]  更换 WireGuard 配置（不给文件就让你粘贴）
  wg-luodi mode auto|kernel|userspace   切换模式（userspace = 强制无网卡模式）
  wg-luodi reapply         重新给所有节点应用设置
  wg-luodi restart         重启网关
  wg-luodi update          更新到 GitHub 上的最新版（配置、端口都保留）
  wg-luodi uninstall [-y]  卸载并恢复所有节点
EOF
}

# ---------- 25. 入口 ----------
# 没有参数：装好了就打开菜单（用 wg-luodi 命令时），没装就开始安装。
main() {
  # 会提问的命令：先找到键盘在哪（管道运行时改从 /dev/tty 读），并记下终端设置
  case "${1:-}" in hook|check|up|down|apply-update|version|-v|--version|help|-h|--help) ;; *) tty_init ;; esac
  case "${1:-}" in
    hook) shift; do_hook "$@" ;;
    check) do_check ;;
    up) do_up ;;
    down) do_down ;;
    status) need_root; do_status ;;
    test) need_root; do_test "$2" ;;
    speed) need_root; do_speed ;;
    add-port) need_root; shift; _ports_change add "$@" ;;
    del-port|remove-port) need_root; shift; _ports_change del "$@" ;;
    set-conf|replace-conf) need_root; do_set_conf "$2" ;;
    mode) need_root; do_mode "$2" ;;
    reapply) need_root; do_reapply ;;
    restart) need_root; do_restart ;;
    uninstall) do_uninstall "$2" ;;
    install) WGL_FORCE_REINSTALL=1; do_install ;;
    update|upgrade) do_self_update ;;
    apply-update) do_update ;;
    menu) do_menu ;;
    version|-v|--version) echo "wg-luodi $WGL_VERSION" ;;
    help|-h|--help) usage ;;
    "")
      _me=$(readlink -f "$0" 2>/dev/null || echo "$0")
      if [ "$_me" = "$(readlink -f "$WGL_CMD" 2>/dev/null)" ] && installed; then do_menu; else do_install; fi ;;
    *) usage; exit 1 ;;
  esac
}

# 测试时可以只加载函数、不执行（WGL_SOURCE_ONLY=1）
[ "${WGL_SOURCE_ONLY:-0}" = 1 ] || main "$@"
