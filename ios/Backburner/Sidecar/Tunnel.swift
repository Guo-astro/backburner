// Tunnel.swift - the encrypted, authenticated channel for using the phone over Wi-Fi. Shared by the app (WifiTunnel.swift, the
// listener) and the Mac (tools/wifi-tunnel, the client); Foundation + CryptoKit only.
//
// Why: the app's servers speak protocols with no authentication, so they answer the USB cable only (CableOnly.h). Over Wi-Fi
// the phone runs this tunnel instead: nothing reaches a server until the Mac proves it holds the key the phone gave it over
// the cable (`pair` on :50061, cable only), and every byte after that is encrypted and authenticated.
//
// Protocol: Noise_NNpsk0_25519_ChaChaPoly_SHA256 (noiseprotocol.org, rev 34), checked against the published test vectors in
// tests/security/tunnel-test.swift. NNpsk0: a fresh X25519 key pair per connection on both sides (forward secrecy), the
// pairing key mixed in before the first message (a peer without it can't produce or read anything), ChaCha20-Poly1305
// for every message. Prologue "backburner-wifi-tunnel v1".
//   Mac -> phone   u32 len | e(32) | encrypted payload [target port u16 BE, 0, 0]
//   phone -> Mac   u32 len | e(32) | encrypted empty payload
//   then frames    u32 len | ChaCha20-Poly1305(plaintext <= 65519 bytes), one key and counter per direction
// The Mac's first frame is an empty "open" frame. The phone connects to the local server only after it decrypts it, so a
// replayed first message (which an eavesdropper can't complete) never even opens a connection to a server.
import CryptoKit
import Foundation

enum TunnelError: Error, CustomStringConvertible {
    case closed, tooLarge(Int), short, auth, badPort(Int), io(String)
    var description: String {
        switch self {
        case .closed: return "connection closed"
        case .tooLarge(let n): return "frame of \(n) bytes is too large"
        case .short: return "message too short"
        case .auth: return "authentication failed (wrong key, or the data was altered)"
        case .badPort(let p): return "port \(p) is not a tunnel target"
        case .io(let s): return s
        }
    }
}

// ---- Noise ---------------------------------------------------------------------------------------

struct NoiseCipher {
    var k: SymmetricKey?
    var n: UInt64 = 0

    static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var b = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { b.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: b)
    }
    mutating func encrypt(ad: Data, _ pt: Data) throws -> Data {
        guard let k else { return pt }
        guard n < UInt64.max else { throw TunnelError.auth }   // nonce exhausted: never reuse one
        let box = try ChaChaPoly.seal(pt, using: k, nonce: Self.nonce(n), authenticating: ad)
        n += 1
        return box.ciphertext + box.tag
    }
    mutating func decrypt(ad: Data, _ ct: Data) throws -> Data {
        guard let k else { return ct }
        guard ct.count >= 16, n < UInt64.max else { throw TunnelError.short }
        let c = Data(ct)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(n), ciphertext: c.prefix(c.count - 16), tag: c.suffix(16))
            let pt = try ChaChaPoly.open(box, using: k, authenticating: ad)
            n += 1   // only after a message authenticates (Noise 5.1)
            return pt
        } catch {
            throw TunnelError.auth
        }
    }
}

struct NoiseSymmetric {
    var ck: Data
    var h: Data
    var cipher = NoiseCipher()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
    }
    static func hmac(_ key: Data, _ d: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: d, using: SymmetricKey(data: key)))
    }
    static func hkdf(_ ck: Data, _ ikm: Data, _ n: Int) -> [Data] {
        let t = hmac(ck, ikm)
        let o1 = hmac(t, Data([1]))
        let o2 = hmac(t, o1 + Data([2]))
        return n == 2 ? [o1, o2] : [o1, o2, hmac(t, o2 + Data([3]))]
    }
    mutating func mixHash(_ d: Data) { h = Data(SHA256.hash(data: h + d)) }
    mutating func mixKey(_ ikm: Data) {
        let o = Self.hkdf(ck, ikm, 2)
        ck = o[0]
        cipher = NoiseCipher(k: SymmetricKey(data: o[1]), n: 0)
    }
    mutating func mixKeyAndHash(_ ikm: Data) {
        let o = Self.hkdf(ck, ikm, 3)
        ck = o[0]
        mixHash(o[1])
        cipher = NoiseCipher(k: SymmetricKey(data: o[2]), n: 0)
    }
    mutating func encryptAndHash(_ pt: Data) throws -> Data {
        let c = try cipher.encrypt(ad: h, pt)
        mixHash(c)
        return c
    }
    mutating func decryptAndHash(_ c: Data) throws -> Data {
        let p = try cipher.decrypt(ad: h, c)
        mixHash(c)
        return p
    }
    func split() -> (NoiseCipher, NoiseCipher) {
        let o = Self.hkdf(ck, Data(), 2)
        return (NoiseCipher(k: SymmetricKey(data: o[0])), NoiseCipher(k: SymmetricKey(data: o[1])))
    }
}

