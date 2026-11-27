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

## 多个落地同时在线

手里有好几份 WireGuard 配置（比如美国、英国、新加坡各一份），想让不同端口的节点走不同落地？
先按上面装好第一个（比如叫 `us`），再加另外两个：

```bash
wg-luodi add-landing uk   # 粘贴英国的配置，再选走 uk 的端口
wg-luodi add-landing sg   # 粘贴新加坡的配置，再选走 sg 的端口
```

每个端口最多属于一个落地。常用命令：

```bash
wg-luodi landings                    # 列出所有落地：名字、端口、出口 IP
wg-luodi add-port uk 45192 50000     # 把端口加到 uk（只有一个落地时落地名可以省略）
wg-luodi del-port uk 45192           # 把端口从 uk 去掉
wg-luodi set-conf uk                 # 换 uk 的配置（换钥匙时用）
wg-luodi speed uk                    # 测 uk 这条路的速度
wg-luodi del-landing sg              # 删掉 sg，它的端口恢复成不走 WireGuard
wg-luodi rename-landing default us   # 给落地改名
```

老版本升级上来时，原来的那份配置会自动变成一个叫 `default` 的落地，端口和网关端口都保留，
节点配置第一次重新应用时会自动换成新格式（节点会重启一次）。想改名字就用 `rename-landing`。
