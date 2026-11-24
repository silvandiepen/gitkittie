import Foundation

/// IDNA host display (RFC 3492 Punycode, RFC 5891 `xn--` labels), so a link to `pаypal` with a
/// Cyrillic "а" is shown as the `xn--` name it really is (ThreatModel §2). Encoding only: the
/// reader never resolves anything.
public enum Punycode {
    /// The host with every non-ASCII label encoded as `xn--…`, lowercased.
    public static func asciiHost(_ host: String) -> String {
        host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let text = String(label)
            guard text.unicodeScalars.contains(where: { !$0.isASCII }), let encoded = encode(text) else { return text }
            return "xn--" + encoded
        }.joined(separator: ".")
    }

    /// The labels of a host decoded for display when they are `xn--` (best effort; a label that
    /// does not decode stays as written).
    public static func unicodeHost(_ host: String) -> String {
        host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            guard label.hasPrefix("xn--"), let decoded = decode(String(label.dropFirst(4))) else { return String(label) }
            return decoded
        }.joined(separator: ".")
    }

    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            guard (m - n) <= (Int.max - delta) / (handled + 1) else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    static func decode(_ input: String) -> String? {
        var output: [Int] = []
        var rest = Substring(input)
        if let dash = input.lastIndex(of: "-") {
            output = input[..<dash].unicodeScalars.map { Int($0.value) }
            guard output.allSatisfy({ $0 < 0x80 }) else { return nil }
            rest = input[input.index(after: dash)...]
        }
        var n = initialN, i = 0, bias = initialBias
        var iterator = rest.makeIterator()
        var pending = iterator.next()
        while pending != nil {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard let character = pending, let d = value(of: character) else { return nil }
                pending = iterator.next()
                guard d <= (Int.max - i) / w else { return nil }
                i += d * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                w *= base - t
                k += base
                if pending == nil { return nil }
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n <= 0x10FFFF else { return nil }
            output.insert(n, at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for value in output {
            guard let scalar = Unicode.Scalar(value) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }

    private static func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ d: Int) -> Character {
        Character(Unicode.Scalar(UInt8(d < 26 ? d + 97 : d + 22)))
    }

    private static func value(of character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 48...57: return Int(ascii) - 22
        case 65...90: return Int(ascii) - 65
        case 97...122: return Int(ascii) - 97
        default: return nil
        }
    }
}
