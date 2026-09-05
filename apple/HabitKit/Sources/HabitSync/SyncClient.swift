import Foundation
import HabitCore

/// Der Zugang zum Server.
///
/// Als Protokoll, damit die Engine ohne Netz prüfbar bleibt — ein Abgleich, den
/// man nur gegen einen laufenden Server testen kann, wird nicht getestet.
public protocol SyncTransport: Sendable {
    func pull(since: Int64, limit: Int) async throws -> SyncDelta
    func push(_ delta: SyncDelta) async throws -> SyncReport
}

public struct ServerConfig: Hashable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum SyncError: Error, CustomStringConvertible {
    case notConfigured
    case unauthorized
    case server(status: Int, body: String)
    case transport(any Error)

    public var description: String {
        switch self {
        case .notConfigured: "Kein Server eingerichtet"
        case .unauthorized: "Das Token wird nicht akzeptiert"
        case .server(let status, let body): "Server antwortete mit \(status): \(body)"
        case .transport(let fehler): "Verbindung fehlgeschlagen: \(fehler)"
        }
    }
}

/// `SyncTransport` über URLSession.
public struct HTTPSyncTransport: SyncTransport {
    private let config: ServerConfig
    private let session: URLSession

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func pull(since: Int64, limit: Int) async throws -> SyncDelta {
        var komponenten = URLComponents(
            url: config.baseURL.appending(path: "sync"), resolvingAgainstBaseURL: false)!
        komponenten.queryItems = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var anfrage = URLRequest(url: komponenten.url!)
        anfrage.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return try await sende(anfrage, als: SyncDelta.self)
    }

    public func push(_ delta: SyncDelta) async throws -> SyncReport {
        var anfrage = URLRequest(url: config.baseURL.appending(path: "sync"))
        anfrage.httpMethod = "POST"
        anfrage.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anfrage.httpBody = try SyncCoding.encoder().encode(delta)
        return try await sende(anfrage, als: SyncReport.self)
    }

    private func sende<T: Decodable>(_ anfrage: URLRequest, als: T.Type) async throws -> T {
        let daten: Data, antwort: URLResponse
        do {
            (daten, antwort) = try await session.data(for: anfrage)
        } catch {
            throw SyncError.transport(error)
        }
        let status = (antwort as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw SyncError.unauthorized }
        guard (200..<300).contains(status) else {
            throw SyncError.server(status: status,
                                   body: String(decoding: daten.prefix(500), as: UTF8.self))
        }
        return try SyncCoding.decoder().decode(T.self, from: daten)
    }
}

/// Dieselbe Kodierung wie die Sicherungsdatei.
///
/// Muss sie sein: der Server liest und schreibt beides, und die Zeitstempel
/// entscheiden bei Last-Write-Wins. Auf Sekunden gerundet wären zwei Änderungen
/// innerhalb derselben Sekunde nicht mehr unterscheidbar.
public enum SyncCoding {
    public static func encoder() -> JSONEncoder { BackupCoding.encoder() }
    public static func decoder() -> JSONDecoder { BackupCoding.decoder() }
}
