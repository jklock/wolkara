import Foundation
import Security

/// An Apple developer team this Mac knows about, and what we can tell about
/// its membership without asking for any credentials.
struct DeveloperTeam: Identifiable, Hashable, Codable {
    enum Kind: Int, Codable, Comparable {
        case unknown, free, expired, paid
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    var id: String          // the 10-character team ID
    var name: String
    var kind: Kind
    var evidence: String    // where we learned it, for the user
}

/// One look at what this Mac knows about the user's developer account.
struct MembershipScan {
    var teams: [DeveloperTeam] = []
    /// Accounts signed in to Xcode › Settings › Apple Accounts.
    var xcodeAccounts = 0
    /// Apple signing certificates with their private key on this Mac.
    var signingCertificates = 0
    /// Teams the user chose in our small Team Check project in Xcode.
    var chosenInXcode: [String] = []
}

/// Finds the user's teams in what Xcode already keeps on this Mac:
/// - the team list Xcode stores for signed-in accounts (with a free-team flag);
/// - provisioning profiles Xcode downloaded: a paid membership's last a year,
///   a free Personal Team's seven days, and only a paid team gets the Network
///   Extension capability Tolkara needs;
/// - Apple signing certificates in the keychain, whose subject names the team;
/// - the team the user chose in our Team Check project (`TeamProbe`).
/// Nothing is sent anywhere. The first build confirms the result for real.
///
/// Signing in to Xcode is not enough for the first two: Xcode's Apple Accounts
/// pane shows the account's teams, but only Xcode's signing machinery saves
/// them (IDEProvisioningTeamByIdentifier, written by IDEFoundation's
/// provisioning team manager), and it runs only when Xcode signs a project.
/// On a Mac where Xcode has never signed anything there is no team list, no
/// profile and no development certificate yet. What Xcode does save at sign-in
/// is the account itself (DVTDeveloperAccountManagerAppleIDLists), so we can
/// tell "not signed in" from "signed in, team not saved yet" and offer the
/// Team Check project or the Team ID.
enum MembershipScanner {
    static let teamID = /^[A-Z0-9]{10}$/
    static let xcodeKeys = ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams", "DVTDeveloperAccountManagerAppleIDLists"]

    static func scan() -> MembershipScan {
        let defaults = xcodeDefaults()
        let certificates = signingCertificates()
        let chosen = TeamProbe.chosenTeams()
        var found: [DeveloperTeam] = []
        found += teams(fromXcodeDefaults: defaults)
        found += provisioningProfiles().compactMap { team(fromProfile: $0) }
        found += certificates.compactMap { team(fromCertificate: $0) }
        found += chosen.map { DeveloperTeam(id: $0, name: "Team \($0)", kind: .unknown, evidence: "Chosen in Xcode") }
        return MembershipScan(teams: merge(found), xcodeAccounts: accountCount(fromXcodeDefaults: defaults),
                              signingCertificates: certificates.count, chosenInXcode: chosen)
    }

