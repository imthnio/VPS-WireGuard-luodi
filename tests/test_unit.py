"""wg-luodi 的单元测试：解析配置、粘贴、端口、生成网关配置、改节点配置（不跑网络）。"""
import base64
import json
import os
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path

from helpers import (BIN, SCRIPT, Sandbox, have_bins, hy2_yaml, make_node, rand_key, reality_keypair,
                     sb_anytls_reality, wg_conf, xray_ss, xray_vless_reality, xray_vmess_ws)


def ss_key():
    """2022-blake3-aes-128-gcm 的合法密码：16 字节的 base64（rand_key 是 32 字节，xray -test 会报 bad key）。"""
    return base64.b64encode(os.urandom(16)).decode()


class SyntaxTest(unittest.TestCase):
    def test_posix_syntax(self):
        for sh in ("sh", "dash", "bash"):
            r = subprocess.run(["sh", "-c", "command -v %s" % sh], capture_output=True)
            if r.returncode == 0:
                r = subprocess.run([sh, "-n", str(SCRIPT)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, sh + ": " + r.stderr)

    def test_no_hardcoded_keys(self):
        """脚本里不能有任何写死的 WireGuard 钥匙（44 位 base64）。"""
        import re
        text = SCRIPT.read_text()
        self.assertIsNone(re.search(r"[A-Za-z0-9+/]{43}=", text))

    def test_no_hardcoded_port(self):
        text = SCRIPT.read_text()
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        self.assertNotIn("45192", code.replace('WG_PORTS="45192 50000"', "").replace("例如 45192 50000", ""))


class ConfTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()

    def tearDown(self):
        self.sb.cleanup()

    def parse(self, text):
        f = self.sb.tmp / "c.conf"
        f.write_bytes(text.encode())
        return self.sb.source('parse_conf "%s" && echo "OK|$WG_ADDR4|$WG_ADDR6|$WG_EP_HOST|$WG_EP_PORT|$WG_EP_KIND|$WG_HAS4|$WG_HAS6|$WG_STRAT|$WG_DNS1|$WG_KA|$WG_PSK" || echo "ERR|$PARSE_ERR"' % f)

    def test_crlf_bom_lowercase(self):
        k1, k2, k3 = rand_key(), rand_key(), rand_key()
        text = "\ufeff[interface]\r\nprivatekey=%s\r\nAddress = 172.16.0.2/32\r\nAddress=fd01::2/128\r\nDNS = 1.1.1.1, 2606:4700:4700::1111\r\n\r\n# 注释\r\n[Peer]\r\nPublicKey = %s\r\nPresharedKey = %s\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\nEndpoint = engage.example.com:2408  # 落地机\r\nPersistentKeepalive = 15\r\n" % (k1, k2, k3)
        out = self.parse(text).stdout.strip().split("|")
        self.assertEqual(out[0], "OK", out)
        self.assertEqual(out[1].strip(), "172.16.0.2/32")
        self.assertEqual(out[2].strip(), "fd01::2/128")
        self.assertEqual(out[3:6], ["engage.example.com", "2408", "name"])
        self.assertEqual(out[6:10], ["1", "1", "prefer_ipv4", "1.1.1.1"])
        self.assertEqual(out[10], "15")
        self.assertEqual(out[11], k3)

    def test_ipv4_only_forces_ipv4(self):
        out = self.parse(wg_conf(rand_key(), rand_key(), "1.2.3.4:51820", address="10.0.0.2", allowed="0.0.0.0/0, ::/0", dns="")).stdout
        self.assertIn("|1|0|ipv4_only|1.1.1.1|25|", out)

    def test_ipv6_endpoint(self):
        out = self.parse(wg_conf(rand_key(), rand_key(), "[2001:db8::1]:51820")).stdout
        self.assertIn("|2001:db8::1|51820|6|", out)

    def test_errors(self):
        k1, k2 = rand_key(), rand_key()
        cases = [
            (wg_conf("abc", k2, "1.2.3.4:51820"), "PrivateKey"),
            (wg_conf(k1, "", "1.2.3.4:51820"), "PublicKey"),
            (wg_conf(k1, k2, "1.2.3.4"), "Endpoint"),
            (wg_conf(k1, k2, "2001:db8::1:51820"), "Endpoint"),
            (wg_conf(k1, k2, "1.2.3.4:70000"), "端口"),
            (wg_conf(k1, k2, "1.2.3.4:51820", allowed="10.0.0.0/8"), "0.0.0.0/0"),
            (wg_conf(k1, k2, "1.2.3.4:51820", address="10.0.0.300/32"), "Address"),
            ("[Interface]\nPrivateKey = %s\nAddress = 10.0.0.2/32\n" % k1, "[Peer]"),
        ]
        for text, word in cases:
            out = self.parse(text).stdout
            self.assertTrue(out.startswith("ERR|"), (text, out))
            self.assertIn(word, out)

    def paste(self, stdin):
        f = self.sb.tmp / "p.conf"
        return self.sb.source('read_conf_paste "%s" && parse_conf "%s" && echo "GOT $WG_EP_HOST"; echo "REST: $(cat)"' % (f, f), stdin=stdin)

    def test_paste_stops_at_blank_line_after_complete(self):
        conf = wg_conf(rand_key(), rand_key(), "5.6.7.8:51820")
        out = self.paste("\n" + conf + "\n下一题的回答\n").stdout
        self.assertIn("GOT 5.6.7.8", out)
        self.assertIn("REST: 下一题的回答", out)   # 空行之后的内容留给下一个问题

    def test_paste_ctrl_d_without_newline(self):
        conf = wg_conf(rand_key(), rand_key(), "5.6.7.8:51820").rstrip("\n")
        self.assertIn("GOT 5.6.7.8", self.paste(conf).stdout)

    def test_paste_crlf(self):
        conf = wg_conf(rand_key(), rand_key(), "5.6.7.8:51820", crlf=True)
        self.assertIn("GOT 5.6.7.8", self.paste(conf + "\r\n").stdout)

    def test_paste_file_path(self):
        f = self.sb.tmp / "wg0.conf"
        f.write_text(wg_conf(rand_key(), rand_key(), "9.9.9.9:51820"))
        self.assertIn("GOT 9.9.9.9", self.paste(str(f) + "\n").stdout)

    def test_ports(self):
        r = self.sb.source('parse_ports "45192, 50000，60000 50001-50003 045192 ;7"; echo "[$PORTS_OUT]"')
        self.assertIn("[7 45192 50000 50001 50002 50003 60000]", r.stdout)
        for bad in ("0", "70000", "abc", "5-1", "1000-2000"):
            r = self.sb.source('parse_ports "%s" || echo "BAD $PARSE_ERR"' % bad)
            self.assertIn("BAD", r.stdout, bad)


class EpMarkTest(unittest.TestCase):
    """WireGuard 连落地机走哪条路：候选标记、状态解读、握手选择。"""
    RULES = ("0:\\tfrom all lookup local\\n5188:\\tfrom all fwmark 0xcab0 lookup 51888\\n"
             "8904:\\tfrom all fwmark 0x24681 lookup 24680\\n8905:\\tfrom all fwmark 0x24680 lookup main\\n"
             "8906:\\tfrom all fwmark 0x24682/0xffff lookup main\\n8920:\\tfrom all lookup 24680\\n")

    def setUp(self):
        self.sb = Sandbox()
        self.sb.etc.mkdir()

    def tearDown(self):
        self.sb.cleanup()

    L2TP_RULES = ("0:\\tfrom all lookup local\\n8905:\\tfrom all fwmark 0x24680 lookup main\\n"
                  "8906:\\tfrom all fwmark 0x24682 lookup main\\n8920:\\tfrom all lookup 24680\\n")

    def l2tp(self):
        d = self.sb.tmp / "l2tp-vless"
        d.mkdir(exist_ok=True)
        (d / "v2-owned").write_text("")
        return {"WGL_L2TP_DIR": str(d), "FAKE_IP_RULES": self.L2TP_RULES}

    def test_candidates(self):
        r = self.sb.source("_ep_cands", {"FAKE_IP_RULES": self.RULES, "WGL_L2TP_DIR": str(self.sb.tmp / "none")})
        self.assertEqual(r.stdout.split(), ["51889"], r.stderr)   # 不借用来历不明的直连标记
        r = self.sb.source("_ep_cands", self.l2tp())
        self.assertEqual(r.stdout.split(), ["149122"], r.stderr)  # L2TP-VPS 专门留的直连标记，51889 会被它拦下

    def test_epm_states(self):
        for st, mode, want in (("", "kernel", "51889"), ("149122", "kernel", "149122"), ("off", "kernel", "off"),
                               ("retry", "kernel", "off"), ("149122", "userspace", "off")):
            (self.sb.etc / "state").write_text("EP_MARK=%s\n" % st)
            r = self.sb.source("MODE=%s; _epm" % mode)
            self.assertEqual(r.stdout, want, (st, mode))

    def test_pick(self):
        (self.sb.etc / "state").write_text("")
        r = self.sb.source("MODE=kernel; _ep_pick; st_get EP_MARK", {"FAKE_IP_RULES": self.RULES})
        self.assertEqual(r.stdout.strip(), "51889", r.stderr)      # 第一个候选就握上手
        r = self.sb.source("MODE=kernel; _hs_wait() { return 1; }; _ep_pick; st_get EP_MARK", {"FAKE_NO_HS": "1"})
        self.assertEqual(r.stdout.strip(), "retry", r.stderr)      # 怎么都握不上：之后再试
        self.assertFalse(list((self.sb.etc / "wireguard").glob("*")))   # 临时钥匙文件不留

    def pick(self, extra):
        (self.sb.etc / "state").write_text("")
        env = {"WGL_L2TP_DIR": str(self.sb.tmp / "none")}
        env.update(extra)
        # 下载试路：FAKE_CURL=ok 表示经隧道能下载，FAKE_CURL_MAX=N 表示网卡 MTU 超过 N 时下不下来
        stub = ('_curl_tun() { [ "$FAKE_CURL" = ok ] || return 1; [ -z "$FAKE_CURL_MAX" ] && return 0; '
                '_m=$(cat "$WGL_DIR/mtu" 2>/dev/null || echo 1420); [ "$_m" -le "$FAKE_CURL_MAX" ]; }; '
                'ip() { case "$*" in *"link set dev"*mtu*) echo "$6" > "$WGL_DIR/mtu";; esac; command ip "$@"; }; ')
        r = self.sb.source(stub + "MODE=kernel; WG_HAS4=1; _ep_pick; st_get EP_MARK; st_get EP_MTU; st_get EP_CHECK; wg_mtu", env)
        return r.stdout.split(), r

    def test_pick_needs_big_packets_through_l2tp_mark(self):
        out, r = self.pick(self.l2tp())                                  # 大包能过：用 L2TP 的直连标记
        self.assertEqual(out, ["149122", "149122:1420", "3", "1420"], r.stderr)
        out, r = self.pick(dict(self.l2tp(), FAKE_PING_MAX="1300"))     # 路上 MTU 小：调小隧道 MTU 后照样用
        self.assertEqual(out[:2], ["149122", "149122:1300"], r.stderr)
        self.assertEqual(out[-1], "1300")
        out, r = self.pick(dict(self.l2tp(), FAKE_PING_MAX="100"))      # 握手能成、大包过不去：不用这条路
        self.assertEqual(out[0], "off", r.stderr)
        self.assertIn("大包过不去", (self.sb.etc / "log").read_text())
        out, r = self.pick(dict(self.l2tp(), FAKE_NO_PING="1"))         # 不回 ping、也下载不了：借来的标记不用
        self.assertEqual(out[0], "off", r.stderr)

    def test_pick_uses_a_download_when_ping_is_blocked(self):
        # 很多落地机不回 ping：实际下载能成功就照样直连，不被迫套在 L2TP 里走
        out, r = self.pick(dict(self.l2tp(), FAKE_NO_PING="1", FAKE_CURL="ok"))
        self.assertEqual(out[:3], ["149122", "149122:1420", "3"], r.stderr)
        out, r = self.pick(dict(self.l2tp(), FAKE_NO_PING="1", FAKE_CURL="ok", FAKE_CURL_MAX="1340"))
        self.assertEqual(out[:2], ["149122", "149122:1340"], r.stderr)   # 大包只能过 1340：隧道 MTU 调小后照样直连

    def test_probe_works_for_ipv6_only_tunnels(self):
        (self.sb.etc / "state").write_text("")
        r = self.sb.source("MODE=kernel; WG_HAS4=0; WG_HAS6=1; _mtu_probe; echo rc=$?; st_get EP_MTU",
                           {"FAKE_PING_MAX": "1300", "WGL_L2TP_DIR": str(self.sb.tmp / "none")})
        self.assertEqual(r.stdout.split(), ["rc=0", "51889:1340"], r.stderr)   # 1292 数据 + 48 包头
        self.assertIn("ping -6 ", self.sb.fake_log())
        self.assertIn("2606:4700:4700::1111", self.sb.fake_log())

    def test_pick_own_mark_without_ping_works_as_before(self):
        out, r = self.pick({"FAKE_NO_PING": "1"})
        self.assertEqual(out[0], "51889", r.stderr)
        out, r = self.pick({"FAKE_PING_MAX": "100"})                    # 自己的标记：大包确定过不去也换路
        self.assertEqual(out[0], "off", r.stderr)

    def test_off_from_older_ping_only_check_is_rechecked(self):
        # 1.1.16 及以前：落地不回 ping 时被迫套在 L2TP 里走（off、EP_CHECK=2），升级后用下载再试一次
        (self.sb.etc / "state").write_text("EP_MARK=off\nEP_CHECK=2\n")
        r = self.sb.source('MODE=kernel; ip() { case "$*" in "link show"*) return 0;; *"rule show"*) echo "lookup 51888";; *"route show"*) echo default;; esac; }; '
                           '_live_sync() { :; }; kernel_ensure; echo "rc=$?"')
        self.assertEqual(r.stdout.split(), ["rc=1"], r.stderr)
        (self.sb.etc / "state").write_text("EP_MARK=149122\nEP_CHECK=2\n")   # 已经直连的不动
        r = self.sb.source('MODE=kernel; ip() { case "$*" in "link show"*) return 0;; *"rule show"*) echo "lookup 51888";; *"route show"*) echo default;; esac; }; '
                           '_live_sync() { :; }; WG_EP_KIND=ip; kernel_ensure; echo "rc=$?"')
        self.assertEqual(r.stdout.split(), ["rc=0"], r.stderr)

    def test_speed_is_reported_in_mbps(self):
        r = self.sb.source('_to() { shift; "$@"; }; curl() { printf 1250000; }; _speed')
        self.assertEqual(r.stdout, "10.0", r.stderr)                     # 1250000 字节/秒 = 10 Mbps
        r = self.sb.source('_to() { shift; "$@"; }; curl() { printf 0; }; _speed || echo NONE')
        self.assertEqual(r.stdout.strip(), "NONE", r.stderr)

    def test_rtt_reads_iputils_and_busybox(self):
        for line in ("rtt min/avg/max/mdev = 10.1/23.6/30.2/1.1 ms",
                     "round-trip min/avg/max = 10.1/23.6/30.2 ms"):
            r = self.sb.source("ping() { echo '%s'; }; _rtt" % line)
            self.assertEqual(r.stdout, "24", (line, r.stderr))
        r = self.sb.source("ping() { return 1; }; _rtt || echo NONE")
        self.assertEqual(r.stdout.strip(), "NONE")

    def test_parallel_speed_adds_up(self):
        r = self.sb.source('_to() { shift; "$@"; }; curl() { printf 1250000; }; _speed_par 4')
        self.assertEqual(r.stdout, "40.0", r.stderr)                     # 4 个连接各 10 Mbps
        self.assertFalse(list(self.sb.etc.glob("speed.*")))               # 临时文件不留

    def test_speed_verdict_names_the_slow_segment(self):
        def v(*a):
            return self.sb.source("_speed_verdict %s" % " ".join("'%s'" % x for x in a)).stdout
        self.assertIn("网关", v("80", "90", "20", "100"))                  # 网卡快、经网关慢：网关/CPU
        self.assertIn("4 个连接", v("10", "40", "9", "100"))               # 单连接被卡、总带宽有余量
        self.assertIn("落地机本身的带宽", v("10", "11", "9", "100"))        # 怎么测都慢：落地机
        self.assertIn("差不多", v("90", "95", "88", "100"))
        self.assertIn("完全下载不了", v("", "", "", "100"))
        self.assertIn("比平时的出口快很多", v("243.8", "301.7", "260.4", "55.2"))   # 实测：WireGuard 比 L2TP 快 5 倍

    def test_client_address_on_l2tp_server_is_the_servers_own(self):
        # 普通 curl 在 L2TP 服务器上走 L2TP，查到的是 L2TP 出口；要用 l2tp-fetch 账号走服务器自己的网络查
        stub = ('_to() { shift; "$@"; }; id() { [ "$1" = l2tp-fetch ]; }; '
                'su() { echo 198.51.100.7; }; curl() { echo 81.187.228.68; }; ')
        r = self.sb.source(stub + "pub_ip 4", self.l2tp())
        self.assertEqual(r.stdout, "198.51.100.7", r.stderr)
        r = self.sb.source(stub + "pub_ip 4", {"WGL_L2TP_DIR": str(self.sb.tmp / "none")})
        self.assertEqual(r.stdout, "81.187.228.68", r.stderr)      # 没装 L2TP：照旧

    def test_l2tp_note(self):
        r = self.sb.source('_l2tp_note', {"WGL_L2TP_DIR": str(self.sb.tmp / "none")})
        self.assertEqual(r.stdout, "")
        env = self.l2tp()
        self.assertIn("L2TP-VPS", self.sb.source('_l2tp_note', env).stdout)
        (Path(env["WGL_L2TP_DIR"]) / "disabled").write_text("")             # L2TP 执行过 recover：不提
        self.assertEqual(self.sb.source('_l2tp_note', env).stdout, "")

    def test_picking_marker(self):
        r = self.sb.source('echo $$ > "$WGL_DIR/picking"; gw_picking && echo YES')
        self.assertEqual(r.stdout.strip(), "YES", r.stderr)              # 选路的进程还活着：正在启动
        (self.sb.etc / "picking").write_text("999999\n")
        r = self.sb.source('gw_picking && echo YES || echo NO')
        self.assertEqual(r.stdout.strip(), "NO", r.stderr)               # 进程没了（被杀了）：不算
        r = self.sb.source('rm -f "$WGL_DIR/picking"; gw_picking && echo YES || echo NO')
        self.assertEqual(r.stdout.strip(), "NO", r.stderr)

    def test_old_choice_is_rechecked_once(self):
        (self.sb.etc / "state").write_text("EP_MARK=off\n")
        r = self.sb.source('MODE=kernel; ip() { case "$*" in "link show"*) return 0;; *"rule show"*) echo "lookup 51888";; *"route show"*) echo default;; esac; }; '
                           '_live_sync() { :; }; kernel_ensure; echo "rc=$?"; st_get EP_MARK')
        self.assertEqual(r.stdout.split(), ["rc=1"], r.stderr)          # 让网关重启、重新选路
        (self.sb.etc / "state").write_text("EP_MARK=off\nEP_CHECK=3\n")
        r = self.sb.source('MODE=kernel; ip() { case "$*" in "link show"*) return 0;; *"rule show"*) echo "lookup 51888";; *"route show"*) echo default;; esac; }; '
                           '_live_sync() { :; }; WG_EP_KIND=ip; kernel_ensure; echo "rc=$?"; st_get EP_MARK')
        self.assertEqual(r.stdout.split(), ["rc=0", "off"], r.stderr)

    def test_retry_is_repicked_once_landing_is_back(self):
        # 落地机掉线时记成 retry、先走默认的路；落地机回来后在默认的路上又握上了手，
        # 以前因为“最近有握手”就不再选路，一直套在 L2TP 里走、大包也没试过。
        stub = ('MODE=kernel; ip() { case "$*" in "link show"*) return 0;; *"rule show"*) echo "lookup 51888";; *"route show"*) echo default;; esac; }; '
                '_live_sync() { :; }; WG_EP_KIND=ip; wg() { printf "peer\\t%s\\n" "$HS"; }; ')
        (self.sb.etc / "state").write_text("EP_MARK=retry\nEP_CHECK=3\n")
        r = self.sb.source(stub + 'HS=$(($(date +%s) - 10)); kernel_ensure; echo "rc=$?"; st_get EP_MARK')
        self.assertEqual(r.stdout.split(), ["rc=1"], r.stderr)          # 握上了：重启网关、重新选路
        (self.sb.etc / "state").write_text("EP_MARK=retry\nEP_CHECK=3\n")
        r = self.sb.source(stub + 'HS=0; kernel_ensure; echo "rc=$?"; st_get EP_MARK')
        self.assertEqual(r.stdout.split(), ["rc=1"], r.stderr)          # 还是没握手：照旧重试
        (self.sb.etc / "state").write_text("EP_MARK=149122\nEP_CHECK=3\n")
        r = self.sb.source(stub + 'HS=$(($(date +%s) - 10)); kernel_ensure; echo "rc=$?"; st_get EP_MARK')
        self.assertEqual(r.stdout.split(), ["rc=0", "149122"], r.stderr)   # 已经选好的不动


class MultiLandingTest(unittest.TestCase):
    """多落地：名字、标记递增、多出口网关、老布局迁移。"""

    def setUp(self):
        self.sb = Sandbox()
        self.sb.etc.mkdir()
        self.names = ["us", "uk", "sg"]
        (self.sb.etc / "state").write_text(
            "LANDINGS=us uk sg\nMODE=userspace\nSOCKS_USER=wgltest\nSOCKS_PASS=pw%s\n" % uuid.uuid4().hex[:8])
        self.make_landing("us", "31001", 40001, 40002)
        self.make_landing("uk", "31002", 40003, 40004, address="10.66.0.3/32, fd00::3/128",
                          allowed="0.0.0.0/0, ::/0")
        self.make_landing("sg", "31003", 40005, 40006)

    def tearDown(self):
        self.sb.cleanup()

    def make_landing(self, name, ports, socks, dns, **kw):
        d = self.sb.etc / "landings" / name
        d.mkdir(parents=True)
        (d / "wg.conf").write_text(wg_conf(rand_key(), rand_key(), kw.get("ep", "1.2.3.4:51820"),
                                           address=kw.get("address", "10.66.0.2/32"),
                                           allowed=kw.get("allowed", "0.0.0.0/0")))
        (d / "state").write_text("PORTS=%s\nEP_FAM=4\nEP_MARK=\nSOCKS_PORT=%d\nDNS_PORT=%d\n" % (ports, socks, dns))
        return d

    def gw_json(self, mode):
        out = self.sb.tmp / ("gw-%s.json" % mode)
        r = self.sb.source('MODE=%s; write_gw_json "%s"' % (mode, out))
        self.assertEqual(r.returncode, 0, r.stderr)
        j = json.loads(out.read_text())
        if have_bins():
            c = subprocess.run([BIN + "/sing-box", "check", "-c", str(out)], capture_output=True, text=True)
            self.assertEqual(c.returncode, 0, c.stderr)
        return j

    def test_landing_names(self):
        (self.sb.etc / "state").write_text("LANDINGS=us uk-1 BAD_name toolongname1234\n")
        r = self.sb.source('_landing_names; echo; _landing_valid us && echo us-ok; _landing_valid US || echo US-bad; '
                           '_landing_valid a_b || echo ab-bad; _landing_valid abcdefghijklm || echo long-bad; '
                           '_landing_valid uk-1 && echo uk1-ok')
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "us uk-1")          # 非法名字（大写、下划线、超 12 字符）被滤掉
        self.assertEqual(lines[1:], ["us-ok", "US-bad", "ab-bad", "long-bad", "uk1-ok"])
        # LANDINGS 键丢了（比如更新回滚）：按目录里的落地算
        (self.sb.etc / "state").write_text("MODE=userspace\n")
        r = self.sb.source('_landing_names')
        self.assertEqual(r.stdout, "sg uk us")

    def test_marks_increment(self):
        r = self.sb.source('for n in us uk sg; do echo "$n $(_landing_mark $n) $(_landing_table $n) $(_landing_pref $n) $(_landing_epmark $n) $(_landing_eppref $n) $(_landing_iface $n)"; done; '
                           'echo "legacy $(_landing_mark "") $(_landing_iface "")"')
        self.assertEqual(r.stdout.splitlines(), [
            "us 51888 51888 5188 51889 5189 wg-us",
            "uk 51890 51890 5190 51891 5191 wg-uk",
            "sg 51892 51892 5192 51893 5193 wg-sg",
            "legacy 51888 wg-luodi",
        ])
        # 各落地的业务标记（mark）和连落地机标记（epmark）绝不能撞车，规则优先级也互不冲突
        rows = [line.split() for line in r.stdout.splitlines()[:3]]
        marks = {row[1] for row in rows}
        epmarks = {row[4] for row in rows}
        prefs = {row[3] for row in rows}
        epprefs = {row[5] for row in rows}
        self.assertTrue(marks.isdisjoint(epmarks))
        self.assertTrue(prefs.isdisjoint(epprefs))

    def test_ep_candidates_per_landing(self):
        r = self.sb.source('LND=uk; _ep_cands', {"WGL_L2TP_DIR": str(self.sb.tmp / "none")})
        self.assertEqual(r.stdout.strip(), "51891")   # 第二个落地试自己的标记，不抢第一个的 51889，也不撞自己的 51890
        r = self.sb.source('LND=uk; _ep_cands', {"WGL_L2TP_DIR": str(self.sb.tmp / "none"),
                                                 "FAKE_IP_RULES": "8906:\\tfrom all fwmark 0x24682 lookup main\\n"})
        self.assertEqual(r.stdout.strip(), "51891")   # 没装 L2TP-VPS：规则在也不借它的标记

    def test_gw_json_multi_userspace(self):
        j = self.gw_json("userspace")
        self.assertEqual([e["tag"] for e in j["endpoints"]], ["wg-us", "wg-uk", "wg-sg"])
        self.assertTrue(all(e["system"] is False for e in j["endpoints"]))       # 不建网卡、不要 TUN
        ib = {x["tag"]: x for x in j["inbounds"]}
        self.assertEqual(sorted(ib), ["dns-sg", "dns-uk", "dns-us", "socks-sg", "socks-uk", "socks-us"])
        self.assertEqual([ib["socks-" + n]["listen_port"] for n in self.names], [40001, 40003, 40005])
        self.assertEqual([ib["dns-" + n]["listen_port"] for n in self.names], [40002, 40004, 40006])
        self.assertTrue(all(x["listen"] == "127.0.0.1" for x in j["inbounds"]))  # 网关只听本机
        self.assertEqual(ib["socks-us"]["users"], ib["socks-uk"]["users"])       # 共用一对用户名密码
        rules = j["route"]["rules"]
        self.assertEqual([r for r in rules if r.get("action") == "hijack-dns"],
                         [{"inbound": ["dns-" + n], "action": "hijack-dns"} for n in self.names])
        self.assertEqual([r for r in rules if r.get("action") == "resolve"], [
            {"inbound": ["socks-us"], "action": "resolve", "server": "wg-dns-us", "strategy": "ipv4_only"},
            {"inbound": ["socks-uk"], "action": "resolve", "server": "wg-dns-uk", "strategy": "prefer_ipv4"},
            {"inbound": ["socks-sg"], "action": "resolve", "server": "wg-dns-sg", "strategy": "ipv4_only"},
        ])
        self.assertEqual([r for r in rules if "outbound" in r],
                         [{"inbound": ["socks-" + n], "outbound": "wg-" + n} for n in self.names])
        rej = [r for r in rules if r.get("action") == "reject"]
        self.assertEqual(rej, [{"inbound": ["socks-us"], "ip_cidr": ["::/0"], "action": "reject", "no_drop": True},
                               {"inbound": ["socks-sg"], "ip_cidr": ["::/0"], "action": "reject", "no_drop": True}])
        self.assertEqual(j["route"]["final"], "wg-us")                            # final 指向第一个落地
        srv = {s["tag"]: s for s in j["dns"]["servers"]}
        self.assertEqual(srv["wg-dns-us"], {"type": "udp", "tag": "wg-dns-us", "server": "10.66.0.1",
                                            "detour": "wg-us"})
        self.assertEqual(srv["wg-dns-uk"]["detour"], "wg-uk")
        self.assertEqual(j["dns"]["strategy"], "ipv4_only")   # 全局策略用第一个落地的
        self.assertEqual(j["dns"]["rules"], [
            {"inbound": ["dns-us"], "server": "wg-dns-us", "strategy": "ipv4_only"},
            {"inbound": ["dns-uk"], "server": "wg-dns-uk", "strategy": "prefer_ipv4"},
            {"inbound": ["dns-sg"], "server": "wg-dns-sg", "strategy": "ipv4_only"},
        ])
        self.assertEqual(j["dns"]["final"], "wg-dns-us")
        self.assertEqual(j["route"]["default_domain_resolver"], {"server": "wg-dns-us", "strategy": "ipv4_only"})
        self.assertNotIn("outbounds", j)

    def test_gw_json_multi_kernel(self):
        j = self.gw_json("kernel")
        self.assertEqual(j["outbounds"], [
            {"type": "direct", "tag": "wg-out-us", "bind_interface": "wg-us", "routing_mark": 51888},
            {"type": "direct", "tag": "wg-out-uk", "bind_interface": "wg-uk", "routing_mark": 51890},
            {"type": "direct", "tag": "wg-out-sg", "bind_interface": "wg-sg", "routing_mark": 51892},
        ])
        self.assertNotIn("endpoints", j)
        self.assertEqual(j["route"]["final"], "wg-out-us")
        self.assertEqual([r for r in j["route"]["rules"] if "outbound" in r],
                         [{"inbound": ["socks-" + n], "outbound": "wg-out-" + n} for n in self.names])
        srv = {s["tag"]: s for s in j["dns"]["servers"]}
        self.assertEqual(srv["wg-dns-uk"],
                         {"type": "udp", "tag": "wg-dns-uk", "server": "10.66.0.1",
                          "bind_interface": "wg-uk", "routing_mark": 51890})
        self.assertNotIn("local", srv)   # 内核模式不用 local 解析器

    def test_kernel_up_down_per_landing(self):
        (self.sb.etc / "landings" / "us" / "state").write_text(
            "PORTS=31001\nEP_FAM=4\nEP_MARK=51889\nEP_CHECK=3\nSOCKS_PORT=40001\nDNS_PORT=40002\n")
        r = self.sb.source('MODE=kernel; kernel_up us; echo "RC=$?"')
        self.assertIn("RC=0", r.stdout, r.stderr)
        log = self.sb.fake_log()
        for want in ("ip link add dev wg-us type wireguard", "wg setconf wg-us",
                     "ip -4 addr add 10.66.0.2/32 dev wg-us",
                     "ip -4 route replace default dev wg-us table 51888",
                     "ip -4 rule add fwmark 51888 lookup 51888 pref 5188",
                     "ip -4 rule add fwmark 51889 lookup main pref 5189"):
            self.assertIn(want, log)
        self.assertNotIn("dev wg-luodi", log)      # 不碰老布局的网卡名
        open(self.sb.env["FAKE_LOG"], "w").close()
        r = self.sb.source('kernel_down')           # 不给名字：所有落地各拆一张
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.sb.fake_log()
        for want in ("ip link del dev wg-us", "ip link del dev wg-uk", "ip link del dev wg-sg",
                     "ip -4 rule del fwmark 51888 lookup 51888 pref 5188",
                     "ip -4 rule del fwmark 51890 lookup 51890 pref 5190",
                     "ip -4 rule del fwmark 51891 lookup main pref 5191",
                     "ip -4 route flush table 51892"):
            self.assertIn(want, log)

    def test_migrate_legacy(self):
        etc = self.sb.tmp / "legacy"
        etc.mkdir()
        conf = wg_conf(rand_key(), rand_key(), "5.6.7.8:51820")
        (etc / "wg.conf").write_text(conf)
        (etc / "state").write_text("MODE=userspace\nPORTS=31001 31002\nEP_FAM=4\nEP_MARK=\n"
                                   "SOCKS_PORT=40001\nDNS_PORT=40002\nSOCKS_USER=u1\nSOCKS_PASS=p1\nVERSION=1.1.20\n")
        r = self.sb.source('migrate_legacy; echo "LANDINGS=$(st_get LANDINGS)"', {"WGL_DIR": str(etc)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("LANDINGS=default", r.stdout)
        d = etc / "landings" / "default"
        self.assertEqual((d / "wg.conf").read_text(), conf)
        st = dict(l.split("=", 1) for l in (d / "state").read_text().splitlines())
        self.assertEqual((st["PORTS"], st["EP_FAM"], st["SOCKS_PORT"], st["DNS_PORT"]),
                         ("31001 31002", "4", "40001", "40002"))
        self.assertIn("EP_MARK", st)
        self.assertEqual((etc / "wg.conf.prev").read_text(), conf)     # 老配置留一份 .prev 备份
        before = (d / "state").read_bytes()
        self.sb.source('migrate_legacy', {"WGL_DIR": str(etc)})        # 幂等：再迁一次什么都不变
        self.assertEqual((d / "state").read_bytes(), before)
        gstate = (etc / "state").read_text()                            # 全局 state 里的旧键迁完就删掉
        for k in ("PORTS=", "EP_FAM=", "EP_MARK=", "SOCKS_PORT=", "DNS_PORT="):
            self.assertNotIn(k, gstate)
        gw = json.loads((etc / "gw.json").read_text())                 # 迁移时网关配置已按新布局生成
        self.assertEqual(gw["endpoints"][0]["tag"], "wg-default")
        self.assertEqual(gw["inbounds"][0]["tag"], "socks-default")
        self.assertEqual(gw["inbounds"][0]["listen_port"], 40001)
        r = self.sb.source('load_all; echo "PORTS=$PORTS LND=$LND MODE=$MODE EP=$WG_EP_HOST"',
                           {"WGL_DIR": str(etc)})
        self.assertIn("PORTS=31001 31002 LND=default MODE=userspace EP=5.6.7.8", r.stdout)

    def test_landing_name_needs_a_letter(self):
        # 全是数字的名字会和端口分不清（add-port uk 31001 里 31001 是端口不是落地）
        r = self.sb.source('_landing_valid 31001 || echo digits-bad; _landing_valid us1 && echo us1-ok; '
                           '_landing_valid 1a && echo 1a-ok; _landing_valid -- || echo dash-bad')
        self.assertEqual(r.stdout.split(), ["digits-bad", "us1-ok", "1a-ok", "dash-bad"])

    def test_port_landing_and_union(self):
        r = self.sb.source('echo "us=$(_port_landing 31001) uk=$(_port_landing 31002) sg=$(_port_landing 31003) none=$(_port_landing 9999)"; '
                           'echo "ALL=$(_all_ports)"; echo "MAP=$(_port_map 31002 31001 31003)"; '
                           'echo "MSG=$(_map_msg "31001:us 31002:uk")"')
        self.assertEqual(r.stdout.splitlines(), [
            "us=us uk=uk sg=sg none=",
            "ALL=31001 31002 31003",
            "MAP=31002:uk 31001:us 31003:sg",
            "MSG=端口 31001 走 us，端口 31002 走 uk",
        ])

    def test_nat_alias_and_hop_port_landing(self):
        # NAT 公网端口（link_port）和 Hysteria2 端口跳跃（hop）映射到节点内部监听端口的归属落地
        r = self.sb.source('PORTS=$(_all_ports); '
                           'echo "nat=$(_cfg_port_map 39001 31001 39001)"; '
                           'echo "hop=$(_cfg_port_map 39002 31000-31005 39002)"; '
                           'echo "direct=$(_cfg_port_map 31002 41000 31002)"')
        self.assertEqual(r.stdout.splitlines(), [
            "nat=39001:us",
            "hop=39002:us",
            "direct=31002:uk",
        ])

    def test_pick_gateway_ports_conflict(self):
        # 与其它落地撞网关端口、或 SOCKS_PORT == DNS_PORT 时，必须换新端口；不冲突时原样保留
        (self.sb.etc / "landings" / "sg" / "state").write_text(
            "PORTS=31003\nEP_FAM=4\nEP_MARK=\nSOCKS_PORT=40001\nDNS_PORT=40006\n")
        r = self.sb.source('pick_gateway_ports sg; echo "$(_lst_get sg SOCKS_PORT) $(_lst_get sg DNS_PORT)"')
        sp, dp = r.stdout.strip().split()
        self.assertNotIn(sp, ("40001", "40002", "40003", "40004"))
        self.assertNotEqual(sp, dp)
        # 不冲突时保留原端口
        r = self.sb.source('pick_gateway_ports us; echo "$(_lst_get us SOCKS_PORT) $(_lst_get us DNS_PORT)"')
        self.assertEqual(r.stdout.strip(), "40001 40002")

    def test_write_gw_json_preserves_lnd(self):
        out = self.sb.tmp / "gw-preserve.json"
        r = self.sb.source('load_all; write_gw_json "%s"; echo "LND=$LND"' % out)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "LND=us")

    def test_do_landings_loads_init_and_wgl_ifaces(self):
        (self.sb.etc / "state").write_text(
            "LANDINGS=us uk sg\nMODE=userspace\nINIT=systemd\nSOCKS_USER=wgltest\nSOCKS_PASS=pw1\n")
        r = self.sb.source('systemctl() { [ "$1" = is-active ] && return 0; }; '
                           'wg_exit_ip() { echo "203.0.113.1"; }; '
                           'do_landings; echo "IFACES=$(_wgl_ifaces)"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("203.0.113.1", r.stdout)
        self.assertIn("IFACES=wg-luodi wg-us wg-uk wg-sg", r.stdout)

    def test_gw_wait_empty_port_fails_fast(self):
        r = self.sb.source('WGL_WAIT=25; gw_wait nonexistent && echo OK || echo FAIL')
        self.assertEqual(r.stdout.strip(), "FAIL")


@unittest.skipUnless(have_bins(), "需要 WGL_TEST_BIN（xray、sing-box、hysteria）")
class GatewayAndPatchTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.sb.etc.mkdir()
        st = "SOCKS_PORT=40001\nDNS_PORT=40002\nSOCKS_USER=wgltest\nSOCKS_PASS=pw%s\n" % uuid.uuid4().hex[:8]
        (self.sb.etc / "state").write_text(st)

    def tearDown(self):
        self.sb.cleanup()

    def test_gateway_json_both_modes(self):
        f = self.sb.tmp / "wg.conf"
        for addr, allowed in (("10.0.0.2/32", "0.0.0.0/0"), ("10.0.0.2/32, fd00::2/128", "0.0.0.0/0, ::/0")):
            f.write_text(wg_conf(rand_key(), rand_key(), "engage.example.com:2408", address=addr, allowed=allowed))
            for mode in ("userspace", "kernel"):
                out = self.sb.tmp / ("gw-%s.json" % mode)
                r = self.sb.source('parse_conf "%s" || exit 9; MODE=%s; EP_STRAT=ipv4_only; write_gw_json "%s"' % (f, mode, out))
                self.assertEqual(r.returncode, 0, r.stderr)
                c = subprocess.run([BIN + "/sing-box", "check", "-c", str(out)], capture_output=True, text=True)
                self.assertEqual(c.returncode, 0, c.stderr)
                j = json.loads(out.read_text())
                self.assertEqual(j["inbounds"][0]["listen"], "127.0.0.1")   # 网关只听本机
                self.assertEqual(j["inbounds"][1]["listen"], "127.0.0.1")
                for rule in j["route"]["rules"]:                               # 拒绝不能自动变成“悄悄丢掉”
                    if rule.get("action") == "reject":
                        self.assertTrue(rule.get("no_drop"))
                if mode == "kernel":
                    self.assertEqual(j["outbounds"][0]["bind_interface"], "wg-luodi")
                    self.assertNotIn("endpoints", j)
                else:
                    self.assertFalse(j["endpoints"][0]["system"])            # 不建网卡、不要 TUN
                    self.assertEqual(j["dns"]["servers"][0]["detour"], "wg")  # DNS 也走隧道

    def apply(self, ports, kind, cfg, act="apply", alias=""):
        b = {"xray": "xray", "sing-box": "sing-box", "hysteria": "hysteria"}[kind]
        return self.sb.source('find_jq; PORTS="%s"; apply_one %s "%s" none - "%s/%s" "%s" %s 0; echo "RC=$? $AP_MSG"'
                              % (ports, kind, cfg, BIN, b, alias, act))

    def validate(self, kind, cfg):
        if kind == "xray":
            r = subprocess.run([BIN + "/xray", "-test", "-config", str(cfg)], capture_output=True, text=True)
        else:
            r = subprocess.run([BIN + "/sing-box", "check", "-c", str(cfg)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_xray_patch_idempotent_and_restore(self):
        priv, _ = reality_keypair()
        cfg = make_node(self.sb, 1, "xray", xray_vless_reality(31001, str(uuid.uuid4()), priv, "abcd"))
        orig = cfg.read_bytes()
        r = self.apply("31001 31002", "xray", cfg)
        self.assertIn("RC=0 已改好", r.stdout, r.stderr)
        j = json.loads(cfg.read_text())
        self.assertEqual(j["inbounds"][0]["tag"], "wg-luodi-in-31001")
        self.assertEqual(j["routing"]["rules"][0], {"type": "field", "inboundTag": ["wg-luodi-in-31001"], "outboundTag": "wg-luodi"})
        self.assertEqual(j["outbounds"][0], {"protocol": "freedom"})          # 默认出站还是直连
        self.assertEqual(j["outbounds"][-1]["tag"], "wg-luodi")
        self.validate("xray", cfg)
        once = cfg.read_bytes()
        self.assertIn("已经在走", self.apply("31001 31002", "xray", cfg).stdout)
        self.assertEqual(once, cfg.read_bytes())                              # 第二次什么都不改
        self.assertIn("RC=0", self.apply("31001", "xray", cfg, act="strip").stdout)
        self.assertEqual(orig, cfg.read_bytes())                              # 卸载后逐字节还原

    def test_xray_other_port_untouched(self):
        cfg = make_node(self.sb, 2, "xray", xray_ss(31003, rand_key()))
        orig = cfg.read_bytes()
        self.assertIn("不涉及", self.apply("31001", "xray", cfg).stdout)
        self.assertEqual(orig, cfg.read_bytes())

    def test_xray_multi_inbound_and_existing_rules(self):
        conf = xray_vmess_ws(31004, str(uuid.uuid4()), "/ws")
        conf["inbounds"].append({"tag": "api", "listen": "127.0.0.1", "port": 31005, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}})
        conf["inbounds"].append({"tag": "mine", "port": "31006", "protocol": "socks", "settings": {"auth": "noauth"}})
        conf["routing"] = {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "direct"}]}
        conf["outbounds"] = [{"protocol": "freedom", "tag": "direct"}]
        cfg = make_node(self.sb, 3, "xray", conf)
        self.assertIn("RC=0", self.apply("31004 31006", "xray", cfg).stdout)
        j = json.loads(cfg.read_text())
        self.assertEqual(j["routing"]["rules"][0]["inboundTag"], ["wg-luodi-in-31004", "mine"])
        self.assertEqual(j["routing"]["rules"][1]["inboundTag"], ["api"])
        self.assertEqual(j["routing"]["domainStrategy"], "IPIfNonMatch")
        self.validate("xray", cfg)
        # 删掉一个端口：只剩 31006
        self.apply("31006", "xray", cfg)
        j = json.loads(cfg.read_text())
        self.assertNotIn("tag", j["inbounds"][0])
        self.assertEqual(j["routing"]["rules"][0]["inboundTag"], ["mine"])

    def test_singbox_patch(self):
        priv, _ = reality_keypair()
        conf = sb_anytls_reality(31007, "pw", priv, "abcd")
        conf["route"] = {"rules": [{"action": "sniff"}, {"ip_is_private": True, "action": "reject"}]}
        cfg = make_node(self.sb, 4, "sing-box", conf)
        orig = cfg.read_bytes()
        self.assertIn("RC=0 已改好", self.apply("31007", "sing-box", cfg).stdout)
        j = json.loads(cfg.read_text())
        self.assertEqual(j["route"]["rules"][0], {"action": "sniff"})        # 嗅探规则留在最前面
        self.assertEqual(j["route"]["rules"][1], {"inbound": ["wg-luodi-in-31007"], "outbound": "wg-luodi"})
        self.assertEqual(j["outbounds"][-1]["server"], "127.0.0.1")
        self.validate("sing-box", cfg)
        self.apply("31007", "sing-box", cfg, act="strip")
        self.assertEqual(orig, cfg.read_bytes())

    def test_hysteria_patch(self):
        nd = self.sb.nodes / "5"
        nd.mkdir(parents=True)
        cfg = make_node(self.sb, 5, "hysteria", hy2_yaml(31008, nd, "p" * 32, "o" * 32))
        orig = cfg.read_bytes()
        r = self.sb.source('find_jq; hy_listen_port "%s"' % cfg)
        self.assertEqual(r.stdout.strip(), "31008")
        self.assertIn("RC=0", self.apply("31008", "hysteria", cfg).stdout)
        text = cfg.read_text()
        self.assertIn("# wg-luodi begin", text)
        self.assertIn("addr: 127.0.0.1:40001", text)
        self.assertIn("addr: 127.0.0.1:40002", text)   # DNS 也走网关
        self.assertIn("已经在走", self.apply("31008", "hysteria", cfg).stdout)
        self.apply("31008", "hysteria", cfg, act="strip")
        self.assertEqual(orig, cfg.read_bytes())

    def test_hysteria_with_own_outbounds_is_skipped(self):
        nd = self.sb.nodes / "6"
        nd.mkdir(parents=True)
        text = hy2_yaml(31009, nd, "p" * 32, "o" * 32) + "outbounds:\n  - name: mine\n    type: direct\n"
        cfg = make_node(self.sb, 6, "hysteria", text)
        r = self.apply("31009", "hysteria", cfg)
        self.assertIn("RC=2", r.stdout)
        self.assertEqual(text, cfg.read_text())

    def test_nat_link_port_and_hop_alias(self):
        cfg = make_node(self.sb, 7, "xray", xray_ss(31010, rand_key()), link_port=41010)
        r = self.sb.source('find_jq; PORTS="41010"; cfg_wg_ports xray "%s" "41010"' % cfg)
        self.assertEqual(r.stdout.strip(), "31010")
        r = self.sb.source('find_jq; PORTS="45001"; cfg_wg_ports hysteria "%s" "45000-45010"' % cfg)
        r2 = self.sb.source("find_jq; PORTS='41010'; discover_nodes")
        self.assertIn("|41010", r2.stdout)

    def test_invalid_result_not_written(self):
        """改完通不过 xray -test 时，原配置不动。"""
        conf = xray_ss(31011, rand_key())
        conf["inbounds"][0]["settings"]["method"] = "bogus-method"   # 本来就坏的配置
        cfg = make_node(self.sb, 8, "xray", conf)
        orig = cfg.read_bytes()
        r = self.apply("31011", "xray", cfg)
        self.assertIn("RC=1", r.stdout)
        self.assertEqual(orig, cfg.read_bytes())

    def test_panel_config_not_touched(self):
        r = self.sb.source("find_jq; apply_one panel /usr/local/x-ui/bin/config.json none - x '' apply 0; echo \"RC=$? $AP_MSG\"")
        self.assertIn("RC=2", r.stdout)
        self.assertIn("面板", r.stdout)


@unittest.skipUnless(have_bins(), "需要 WGL_TEST_BIN（xray、sing-box、hysteria）")
class MultiPatchTest(unittest.TestCase):
    """多落地：不同端口走不同落地、端口归属冲突、删落地、老 tag 迁移。"""

    def setUp(self):
        self.sb = Sandbox()
        self.sb.etc.mkdir()
        (self.sb.etc / "state").write_text(
            "LANDINGS=us uk\nMODE=userspace\nINIT=openrc\nSOCKS_USER=wgltest\nSOCKS_PASS=pw%s\n" % uuid.uuid4().hex[:8])
        self.make_landing("us", "31001", 40001, 40002)
        self.make_landing("uk", "31002", 40003, 40004)

    def tearDown(self):
        self.sb.cleanup()

    def make_landing(self, name, ports, socks, dns):
        d = self.sb.etc / "landings" / name
        d.mkdir(parents=True)
        (d / "wg.conf").write_text(wg_conf(rand_key(), rand_key(), "1.2.3.4:51820"))
        (d / "state").write_text("PORTS=%s\nEP_FAM=4\nEP_MARK=\nSOCKS_PORT=%d\nDNS_PORT=%d\n" % (ports, socks, dns))
        return d

    def apply(self, ports, kind, cfg, act="apply", alias=""):
        b = {"xray": "xray", "sing-box": "sing-box", "hysteria": "hysteria"}[kind]
        return self.sb.source('find_jq; PORTS="%s"; apply_one %s "%s" none - "%s/%s" "%s" %s 0; echo "RC=$? $AP_MSG"'
                              % (ports, kind, cfg, BIN, b, alias, act))

    def validate(self, kind, cfg):
        if kind == "xray":
            r = subprocess.run([BIN + "/xray", "-test", "-config", str(cfg)], capture_output=True, text=True)
        else:
            r = subprocess.run([BIN + "/sing-box", "check", "-c", str(cfg)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_xray_two_ports_two_landings(self):
        priv, _ = reality_keypair()
        conf = xray_vless_reality(31001, str(uuid.uuid4()), priv, "abcd")
        conf["inbounds"].append(xray_ss(31002, ss_key())["inbounds"][0])
        cfg = make_node(self.sb, 1, "xray", conf)
        orig = cfg.read_bytes()
        r = self.apply("31001 31002", "xray", cfg)
        self.assertIn("RC=0 已改好", r.stdout, r.stderr)
        self.assertIn("31001 走 us", r.stdout)
        self.assertIn("31002 走 uk", r.stdout)
        j = json.loads(cfg.read_text())
        obs = {o["tag"]: o for o in j["outbounds"] if o.get("tag", "").startswith("wg-luodi")}
        self.assertEqual(sorted(obs), ["wg-luodi-uk", "wg-luodi-us"])

        def socks_port(ob):   # 新版写法 settings.port，老版写法 settings.servers[0].port
            s = ob["settings"]
            return s.get("port") or s["servers"][0]["port"]

        self.assertEqual(socks_port(obs["wg-luodi-us"]), 40001)
        self.assertEqual(socks_port(obs["wg-luodi-uk"]), 40003)
        rules = [x for x in j["routing"]["rules"] if x.get("outboundTag", "").startswith("wg-luodi")]
        self.assertEqual(rules, [
            {"type": "field", "inboundTag": ["wg-luodi-in-31002"], "outboundTag": "wg-luodi-uk"},
            {"type": "field", "inboundTag": ["wg-luodi-in-31001"], "outboundTag": "wg-luodi-us"},
        ])
        self.validate("xray", cfg)
        once = cfg.read_bytes()
        self.assertIn("已经在走", self.apply("31001 31002", "xray", cfg).stdout)
        self.assertEqual(once, cfg.read_bytes())                              # 第二次什么都不改
        self.apply("31001 31002", "xray", cfg, act="strip")
        self.assertEqual(orig, cfg.read_bytes())                              # 卸载后逐字节还原

    def test_singbox_two_ports_two_landings(self):
        priv, _ = reality_keypair()
        conf = sb_anytls_reality(31001, "pw", priv, "abcd")
        conf["inbounds"].append({"type": "shadowsocks", "listen": "0.0.0.0", "listen_port": 31002,
                                 "method": "2022-blake3-aes-128-gcm", "password": rand_key()})
        cfg = make_node(self.sb, 2, "sing-box", conf)
        orig = cfg.read_bytes()
        self.assertIn("RC=0 已改好", self.apply("31001 31002", "sing-box", cfg).stdout)
        j = json.loads(cfg.read_text())
        obs = {o["tag"]: o for o in j["outbounds"] if o.get("tag", "").startswith("wg-luodi")}
        self.assertEqual(sorted(obs), ["wg-luodi-uk", "wg-luodi-us"])
        self.assertEqual(obs["wg-luodi-us"]["server_port"], 40001)
        self.assertEqual(obs["wg-luodi-uk"]["server_port"], 40003)
        rules = [x for x in j["route"]["rules"] if x.get("outbound", "").startswith("wg-luodi")]
        self.assertEqual(rules, [
            {"inbound": ["wg-luodi-in-31002"], "outbound": "wg-luodi-uk"},
            {"inbound": ["wg-luodi-in-31001"], "outbound": "wg-luodi-us"},
        ])
        self.validate("sing-box", cfg)
        self.apply("31001 31002", "sing-box", cfg, act="strip")
        self.assertEqual(orig, cfg.read_bytes())

    def test_hysteria_uses_its_ports_landing(self):
        nd = self.sb.nodes / "3"
        nd.mkdir(parents=True)
        cfg = make_node(self.sb, 3, "hysteria", hy2_yaml(31002, nd, "p" * 32, "o" * 32))
        orig = cfg.read_bytes()
        self.assertIn("RC=0", self.apply("31002", "hysteria", cfg).stdout)
        text = cfg.read_text()
        self.assertIn("name: wg-luodi-uk", text)
        self.assertIn("addr: 127.0.0.1:40003", text)
        self.assertIn("addr: 127.0.0.1:40004", text)   # DNS 也走 uk 的隧道
        self.apply("31002", "hysteria", cfg, act="strip")
        self.assertEqual(orig, cfg.read_bytes())

    def test_port_conflict_across_landings(self):
        r = self.sb.source('_ports_change add uk 31001; echo "RC=$?"')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("已经在走落地 us", r.stdout + r.stderr)
        self.assertIn("del-port us 31001", r.stdout + r.stderr)
        # 加到同一个落地是允许的（已经在里面了，等于没变化）
        r = self.sb.source('_ports_change add us 31001; echo "RC=$?"')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_add_port_to_landing_patches_node(self):
        cfg = make_node(self.sb, 4, "xray", xray_ss(31009, ss_key()))
        r = self.sb.source('_ports_change add us 31009; echo "RC=$?"')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        j = json.loads(cfg.read_text())
        self.assertIn("wg-luodi-us", [o.get("tag") for o in j["outbounds"]])
        st = dict(l.split("=", 1) for l in (self.sb.etc / "landings" / "us" / "state").read_text().splitlines())
        self.assertEqual(st["PORTS"], "31001 31009")
        r = self.sb.source('_ports_change del us 31009; echo "RC=$?"')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        j = json.loads(cfg.read_text())
        self.assertNotIn("wg-luodi-us", [o.get("tag") for o in j["outbounds"]])

    def test_del_landing_restores_its_ports(self):
        shutil.copy(BIN + "/sing-box", str(self.sb.lib / "sing-box"))
        shutil.copy(str(SCRIPT), str(self.sb.cmd))   # 假 rc-service 重启网关时要跑 wg-luodi up/down
        self.sb.cmd.chmod(0o755)
        priv, _ = reality_keypair()
        conf = xray_vless_reality(31001, str(uuid.uuid4()), priv, "abcd")
        conf["inbounds"].append(xray_ss(31002, ss_key())["inbounds"][0])
        cfg = make_node(self.sb, 5, "xray", conf)
        self.assertIn("RC=0", self.apply("31001 31002", "xray", cfg).stdout)
        r = self.sb.source('do_del_landing us -y; echo "RC=$?"')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.sb.etc / "landings" / "us").exists())
        st = (self.sb.etc / "state").read_text()
        self.assertIn("LANDINGS=uk", st)
        j = json.loads(cfg.read_text())
        tags = [o.get("tag") for o in j["outbounds"]]
        self.assertNotIn("wg-luodi-us", tags)          # us 的出站和规则没了
        self.assertIn("wg-luodi-uk", tags)             # uk 的还在
        rules = [x for x in j["routing"]["rules"] if x.get("outboundTag", "").startswith("wg-luodi")]
        self.assertEqual(rules, [{"type": "field", "inboundTag": ["wg-luodi-in-31002"], "outboundTag": "wg-luodi-uk"}])
        self.validate("xray", cfg)

    def test_add_landing(self):
        shutil.copy(BIN + "/sing-box", str(self.sb.lib / "sing-box"))
        shutil.copy(str(SCRIPT), str(self.sb.cmd))   # 假 rc-service 重启网关时要跑 wg-luodi up/down
        self.sb.cmd.chmod(0o755)
        conf = self.sb.tmp / "sg.conf"
        conf.write_text(wg_conf(rand_key(), rand_key(), "1.2.3.4:51820"))
        cfg = make_node(self.sb, 7, "xray", xray_ss(31009, ss_key()))
        r = self.sb.source('do_add_landing sg; echo "RC=$?"',
                           {"WG_CONF_FILE": str(conf), "WG_PORTS": "31009"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("LANDINGS=us uk sg", (self.sb.etc / "state").read_text())
        st = dict(l.split("=", 1) for l in (self.sb.etc / "landings" / "sg" / "state").read_text().splitlines())
        self.assertEqual(st["PORTS"], "31009")
        j = json.loads(cfg.read_text())
        self.assertIn("wg-luodi-sg", [o.get("tag") for o in j["outbounds"]])
        gw = json.loads((self.sb.etc / "gw.json").read_text())
        self.assertIn("wg-sg", [e["tag"] for e in gw["endpoints"]])
        # 再加一次同名落地：报错
        r = self.sb.source('do_add_landing sg; echo "RC=$?"',
                           {"WG_CONF_FILE": str(conf), "WG_PORTS": "31010"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("已经有落地 sg", r.stdout + r.stderr)

    def test_rename_landing(self):
        shutil.copy(BIN + "/sing-box", str(self.sb.lib / "sing-box"))
        shutil.copy(str(SCRIPT), str(self.sb.cmd))
        self.sb.cmd.chmod(0o755)
        cfg = make_node(self.sb, 8, "xray", xray_ss(31001, ss_key()))
        self.assertIn("RC=0", self.apply("31001", "xray", cfg).stdout)
        r = self.sb.source('do_rename_landing us usa; echo "RC=$?"')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.sb.etc / "landings" / "us").exists())
        self.assertTrue((self.sb.etc / "landings" / "usa" / "wg.conf").exists())
        self.assertIn("LANDINGS=usa uk", (self.sb.etc / "state").read_text())
        j = json.loads(cfg.read_text())
        tags = [o.get("tag") for o in j["outbounds"]]
        self.assertIn("wg-luodi-usa", tags)
        self.assertNotIn("wg-luodi-us", tags)
        self.validate("xray", cfg)

    def test_migrated_node_old_tag_is_replaced(self):
        # 先按老布局改好节点（单出站 wg-luodi），再迁移：第一次重新应用就换成 wg-luodi-default
        etc = self.sb.etc
        (etc / "wg.conf").write_text(wg_conf(rand_key(), rand_key(), "5.6.7.8:51820"))
        (etc / "state").write_text("MODE=userspace\nPORTS=31001\nEP_FAM=4\nEP_MARK=\n"
                                   "SOCKS_PORT=40001\nDNS_PORT=40002\nSOCKS_USER=wgltest\nSOCKS_PASS=pw1\n")
        shutil.rmtree(etc / "landings")
        cfg = make_node(self.sb, 6, "xray", xray_ss(31001, ss_key()))
        self.assertIn("RC=0 已改好", self.apply("31001", "xray", cfg).stdout)
        self.assertIn('"wg-luodi"', cfg.read_text())
        self.sb.source('migrate_legacy')
        self.assertIn("RC=0 已改好", self.apply("31001", "xray", cfg).stdout)
        j = json.loads(cfg.read_text())
        tags = [o.get("tag") for o in j["outbounds"]]
        self.assertIn("wg-luodi-default", tags)
        self.assertNotIn("wg-luodi", tags)
        rules = [x for x in j["routing"]["rules"] if x.get("outboundTag", "").startswith("wg-luodi")]
        self.assertEqual(rules, [{"type": "field", "inboundTag": ["wg-luodi-in-31001"],
                                  "outboundTag": "wg-luodi-default"}])
        self.validate("xray", cfg)
        self.assertIn("已经在走", self.apply("31001", "xray", cfg).stdout)   # 再跑一次就不动了


if __name__ == "__main__":
    unittest.main()