// Noise_NNpsk0_25519_ChaChaPoly_SHA256:  -> psk, e   <- e, ee
struct NoiseNNpsk0 {
    static let protocolName = "Noise_NNpsk0_25519_ChaChaPoly_SHA256"
    var sym: NoiseSymmetric
    let e: Curve25519.KeyAgreement.PrivateKey
    let psk: Data
    var re = Data()

    init(prologue: Data, psk: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
        guard psk.count == 32 else { throw TunnelError.io("the pairing key must be 32 bytes") }
        sym = NoiseSymmetric(protocolName: Self.protocolName)
        sym.mixHash(prologue)
        self.psk = psk
        e = ephemeral
    }
    private func dh(_ pub: Data) throws -> Data {
        let s = try e.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub))
        let out = s.withUnsafeBytes { Data($0) }
        guard out.contains(where: { $0 != 0 }) else { throw TunnelError.auth }   // a low-order public key
        return out
    }
    private mutating func mixEphemeral(_ pub: Data) { sym.mixHash(pub); sym.mixKey(pub) }   // psk handshakes MixKey every e

    // initiator (the Mac)
    mutating func writeMessage1(_ payload: Data) throws -> Data {
        sym.mixKeyAndHash(psk)
        let pub = e.publicKey.rawRepresentation
        mixEphemeral(pub)
        return pub + (try sym.encryptAndHash(payload))
    }
    mutating func readMessage2(_ m: Data) throws -> (payload: Data, send: NoiseCipher, recv: NoiseCipher) {
        let m = Data(m)
        guard m.count >= 32 + 16 else { throw TunnelError.short }
        re = Data(m.prefix(32))
        mixEphemeral(re)
        sym.mixKey(try dh(re))
        let p = try sym.decryptAndHash(Data(m.dropFirst(32)))
        let (c1, c2) = sym.split()
        return (p, c1, c2)
    }
    // responder (the phone)
    mutating func readMessage1(_ m: Data) throws -> Data {
        let m = Data(m)
        guard m.count >= 32 + 16 else { throw TunnelError.short }
        sym.mixKeyAndHash(psk)
        re = Data(m.prefix(32))
        mixEphemeral(re)
        return try sym.decryptAndHash(Data(m.dropFirst(32)))
    }
    mutating func writeMessage2(_ payload: Data) throws -> (message: Data, send: NoiseCipher, recv: NoiseCipher) {
        let pub = e.publicKey.rawRepresentation
        mixEphemeral(pub)
        sym.mixKey(try dh(re))
        let c = try sym.encryptAndHash(payload)
        let (c1, c2) = sym.split()
        return (pub + c, c2, c1)
    }
    var handshakeHash: Data { sym.h }
}

// ---- sockets -------------------------------------------------------------------------------------