    /// Xcode's settings, read afresh: Xcode may have saved its team list since
    /// the last check, and a process caches another app's settings.
    static func xcodeDefaults() -> [String: Any] {
        let domain = Toolchain.xcodeBundleIdentifier as CFString
        CFPreferencesAppSynchronize(domain)
        var defaults: [String: Any] = [:]
        for key in xcodeKeys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain) { defaults[key] = value }
        }
        return defaults
    }

    /// The provisioning profiles Xcode downloaded to this Mac.
    static func provisioningProfiles() -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"].flatMap { folder in
            let files = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
            return files.filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) }
                .compactMap { try? Data(contentsOf: $0) }.compactMap(decodeProfile)
        }
    }

    /// When the newest profile for an app runs out: after that the app no
    /// longer opens on the iPad until it is built and installed again.
    static func expiry(team: String, bundleID: String, in profiles: [[String: Any]]) -> Date? {
        profiles.filter { ($0["Entitlements"] as? [String: Any])?["application-identifier"] as? String == "\(team).\(bundleID)" }
            .compactMap { $0["ExpirationDate"] as? Date }.max()
    }

    /// Xcode's IDEProvisioningTeamByIdentifier (current) or IDEProvisioningTeams
    /// (older): account → [{teamID, teamName, isFreeProvisioningTeam, teamType}].
    static func teams(fromXcodeDefaults defaults: [String: Any]) -> [DeveloperTeam] {
        var result: [DeveloperTeam] = []
        for key in ["IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"] {
            guard let accounts = defaults[key] as? [String: Any] else { continue }
            for case let list as [[String: Any]] in accounts.values {
                for entry in list {
                    guard let id = entry["teamID"] as? String, id.wholeMatch(of: teamID) != nil else { continue }
                    let free = (entry["isFreeProvisioningTeam"] as? Bool) ?? ((entry["isFreeProvisioningTeam"] as? NSNumber)?.boolValue ?? false)
                    let personal = (entry["teamType"] as? String)?.localizedCaseInsensitiveContains("personal") ?? false
                    result.append(DeveloperTeam(id: id, name: entry["teamName"] as? String ?? id,
                                                kind: free || personal ? .free : .paid, evidence: "Signed in to Xcode"))
                }
            }
        }
        return result
    }

    /// How many accounts are signed in to Xcode. Xcode saves the list at
    /// sign-in, before it has saved any team: DVTDeveloperAccountManagerAppleIDLists
    /// → {"IDE.Identifiers.Prod": [{identifier}]} (current) or {"IDE.Prod": [{username}]} (older).
    static func accountCount(fromXcodeDefaults defaults: [String: Any]) -> Int {
        guard let lists = defaults["DVTDeveloperAccountManagerAppleIDLists"] as? [String: Any] else { return 0 }
        var accounts = Set<String>()
        for (environment, value) in lists where environment.hasSuffix("Prod") {
            for case let entry as [String: Any] in (value as? [Any]) ?? [] {
                if let name = (entry["identifier"] ?? entry["username"]) as? String, !name.isEmpty { accounts.insert(name) }
            }
        }
        return accounts.count
    }

    /// One provisioning profile's team and what its lifetime and entitlements say.
    static func team(fromProfile plist: [String: Any], now: Date = Date()) -> DeveloperTeam? {
        guard let id = (plist["TeamIdentifier"] as? [String])?.first, id.wholeMatch(of: teamID) != nil,
              let created = plist["CreationDate"] as? Date, let expires = plist["ExpirationDate"] as? Date else { return nil }
        let name = plist["TeamName"] as? String ?? id
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let paidOnly = entitlements.keys.contains { $0.hasPrefix("com.apple.developer.networking.networkextension") }
        let lifetime = expires.timeIntervalSince(created)
        let kind: DeveloperTeam.Kind
        if lifetime <= 8 * 86400 && !paidOnly { kind = .free }
        else if expires < now { kind = .expired }
        else { kind = .paid }
        return DeveloperTeam(id: id, name: name, kind: kind, evidence: "Provisioning profile")
    }

    /// An Apple signing certificate's subject: "Apple Development: Name (ABC)"
    /// with the team ID as its organizational unit and the team name as its
    /// organization. (The ID in the common name is the person's, not the team's.)
    struct SigningCertificate: Equatable {
        var commonName: String
        var teamID: String?
        var teamName: String?
        var expires: Date?
    }

    static let signingPrefixes = ["Apple Development:", "Apple Distribution:", "iPhone Developer:", "iPhone Distribution:",
                                  "Mac Developer:", "Developer ID Application:", "3rd Party Mac Developer Application:"]

    /// The team a certificate belongs to. Free and paid teams both get
    /// development certificates, so this only says which team, not which kind:
    /// the first build confirms it.
    static func team(fromCertificate certificate: SigningCertificate, now: Date = Date()) -> DeveloperTeam? {
        guard signingPrefixes.contains(where: certificate.commonName.hasPrefix),
              let id = certificate.teamID, id.wholeMatch(of: teamID) != nil,
              (certificate.expires ?? .distantFuture) > now else { return nil }
        return DeveloperTeam(id: id, name: certificate.teamName ?? "Team \(id)", kind: .unknown, evidence: "Signing certificate")
    }

    /// The Apple signing certificates whose private key is on this Mac. Reads
    /// certificates only, never keys, so the keychain asks nothing.
    static func signingCertificates() -> [SigningCertificate] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [AnyObject] else { return [] }
        return items.compactMap { item -> SigningCertificate? in
            guard CFGetTypeID(item) == SecIdentityGetTypeID() else { return nil }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(item as! SecIdentity, &certificate) == errSecSuccess, let certificate,
                  let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName, kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
                    as? [String: Any] else { return nil }
            return self.certificate(fromValues: values)
        }.filter { certificate in signingPrefixes.contains(where: certificate.commonName.hasPrefix) }
    }

    /// The subject and expiry out of SecCertificateCopyValues' result.
    static func certificate(fromValues values: [String: Any]) -> SigningCertificate? {
        let subject = (values[kSecOIDX509V1SubjectName as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        func field(_ oid: CFString) -> String? {
            subject.first { $0[kSecPropertyKeyLabel as String] as? String == oid as String }?[kSecPropertyKeyValue as String] as? String
        }
        guard let commonName = field(kSecOIDCommonName) else { return nil }
        let notAfter = (values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any])?[kSecPropertyKeyValue as String] as? NSNumber
        return SigningCertificate(commonName: commonName, teamID: field(kSecOIDOrganizationalUnitName), teamName: field(kSecOIDOrganizationName),
                                  expires: notAfter.map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) })
    }

    /// One entry per team, keeping the strongest evidence and the best name.
    static func merge(_ teams: [DeveloperTeam]) -> [DeveloperTeam] {
        var best: [String: DeveloperTeam] = [:]
        for team in teams {
            guard var current = best[team.id] else { best[team.id] = team; continue }
            let named = current.name == "Team \(current.id)" && team.name != "Team \(team.id)" ? team.name : current.name
            if team.kind > current.kind { current = team }
            current.name = named
            best[team.id] = current
        }
        return best.values.sorted { ($0.kind, $1.name) > ($1.kind, $0.name) }
    }

    /// A Team ID as people paste it: "abcde12345", "ABCDE 12345", "Team ID: ABCDE12345".
    static func teamID(fromTyped text: String) -> String? {
        let upper = text.uppercased()
        let compact = upper.filter { !$0.isWhitespace }
        if compact.wholeMatch(of: teamID) != nil { return compact }
        let tokens = upper.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let ids = tokens.filter { $0.wholeMatch(of: teamID) != nil }
        return ids.count == 1 ? ids[0] : nil
    }

    /// The property list inside a signed provisioning profile (CMS).
    static func decodeProfile(_ data: Data) -> [String: Any]? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let status = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return (try? PropertyListSerialization.propertyList(from: content as Data, format: nil)) as? [String: Any]
    }
}

