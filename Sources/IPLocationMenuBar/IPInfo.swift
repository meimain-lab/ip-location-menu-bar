import Foundation

/// Subset of the https://ipapi.co/json/ response. Every field is optional
/// because ipapi omits or nulls fields it cannot resolve.
struct IPInfo: Decodable {
    let ip: String?
    let city: String?
    let region: String?
    let regionCode: String?
    let countryName: String?
    let postal: String?
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
    let utcOffset: String?
    let org: String?
    let asn: String?

    /// Short label for the status bar, e.g. "Los Angeles · CA".
    var shortLocation: String {
        let regionPart = regionCode.nonEmpty ?? region.nonEmpty
        return [city.nonEmpty, regionPart].compactMap { $0 }.joined(separator: " · ")
    }

    var coordinates: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// "America/Los_Angeles (UTC-07:00)"
    var timezoneDescription: String? {
        guard let timezone = timezone.nonEmpty else { return nil }
        guard let offset = utcOffset, offset.count == 5 else { return timezone }
        let formatted = "\(offset.prefix(3)):\(offset.suffix(2))"
        return "\(timezone) (UTC\(formatted))"
    }
}

/// Shape of an ipapi error body, e.g. {"error": true, "reason": "RateLimited"}.
struct IPAPIErrorBody: Decodable {
    let error: Bool?
    let reason: String?
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
