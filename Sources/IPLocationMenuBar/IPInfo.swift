import Foundation

/// Subset of the https://ipapi.co/json/ response. Every field is optional
/// because ipapi omits or nulls fields it cannot resolve.
struct IPInfo: Decodable {
    var ip: String?
    var city: String?
    var region: String?
    var regionCode: String?
    /// Two-letter country code, e.g. "US"; steadier than the display name.
    var country: String?
    var countryName: String?
    var postal: String?
    var latitude: Double?
    var longitude: Double?
    var timezone: String?
    var utcOffset: String?
    var org: String?
    var asn: String?

    /// Short label for the status bar, e.g. "Los Angeles · CA".
    var shortLocation: String {
        let regionPart = regionCode.nonEmpty ?? usStateCode ?? region.nonEmpty
        return [city.nonEmpty, regionPart].compactMap { $0 }.joined(separator: " · ")
    }

    /// Identifies this exit for "ignore until it changes". Only ASN and IP, because sources
    /// disagree on region and country formatting for the same exit.
    var signature: String {
        [asn?.uppercased(), ip].map { $0 ?? "" }.joined(separator: "|")
    }

    /// "California" -> "CA" for sources that only return the state name, so the
    /// status bar label stays the same whichever source answered.
    private var usStateCode: String? {
        guard country == "US" || countryName == "United States", let region = region.nonEmpty else { return nil }
        return Self.usStates[region]
    }

    private static let usStates: [String: String] = [
        "Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA",
        "Colorado": "CO", "Connecticut": "CT", "Delaware": "DE", "District of Columbia": "DC",
        "Florida": "FL", "Georgia": "GA", "Hawaii": "HI", "Idaho": "ID", "Illinois": "IL",
        "Indiana": "IN", "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA",
        "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA", "Michigan": "MI", "Minnesota": "MN",
        "Mississippi": "MS", "Missouri": "MO", "Montana": "MT", "Nebraska": "NE", "Nevada": "NV",
        "New Hampshire": "NH", "New Jersey": "NJ", "New Mexico": "NM", "New York": "NY",
        "North Carolina": "NC", "North Dakota": "ND", "Ohio": "OH", "Oklahoma": "OK", "Oregon": "OR",
        "Pennsylvania": "PA", "Rhode Island": "RI", "South Carolina": "SC", "South Dakota": "SD",
        "Tennessee": "TN", "Texas": "TX", "Utah": "UT", "Vermont": "VT", "Virginia": "VA",
        "Washington": "WA", "West Virginia": "WV", "Wisconsin": "WI", "Wyoming": "WY",
    ]

    var coordinates: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// "America/Los_Angeles (UTC-07:00)"
    var timezoneDescription: String? {
        guard let timezone = timezone.nonEmpty else { return nil }
        var offset = utcOffset
        if offset == nil, let zone = TimeZone(identifier: timezone) {
            // Sources other than ipapi.co omit the offset; derive it, including DST.
            let minutes = zone.secondsFromGMT() / 60
            offset = String(format: "%@%02d%02d", minutes < 0 ? "-" : "+", abs(minutes) / 60, abs(minutes) % 60)
        }
        guard let offset, offset.count == 5 else { return timezone }
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
