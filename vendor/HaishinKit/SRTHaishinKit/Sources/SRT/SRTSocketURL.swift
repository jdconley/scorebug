import Combine
import Foundation
import HaishinKit
import libsrt

struct SRTSocketURL {
    static let defaultPort: Int = 9710

    private static func getQueryItems(_ url: URL) -> [String: String] {
        // Native control-plane grants use normal percent-encoded URL query
        // values. Decode each item exactly once, after separating delimiters.
        let queries = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var paramsReturn: [String: String] = [:]
        for query in queries {
            if let value = query.value { paramsReturn[query.name] = value }
        }
        return paramsReturn
    }

    let url: URL
    let mode: SRTMode
    let options: [SRTSocketOption]

    var remote: sockaddr_in? {
        guard let host = url.host else {
            return nil
        }
        return .init(host, port: url.port ?? Self.defaultPort)
    }

    var local: sockaddr_in? {
        let queryItems = Self.getQueryItems(url)
        let adapter = queryItems["adapter"] ?? "0.0.0.0"
        if let port = queryItems["port"] {
            return .init(adapter, port: Int(port) ?? url.port ?? Self.defaultPort)
        }
        return .init(adapter, port: url.port ?? Self.defaultPort)
    }

    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme, scheme == "srt" else {
            return nil
        }
        let queryItems = Self.getQueryItems(url)
        var options: [SRTSocketOption] = []
        for item in queryItems {
            guard let name = SRTSocketOption.Name(rawValue: item.key) else {
                continue
            }
            if let option = try? SRTSocketOption(name: name, value: item.value) {
                options.append(option)
            }
        }
        self.url = url
        self.mode = {
            switch queryItems["mode"] {
            case "client", "caller":
                return .caller
            case "server", "listener":
                return .listener
            case "rendezvous":
                return .rendezvous
            default:
                if queryItems["adapter"] != nil {
                    return .rendezvous
                }
                if url.host?.isEmpty == true {
                    return .listener
                }
                return .caller
            }
        }()
        self.options = options
    }
}
