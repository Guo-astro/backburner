// WifiTunnel.swift - the only way into the app over Wi-Fi: Tunnel.swift's encrypted, authenticated channel on :50070.
//
// Listens only while the phone is paired (a key in the Keychain from `pair` over the cable; scripts/phone-wifi.sh). Every
// connection must complete the handshake with that key (Tunnel.serverHandshake) before a byte goes anywhere; then it is
// spliced to one server on this phone's loopback (ggml RPC, tail, control, phone attention), which the cable gate admits as
// loopback. Unpairing deletes the key: the listener closes within two seconds and handshakes fail at once.
import Foundation

enum WifiTunnel {
    private static let lock = NSLock()
    private static var listening = false
    private static var active = 0
    private static var sessions = 0
    private static var refused = 0
    private static var lastRefused = ""
    static let maxActive = 16

    /// Start the listener if the phone is paired and it isn't running. Cheap; call it on every UI refresh.
    static func startIfPaired() {
        lock.lock()
        defer { lock.unlock() }
        guard !listening, SidecarRPC.wifiKey() != nil else { return }
        listening = true
        Thread.detachNewThread { serve() }
    }

    private static func report() {
        lock.lock()
        let s = listening
            ? "listening on :\(Tunnel.port), \(active) open, \(sessions) served, \(refused) refused" + (lastRefused.isEmpty ? "" : " (last: \(lastRefused))")
            : (SidecarRPC.wifiKey() == nil ? "not paired" : "stopped")
        lock.unlock()
        SidecarRPC.setWifiTunnelStatus(s)
    }

    private static func serve() {
        let srv = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_port = UInt16(Tunnel.port).bigEndian
        a.sin_addr.s_addr = INADDR_ANY   // authenticated by the handshake below, not by address
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
            && listen(srv, 8) == 0
        if !ok {
            close(srv)
            lock.lock(); listening = false; lock.unlock()
            SidecarRPC.setWifiTunnelStatus("listen :\(Tunnel.port) failed: \(String(cString: strerror(errno)))")
            return
        }
        report()
        while true {
            var pfd = pollfd(fd: srv, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 2000)
            if SidecarRPC.wifiKey() == nil { break }   // unpaired: stop listening
            if r <= 0 { continue }
            let fd = accept(srv, nil, nil)
            if fd < 0 { continue }
            lock.lock()
            let full = active >= maxActive
            if !full { active += 1 }
            lock.unlock()
            if full { close(fd); refuse("too many connections"); continue }
            Thread.detachNewThread { handle(fd) }
        }
        close(srv)
        lock.lock(); listening = false; lock.unlock()
        report()
    }

    private static func refuse(_ why: String) {
        lock.lock(); refused += 1; lastRefused = why; lock.unlock()
        report()
    }

    private static func handle(_ fd: Int32) {
        defer {
            close(fd)
            lock.lock(); active -= 1; lock.unlock()
            report()
        }
        Sock.tune(fd)
        Sock.setTimeout(fd, seconds: 5)   // a handshake that stalls is dropped
        guard let key = SidecarRPC.wifiKey() else { refuse("not paired"); return }
        let target: Int, send: NoiseCipher, recv: NoiseCipher
        do {
            (target, send, recv) = try Tunnel.serverHandshake(fd: fd, psk: key)
        } catch {
            refuse("\(error)")
            return
        }
        Sock.setTimeout(fd, seconds: 0)
        guard let local = try? Sock.connectTCP("127.0.0.1", target) else { refuse("port \(target) is not up"); return }
        lock.lock(); sessions += 1; lock.unlock()
        report()
        Tunnel.pump(plain: local, secure: fd, send: send, recv: recv)
        close(local)
    }
}
