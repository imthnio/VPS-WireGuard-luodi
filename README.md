# 小白一键 WireGuard 落地（wg-luodi）

你手里有一份 **WireGuard 配置**（落地机 / 机场给你的，里面有 `[Interface]` 和 `[Peer]`），
想让服务器上**某几个端口**的节点用 WireGuard 的 IP 上网，其它端口的节点照旧用服务器自己的 IP？
运行这个脚本，只回答两个问题就行：

1. 把 WireGuard 配置粘贴进来；
2. 哪些端口要走 WireGuard（可以填多个，比如 `45192 50000`）。

剩下的全自动：检测系统、检测能不能用内核 WireGuard、装好需要的程序、改好节点配置、设成开机自启。
**SSH 和服务器自己的网络完全不动**（不改默认路由，不会把你锁在门外）。

支持 Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Alpine，x86_64 和 ARM64；
KVM、母鸡、OpenVZ、LXC、NAT 小鸡都能用，**没有 TUN、没有 WireGuard 内核模块也能用**。

## 一键安装

```bash
# 1. SSH 连上你的服务器（root 用户）
# 2. 粘贴下面这一行，回车（没有 curl 会先装上）：
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; U=https://raw.githubusercontent.com/imthnio/VPS-WireGuard-luodi/main/wg-luodi.sh; command -v curl >/dev/null 2>&1 || apk add --no-cache curl || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl; } || dnf install -y curl || yum install -y curl; rm -f /tmp/wg-luodi.sh; if { curl -fsSL -o /tmp/wg-luodi.sh "$U" || wget -O /tmp/wg-luodi.sh "$U"; } && [ -s /tmp/wg-luodi.sh ]; then sh /tmp/wg-luodi.sh; else echo "脚本没下载下来。请把上面的报错发出来。"; fi
# 3. 按提示粘贴 WireGuard 配置（粘完按一次回车空一行），再输入端口。看不懂就回车用默认。
```

只有 IPv6 的服务器连不上 GitHub，把上面这一行里的 `U=https://raw.githubusercontent.com/...`
改成 `U=https://v6.gh-proxy.org/https://raw.githubusercontent.com/...` 再运行。

## 它做了什么（大白话）

