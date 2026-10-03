// tunnel-test.swift - the Wi-Fi tunnel's crypto and handshake (ios/Backburner/Sidecar/Tunnel.swift), on the Mac.
//   tests/security/run.sh   (builds this with Tunnel.swift; exits non-zero on any failure)
// 1. Noise_NNpsk0_25519_ChaChaPoly_SHA256 against the published test vector (noise-nnpsk0-vectors.json): every handshake and
//    transport ciphertext and the handshake hash, byte for byte.
// 2. Real sockets on loopback: the right key carries 8 MB intact both ways; a wrong key, a tampered frame, a replayed first
//    message, a port outside the allowlist, an oversized frame and a garbage handshake are all refused before anything is
//    forwarded.
import CryptoKit
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ msg: String) { if c { pass += 1 } else { fail += 1; FileHandle.standardError.write("FAIL \(msg)\n".data(using: .utf8)!) } }
func hex(_ s: String) -> Data { var d = Data(); var i = s.startIndex; while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }; return d }

func vectors() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("noise-nnpsk0-vectors.json")
    let v = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let psk = hex((v["init_psks"] as! [String])[0])
    var ini = try NoiseNNpsk0(prologue: hex(v["init_prologue"] as! String), psk: psk,
                              ephemeral: try .init(rawRepresentation: hex(v["init_ephemeral"] as! String)))
    var res = try NoiseNNpsk0(prologue: hex(v["resp_prologue"] as! String), psk: psk,
                              ephemeral: try .init(rawRepresentation: hex(v["resp_ephemeral"] as! String)))
    let msgs = v["messages"] as! [[String: String]]
    let m0 = try ini.writeMessage1(hex(msgs[0]["payload"]!))
    check(m0 == hex(msgs[0]["ciphertext"]!), "vector message 0 ciphertext")
    check(try res.readMessage1(m0) == hex(msgs[0]["payload"]!), "vector message 0 payload")
    let (m1, rSend, rRecv) = try res.writeMessage2(hex(msgs[1]["payload"]!))
    check(m1 == hex(msgs[1]["ciphertext"]!), "vector message 1 ciphertext")
    let (p1, iSend, iRecv) = try ini.readMessage2(m1)
    check(p1 == hex(msgs[1]["payload"]!), "vector message 1 payload")
    check(ini.handshakeHash == hex(v["handshake_hash"] as! String) && res.handshakeHash == ini.handshakeHash, "vector handshake hash")
    var (is_, ir, rs, rr) = (iSend, iRecv, rSend, rRecv)
    for (i, m) in msgs.enumerated().dropFirst(2) {
        let fromInit = i % 2 == 0
        let ct = fromInit ? try is_.encrypt(ad: Data(), hex(m["payload"]!)) : try rs.encrypt(ad: Data(), hex(m["payload"]!))
        check(ct == hex(m["ciphertext"]!), "vector transport message \(i) ciphertext")
        let pt = fromInit ? try rr.decrypt(ad: Data(), ct) : try ir.decrypt(ad: Data(), ct)
        check(pt == hex(m["payload"]!), "vector transport message \(i) payload")
    }
}

func listener() -> (Int32, Int) {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(s, 4)
    var b = sockaddr_in(); var l = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &b) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &l) } }
    return (s, Int(UInt16(bigEndian: b.sin_port)))
}

// one server connection: handshake, then echo through the tunnel; returns the handshake's error, if any
func serveOnce(_ ls: Int32, psk: Data) -> Error? {
    let fd = accept(ls, nil, nil)
    defer { close(fd) }
    Sock.setTimeout(fd, seconds: 3)
    do {
        let (_, send, recv) = try Tunnel.serverHandshake(fd: fd, psk: psk)
        Sock.setTimeout(fd, seconds: 0)
        var sp: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &sp)
        Thread.detachNewThread {   // the "server": echo
            var b = [UInt8](repeating: 0, count: 65536)
            while true { let n = read(sp[1], &b, b.count); if n <= 0 { break }; _ = try? Sock.writeAll(sp[1], Data(b[0..<n])) }
            close(sp[1])
        }
        Tunnel.pump(plain: sp[0], secure: fd, send: send, recv: recv)
        close(sp[0])
        return nil
    } catch { return error }
}