/// A tiny Mac app project that only exists so the user can pick their team in
/// Xcode's own Signing & Capabilities editor. That makes Xcode load the
/// account's teams through its signing machinery: it saves the team list and,
/// if there is none yet, creates the development certificate Tolkara's build
/// needs anyway. Xcode writes the chosen team into the project file, where we
/// read it back. It is never built, has no capabilities (so no provisioning
/// profile or App ID is made for it) and lives in our support folder.
enum TeamProbe {
    static var folder: URL { AppPaths.support.appendingPathComponent("Team Check", isDirectory: true) }
    static var project: URL { folder.appendingPathComponent("Team Check.xcodeproj", isDirectory: true) }
    static var projectFile: URL { project.appendingPathComponent("project.pbxproj") }

    /// Writes the project unless it is there already (it may hold the team).
    @discardableResult
    static func create(in folder: URL = folder) throws -> URL {
        let fileManager = FileManager.default
        let project = folder.appendingPathComponent("Team Check.xcodeproj", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let main = folder.appendingPathComponent("main.swift")
        if !fileManager.fileExists(atPath: main.path) {
            try "// Tolkara Management: choose your team in Signing & Capabilities. This app is never built.\n"
                .write(to: main, atomically: true, encoding: .utf8)
        }
        let file = project.appendingPathComponent("project.pbxproj")
        if !fileManager.fileExists(atPath: file.path) {
            try pbxproj.write(to: file, atomically: true, encoding: .utf8)
        }
        return project
    }

    static func chosenTeams() -> [String] {
        (try? String(contentsOf: projectFile, encoding: .utf8)).map(teams(inProjectFile:)) ?? []
    }

    /// DEVELOPMENT_TEAM = ABCDE12345; as Xcode writes it when a team is chosen.
    static func teams(inProjectFile text: String) -> [String] {
        var seen: [String] = []
        for match in text.matches(of: /DEVELOPMENT_TEAM\s*=\s*"?([A-Z0-9]{10})"?\s*;/) where !seen.contains(String(match.1)) {
            seen.append(String(match.1))
        }
        return seen
    }

    static let pbxproj = """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 56;
    	objects = {
    		7E0000000000000000000001 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = 7E0000000000000000000002 /* main.swift */; };
    		7E0000000000000000000002 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
    		7E0000000000000000000003 /* Team Check.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Team Check.app"; sourceTree = BUILT_PRODUCTS_DIR; };
    		7E0000000000000000000004 = {isa = PBXGroup; children = (7E0000000000000000000002 /* main.swift */, 7E0000000000000000000005 /* Products */, ); sourceTree = "<group>"; };
    		7E0000000000000000000005 /* Products */ = {isa = PBXGroup; children = (7E0000000000000000000003 /* Team Check.app */, ); name = Products; sourceTree = "<group>"; };
    		7E0000000000000000000006 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (7E0000000000000000000001 /* main.swift in Sources */, ); runOnlyForDeploymentPostprocessing = 0; };
    		7E0000000000000000000007 /* Team Check */ = {isa = PBXNativeTarget; buildConfigurationList = 7E0000000000000000000008 /* Build configuration list for PBXNativeTarget "Team Check" */; buildPhases = (7E0000000000000000000006 /* Sources */, ); buildRules = (); dependencies = (); name = "Team Check"; productName = "Team Check"; productReference = 7E0000000000000000000003 /* Team Check.app */; productType = "com.apple.product-type.application"; };
    		7E0000000000000000000008 /* Build configuration list for PBXNativeTarget "Team Check" */ = {isa = XCConfigurationList; buildConfigurations = (7E0000000000000000000009 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    		7E0000000000000000000009 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {
    			CODE_SIGN_STYLE = Automatic;
    			GENERATE_INFOPLIST_FILE = YES;
    			MACOSX_DEPLOYMENT_TARGET = 14.0;
    			PRODUCT_BUNDLE_IDENTIFIER = local.tolkara.teamcheck;
    			PRODUCT_NAME = "Team Check";
    			SWIFT_VERSION = 5.0;
    		}; name = Debug; };
    		7E000000000000000000000A /* Build configuration list for PBXProject "Team Check" */ = {isa = XCConfigurationList; buildConfigurations = (7E000000000000000000000B /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    		7E000000000000000000000B /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {
    			ALWAYS_SEARCH_USER_PATHS = NO;
    			SDKROOT = macosx;
    		}; name = Debug; };
    		7E000000000000000000000C /* Project object */ = {isa = PBXProject; buildConfigurationList = 7E000000000000000000000A /* Build configuration list for PBXProject "Team Check" */; compatibilityVersion = "Xcode 14.0"; mainGroup = 7E0000000000000000000004; productRefGroup = 7E0000000000000000000005 /* Products */; projectDirPath = ""; projectRoot = ""; targets = (7E0000000000000000000007 /* Team Check */, ); };
    	};
    	rootObject = 7E000000000000000000000C /* Project object */;
    }

    """
}
