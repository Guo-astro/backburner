// backburner-tunnel - the Mac's end of the Wi-Fi tunnel (ios/Backburner/Sidecar/Tunnel.swift). Built by scripts/phone-wifi.sh.
//
//   backburner-tunnel --phone WIFI_IP --key KEYFILE [--map LOCAL:REMOTE ...]
//
// Listens on 127.0.0.1 only (default maps 51052:50052 51060:50060 51061:50061 51062:50062) and carries each local connection
// to the phone's server REMOTE through an encrypted, authenticated channel (Noise NNpsk0 with the key the phone gave this Mac
// when it was paired over the cable). Point the Mac's tools at 127.0.0.1:LOCAL, e.g. LLAMA_SPLIT_TAIL=127.0.0.1:51060.
// The key file must be readable by you alone (scripts/phone-wifi.sh pair writes it so).
import Foundation

func die(_ s: String) -> Never { FileHandle.standardError.write("backburner-tunnel: \(s)\n".data(using: .utf8)!); exit(1) }

@main struct Main {
    static func main() {
        var phone = "", keyPath = "", maps: [(Int, Int)] = [], probe = false, wrongKey = false
        var args = CommandLine.arguments.dropFirst()
        while let a = args.popFirst() {
            switch a {
            case "--phone": phone = args.popFirst() ?? ""
            case "--key": keyPath = args.popFirst() ?? ""
            case "--probe": probe = true            // check mode (scripts/check-phone-exposure.py): `mem` through the tunnel, then exit
            case "--probe-wrong-key": wrongKey = true // check mode: a random key must be refused
            case "--map":
                let p = (args.popFirst() ?? "").split(separator: ":").compactMap { Int($0) }
                guard p.count == 2, Tunnel.targets.contains(p[1]) else { die("--map LOCAL:REMOTE, REMOTE one of \(Tunnel.targets.sorted())") }
                maps.append((p[0], p[1]))
            default: die("usage: backburner-tunnel --phone WIFI_IP --key KEYFILE [--map LOCAL:REMOTE ...]")
            }
        }
        if wrongKey {
            guard !phone.isEmpty else { die("--probe-wrong-key needs --phone") }
            let bogus = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            do {
                let fd = try Sock.connectTCP(phone, Tunnel.port)
                Sock.setTimeout(fd, seconds: 5)
                _ = try Tunnel.clientHandshake(fd: fd, psk: bogus, target: 50061)
                // the phone never answers a wrong key; reaching here means it did
                print("PROBE-FAIL: the phone completed a handshake with a random key"); exit(2)
            } catch {
                print("PROBE-OK: a random key was refused (\(error))"); exit(0)
            }
        }
        guard !phone.isEmpty, !keyPath.isEmpty else { die("usage: backburner-tunnel --phone WIFI_IP --key KEYFILE [--map LOCAL:REMOTE ...]") }
        if maps.isEmpty { maps = Tunnel.targets.sorted().map { ($0 + 1000, $0) } }

        var st = stat()
        guard stat(keyPath, &st) == 0 else { die("no key file \(keyPath) (pair first: scripts/phone-wifi.sh pair)") }
        guard st.st_mode & 0o077 == 0, st.st_uid == getuid() else { die("\(keyPath) must be yours and readable by you alone (chmod 600)") }
        guard let txt = try? String(contentsOfFile: keyPath, encoding: .utf8),
              let key = Data(base64Encoded: txt.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else { die("\(keyPath) is not a pairing key") }

        // one handshake up front, so a wrong key or an unreachable phone fails now, not on first use
        do {
            let fd = try Sock.connectTCP(phone, Tunnel.port)
            Sock.setTimeout(fd, seconds: 5)
            _ = try Tunnel.clientHandshake(fd: fd, psk: key, target: 50061)
            close(fd)
        } catch {
            die("\(phone):\(Tunnel.port): \(error)")
        }

        if probe {
            do {
                let fd = try Sock.connectTCP(phone, Tunnel.port)
                Sock.setTimeout(fd, seconds: 5)
                var (send, recv) = try Tunnel.clientHandshake(fd: fd, psk: key, target: 50061)
                try Sock.writeAll(fd, Sock.frame(try send.encrypt(ad: Data(), Data("mem\n".utf8))))
                var reply = Data()
                while !reply.contains(0x0a) { reply += try recv.decrypt(ad: Data(), try Sock.readFrame(fd, max: Tunnel.maxPlain + 16)) }
                let ok = (try? JSONSerialization.jsonObject(with: reply.prefix(while: { $0 != 0x0a }))) is [String: Any]
                print(ok ? "PROBE-OK: the control port answered through the tunnel" : "PROBE-FAIL: unexpected reply to mem")
                // pairing must need the cable itself: through the tunnel it is refused (and the reply is never printed: it
                // would hold a key if the check failed)
                try Sock.writeAll(fd, Sock.frame(try send.encrypt(ad: Data(), Data("pair\n".utf8))))
                reply = Data()
                while !reply.contains(0x0a) { reply += try recv.decrypt(ad: Data(), try Sock.readFrame(fd, max: Tunnel.maxPlain + 16)) }
                close(fd)
                let refused = String(decoding: reply, as: UTF8.self).contains("refused: pairing works over the USB cable only")
                print(refused ? "PROBE-OK: pairing through the tunnel was refused" : "PROBE-FAIL: pairing through the tunnel was NOT refused")
                exit(ok && refused ? 0 : 2)
            } catch {
                print("PROBE-FAIL: \(error)"); exit(2)
            }
        }

        for (local, remote) in maps {
            let ls = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_port = UInt16(local).bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")   // this Mac only
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ls, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            guard ok, listen(ls, 8) == 0 else { die("127.0.0.1:\(local): \(String(cString: strerror(errno)))") }
            print("tunnel: 127.0.0.1:\(local) -> \(phone) :\(remote) (encrypted)")
            Thread.detachNewThread {
                while true {
                    let c = accept(ls, nil, nil)
                    if c < 0 { continue }
                    Thread.detachNewThread {
                        defer { close(c) }
                        Sock.tune(c)
                        do {
                            let fd = try Sock.connectTCP(phone, Tunnel.port)
                            defer { close(fd) }
                            Sock.setTimeout(fd, seconds: 5)
                            let (send, recv) = try Tunnel.clientHandshake(fd: fd, psk: key, target: remote)
                            Sock.setTimeout(fd, seconds: 0)
                            Tunnel.pump(plain: c, secure: fd, send: send, recv: recv)
                        } catch {
                            FileHandle.standardError.write("backburner-tunnel: :\(remote): \(error)\n".data(using: .utf8)!)
                        }
                    }
                }
            }
        }
        fflush(stdout)
        while true { sleep(3600) }
    }
}
