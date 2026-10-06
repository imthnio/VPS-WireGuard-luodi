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

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
