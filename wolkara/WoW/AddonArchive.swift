import Foundation
import ZIPFoundation

@objc(TKAddonArchive)
final class TKAddonArchive: NSObject {
    private static let compressedLimit: UInt64 = 128 * 1024 * 1024
    private static let expandedLimit: UInt64 = 512 * 1024 * 1024
    private static let fileLimit: UInt64 = 64 * 1024 * 1024
    private static let entryLimit = 20_000

    private static func failure(_ message: String, _ output: NSErrorPointer) -> Bool {
        output?.pointee = NSError(domain: "Wolkara.AddOns", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        return false
    }

    private static func safePath(_ path: String) -> Bool {
        // ZIPFoundation reports directory entries with a trailing slash. It is
        // structural metadata, not an empty path component; reject all other
        // empty components so traversal and doubled separators stay forbidden.
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalized.isEmpty || normalized.hasPrefix("/") || normalized.contains(":") || normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return false }
        return !normalized.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    @objc(extractArchiveAtURL:toDirectoryURL:error:)
    static func extract(archiveURL: URL, to directoryURL: URL, error output: NSErrorPointer) -> Bool {
        let manager = FileManager.default
        // The extractor owns only a new staging directory. Never remove or write
        // through an existing directory (which could contain files or symlinks).
        guard !manager.fileExists(atPath: directoryURL.path) else {
            return failure("The extraction destination already exists.", output)
        }
        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .read) }
        catch { return failure("The selected file is not a supported ZIP archive.", output) }
        var compressed: UInt64 = 0, expanded: UInt64 = 0
        var paths = Set<String>()
        var entries: [Entry] = []
        for entry in archive {
            guard entries.count < entryLimit else { return failure("The ZIP archive has too many entries.", output) }
            guard entry.type != .symlink, safePath(entry.path), entry.uncompressedSize <= fileLimit else { return failure("The ZIP archive contains an unsafe entry.", output) }
            compressed += entry.compressedSize; expanded += entry.uncompressedSize
            guard compressed <= compressedLimit, expanded <= expandedLimit, paths.insert(entry.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { return failure("The ZIP archive exceeds limits or contains colliding paths.", output) }
            entries.append(entry)
        }
        do {
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for entry in entries {
                let destination = directoryURL.appendingPathComponent(entry.path)
                let checksum = try archive.extract(entry, to: destination)
                guard checksum == entry.checksum else {
                    throw NSError(domain: "Wolkara.AddOns", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The ZIP archive failed its integrity check."])
                }
            }
            return true
        } catch let caught {
            try? manager.removeItem(at: directoryURL)
            output?.pointee = caught as NSError
            return false
        }
    }
}
