import Foundation
import Vapor

enum CurrencyCode {
    static func validated(_ value: String) throws -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.isEmpty { return nil }
        guard Locale.Currency.isoCurrencies.contains(where: { $0.identifier == code }) else {
            throw Abort(.badRequest, reason: "Choose a supported currency code.")
        }
        return code
    }
}
