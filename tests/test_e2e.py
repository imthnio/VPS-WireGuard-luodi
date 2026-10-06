"""端到端测试：在一台机器上用纯用户态程序模拟“服务器 + 落地机”，不建任何网卡。

- 落地机：一个 sing-box，用无网卡的 WireGuard 监听本机 UDP 端口，并且把访问“测 IP 网站”的连接
  改到另一个端口；那个端口固定回答 198.51.100.7（假装是 WireGuard 出口 IP）。
- 测 IP 网站：本机两个小 HTTP 服务。直连访问回答 203.0.113.5（假装是服务器自己的 IP）。
- 节点：和 VPS-dajianjiedian 一样格式的 Xray / sing-box / Hysteria2 节点，真的跑起来。
- 服务管理：假的 rc-service（OpenRC），真的启动/停止进程。

于是“某个端口的节点出口是不是 WireGuard IP”可以在本机完整验证，包括 DNS 也走隧道。
"""
import json
import os
import signal
import subprocess
import sys
import time
import unittest
import uuid
from pathlib import Path

from helpers import (BIN, SCRIPT, Sandbox, box_ip, free_port, have_bins, hy2_yaml, make_node, reality_keypair,
                     sb_anytls_reality, wg_conf, wg_keypair, xray_ss, xray_vless_reality, xray_vmess_ws)

ECHO = r'''
import http.server, sys
body = sys.argv[3].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer((sys.argv[1], int(sys.argv[2])), H).serve_forever()
'''
WG_IP = "198.51.100.7"
SERVER_IP = "203.0.113.5"


