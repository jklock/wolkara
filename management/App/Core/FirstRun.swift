import Foundation

/// Whether a game has started once on this Mac and saved what the device needs
/// (a profile's `setup.firstRun`). World of Warcraft writes its region and
/// languages to WTF/Config.wtf, as `SET portal "eu"` lines, the first time
/// Battle.net starts it. A copy that never started on the Mac has none: on the
/// device the game then asks for a region in a window Tolkara cannot show yet,
/// and quits within a second. The copy helpers carry only these keys
/// (tools/first_run.py follows the same rules).
struct FirstRunCheck: Hashable {
    var keys: [String]
    var fileExists: Bool
    var values: [String: String]

    var missing: [String] { keys.filter { values[$0] == nil } }
    var isDone: Bool { missing.isEmpty }
    /// "eu · deDE · deDE": what was saved, in the profile's order.
    var summary: String { keys.compactMap { values[$0] }.joined(separator: " · ") }

    /// The named keys with a plain value: `SET <key> "<value>"`. Nothing else
    /// in the file (an account name, say) is read.
    static func values(in text: String, keys: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.trimmingCharacters(in: .whitespaces).wholeMatch(of: /SET ([A-Za-z0-9_]+) "([A-Za-z0-9_-]+)"/),
                  keys.contains(String(match.1)) else { continue }
            values[String(match.1)] = String(match.2)
        }
        return values
    }

    static func check(_ firstRun: AppProfile.FirstRun, source folder: URL) -> FirstRunCheck {
        let file = folder.appendingPathComponent(firstRun.settings)
        // Config.wtf is a few kilobytes; never read a large file whole.
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard FileManager.default.fileExists(atPath: file.path), size <= 1 << 20,
              let data = try? Data(contentsOf: file) else {
            return FirstRunCheck(keys: firstRun.keys, fileExists: FileManager.default.fileExists(atPath: file.path), values: [:])
        }
        return FirstRunCheck(keys: firstRun.keys, fileExists: true, values: values(in: String(decoding: data, as: UTF8.self), keys: firstRun.keys))
    }

    /// The same check for the copy on the device, from the file read there.
    static func check(_ firstRun: AppProfile.FirstRun, deviceFile data: Data?) -> FirstRunCheck {
        FirstRunCheck(keys: firstRun.keys, fileExists: data != nil,
                      values: data.map { values(in: String(decoding: $0, as: UTF8.self), keys: firstRun.keys) } ?? [:])
    }
}

/// The region and language on the device, compared with this Mac's: what the
/// library asks the user to do.
enum DeviceSettings: Equatable {
    case fine
    /// Missing on the device and on this Mac: the game must start on the Mac first.
    case startOnMac
    /// This Mac has them and the device has none, or other ones: copy again.
    case copyAgain(changed: Bool)

    var isFine: Bool { self == .fine }

    static func compare(mac: FirstRunCheck?, device: FirstRunCheck?) -> DeviceSettings {
        guard let device else { return .fine }
        if !device.isDone { return mac?.isDone == true ? .copyAgain(changed: false) : .startOnMac }
        if let mac, mac.isDone, mac.values != device.values { return .copyAgain(changed: true) }
        return .fine
    }
}

extension AppProfile {
    /// The settings file on the device, relative to the app's container.
    var firstRunDevicePath: String? { firstRun.map { "Documents/\(destination)/\($0.settings)" } }
}
