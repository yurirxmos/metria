import Foundation

/// The wire format Metria publishes to its paired clients (the local `/snapshot`
/// endpoint, the encrypted ntfy relay, and the mobile app/widgets that read either).
/// Field names and the ISO-8601 date strategy are a cross-client contract: add fields,
/// never rename or retype `name`, `percent`, `resetDate`, or `updatedAt`. Fields added
/// later (`usedCents`, `limitCents`) must stay optional so an older Mac's snapshot still
/// decodes.
public struct UsageSnapshot: Codable, Equatable {
    public struct Provider: Codable, Equatable {
        public let name: String
        public let percent: Double
        public let resetDate: Date?
        /// What this cycle costs, in cents, when the provider measures money rather than a
        /// bare percentage (Cursor). Added after the first shipped clients, so older
        /// senders leave both nil and every reader must tolerate their absence.
        public let usedCents: Double?
        public let limitCents: Double?

        public init(name: String, percent: Double, resetDate: Date?, usedCents: Double? = nil, limitCents: Double? = nil) {
            self.name = name
            self.percent = percent
            self.resetDate = resetDate
            self.usedCents = usedCents
            self.limitCents = limitCents
        }

        public func spendParts(_ display: SpendDisplay) -> SpendParts {
            SpendFormat.parts(usedCents: usedCents, limitCents: limitCents, display: display)
        }
    }

    public let updatedAt: Date
    public let providers: [Provider]

    public init(updatedAt: Date, providers: [Provider]) {
        self.updatedAt = updatedAt
        self.providers = providers
    }
}

public enum UsageSnapshotCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
