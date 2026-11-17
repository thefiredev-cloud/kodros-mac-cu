import Foundation

@main
struct JsonTextTest {
    static func main() {
        let samples: [(String, String)] = [
            ("empty", ""),
            ("plain", "Safari"),
            ("quote", "say \"hi\""),
            ("slash", "a\\b"),
            ("newline", "a\nb"),
            ("tab", "a\tb"),
            ("cr", "a\rb"),
            ("crlf", "a\r\nb"),
            ("bs", "a\u{0008}b"),
            ("ff", "a\u{000c}b"),
            ("soh", "a\u{0001}b"),
            ("us", "a\u{001f}b"),
            ("emoji", "ok ✅"),
            ("mixed", "say \"hi\"\tthen\\"),
        ]
        var failed = 0
        for (name, sample) in samples {
            let wrapped = "{\"v\":\(jsonString(sample))}"
            let rawControl = wrapped.unicodeScalars.contains { $0.value < 0x20 }
            var parsed: String?
            if let data = wrapped.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsed = obj["v"] as? String
            }
            if rawControl || parsed != sample {
                failed += 1
                fputs("FAIL \(name)\n", stderr)
            } else {
                print("PASS \(name)")
            }
        }
        if failed != 0 {
            fputs("failed \(failed)\n", stderr)
            exit(1)
        }
        print("ok \(samples.count)")
    }
}
