import Foundation

/// Turns the address of Nod as the user typed it into the origin the app talks to.
public enum NodAddress {
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case notAnAddress
        /// Nod is reached over HTTPS only; the key must never travel unencrypted.
        case notSecure(String)
    }

    /// The result is always an HTTPS origin: scheme, host and port. Nod answers only at its
    /// public origin, so a path, query, fragment or credentials in what was typed are dropped.
    public static func parse(_ text: String) -> Result<URL, Problem> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard !text.contains(where: \.isWhitespace) else { return .failure(.notAnAddress) }
        if !text.contains("://") { text = "https://" + text }
        guard let typed = URLComponents(string: text), let scheme = typed.scheme?.lowercased() else {
            return .failure(.notAnAddress)
        }
        guard scheme == "https" else { return .failure(.notSecure(scheme)) }
        guard let host = typed.host, !host.isEmpty else { return .failure(.notAnAddress) }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host.lowercased()
        origin.port = typed.port == 443 ? nil : typed.port
        guard let url = origin.url else { return .failure(.notAnAddress) }
        return .success(url)
    }
}
