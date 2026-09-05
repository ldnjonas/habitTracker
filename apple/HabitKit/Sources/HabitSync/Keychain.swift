import Foundation
import Security

/// Das Server-Token im Schlüsselbund.
///
/// Nicht in `app_setting`: die Datenbankdatei liegt unverschlüsselt im
/// Anwendungsordner und wandert in jede Sicherung. Ein Zugangsschlüssel, der
/// mit dem Backup den Rechner verlässt, ist keiner.
public enum TokenStore {
    private static let dienst = "de.jonasreinhard.habittracker.sync"

    public static func speichere(_ token: String, fuer server: String) throws {
        let daten = Data(token.utf8)
        let suche: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: server,
        ]
        SecItemDelete(suche as CFDictionary)

        var eintrag = suche
        eintrag[kSecValueData as String] = daten
        // Nur auf diesem Gerät und erst nach dem ersten Entsperren: ein Token
        // gehört nicht in eine Gerätesicherung, die woanders eingespielt wird.
        eintrag[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(eintrag as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func lese(fuer server: String) -> String? {
        let suche: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ergebnis: CFTypeRef?
        guard SecItemCopyMatching(suche as CFDictionary, &ergebnis) == errSecSuccess,
              let daten = ergebnis as? Data else { return nil }
        return String(decoding: daten, as: UTF8.self)
    }

    public static func loesche(fuer server: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: server,
        ] as CFDictionary)
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        public var description: String {
            switch self {
            case .status(let code):
                "Schlüsselbund meldet \(code): "
                    + (SecCopyErrorMessageString(code, nil) as String? ?? "unbekannt")
            }
        }
    }
}