- 在本机 `127.0.0.1` 上开一个**只有本机能连**的小网关（sing-box 程序），它负责把流量从 WireGuard 发出去。
- 找到服务器上的节点（Xray、sing-box、Hysteria2，包括 [VPS-dajianjiedian](https://github.com/imthnio/VPS-dajianjiedian) 搭的节点），
  只给**你指定的端口**加一条规则：“这个端口进来的流量交给网关”。其它端口一个字都不改。
- 改之前先备份，改完先用节点程序自己检查配置，通过了才重启；不通过就原样放回去，**原来的节点不会坏**。
- 走 WireGuard 的节点，**域名解析（DNS）也走 WireGuard**，不会暴露服务器。
- WireGuard 断了的时候，这些端口暂时上不了网，**不会偷偷改用服务器 IP**。
- 开机自启（systemd / Alpine 的 OpenRC 都支持），每 2 分钟巡检一次：节点被别的脚本重建了、路由规则丢了，会自动补回去。
- 以后在这些端口上**新搭的节点也会自动走 WireGuard**（和 VPS-dajianjiedian 配合时，节点启动前就改好）。

### 两种模式，脚本自动选

| 你的服务器 | 用哪种模式 | 说明 |
| --- | --- | --- |
| KVM 小鸡、独立服务器（母鸡） | 内核网卡模式（kernel） | 建一张叫 `wg-luodi` 的 WireGuard 网卡，最快。不改默认路由，只有网关发出的、带专用标记的包才走它 |
| LXC、OpenVZ、NAT 小鸡（没有内核模块） | 无网卡模式（userspace） | WireGuard 在 sing-box 程序里跑，**不需要 TUN、不需要内核模块** |
| 只有 IPv6 的服务器 | 两种都行 | 落地机地址也得有 IPv6，否则脚本会告诉你该找谁要 |

想强制用某种模式（比如两种都测一遍）：

```bash
wg-luodi mode userspace   # 强制无网卡模式
wg-luodi mode kernel      # 强制内核网卡模式（服务器不支持时会用大白话告诉你缺什么、该问服务商什么）
wg-luodi mode auto        # 回到自动
```

## 怎么确认成功了

1. 手机/电脑客户端连上**端口在名单里**的节点，浏览器打开 [ip.sb](https://ip.sb)，显示的应该是 **WireGuard 的出口 IP**；
2. 连**其它端口**的节点打开 ip.sb，显示的还是**服务器自己的 IP**；
3. 不想拿手机试？在服务器上运行：

```bash
wg-luodi test          # 逐个节点自动实测出口 IP，每个节点后面打 ✔ 或 ✘
wg-luodi status        # 看握手时间、WireGuard 出口 IP、服务器自己的 IP、哪些节点走了 WireGuard
```

## 日常管理

输入 `wg-luodi` 打开中文菜单，或者直接用命令：

| 命令 | 作用 |
| --- | --- |
| `wg-luodi status` | 查看状态（握手、出口 IP、节点情况） |
| `wg-luodi test [端口]` | 逐个节点实测出口 IP |
| `wg-luodi add-port 50000 50001` | 再加几个走 WireGuard 的端口 |
| `wg-luodi del-port 50000` | 去掉某个端口（那个节点恢复用服务器 IP） |
| `wg-luodi set-conf` | 换 WireGuard 配置（换钥匙 / 换落地机）。旧配置本来是通的、新配置却测不通时，会自动换回旧的 |
| `wg-luodi mode auto\|kernel\|userspace` | 切换模式 |
| `wg-luodi reapply` | 重新给所有节点应用设置（节点被别的脚本重建后用，平时巡检会自动做） |
| `wg-luodi restart` | 重启网关 |
| `wg-luodi update` | 更新到最新版。WireGuard 配置、端口、模式都保留；更新后网关起不来会自动换回旧版 |
| `wg-luodi uninstall` | 卸载：节点配置逐字节还原，删除脚本装的所有东西 |

**更新**：在已经装过的服务器上，再粘贴一次上面的一键安装命令就会自动更新到最新版（或者运行 `wg-luodi update`）。
不用重新粘贴配置、不用重新选端口；sing-box 有新版也会一起换上。更新后网关起不来，会自动换回旧版。
想换配置、换端口重新装：运行安装命令后选「重新安装」，或用下面的免交互安装。

重复运行安装命令不会出错，也不会重复改配置。

## 免交互安装（批量 / 自动化）

```bash
# 先把 WireGuard 配置存成文件（脚本会把它复制到 /etc/wg-luodi/wg.conf，权限 600）
WG_CONF_FILE=/root/wg.conf WG_PORTS="45192 50000" WG_MODE=auto sh /tmp/wg-luodi.sh
```

- `WG_CONF_FILE`：WireGuard 配置文件路径
- `WG_PORTS`：走 WireGuard 的端口，空格或逗号隔开，也可以写范围 `50000-50010`
- `WG_MODE`：`auto`（默认）/ `kernel` / `userspace`
- 卸载不提问：`wg-luodi uninstall -y`

## 文件都放在哪

| 位置 | 是什么 |
| --- | --- |
| `/etc/wg-luodi/wg.conf` | 你的 WireGuard 配置（权限 600，只有 root 能看） |
| `/etc/wg-luodi/state` | 模式、端口、网关端口和随机密码 |
| `/etc/wg-luodi/backup/` | 节点配置的备份（卸载时用来还原） |
| `/usr/local/lib/wg-luodi/` | 网关程序 sing-box（约 40–80 MB） |
| `/usr/local/bin/wg-luodi` | 管理命令 |
| `/var/log/wg-luodi.log` | 日志 |

## 常见问题

**Q：粘贴配置后没反应？**
粘贴完按一次回车（空一行）就结束；也可以按 Ctrl+D。配置里必须有 `PrivateKey`、`Address`、`PublicKey`、`Endpoint`、`AllowedIPs`，
而且 `AllowedIPs` 要包含 `0.0.0.0/0`（或 `::/0`）才能当落地用。从 Windows 复制过来的也没问题。

**Q：端口填哪个？**
填你打算用来搭节点的端口（脚本不会去检测，直接问你）。之后在这些端口上搭的节点会自动走 WireGuard。NAT 小鸡上，填公网端口或本机端口都行。

**Q：`wg-luodi test` 显示 ✘ / 出口 IP 是空的？**
先看 `wg-luodi status` 里的握手时间。没有握手，常见原因：配置过期或钥匙换了、落地机不在线、服务器到落地机的 UDP 被屏蔽。
换新配置用 `wg-luodi set-conf`。

**Q：我的节点是 x-ui / 3x-ui / Marzban 等面板搭的，为什么没改？**
面板每次都会重新生成配置，脚本改了也会被面板覆盖，所以不碰。运行 `wg-luodi status`，它会把要在面板里加的 SOCKS5 出站
（地址 `127.0.0.1`、端口、用户名、密码）打印出来；在面板里给对应入站加一条路由，出站选它就行。

**Q：Hysteria2 节点能按端口分吗？**
Hysteria2 一个程序只开一个端口，所以端口在名单里，这个 Hysteria2 节点整个走 WireGuard。
如果你自己在 Hysteria2 配置里写了 `outbounds:`，脚本不会去动它，会提示你。

**Q：会不会把服务器弄断网 / SSH 连不上？**
不会。脚本不改默认路由：内核网卡模式只用一张专用路由表，只有网关发出的、带标记的包才走它；无网卡模式根本不建网卡。

**Q：服务器重启后还有效吗？**
有效。systemd 机器上是 `wg-luodi` 服务和 `wg-luodi-watch` 定时器；Alpine 上是 OpenRC 的 `wg-luodi` 和 `wg-luodi-watch` 服务。

**Q：只有 IPv6 的服务器能用吗？**
能，但落地机地址也要能用 IPv6 连上。WireGuard 配置只有 IPv4 地址时，走 WireGuard 的节点会只用 IPv4 访问网站，反过来也一样，
所以不会因为“这一头没有对应的地址”而打不开网页。

**Q：内核网卡模式用不了，要问服务商什么？**
脚本会用大白话告诉你。一般是：“请帮我开启 WireGuard 内核模块”（LXC / OpenVZ 小鸡通常开不了）。用不了也没关系，无网卡模式照样能用。

**Q：`wg-luodi test` 显示 ✔，但手机连不上 Hysteria2 节点？**
Hysteria2 用的是 UDP。NAT 小鸡的端口转发很多只转 TCP 不转 UDP，要找商家给这个端口开 UDP 转发。这和本脚本无关，不装本脚本也一样连不上。

**Q：同一份 WireGuard 配置能装在两台服务器上吗？**
不要。一份配置（同一把钥匙）同时只能在一台服务器上用，两台一起用会互相抢，隧道时通时断。每台服务器找落地机要一份单独的配置。

**Q：小内存小鸡装的时候会不会把内存撑爆？**
不会。下载和解压 sing-box 放在硬盘上，不用 /tmp（很多小鸡的 /tmp 是内存盘）。硬盘剩余要有大约 150MB。

**Q：怎么彻底卸载？**
`wg-luodi uninstall`。所有节点配置还原成改之前的样子（逐字节一样），网关、服务、路由规则、配置文件全部删掉，节点继续正常运行。

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
