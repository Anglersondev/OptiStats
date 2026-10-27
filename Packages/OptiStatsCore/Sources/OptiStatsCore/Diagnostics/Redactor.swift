import Foundation

/// Remove dados pessoais de texto de diagnóstico antes de copiar/exportar.
public enum Redactor {
    public static func redact(_ text: String, userName: String = NSUserName(), hostName: String? = nil) -> String {
        var out = text
        func replace(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            out = re.stringByReplacingMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        replace("/Users/[^/\\s\"']+", "/Users/<usuario>")
        replace("/home/[^/\\s\"']+", "/home/<usuario>")
        replace("\\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\\b", "<mac>")
        replace("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", "<ip>")
        replace("\\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\\b", "<ipv6>")
        replace("(?i)(serial(?: number)?[^:=\\n]*[:=]\\s*)[A-Z0-9]{8,}", "$1<serial>")
        replace("(?i)(ssid[^:=\\n]*[:=]\\s*)[^\\n]+", "$1<ssid>")
        replace("\\b[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}\\b", "<uuid>")
        if userName.count >= 3 {
            out = out.replacingOccurrences(of: userName, with: "<usuario>")
        }
        if let host = hostName, host.count >= 3 { out = out.replacingOccurrences(of: host, with: "<host>") }
        return out
    }
}
