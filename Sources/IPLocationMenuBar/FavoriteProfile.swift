import Foundation

/// A saved "known good" IP profile. Refreshed info is compared against these
/// to flag when the public exit (VPN, proxy, ISP) is not the expected one.
struct FavoriteProfile: Codable, Identifiable {
    enum Field: CaseIterable {
        case country, region, asn, ip
    }

    /// One field that does not match, with the saved value to show as "应为 …".
    struct Difference {
        let field: Field
        let expected: String
    }

    let id: UUID
    var name: String
    var countryCode: String?
    var countryName: String?
    var regionCode: String?
    var region: String?
    var city: String?
    var asn: String?
    var org: String?
    var ip: String?
    /// Also require the exact IP; off by default because ISPs and proxies rotate IPs within one ASN.
    var lockIP: Bool

    init(from info: IPInfo, name: String) {
        id = UUID()
        self.name = name
        countryCode = info.country
        countryName = info.countryName
        regionCode = info.regionCode
        region = info.region
        city = info.city
        asn = info.asn
        org = info.org
        ip = info.ip
        lockIP = false
    }

    var summary: String {
        let place = [city.nonEmpty, regionCode.nonEmpty ?? region.nonEmpty].compactMap { $0 }.joined(separator: " · ")
        return [place.isEmpty ? nil : place, asn.nonEmpty].compactMap { $0 }.joined(separator: "，")
    }

    /// Fields that differ from `info`. A field missing on either side is skipped rather than flagged.
    func differences(from info: IPInfo) -> [Difference] {
        var result: [Difference] = []

        if let saved = countryCode.nonEmpty, let current = info.country.nonEmpty, !Self.same(saved, current) {
            result.append(Difference(field: .country, expected: countryName.nonEmpty ?? saved))
        }

        // City is ignored: ipapi often flips between neighbouring cities for the same exit.
        if let saved = regionCode.nonEmpty, let current = info.regionCode.nonEmpty {
            if !Self.same(saved, current) {
                result.append(Difference(field: .region, expected: region.nonEmpty ?? saved))
            }
        } else if let saved = region.nonEmpty, let current = info.region.nonEmpty, !Self.same(saved, current) {
            result.append(Difference(field: .region, expected: saved))
        }

        if let saved = asn.nonEmpty, let current = info.asn.nonEmpty, !Self.same(saved, current) {
            result.append(Difference(field: .asn, expected: [saved, org.nonEmpty].compactMap { $0 }.joined(separator: " ")))
        }

        if lockIP, let saved = ip.nonEmpty, let current = info.ip.nonEmpty, saved != current {
            result.append(Difference(field: .ip, expected: saved))
        }

        return result
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

enum ProfileMatch {
    case noFavorites
    case matched(FavoriteProfile)
    case mismatched(closest: FavoriteProfile, differences: [FavoriteProfile.Difference])
    case ignored

    var isMismatch: Bool {
        if case .mismatched = self { return true }
        return false
    }
}

/// Persists favorites and related preferences in UserDefaults.
@MainActor
final class FavoriteStore {
    private enum Key {
        static let profiles = "favoriteProfiles"
        static let notifyOnMismatch = "notifyOnMismatch"
        static let ignoredSignature = "ignoredSignature"
    }

    private let defaults = UserDefaults.standard

    private(set) var profiles: [FavoriteProfile] = []

    init() {
        if let data = defaults.data(forKey: Key.profiles),
           let decoded = try? JSONDecoder().decode([FavoriteProfile].self, from: data) {
            profiles = decoded
        }
    }

    var notifyOnMismatch: Bool {
        get { defaults.object(forKey: Key.notifyOnMismatch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notifyOnMismatch) }
    }

    /// Signature of the info the user chose to ignore; cleared once the info changes.
    var ignoredSignature: String? {
        get { defaults.string(forKey: Key.ignoredSignature) }
        set { defaults.set(newValue, forKey: Key.ignoredSignature) }
    }

    func add(_ profile: FavoriteProfile) {
        profiles.append(profile)
        save()
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func toggleLockIP(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lockIP.toggle()
        save()
    }

    func match(_ info: IPInfo) -> ProfileMatch {
        guard !profiles.isEmpty else { return .noFavorites }

        let ranked = profiles
            .map { (profile: $0, differences: $0.differences(from: info)) }
            .sorted { $0.differences.count < $1.differences.count }
        let best = ranked[0]
        if best.differences.isEmpty { return .matched(best.profile) }

        if let ignoredSignature, ignoredSignature == info.signature { return .ignored }
        return .mismatched(closest: best.profile, differences: best.differences)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.profiles)
        }
    }
}
