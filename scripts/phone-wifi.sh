#!/bin/bash
# phone-wifi.sh - use a phone over Wi-Fi, safely: pair it over the USB cable once, then talk to it through an encrypted,
# authenticated tunnel (ios/Backburner/Sidecar/Tunnel.swift). Over Wi-Fi the app's servers answer nothing else.
#   scripts/phone-wifi.sh pair      # phone on the cable: it makes a key and hands it to this Mac (~/.config/backburner/wifi)
#   scripts/phone-wifi.sh up [IP]   # the tunnel to the paired phone's Wi-Fi address (IP: override); stays in the foreground
#   scripts/phone-wifi.sh unpair    # phone on the cable: delete its key (its Wi-Fi listener closes) and this Mac's copy
#   scripts/phone-wifi.sh status
# Through the tunnel the phone's servers are on 127.0.0.1: tail 51060, control 51061, attention 51062, ggml RPC 51052,
# e.g. LLAMA_SPLIT_TAIL=127.0.0.1:51060 scripts/serve.sh. Model files still go over the cable (phone-tail.sh, phone-push.py).
# More than one paired phone: UDID=... picks one.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${XDG_CONFIG_HOME:-$HOME/.config}/backburner/wifi
BIN=build/bin/backburner-tunnel
umask 077

cable_ip() { scripts/phone-up.sh 2>/dev/null | head -1 | awk '{print $1}'; }
cable_udid() {
  local raw; raw=$(ioreg -p IOUSB -w 0 -l 2>/dev/null | sed -n 's/.*"kUSBSerialNumberString" = "\(00008[0-9A-F]*\)".*/\1/p' | head -1)
  [ ${#raw} -eq 24 ] && echo "${raw:0:8}-${raw:8}"
}
ctl() {   # one command on the phone's control port over the cable; prints the JSON reply
  python3 - "$1" "$2" <<'PY'
import json, socket, sys
with socket.create_connection((sys.argv[1], 50061), timeout=10) as s:
    s.sendall(sys.argv[2].encode() + b"\n")
    b = b""
    while not b.endswith(b"\n"):
        c = s.recv(65536)
        if not c: break
        b += c
print(b.decode().strip())
PY
}
pick() {   # the paired phone's UDID
  if [ -n "${UDID:-}" ]; then echo "$UDID"; return; fi
  local keys=("$DIR"/*.key)
  [ -e "${keys[0]}" ] || { echo "phone-wifi: no paired phone (scripts/phone-wifi.sh pair)" >&2; exit 1; }
  [ ${#keys[@]} -eq 1 ] || { echo "phone-wifi: ${#keys[@]} paired phones; pick one with UDID=" >&2; exit 1; }
  basename "${keys[0]}" .key
}

case "${1:-status}" in
  pair)
    IP=$(cable_ip); U=$(cable_udid || true)
    [ -n "$IP" ] && [ -n "$U" ] || { echo "phone-wifi: pairing needs the phone on the USB cable with Backburner open" >&2; exit 1; }
    mkdir -p "$DIR"; chmod 700 "$DIR"
    ctl "$IP" pair | python3 -c '
import json, os, sys
r = json.loads(sys.stdin.read())
if r.get("error") or not r.get("wifi_key"):
    sys.exit("phone-wifi: pairing failed: " + str(r.get("error", "no key in the reply")))
d, u = sys.argv[1], sys.argv[2]
fd = os.open(os.path.join(d, u + ".key"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, (r["wifi_key"] + "\n").encode()); os.close(fd)
with open(os.path.join(d, u + ".json"), "w") as f: json.dump({"wifi_ip": r.get("wifi_ip", "")}, f)
print("phone-wifi: paired; key saved for this Mac only. Wi-Fi address now: " + (r.get("wifi_ip") or "none (Wi-Fi off?)"))
' "$DIR" "$U"
    ;;
  up)
    U=$(pick)
    W=${2:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("wifi_ip",""))' "$DIR/$U.json" 2>/dev/null || true)}
    [ -n "$W" ] || { echo "phone-wifi: no Wi-Fi address known; pass it: scripts/phone-wifi.sh up IP" >&2; exit 1; }
    if [ ! -x "$BIN" ] || [ "$BIN" -ot ios/Backburner/Sidecar/Tunnel.swift ] || [ "$BIN" -ot tools/wifi-tunnel/main.swift ]; then
      mkdir -p "$(dirname "$BIN")"
      xcrun swiftc -O -parse-as-library -o "$BIN" ios/Backburner/Sidecar/Tunnel.swift tools/wifi-tunnel/main.swift
    fi
    exec "$BIN" --phone "$W" --key "$DIR/$U.key"
    ;;
  unpair)
    IP=$(cable_ip); U=$(cable_udid || true)
    [ -n "$IP" ] || { echo "phone-wifi: unpairing needs the phone on the USB cable" >&2; exit 1; }
    ctl "$IP" unpair | grep -q '"paired":false' && echo "phone-wifi: the phone deleted its key; its Wi-Fi listener closes"
    [ -n "$U" ] && rm -f "$DIR/$U.key" "$DIR/$U.json" && echo "phone-wifi: removed this Mac's copy"
    ;;
  status)
    ls "$DIR"/*.key 2>/dev/null | sed 's|.*/||; s|\.key$| paired|' || echo "no paired phones"
    IP=$(cable_ip)
    [ -n "$IP" ] && ctl "$IP" mem | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print("on the cable:", {k: r.get(k) for k in ("wifi_paired","wifi_ip","wifi_tunnel","gate_denied","gate_last_denied","cable_if","cable_if_type")})'
    ;;
  *) sed -n 2,13p "$0"; exit 1 ;;
esac
