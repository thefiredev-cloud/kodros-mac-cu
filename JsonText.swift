// JSON string encoding for mac-cu command output.
// U+0000 through U+001F must be escaped or the line is not JSON.

func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22:
            out += "\\\""
        case 0x5C:
            out += "\\\\"
        case 0x08:
            out += "\\b"
        case 0x09:
            out += "\\t"
        case 0x0A:
            out += "\\n"
        case 0x0C:
            out += "\\f"
        case 0x0D:
            out += "\\r"
        case 0x00...0x1F:
            out += "\\u00" + hexByte(scalar.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
    return out
}

private func hexByte(_ v: UInt32) -> String {
    let digits = Array("0123456789abcdef")
    return String(digits[Int((v >> 4) & 0xF)]) + String(digits[Int(v & 0xF)])
}