enum Sock {
    static func readExact(_ fd: Int32, _ n: Int) throws -> Data {
        var d = Data(count: n)
        var got = 0
        while got < n {
            let r = d.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r == 0 { throw TunnelError.closed }
            if r < 0 { if errno == EINTR { continue }; throw TunnelError.io(String(cString: strerror(errno))) }
            got += r
        }
        return d
    }
    static func writeAll(_ fd: Int32, _ d: Data) throws {
        try d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var off = 0
            while off < b.count {
                let w = write(fd, b.baseAddress! + off, b.count - off)
                if w < 0 { if errno == EINTR { continue }; throw TunnelError.io(String(cString: strerror(errno))) }
                off += w
            }
        }
    }
    static func frame(_ d: Data) -> Data {
        var len = UInt32(d.count).bigEndian
        return Data(bytes: &len, count: 4) + d
    }
    static func readFrame(_ fd: Int32, max: Int) throws -> Data {
        let h = try readExact(fd, 4)
        let n = Int(h.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard n <= max else { throw TunnelError.tooLarge(n) }
        return try readExact(fd, n)
    }
    static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    static func tune(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    static func connectTCP(_ host: String, _ port: Int) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw TunnelError.io("bad address \(host)") }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelError.io("socket failed") }
        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            let e = String(cString: strerror(errno)); close(fd); throw TunnelError.io("connect \(host):\(port): \(e)")
        }
        tune(fd)
        return fd
    }
}

// ---- the channel ---------------------------------------------------------------------------------

enum Tunnel {
    static let prologue = Data("backburner-wifi-tunnel v1".utf8)
    static let port = 50070
    static let maxPlain = 65535 - 16
    /// the servers the tunnel may reach (on the phone's loopback): ggml RPC, prefill tail, control, phone attention
    static let targets: Set<Int> = [50052, 50060, 50061, 50062]

    /// Mac side: handshake on a connected socket; returns the two directions. Throws on a wrong key or any tampering.
    static func clientHandshake(fd: Int32, psk: Data, target: Int) throws -> (send: NoiseCipher, recv: NoiseCipher) {
        var hs = try NoiseNNpsk0(prologue: prologue, psk: psk)
        let payload = Data([UInt8(target >> 8), UInt8(target & 0xff), 0, 0])
        try Sock.writeAll(fd, Sock.frame(try hs.writeMessage1(payload)))
        let (_, send, recv) = try hs.readMessage2(try Sock.readFrame(fd, max: 256))
        var s = send
        try Sock.writeAll(fd, Sock.frame(try s.encrypt(ad: Data(), Data())))   // the "open" frame
        return (s, recv)
    }

    /// Phone side: handshake on an accepted socket. Returns the target port and the two directions once the Mac's "open"
    /// frame authenticates; throws (and the caller closes the socket, having forwarded nothing) otherwise.
    static func serverHandshake(fd: Int32, psk: Data) throws -> (target: Int, send: NoiseCipher, recv: NoiseCipher) {
        var hs = try NoiseNNpsk0(prologue: prologue, psk: psk)
        let p = try hs.readMessage1(try Sock.readFrame(fd, max: 256))
        guard p.count == 4 else { throw TunnelError.short }
        let target = Int(p[p.startIndex]) << 8 | Int(p[p.startIndex + 1])
        guard targets.contains(target) else { throw TunnelError.badPort(target) }
        let (m, send, recv) = try hs.writeMessage2(Data())
        try Sock.writeAll(fd, Sock.frame(m))
        var r = recv
        let open = try r.decrypt(ad: Data(), try Sock.readFrame(fd, max: 16))
        guard open.isEmpty else { throw TunnelError.short }
        return (target, send, r)
    }

    /// Pump plaintext between `plain` (a local socket) and `secure` (the encrypted side) until either end closes.
    static func pump(plain: Int32, secure: Int32, send: NoiseCipher, recv: NoiseCipher) {
        let done = DispatchGroup()
        done.enter()
        Thread.detachNewThread {
            var r = recv
            while true {
                guard let ct = try? Sock.readFrame(secure, max: maxPlain + 16), let pt = try? r.decrypt(ad: Data(), ct),
                      (try? Sock.writeAll(plain, pt)) != nil else { break }
            }
            shutdown(plain, SHUT_RDWR); shutdown(secure, SHUT_RDWR)
            done.leave()
        }
        var s = send
        var buf = [UInt8](repeating: 0, count: maxPlain)
        while true {
            let n = read(plain, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            guard let ct = try? s.encrypt(ad: Data(), Data(buf[0..<n])), (try? Sock.writeAll(secure, Sock.frame(ct))) != nil else { break }
        }
        shutdown(plain, SHUT_RDWR); shutdown(secure, SHUT_RDWR)
        done.wait()
    }
}
