import Foundation

/// Free, keyless IP geolocation services. Each one maps its own response shape onto `IPInfo`.
/// The order of `allCases` is the order auto-switch falls back through after the preferred one.
enum IPProvider: String, CaseIterable {
    case ipapiCo = "ipapi.co"
    case geoJS = "geojs"
    case ipAPICom = "ip-api.com"
    case ipapiIs = "ipapi.is"
    case ipinfo = "ipinfo.io"

    static let defaultProvider = IPProvider.ipapiCo

    var displayName: String {
        switch self {
        case .ipapiCo: return "ipapi.co"
        case .geoJS: return "GeoJS"
        case .ipAPICom: return "ip-api.com"
        case .ipapiIs: return "ipapi.is"
        case .ipinfo: return "ipinfo.io"
        }
    }

    /// One-line note shown in the source menu.
    var note: String {
        switch self {
        case .ipapiCo: return "字段最全，每天约 1000 次"
        case .geoJS: return "不限次数，无邮编"
        case .ipAPICom: return "每分钟 45 次，仅 HTTP"
        case .ipapiIs: return "每天 1000 次，无邮编"
        case .ipinfo: return "每月 5 万次"
        }
    }

    /// Looks up the caller's own IP, or `lookupIP` when set (testing).
    func url(lookupIP: String?) -> URL {
        let string: String
        switch self {
        case .ipapiCo:
            string = lookupIP.map { "https://ipapi.co/\($0)/json/" } ?? "https://ipapi.co/json/"
        case .geoJS:
            string = lookupIP.map { "https://get.geojs.io/v1/ip/geo/\($0).json" } ?? "https://get.geojs.io/v1/ip/geo.json"
        case .ipAPICom:
            // The free tier is HTTP only; Info.plist allows it for this one domain.
            let fields = "status,message,country,countryCode,region,regionName,city,zip,lat,lon,timezone,offset,isp,as,query"
            string = "http://ip-api.com/json/\(lookupIP ?? "")?fields=\(fields)"
        case .ipapiIs:
            string = lookupIP.map { "https://api.ipapi.is/?q=\($0)" } ?? "https://api.ipapi.is/"
        case .ipinfo:
            string = lookupIP.map { "https://ipinfo.io/\($0)/json" } ?? "https://ipinfo.io/json"
        }
        return URL(string: string)!
    }

    /// Decodes a 200 response. Throws `IPAPIError` for error bodies or responses without usable data.
    func decode(_ data: Data) throws -> IPInfo {
        let info: IPInfo
        switch self {
        case .ipapiCo:
            if let body = try? Self.snakeCase.decode(IPAPIErrorBody.self, from: data), body.error == true {
                throw IPAPIError.api(body.reason ?? "未知原因")
            }
            info = try Self.snakeCase.decode(IPInfo.self, from: data)

        case .geoJS:
            let raw = try Self.snakeCase.decode(GeoJSResponse.self, from: data)
            info = IPInfo(
                ip: raw.ip, city: raw.city, region: raw.region,
                country: raw.countryCode, countryName: raw.country,
                latitude: raw.latitude.flatMap(Double.init), longitude: raw.longitude.flatMap(Double.init),
                timezone: raw.timezone,
                org: raw.organizationName, asn: raw.asn.map { "AS\($0)" }
            )

        case .ipAPICom:
            let raw = try JSONDecoder().decode(IPAPIComResponse.self, from: data)
            guard raw.status == "success" else { throw IPAPIError.api(raw.message ?? "未知原因") }
            let (asn, asName) = Self.splitASN(raw.as)
            info = IPInfo(
                ip: raw.query, city: raw.city, region: raw.regionName, regionCode: raw.region,
                country: raw.countryCode, countryName: raw.country, postal: raw.zip,
                latitude: raw.lat, longitude: raw.lon,
                timezone: raw.timezone, utcOffset: raw.offset.map(Self.formatOffset),
                org: raw.isp.nonEmpty ?? asName, asn: asn
            )

        case .ipapiIs:
            let raw = try JSONDecoder().decode(IPAPIIsResponse.self, from: data)
            if let error = raw.error { throw IPAPIError.api(error) }
            let (asn, asName) = Self.splitASN(raw.asn)
            info = IPInfo(
                ip: raw.ip, city: raw.city, region: raw.region, countryName: raw.country,
                latitude: raw.lat, longitude: raw.lon, timezone: raw.timezone,
                org: asName, asn: asn
            )

        case .ipinfo:
            let raw = try JSONDecoder().decode(IPInfoIOResponse.self, from: data)
            if raw.error != nil { throw IPAPIError.api(raw.error?.title ?? "未知原因") }
            let (asn, asName) = Self.splitASN(raw.org)
            let coordinates = raw.loc?.split(separator: ",").compactMap { Double($0) }
            info = IPInfo(
                ip: raw.ip, city: raw.city, region: raw.region,
                country: raw.country, countryName: raw.country.flatMap { Locale(identifier: "en_US").localizedString(forRegionCode: $0) },
                postal: raw.postal,
                latitude: coordinates?.count == 2 ? coordinates?[0] : nil,
                longitude: coordinates?.count == 2 ? coordinates?[1] : nil,
                timezone: raw.timezone, org: asName, asn: asn
            )
        }

        // A source that answers without an IP or any location is treated as failed.
        guard info.ip.nonEmpty != nil, info.city.nonEmpty != nil || info.countryName.nonEmpty != nil else {
            throw IPAPIError.invalidResponse
        }
        return info
    }

    private static let snakeCase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// "AS7018 AT&T Enterprises, LLC" -> ("AS7018", "AT&T Enterprises, LLC")
    private static func splitASN(_ value: String?) -> (asn: String?, name: String?) {
        guard let value = value.nonEmpty, value.uppercased().hasPrefix("AS") else { return (nil, value.nonEmpty) }
        let parts = value.split(separator: " ", maxSplits: 1)
        return (String(parts[0]).uppercased(), parts.count > 1 ? String(parts[1]) : nil)
    }

    /// Seconds from GMT -> "-0800", the format ipapi.co uses.
    private static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d%02d", sign, minutes / 60, minutes % 60)
    }
}

// MARK: - Raw responses

private struct GeoJSResponse: Decodable {
    let ip: String?
    let city: String?
    let region: String?
    let country: String?
    let countryCode: String?
    let latitude: String?
    let longitude: String?
    let timezone: String?
    let organizationName: String?
    let asn: Int?
}

private struct IPAPIComResponse: Decodable {
    let status: String?
    let message: String?
    let query: String?
    let city: String?
    let region: String?
    let regionName: String?
    let country: String?
    let countryCode: String?
    let zip: String?
    let lat: Double?
    let lon: Double?
    let timezone: String?
    let offset: Int?
    let isp: String?
    let `as`: String?
}

private struct IPAPIIsResponse: Decodable {
    let ip: String?
    let city: String?
    let region: String?
    let country: String?
    let lat: Double?
    let lon: Double?
    let timezone: String?
    let asn: String?
    let error: String?
}

private struct IPInfoIOResponse: Decodable {
    struct ErrorBody: Decodable { let title: String? }

    let ip: String?
    let city: String?
    let region: String?
    let country: String?
    let loc: String?
    let org: String?
    let postal: String?
    let timezone: String?
    let error: ErrorBody?
}
