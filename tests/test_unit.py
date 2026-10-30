"""wg-luodi 的单元测试：解析配置、粘贴、端口、生成网关配置、改节点配置（不跑网络）。"""
import json
import subprocess
import unittest
import uuid
from pathlib import Path

from helpers import (BIN, SCRIPT, Sandbox, have_bins, hy2_yaml, make_node, rand_key, reality_keypair,
                     sb_anytls_reality, wg_conf, xray_ss, xray_vless_reality, xray_vmess_ws)


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
        r = self.sb.source('curl() { printf 1250000; }; _speed')
        self.assertEqual(r.stdout, "10.0", r.stderr)                     # 1250000 字节/秒 = 10 Mbps
        r = self.sb.source('curl() { printf 0; }; _speed || echo NONE')
        self.assertEqual(r.stdout.strip(), "NONE", r.stderr)

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


if __name__ == "__main__":
    unittest.main()
