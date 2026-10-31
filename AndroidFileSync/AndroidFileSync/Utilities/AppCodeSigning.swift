import Foundation
import Security

/// macOS associates Local Network permission with the responsible app's code
/// signature. Unsigned and ad hoc builds don't retain a stable Apple identity.
nonisolated enum AppCodeSigning {
    enum Identity: Equatable {
        case appleIssued(String)
        case adHoc
        case unsigned
        case invalid(Int32)

        var description: String {
            switch self {
            case .appleIssued(let team): return "Apple-issued, team=\(team)"
            case .adHoc: return "ad-hoc"
            case .unsigned: return "unsigned"
            case .invalid(let status): return "invalid, status=\(status)"
            }
        }
    }

    static let identity = inspectCurrentProcess()

    static var hasAppleIdentity: Bool {
        if case .appleIssued = identity { return true }
        return false
    }

    static var diagnosticDescription: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let path = bundle.bundleURL.standardizedFileURL.path
        let location = path.hasPrefix("/Applications/") ? "Applications"
            : path.hasPrefix("/Volumes/") ? "disk-image" : "other"
        return "bundle=\(bundle.bundleIdentifier ?? "unknown"), version=\(version) (\(build)), signing=\(identity.description), location=\(location)"
    }

    static var localNetworkGuidance: String {
        guard !hasAppleIdentity else { return "" }
        return " This build has no valid Apple-issued signing identity. macOS may not match it to the enabled Local Network entry. Install an Apple-signed build in Applications and retry."
    }

    private static func inspectCurrentProcess() -> Identity {
        var code: SecCode?
        let copied = SecCodeCopySelf(SecCSFlags(), &code)
        guard copied == errSecSuccess, let code else { return .invalid(copied) }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code,
            SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            return .invalid(status)
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & UInt32(kSecCodeSignatureAdhoc) != 0 { return .adHoc }
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString("anchor apple generic" as CFString,
            SecCSFlags(), &requirement)
        guard created == errSecSuccess, let requirement else { return .invalid(created) }
        let valid = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        guard valid == errSecSuccess else { return .invalid(valid) }
        return .appleIssued(info[kSecCodeInfoTeamIdentifier as String] as? String ?? "unknown")
    }
}
