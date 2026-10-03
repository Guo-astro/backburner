# Using a phone over Wi-Fi

The cable is the fast, simple path: no setup, nothing to configure, and nothing else on your network can reach the app. Wi-Fi
is for a phone that can't be on a cable, such as a third phone. It is off until you pair the phone, and then everything on
it is encrypted and authenticated.

## Pair, use, unpair

```bash
scripts/phone-wifi.sh pair
```

With the phone on the cable and Backburner open, the phone creates a random 256-bit key, stores it in its Keychain (this
device only, not in backups), and gives it to the Mac, which keeps it in `~/.config/backburner/wifi/` (readable by you
alone). Pairing works over the cable only.

```bash
scripts/phone-wifi.sh up
```

This starts the tunnel to the phone's Wi-Fi address. It keeps running; stop it with Ctrl-C. On this Mac the phone's servers
are then at 127.0.0.1:

| Phone server | Through the tunnel |
|---|---|
| prefill tail (50060) | 127.0.0.1:51060 |
| control (50061) | 127.0.0.1:51061 |
| phone-held context (50062) | 127.0.0.1:51062 |
| ggml RPC (50052) | 127.0.0.1:51052 |

For example, `LLAMA_SPLIT_TAIL=127.0.0.1:51060 scripts/serve.sh`. Copy model files over the cable first (`phone-tail.sh`,
`phone-push.py`).

```bash
scripts/phone-wifi.sh unpair
```

With the phone on the cable, the phone deletes its key and closes the Wi-Fi port within a couple of seconds, and the Mac
deletes its copy. `scripts/phone-wifi.sh status` shows what's paired.

## What protects it

- Over Wi-Fi the phone's servers refuse every connection, and the only open port is the tunnel (50070), and only while
  paired.
- The tunnel is the Noise protocol `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (noiseprotocol.org): a fresh X25519 key pair on
  both sides of every connection, the pairing key mixed in before the first message, and ChaCha20-Poly1305 on every frame
  in both directions. A peer without the key can't produce a first message the phone accepts, or read anything.
  Recorded traffic can't be decrypted later, even with the key (forward secrecy).
- The phone opens a connection to one of its servers only after the Mac's first encrypted frame authenticates, so a replayed
  handshake never reaches a server. The tunnel only reaches the four servers above.
- Pairing and unpairing are refused through the tunnel. They need the cable.
- Handshakes that stall are dropped after 5 s, and at most 16 tunnel connections are open at once.

Checks: `tests/security/run.sh` tests the handshake against the published Noise test vectors, plus wrong keys, tampering,
replay, other ports and oversized or garbage input. `scripts/check-phone-exposure.py` runs the same checks against a real
phone over your Wi-Fi.

## Speed

Wi-Fi adds latency and has less bandwidth than the cable (USB-C is roughly 96 µs per round trip through the app). The
tunnel's encryption runs at about 250 MB/s each way on a Mac's loopback, more than Wi-Fi carries. Prefill moves about 5 MB
per 256-token chunk to the phone, so a Wi-Fi phone helps most on long reads where its compute outweighs the transfer.
