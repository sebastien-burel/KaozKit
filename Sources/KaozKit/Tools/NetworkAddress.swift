import Foundation

/// Whether an address leads out to the internet, for a request that must not
/// reach the local network of the Mac it runs on.
public enum NetworkAddress {
    /// Not loopback, private, link-local, shared, multicast, reserved or
    /// unspecified, in IPv4 or IPv6 — an IPv4 address carried in IPv6
    /// (mapped, compatible, NAT64, 6to4) judged as itself.
    public static func isPublic(_ address: String) -> Bool {
        let address = address.split(separator: "%").first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
            case (100, 64...127), (172, 16...31), (198, 18...19): return false
            case (224...255, _): return false
            default: return true
            }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return false }
        if b[0] & 0xFE == 0xFC { return false }
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }
        if b[0] == 0xFF { return false }
        let tail = "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isPublic(tail) }
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPublic(tail) }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xFF, b[3] == 0x9B, b[4..<12].allSatisfy({ $0 == 0 }) { return isPublic(tail) }
        if b[0] == 0x20, b[1] == 0x02 { return isPublic("\(b[2]).\(b[3]).\(b[4]).\(b[5])") }
        return true
    }

    /// Every address `host` resolves to, as text.
    public static func addresses(of host: String) -> [String] {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buffer))
            }
            cursor = entry.pointee.ai_next
        }
        return out
    }
}