func live() throws {
    let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let wrong = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let (ls, port) = listener()

    // 1. the right key: 8 MB both ways, intact
    var serverErr: Error? = TunnelError.closed
    let g = DispatchGroup(); g.enter()
    Thread.detachNewThread { serverErr = serveOnce(ls, psk: key); g.leave() }
    let fd = try Sock.connectTCP("127.0.0.1", port)
    let (send, recv) = try Tunnel.clientHandshake(fd: fd, psk: key, target: 50061)
    var cp: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &cp)
    Thread.detachNewThread { Tunnel.pump(plain: cp[0], secure: fd, send: send, recv: recv); close(cp[0]); close(fd) }
    let blob = Data((0..<(8 << 20)).map { _ in UInt8.random(in: 0...255) })
    let t0 = Date()
    Thread.detachNewThread { try? Sock.writeAll(cp[1], blob) }
    let back = try Sock.readExact(cp[1], blob.count)
    let dt = Date().timeIntervalSince(t0)
    check(back == blob, "8 MB through the tunnel and back, intact")
    print(String(format: "tunnel loopback: 8 MB echoed in %.2f s (%.0f MB/s each way)", dt, 8 / dt))
    shutdown(cp[1], SHUT_RDWR); close(cp[1])
    g.wait()
    check(serverErr == nil, "server side of the good session: \(String(describing: serverErr))")

    // a hostile client: run `client` against a fresh server connection, return the server's verdict
    func attempt(_ client: @escaping (Int32) throws -> Void) -> Error? {
        var err: Error?
        let g = DispatchGroup(); g.enter()
        Thread.detachNewThread { err = serveOnce(ls, psk: key); g.leave() }
        if let c = try? Sock.connectTCP("127.0.0.1", port) { Sock.setTimeout(c, seconds: 3); try? client(c); shutdown(c, SHUT_RDWR); close(c) }
        g.wait()
        return err
    }
    let e1 = attempt { c in _ = try Tunnel.clientHandshake(fd: c, psk: wrong, target: 50061) }
    check({ if case TunnelError.auth = e1 as? TunnelError ?? .closed { return true }; return false }(), "a wrong key is refused at the first message (\(String(describing: e1)))")

    var captured = Data()
    let e2 = attempt { c in   // tamper with the open frame
        var hs = try NoiseNNpsk0(prologue: Tunnel.prologue, psk: key)
        let m1 = try hs.writeMessage1(Data([0xC3, 0x8D, 0, 0])); captured = m1
        try Sock.writeAll(c, Sock.frame(m1))
        var (_, s, _) = try hs.readMessage2(try Sock.readFrame(c, max: 256))
        var ct = try s.encrypt(ad: Data(), Data()); ct[ct.startIndex] ^= 1
        try Sock.writeAll(c, Sock.frame(ct))
    }
    check({ if case TunnelError.auth = e2 as? TunnelError ?? .closed { return true }; return false }(), "a tampered frame is refused (\(String(describing: e2)))")

    let e3 = attempt { c in   // replay a recorded first message, then guess an open frame
        try Sock.writeAll(c, Sock.frame(captured))
        _ = try Sock.readFrame(c, max: 256)
        try Sock.writeAll(c, Sock.frame(Data((0..<16).map { _ in UInt8.random(in: 0...255) })))
    }
    check({ if case TunnelError.auth = e3 as? TunnelError ?? .closed { return true }; return false }(), "a replayed first message never opens a connection (\(String(describing: e3)))")

    let e4 = attempt { c in _ = try Tunnel.clientHandshake(fd: c, psk: key, target: 22) }
    check({ if case TunnelError.badPort(22) = e4 as? TunnelError ?? .closed { return true }; return false }(), "a port outside the allowlist is refused (\(String(describing: e4)))")

    let e5 = attempt { c in var n = UInt32(1 << 30).bigEndian; try Sock.writeAll(c, Data(bytes: &n, count: 4)) }
    check({ if case TunnelError.tooLarge = e5 as? TunnelError ?? .closed { return true }; return false }(), "an oversized handshake frame is refused (\(String(describing: e5)))")

    let e6 = attempt { c in try Sock.writeAll(c, Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) }
    check(e6 != nil, "plain HTTP at the tunnel port is refused (\(String(describing: e6)))")

    let e7 = attempt { c in try Sock.writeAll(c, Sock.frame(Data(count: 48))) }   // all-zero ephemeral, junk payload
    check(e7 != nil, "an all-zero ephemeral key is refused (\(String(describing: e7)))")
    close(ls)
}

@main struct TunnelTest {
    static func main() {
        do { try vectors() } catch { check(false, "vectors threw \(error)") }
        do { try live() } catch { check(false, "live threw \(error)") }
        print("tunnel-test: \(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }
}
