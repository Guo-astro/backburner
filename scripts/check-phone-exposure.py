#!/usr/bin/env python3
"""check-phone-exposure.py - from this Mac, check what the wired phone exposes (GitHub issue #2). Run it with Backburner open
on a phone on the USB cable, and the Mac on the same Wi-Fi as the phone for the Wi-Fi half. Exit 0 only if everything passes.

  scripts/check-phone-exposure.py [--cable IP] [--wifi IP]

Cable:   every server port answers (ggml RPC 50052, tail 50060, control 50061, attention 50062).
Bonjour: nothing is advertised (_infernet-rpc, _ggml-rpc).
Wi-Fi:   each raw server port refuses: the connection is refused or dropped before a single byte comes back, and the phone's
         gate counted the attempt (control port `mem`: gate_denied, gate_last_denied).
Tunnel:  :50070 is closed while unpaired. Paired (scripts/phone-wifi.sh pair): garbage and a random key are refused, the key
         this Mac holds works, and pairing through the tunnel is refused.
"""
import argparse, json, os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORTS = {50052: "ggml RPC", 50060: "prefill tail", 50061: "control", 50062: "phone attention"}
results = []


def record(ok, what, detail=""):
    results.append(ok)
    tag = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
    print(f"{tag}  {what}" + (f": {detail}" if detail else ""))


def ctl(ip, cmd):
    with socket.create_connection((ip, 50061), timeout=10) as s:
        s.sendall(cmd.encode() + b"\n")
        b = b""
        while not b.endswith(b"\n"):
            c = s.recv(65536)
            if not c:
                break
            b += c
    return json.loads(b)


def raw_probe(ip, port):
    """'refused' | 'timeout' | 'dropped' (connected, closed with 0 bytes) | 'silent' (open, nothing read, not closed) | 'ANSWERED'"""
    try:
        s = socket.create_connection((ip, port), timeout=3)
    except ConnectionRefusedError:
        return "refused"
    except (socket.timeout, OSError):
        return "timeout"
    try:
        s.settimeout(2)
        try:
            s.sendall(b"mem\n" if port == 50061 else b"\x53\x50\x54\x4c" + b"\x01\x00\x00\x00" + b"\x00" * 8)
        except OSError:
            return "dropped"
        try:
            data = s.recv(4096)
        except socket.timeout:
            return "silent"
        except OSError:
            return "dropped"
        return "dropped" if not data else "ANSWERED"
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cable")
    ap.add_argument("--wifi")
    a = ap.parse_args()

    cable = a.cable or subprocess.run([os.path.join(ROOT, "scripts/phone-up.sh")], capture_output=True, text=True).stdout.split()[:1]
    cable = cable if isinstance(cable, str) else (cable[0] if cable else "")
    if not cable:
        sys.exit("check-phone-exposure: no phone on the USB cable (open Backburner, plug it in)")

    # ---- cable
    try:
        m0 = ctl(cable, "mem")
        record(True, f"cable {cable}: control port answers")
    except Exception as e:
        record(False, f"cable {cable}: control port", str(e))
        m0 = {}
    for port, name in PORTS.items():
        try:
            socket.create_connection((cable, port), timeout=3).close()
            record(True, f"cable: {name} :{port} accepts")
        except Exception as e:
            record(False, f"cable: {name} :{port}", str(e))
    if "gate_denied" not in m0:
        record(False, "the app has the cable gate", "mem has no gate_denied: an app from before the fix?")
    else:
        record(True, "the app has the cable gate", f"cable interface {m0.get('cable_if') or '?'} (type {m0.get('cable_if_type')})")

    # ---- Bonjour
    found = []
    for svc in ("_infernet-rpc._tcp", "_ggml-rpc._tcp"):
        p = subprocess.Popen(["dns-sd", "-B", svc, "local."], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        time.sleep(3)
        p.terminate()
        out = p.communicate()[0]
        found += [l for l in out.splitlines() if " Add " in l]
    record(not found, "nothing advertised over Bonjour", "; ".join(found))

    # ---- Wi-Fi, raw ports
    wifi = a.wifi or m0.get("wifi_ip", "")
    if not wifi:
        record(None, "Wi-Fi checks", "the phone has no Wi-Fi address (Wi-Fi off?) - pass --wifi IP to force")
    else:
        d0 = m0.get("gate_denied", 0)
        connected = 0
        for port, name in PORTS.items():
            r = raw_probe(wifi, port)
            connected += r in ("dropped", "silent", "ANSWERED")
            record(r in ("refused", "timeout", "dropped"), f"Wi-Fi {wifi}: {name} :{port} refuses", r)
        if r == "timeout" and connected == 0:
            print("      (every port timed out: is this Mac on the same Wi-Fi as the phone? then these passes prove little)")
        try:
            m1 = ctl(cable, "mem")
            grew = m1.get("gate_denied", 0) - d0
            record(grew >= connected, "the phone's gate counted the Wi-Fi attempts", f"{grew} refused; last: {m1.get('gate_last_denied', '')}")
        except Exception as e:
            record(False, "re-reading the gate counters", str(e))

        # ---- the tunnel
        paired = m0.get("wifi_paired", False)
        r = raw_probe(wifi, 50070)
        if not paired:
            record(r in ("refused", "timeout"), "unpaired: the Wi-Fi tunnel port is closed", r)
            record(None, "tunnel with a key", "not paired (scripts/phone-wifi.sh pair to test it)")
        else:
            record(r in ("refused", "timeout", "dropped"), "paired: garbage at the tunnel port is refused", r)
            binp = os.path.join(ROOT, "build/bin/backburner-tunnel")
            if not os.path.exists(binp):
                os.makedirs(os.path.dirname(binp), exist_ok=True)
                subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-o", binp, os.path.join(ROOT, "ios/Backburner/Sidecar/Tunnel.swift"),
                                os.path.join(ROOT, "tools/wifi-tunnel/main.swift")], check=True)
            w = subprocess.run([binp, "--phone", wifi, "--probe-wrong-key"], capture_output=True, text=True)
            record(w.returncode == 0, "paired: a random key is refused", (w.stdout + w.stderr).strip())
            keydir = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "backburner/wifi")
            keys = [f for f in os.listdir(keydir) if f.endswith(".key")] if os.path.isdir(keydir) else []
            if len(keys) == 1:
                g = subprocess.run([binp, "--phone", wifi, "--key", os.path.join(keydir, keys[0]), "--probe"], capture_output=True, text=True)
                for line in (g.stdout + g.stderr).strip().splitlines():
                    record(line.startswith("PROBE-OK"), "paired: " + line.split(": ", 1)[-1])
                if g.returncode not in (0, 2):
                    record(False, "paired: the tunnel probe", (g.stdout + g.stderr).strip())
            else:
                record(None, "tunnel with this Mac's key", f"{len(keys)} keys in {keydir}")

    bad = results.count(False)
    print(f"\n{results.count(True)} passed, {bad} failed, {results.count(None)} skipped")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