@unittest.skipUnless(have_bins(), "需要 WGL_TEST_BIN（xray、sing-box、hysteria）")
class E2E(unittest.TestCase):
    procs = []

    @classmethod
    def setUpClass(cls):
        cls.sb = sb = Sandbox()
        cls.ip = box_ip()
        cls.e1, cls.e2 = free_port(), free_port()
        (sb.tmp / "echo.py").write_text(ECHO)
        for port, body in ((cls.e1, SERVER_IP), (cls.e2, WG_IP)):
            cls.procs.append(subprocess.Popen([sys.executable, str(sb.tmp / "echo.py"), cls.ip, str(port), body]))
        cls.land_port = free_port()
        cls.land_priv, cls.land_pub = wg_keypair()
        cls.cli_priv, cls.cli_pub = wg_keypair()
        cls.land = None
        cls.start_landing(cls.cli_pub)
        subprocess.run(["cp", BIN + "/sing-box", str(sb.lib / "sing-box")], check=True)
        sb.env["WGL_IP_URLS"] = "http://%s:%d/" % (cls.ip, cls.e1)
        # 节点：1 VLESS-REALITY(WG) 2 SS(直连) 3 Hysteria2(WG) 4 AnyTLS-REALITY(WG) 5 VMess-WS(直连)
        cls.p = [free_port() for _ in range(7)]
        rpriv, _ = reality_keypair()
        cls.cfg = {}
        cls.cfg[1] = make_node(sb, 1, "xray", xray_vless_reality(cls.p[1], str(uuid.uuid4()), rpriv, "a1b2"))
        cls.cfg[2] = make_node(sb, 2, "xray", xray_ss(cls.p[2], __import__("base64").b64encode(os.urandom(16)).decode()))
        nd3 = sb.nodes / "3"
        nd3.mkdir(parents=True)
        subprocess.run([BIN + "/hysteria", "cert", "--host", "www.samsung.com", "--cert", str(nd3 / "cert.pem"),
                        "--key", str(nd3 / "key.pem"), "--valid-for", "87600h", "--overwrite"],
                       capture_output=True, check=True)
        cls.cfg[3] = make_node(sb, 3, "hysteria", hy2_yaml(cls.p[3], nd3, os.urandom(16).hex(), os.urandom(16).hex()))
        cls.cfg[4] = make_node(sb, 4, "sing-box", sb_anytls_reality(cls.p[4], os.urandom(8).hex(), rpriv, "c3d4"))
        cls.cfg[5] = make_node(sb, 5, "xray", xray_vmess_ws(cls.p[5], str(uuid.uuid4()), "/v"))
        cls.orig = {k: v.read_bytes() for k, v in cls.cfg.items()}
        for n in range(1, 6):
            r = subprocess.run(["rc-service", "xray-node-%d" % n, "start"], env=cls.envp(), capture_output=True, text=True)
            assert r.returncode == 0, (n, (sb.svc / ("xray-node-%d.out" % n)).read_text())

    @classmethod
    def envp(cls, extra=None):
        e = dict(os.environ)
        e.update(cls.sb.env)
        e.update(extra or {})
        return e

    @classmethod
    def start_landing(cls, peer_pub):
        if cls.land:
            cls.land.terminate(); cls.land.wait()
        conf = {
            "log": {"level": "warn"},
            "dns": {"servers": [{"type": "hosts", "tag": "h", "predefined": {"echo.test": cls.ip}}]},
            "endpoints": [{"type": "wireguard", "tag": "wg-in", "system": False, "address": ["10.66.0.1/24"],
                           "private_key": cls.land_priv, "listen_port": cls.land_port,
                           "peers": [{"public_key": peer_pub, "allowed_ips": ["10.66.0.2/32"]}]}],
            "outbounds": [{"type": "direct", "tag": "out"}],
            "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"},
                                {"port": cls.e1, "action": "route-options", "override_port": cls.e2}],
                      "final": "out"},
        }
        f = cls.sb.tmp / "landing.json"
        f.write_text(json.dumps(conf))
        cls.land = subprocess.Popen([BIN + "/sing-box", "run", "-c", str(f)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)

    @classmethod
    def tearDownClass(cls):
        for p in cls.procs + [cls.land]:
            if p:
                p.terminate()
        cls.sb.cleanup()

    def conf_file(self, priv, name="wg.conf"):
        f = self.sb.tmp / name
        f.write_text(wg_conf(priv, self.land_pub, "127.0.0.1:%d" % self.land_port, address="10.66.0.2/32", dns="10.66.0.1"))
        return f

    def check_test_output(self, out, wg_ports, direct_ports):
        for p in wg_ports:
            self.assertRegex(out, r"端口 %d（应该走WireGuard）：.*%s = WireGuard ✔" % (p, WG_IP), out)
        for p in direct_ports:
            self.assertRegex(out, r"端口 %d（应该走直连）：.*%s = 服务器自己的 IP ✔" % (p, SERVER_IP), out)
        self.assertNotIn("✘", out)
        self.assertNotIn("没测通", out)

    def svc(self, name, act, extra=None):
        return subprocess.run(["rc-service", name, act], env=self.envp(extra), capture_output=True, text=True)

    def test_full_flow(self):
        sb, p = self.sb, self.p
        wgp = [p[1], p[3], p[4], p[6]]          # p[6] 现在还没有节点，以后搭
        env = {"WG_CONF_FILE": str(self.conf_file(self.cli_priv)), "WG_PORTS": " ".join(map(str, wgp)), "WG_MODE": "auto"}

        # ---- 1. 安装：没有内核模块的机器（假 ip 建不了网卡）自动选无网卡模式 ----
        sb.env["FAKE_NO_KMOD"] = "1"
        r = sb.run([], env | {"PATH": sb.env["PATH"]}, timeout=400)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("WireGuard 通了，出口 IP：%s" % WG_IP, r.stdout)
        st = (sb.etc / "state").read_text()
        self.assertIn("PORTS=%s" % " ".join(map(str, sorted(wgp))), st)
        self.assertEqual(oct((sb.etc / "wg.conf").stat().st_mode & 0o777), "0o600")
        self.assertTrue((sb.initd / "wg-luodi").exists())
        self.assertIn("rc-update add wg-luodi default", sb.fake_log())
        self.assertIn("rc-update add wg-luodi-watch default", sb.fake_log())

        # ---- 2. 逐个节点实测出口 ----
        r = sb.run_cmd(["test"], timeout=400)
        self.check_test_output(r.stdout, [p[1], p[3], p[4]], [p[2], p[5]])

        # ---- 3. DNS 也走隧道：echo.test 只有落地机的 DNS 认识 ----
        st = dict(l.split("=", 1) for l in (sb.etc / "state").read_text().splitlines())
        c = subprocess.run(["curl", "-s", "--max-time", "10", "-x", "socks5h://%s:%s@127.0.0.1:%s" % (st["SOCKS_USER"], st["SOCKS_PASS"], st["SOCKS_PORT"]),
                            "http://echo.test:%d/" % self.e1], capture_output=True, text=True)
        self.assertEqual(c.stdout, WG_IP)

        # ---- 4. 重复运行安装：不报错，节点配置一个字节都不变 ----
        snap = {k: v.read_bytes() for k, v in self.cfg.items()}
        r = sb.run([], env, timeout=400)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(snap, {k: v.read_bytes() for k, v in self.cfg.items()})

        # ---- 5. 去掉 / 加回端口 ----
        r = sb.run_cmd(["del-port", str(p[4])])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(json.loads(self.cfg[4].read_text()), json.loads(self.orig[4]))
        r = sb.run_cmd(["test", str(p[4])], timeout=200)
        self.check_test_output(r.stdout, [], [p[4]])
        r = sb.run_cmd(["add-port", str(p[4])])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = sb.run_cmd(["test", str(p[4])], timeout=200)
        self.check_test_output(r.stdout, [p[4]], [])

        # ---- 6. 以后在 WG 端口上新搭的节点（VPS-dajianjiedian 启动前钩子）----
        self.cfg[6] = make_node(sb, 6, "xray", xray_vmess_ws(p[6], str(uuid.uuid4()), "/n"))
        self.orig[6] = self.cfg[6].read_bytes()
        r = self.svc("xray-node-6", "start", {"FAKE_DJD_HOOK": "1"})
        self.assertEqual(r.returncode, 0)
        self.assertIn("wg-luodi", self.cfg[6].read_text())
        # 别的脚本把节点 1 重建成原样（没有我们的规则），重启时钩子马上补上
        self.cfg[1].write_bytes(self.orig[1])
        self.svc("xray-node-1", "restart", {"FAKE_DJD_HOOK": "1"})
        self.assertIn("wg-luodi", self.cfg[1].read_text())
        # 没有钩子的情况：巡检 wg-luodi check 发现后改好并重启节点
        self.cfg[4].write_bytes(self.orig[4])
        r = sb.run_cmd(["check"], timeout=200)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("wg-luodi", self.cfg[4].read_text())
        r = sb.run_cmd(["test"], timeout=400)
        self.check_test_output(r.stdout, [p[1], p[3], p[4], p[6]], [p[2], p[5]])

        # ---- 7. 换钥匙：落地机换成新公钥对应的客户端，旧配置失效；set-conf 换上新配置后恢复 ----
        new_priv, new_pub = wg_keypair()
        self.start_landing(new_pub)
        r = sb.run_cmd(["set-conf", str(self.conf_file(new_priv, "wg-new.conf"))], timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("WireGuard 通了，出口 IP：%s" % WG_IP, r.stdout)
        self.assertIn(new_priv, (sb.etc / "wg.conf").read_text())
        # 7b. 贴错配置（落地机不认这把钥匙），而现在的配置是通的：自动换回现在的配置
        bad_priv, _ = wg_keypair()
        r = sb.run_cmd(["set-conf", str(self.conf_file(bad_priv, "wg-bad.conf"))], timeout=300)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("自动换回旧配置", r.stdout + r.stderr)
        self.assertIn(new_priv, (sb.etc / "wg.conf").read_text())
        self.assertIn(bad_priv, (sb.etc / "wg.conf.bad").read_text())
        self.assertEqual(oct((sb.etc / "wg.conf.bad").stat().st_mode & 0o777), "0o600")
        self.assertIn("WireGuard 通了，出口 IP：%s" % WG_IP, r.stdout)
        r = sb.run_cmd(["test", str(p[1])], timeout=200)
        self.check_test_output(r.stdout, [p[1]], [])

        # ---- 8. 切到内核网卡模式（假 ip / wg 只记录命令）再切回来 ----
        open(sb.env["FAKE_LOG"], "w").close()
        sb.env["FAKE_NO_KMOD"] = "0"
        r = sb.run_cmd(["mode", "kernel"], timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("MODE=kernel", (sb.etc / "state").read_text())
        log = sb.fake_log()
        for want in ("ip link add dev wg-luodi type wireguard", "wg setconf wg-luodi",
                     "ip -4 addr add 10.66.0.2/32 dev wg-luodi", "ip link set dev wg-luodi mtu 1420 up",
                     "ip -4 route replace default dev wg-luodi table 51888",
                     "ip -4 rule add fwmark 51888 lookup 51888 pref 5188"):
            self.assertIn(want, log)
        for line in log.splitlines():   # 绝不碰主路由表的默认路由
            if "route" in line and "default" in line and "show" not in line:
                self.assertIn("table 51888", line)
        self.assertFalse((sb.etc / "wg-setconf.conf").exists())          # 临时钥匙文件不留
        gw = json.loads((sb.etc / "gw.json").read_text())
        self.assertEqual(gw["outbounds"][0]["routing_mark"], 51888)
        r = sb.run_cmd(["mode", "userspace"], timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ip link del dev wg-luodi", sb.fake_log())
        self.assertIn("WireGuard 通了", r.stdout)

        # ---- 9. 模拟重启：所有进程被杀，再按开机顺序启动 ----
        sb.stop_all()
        for f in sb.svc.glob("*.pid"):
            f.unlink()
        for name in ["wg-luodi", "wg-luodi-watch"] + ["xray-node-%d" % n for n in range(1, 7)]:
            self.assertEqual(self.svc(name, "start", {"FAKE_DJD_HOOK": "1"}).returncode, 0, name)
        r = sb.run_cmd(["test"], timeout=400)
        self.check_test_output(r.stdout, [p[1], p[3], p[4], p[6]], [p[2], p[5]])
        r = sb.run_cmd(["status"], timeout=200)
        self.assertIn("走 WireGuard ✔", r.stdout)

        # ---- 9b. 更新：装过的机器再跑一次安装命令（不给配置/端口）= 自动更新，配置端口都保留 ----
        snap = {k: v.read_bytes() for k, v in self.cfg.items()}
        conf_before = (sb.etc / "wg.conf").read_bytes()
        st_path = sb.etc / "state"
        st_path.write_text(st_path.read_text().replace("VERSION=", "VERSION=0.9.") )   # 假装装的是旧版
        r = sb.run([], timeout=400)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("自动更新到", r.stdout)
        self.assertIn("更新好了", r.stdout)
        self.assertIn("WireGuard 通了，出口 IP：%s" % WG_IP, r.stdout)
        ver = [l for l in st_path.read_text().splitlines() if l.startswith("VERSION=")][0]
        self.assertNotIn("0.9.", ver)
        self.assertEqual(conf_before, (sb.etc / "wg.conf").read_bytes())
        self.assertEqual(snap, {k: v.read_bytes() for k, v in self.cfg.items()})
        self.assertFalse((sb.etc / "update-backup").exists())
        r = sb.run_cmd(["test"], timeout=400)
        self.check_test_output(r.stdout, [p[1], p[3], p[4], p[6]], [p[2], p[5]])

        # ---- 9c. wg-luodi update：从网址下载最新版再更新（这里用本地文件代替 GitHub）----
        r = sb.run_cmd(["update"], {"WGL_RAW_URL": "file://%s" % SCRIPT}, timeout=400)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("更新好了", r.stdout)
        self.assertEqual(sb.cmd.read_bytes(), Path(SCRIPT).read_bytes())

        # ---- 9d. 新版有问题（生成的网关配置不合格）：自动换回旧版，什么都不变 ----
        bad = sb.tmp / "bad-wg-luodi.sh"
        bad.write_text(Path(SCRIPT).read_text().replace('{ type: "socks", tag: "socks-in"', '{ type: "sockz", tag: "socks-in"')
                       .replace('WGL_VERSION="', 'WGL_VERSION="9'))
        cmd_before, gw_before, st_before = sb.cmd.read_bytes(), (sb.etc / "gw.json").read_bytes(), st_path.read_bytes()
        r = sb.run_cmd(["update"], {"WGL_RAW_URL": "file://%s" % bad}, timeout=400)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("已换回旧版", r.stdout + r.stderr)
        self.assertEqual(cmd_before, sb.cmd.read_bytes())
        self.assertEqual(gw_before, (sb.etc / "gw.json").read_bytes())
        self.assertEqual(st_before, st_path.read_bytes())
        r = sb.run_cmd(["test"], timeout=400)
        self.check_test_output(r.stdout, [p[1], p[3], p[4], p[6]], [p[2], p[5]])

        # ---- 10. 卸载：所有节点配置逐字节还原，文件全部删掉，节点还在正常跑 ----
        r = sb.run_cmd(["uninstall", "-y"], timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("没能自动恢复", r.stdout + r.stderr)     # 最后一个节点是 xray 时也不能误报
        for k, v in self.cfg.items():
            self.assertEqual(v.read_bytes(), self.orig[k], "节点 %d 没还原" % k)
        self.assertFalse(sb.etc.exists())
        self.assertFalse(sb.cmd.exists())
        self.assertFalse((sb.lib / "sing-box").exists())
        self.assertFalse((sb.initd / "wg-luodi").exists())
        for n in range(1, 7):
            self.assertEqual(self.svc("xray-node-%d" % n, "status").returncode, 0, n)


if __name__ == "__main__":
    unittest.main()
