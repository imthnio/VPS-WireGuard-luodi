"""wg-luodi 测试用的公共小工具。

不碰真的系统：所有路径都放进临时目录（WGL_DIR、WGL_LIB、XN_NODES…），
危险命令（ip、wg、modprobe、apt-get、apk、systemctl、rc-service…）全部换成假的，只记日志。
钥匙全部在测试运行时现生成，仓库里没有任何钥匙。

环境变量：
  WGL_TEST_BIN          放 xray、sing-box、hysteria 的目录（没有就跳过需要它们的测试）
  WGL_TEST_BUSYBOX_DIR  busybox 小工具目录（有就用 busybox sh + busybox 的 sed/awk/grep 跑，模拟 Alpine）
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "wg-luodi.sh"
BIN = os.environ.get("WGL_TEST_BIN", "")
BB = os.environ.get("WGL_TEST_BUSYBOX_DIR", "")


def have_bins():
    return bool(BIN) and all((Path(BIN) / b).exists() for b in ("xray", "sing-box", "hysteria"))


def rand_key():
    """一个格式正确的随机 WireGuard 钥匙（只用来测解析，不用来连接）。"""
    return base64.b64encode(os.urandom(32)).decode()


def wg_keypair():
    out = subprocess.run([str(Path(BIN) / "sing-box"), "generate", "wg-keypair"],
                         capture_output=True, text=True, check=True).stdout
    kv = dict(line.split(": ", 1) for line in out.strip().splitlines())
    return kv["PrivateKey"], kv["PublicKey"]


def reality_keypair():
    out = subprocess.run([str(Path(BIN) / "xray"), "x25519"], capture_output=True, text=True, check=True).stdout
    kv = {}
    for line in out.strip().splitlines():
        k, v = line.split(":", 1)
        kv[k.strip()] = v.strip()
    priv = kv.get("PrivateKey") or kv.get("Private key")
    pub = kv.get("Password") or kv.get("Public key") or kv.get("PublicKey")
    return priv, pub


def free_port():
    while True:
        s1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s1.bind(("127.0.0.1", 0))
        p = s1.getsockname()[1]
        s1.close()
        try:
            s2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s2.bind(("0.0.0.0", p))
            s2.close()
        except OSError:
            continue
        if 20000 <= p <= 60000:
            return p


def box_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("192.0.2.1", 9))
    ip = s.getsockname()[0]
    s.close()
    return ip


FAKE_IP = r'''#!/bin/sh
echo "ip $*" >> "$FAKE_LOG"
case "$*" in
  "-V") echo "ip utility, iproute2-6.1.0"; exit 0 ;;
  *"route show default"*) echo "default via 10.9.9.1 dev eth0"; exit 0 ;;
  *"route get"*) echo "1.1.1.1 via 10.9.9.1 dev eth0 src 10.9.9.2"; exit 0 ;;
  *"rule del"*) exit 1 ;;
  "link add dev wgl-probe0 type wireguard") [ "$FAKE_NO_KMOD" = 1 ] && exit 1; exit 0 ;;
  "link show dev wg-luodi") [ -f "$FAKE_LOG.link" ] && exit 0 || exit 1 ;;
  "link add dev wg-luodi type wireguard") touch "$FAKE_LOG.link"; exit 0 ;;
  "link del dev wg-luodi") [ -f "$FAKE_LOG.link" ] || exit 1; rm -f "$FAKE_LOG.link"; exit 0 ;;
esac
exit 0
'''

FAKE_LOGONLY = r'''#!/bin/sh
echo "$(basename "$0") $*" >> "$FAKE_LOG"
exit 0
'''

FAKE_FAIL = r'''#!/bin/sh
echo "$(basename "$0") $*" >> "$FAKE_LOG"
exit 1
'''

# 假的 OpenRC：真的把网关和节点进程跑起来，模拟服务的启动、停止、重启。
FAKE_RC_SERVICE = r'''#!/usr/bin/env python3
import os, signal, subprocess, sys, time
d = os.environ["FAKE_SVC_DIR"]
os.makedirs(d, exist_ok=True)
name = sys.argv[1]
act = sys.argv[2] if len(sys.argv) > 2 else "status"
with open(os.path.join(d, "log"), "a") as f:
    f.write("%s %s\n" % (name, act))
pidf = os.path.join(d, name + ".pid")
sh = os.environ.get("FAKE_SH", "sh").split()
wcmd = os.environ["WGL_CMD"]
bindir = os.environ["XN_BIN_DIR"]

def alive():
    try:
        pid = int(open(pidf).read())
        os.kill(pid, 0)
        st = open("/proc/%d/stat" % pid).read().split(")")[-1].split()[0]
        return st != "Z"
    except Exception:
        return False

def spec():
    if name == "wg-luodi":
        return ([os.environ["WGL_LIB"] + "/sing-box", "run", "-c", os.environ["WGL_DIR"] + "/gw.json"],
                sh + [wcmd, "up"], sh + [wcmd, "down"])
    if name.startswith("xray-node-"):
        nid = name[len("xray-node-"):]
        nd = os.path.join(os.environ["XN_NODES"], nid)
        core = open(os.path.join(nd, "core")).read().strip()
        pre = None
        if os.environ.get("FAKE_DJD_HOOK") == "1" and os.path.exists(wcmd):
            pre = sh + [wcmd, "hook", nid]
        if core == "hysteria":
            return ([bindir + "/hysteria", "server", "-c", nd + "/config.yaml", "--disable-update-check"], pre, None)
        if core == "sing-box":
            return ([bindir + "/sing-box", "run", "-c", nd + "/config.json"], pre, None)
        return ([bindir + "/xray", "-config", nd + "/config.json"], pre, None)
    return (None, None, None)

def start():
    cmd, pre, post = spec()
    if cmd is None:
        return 0
    if alive():
        return 0
    if pre and subprocess.run(pre).returncode != 0:
        return 1
    logf = open(os.path.join(d, name + ".out"), "a")
    p = subprocess.Popen(cmd, stdout=logf, stderr=logf, start_new_session=True)
    open(pidf, "w").write(str(p.pid))
    time.sleep(1.5)
    return 0 if alive() else 1

def stop():
    cmd, pre, post = spec()
    if alive():
        pid = int(open(pidf).read())
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if not alive():
                break
            time.sleep(0.1)
        if alive():
            os.kill(pid, signal.SIGKILL)
    if os.path.exists(pidf):
        os.unlink(pidf)
    if post:
        subprocess.run(post)
    return 0

if act == "start":
    sys.exit(start())
if act == "stop":
    sys.exit(stop())
if act == "restart":
    stop()
    sys.exit(start())
if act == "zap":
    if os.path.exists(pidf):
        os.unlink(pidf)
    sys.exit(0)
if act == "status":
    if spec()[0] is None:
        sys.exit(0)
    sys.exit(0 if alive() else 3)
sys.exit(0)
'''


class Sandbox:
    """一套临时目录 + 假命令 + 环境变量。"""

    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="wgl-test-", dir=os.environ.get("WGL_TEST_TMP")))
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        for name, body in (("ip", FAKE_IP), ("wg", FAKE_LOGONLY), ("modprobe", FAKE_LOGONLY),
                           ("sysctl", FAKE_LOGONLY), ("rc-update", FAKE_LOGONLY), ("openrc-run", FAKE_LOGONLY),
                           ("apt-get", FAKE_FAIL), ("apk", FAKE_FAIL), ("dnf", FAKE_FAIL), ("yum", FAKE_FAIL),
                           ("systemctl", FAKE_FAIL), ("rc-service", FAKE_RC_SERVICE),
                           ("systemd-detect-virt", "#!/bin/sh\necho kvm\n")):
            f = self.stubs / name
            f.write_text(body)
            f.chmod(0o755)
        # jq、curl 用系统里现成的（Alpine 上由 apk 装）
        self.tools = self.tmp / "tools"
        self.tools.mkdir()
        for t in ("jq", "curl", "python3", "openssl", "base64"):
            p = shutil.which(t)
            if p:
                (self.tools / t).symlink_to(p)
        self.etc = self.tmp / "etc-wg-luodi"
        self.lib = self.tmp / "lib"
        self.cmd = self.tmp / "bin" / "wg-luodi"
        self.initd = self.tmp / "init.d"
        self.nodes = self.tmp / "xray-node" / "nodes"
        self.svc = self.tmp / "svc"
        for d in (self.lib, self.cmd.parent, self.initd, self.nodes, self.svc):
            d.mkdir(parents=True, exist_ok=True)
        self.bindir = Path(BIN) if BIN else self.tmp / "nobin"
        if BB:
            self.sh = [str(Path(BB) / "sh")]
            path = "%s:%s:%s" % (self.stubs, self.tools, BB)
        else:
            self.sh = ["sh"]
            path = "%s:%s:/usr/bin:/bin" % (self.stubs, self.tools)
        self.env = {
            "PATH": path, "HOME": str(self.tmp), "TMPDIR": str(self.tmp),
            "WGL_ALLOW_NONROOT": "1", "WGL_DIR": str(self.etc), "WGL_LIB": str(self.lib),
            "WGL_CMD": str(self.cmd), "WGL_SD": str(self.tmp / "systemd"), "WGL_INITD": str(self.initd),
            "XN_NODES": str(self.nodes), "XN_BIN_DIR": str(self.bindir), "WGL_INIT": "openrc",
            "WGL_NO_PROC_SCAN": "1", "WGL_KNOWN_PATHS": "", "WGL_NO_PKG": "1", "WGL_WAIT": "15",
            "FAKE_LOG": str(self.tmp / "fake.log"), "FAKE_SVC_DIR": str(self.svc), "FAKE_SH": " ".join(self.sh),
        }

    def run(self, args, extra=None, stdin=None, timeout=300):
        env = dict(self.env)
        env.update(extra or {})
        return subprocess.run(self.sh + [str(SCRIPT)] + list(args), env=env, input=stdin,
                              capture_output=True, text=True, timeout=timeout)

    def run_cmd(self, args, extra=None, stdin=None, timeout=300):
        """运行装好的管理命令 wg-luodi。"""
        env = dict(self.env)
        env.update(extra or {})
        return subprocess.run(self.sh + [str(self.cmd)] + list(args), env=env, input=stdin,
                              capture_output=True, text=True, timeout=timeout)

    def source(self, snippet, extra=None, stdin=None):
        """只加载脚本里的函数，再跑一小段 shell。"""
        env = dict(self.env)
        env.update(extra or {})
        env["WGL_SOURCE_ONLY"] = "1"
        code = '. "%s"\n%s\n' % (SCRIPT, snippet)
        return subprocess.run(self.sh + ["-c", code], env=env, input=stdin,
                              capture_output=True, text=True, timeout=120)

    def fake_log(self):
        p = Path(self.env["FAKE_LOG"])
        return p.read_text() if p.exists() else ""

    def stop_all(self):
        for pidf in self.svc.glob("*.pid"):
            try:
                os.kill(int(pidf.read_text()), 9)
            except Exception:
                pass

    def cleanup(self):
        self.stop_all()
        shutil.rmtree(self.tmp, ignore_errors=True)


def wg_conf(priv, pub, endpoint, address="10.66.0.2/32", allowed="0.0.0.0/0", dns="10.66.0.1", crlf=False, extra=""):
    lines = ["[Interface]", "PrivateKey = " + priv, "Address = " + address]
    if dns:
        lines.append("DNS = " + dns)
    lines += ["", "[Peer]", "PublicKey = " + pub, "AllowedIPs = " + allowed, "Endpoint = " + endpoint]
    if extra:
        lines.append(extra)
    sep = "\r\n" if crlf else "\n"
    return sep.join(lines) + sep


# ---------- 和 VPS-dajianjiedian 一样格式的节点配置 ----------
def xray_vless_reality(port, uuid, priv, sid, sni="www.samsung.com"):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "0.0.0.0", "port": port, "protocol": "vless",
            "settings": {"clients": [{"id": uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
                "show": False, "dest": sni + ":443", "xver": 0, "serverNames": [sni],
                "privateKey": priv, "shortIds": [sid]}},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}}],
        "outbounds": [{"protocol": "freedom"}],
    }


def xray_ss(port, password):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "0.0.0.0", "port": port, "protocol": "shadowsocks",
                      "settings": {"method": "2022-blake3-aes-128-gcm", "password": password, "network": "tcp,udp"}}],
        "outbounds": [{"protocol": "freedom"}],
    }


def xray_vmess_ws(port, uuid, path):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "0.0.0.0", "port": port, "protocol": "vmess",
                      "settings": {"clients": [{"id": uuid, "alterId": 0}]},
                      "streamSettings": {"network": "ws", "wsSettings": {"path": path}},
                      "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}}],
        "outbounds": [{"protocol": "freedom"}],
    }


def sb_anytls_reality(port, password, priv, sid, sni="www.samsung.com"):
    return {
        "log": {"level": "warning"},
        "inbounds": [{"type": "anytls", "listen": "0.0.0.0", "listen_port": port,
                      "users": [{"name": "xray-node", "password": password}],
                      "tls": {"enabled": True, "server_name": sni, "reality": {
                          "enabled": True, "handshake": {"server": sni, "server_port": 443},
                          "private_key": priv, "short_id": [sid]}}}],
        "outbounds": [{"type": "direct"}],
    }


def hy2_yaml(port, nd, password, obfs):
    return """listen: ":%d"

tls:
  cert: %s/cert.pem
  key: %s/key.pem
  sniGuard: dns-san

obfs:
  type: salamander
  salamander:
    password: "%s"

auth:
  type: password
  password: "%s"

# 不听客户端报的带宽
ignoreClientBandwidth: true
speedTest: false

masquerade:
  type: string
  string:
    content: "<!DOCTYPE html><html><body>Welcome</body></html>"
    statusCode: 200
""" % (port, nd, nd, obfs, password)


def make_node(sb, nid, core, content, link_port=None):
    nd = sb.nodes / str(nid)
    nd.mkdir(parents=True, exist_ok=True)
    (nd / "core").write_text(core + "\n")
    name = "config.yaml" if core == "hysteria" else "config.json"
    if isinstance(content, dict):
        content = json.dumps(content, indent=2) + "\n"
    (nd / name).write_text(content)
    (nd / name).chmod(0o600)
    if link_port:
        (nd / "link_port").write_text("%d\n" % link_port)
    return nd / name
