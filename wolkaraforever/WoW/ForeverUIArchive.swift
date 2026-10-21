import Foundation
import CryptoKit
import ZIPFoundation

// A complete, verifiable snapshot of one Forever edition's user interface:
// `WTF/` (except its own `Backups/`), `Interface/` and a manifest that binds
// every archived file to its SHA-256.
//
// It is deliberately separate from the add-on importer: that one accepts a
// stranger's ZIP and must be suspicious of everything, while this one writes and
// reads a document this app produced. What they share is the pinned
// ZIPFoundation and the same refusal to follow a link or a path out of the tree.
//
// Nothing here writes into the live UI: a backup is built in a temporary
// sibling and renamed only after it has been reopened and checked, and a
// restore is staged beside the live roots and swapped in through a journal.
@objc(TKForeverUIArchive)
final class TKForeverUIArchive: NSObject {
    private static let errorDomain = "WolkaraForever.ForeverUI.Archive"

    // The archive format. `version` is written into every manifest and checked
    // on the way back in, so an older launcher can refuse a newer snapshot
    // instead of half-reading it.
    private static let format = "wolkaraforever.ui.backup"
    private static let formatVersion = 1
    private static let manifestName = ".wolkaraforever-ui-manifest.json"

    // Bounds. A UI folder is large but not unbounded, and a ZIP header is a
    // claim, not a measurement, so extraction is counted as it happens too.
    private static let entryLimit = 100_000
    private static let fileLimit: UInt64 = 512 * 1024 * 1024
    private static let totalLimit: UInt64 = 8 * 1024 * 1024 * 1024
    private static let bufferSize = 1 << 20

    private static let roots = ["WTF", "Interface"]
    private static let excludedDirectories: Set<String> = [
        "Backups", "Cache", "Caches", "Errors", "Logs", "Crash", "Screenshots",
    ]
    private static let excludedNames: Set<String> = [".DS_Store", "Thumbs.db"]
    private static let excludedExtensions: Set<String> = ["log", "dmp", "tmp", "bak", "old", "etilqs"]

    private struct FileEntry: Codable {
        let path: String
        let size: UInt64
        let sha256: String
    }

    private struct Manifest: Codable {
        let format: String
        let version: Int
        let edition: String
        let created: String
        let entries: Int
        let files: [FileEntry]
    }

    private struct Journal: Codable {
        let format: String
        let version: Int
        let staging: String
        let recoveryWTF: String
        let recoveryInterface: String
    }

    private struct Node {
        let path: String        // "WTF/Config.wtf" - always relative, always POSIX
        let url: URL
        let isDirectory: Bool
        let size: UInt64
        let digest: String?
    }

    // MARK: - Failures

    private static func failure(_ message: String, _ output: NSErrorPointer) -> NSError {
        let error = NSError(domain: errorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        output?.pointee = error
        return error
    }

    @discardableResult
    private static func fail(_ message: String, _ output: NSErrorPointer) -> Bool {
        _ = failure(message, output)
        return false
    }

    // MARK: - Paths

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func inside(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = canonical(root).path
        let candidatePath = canonical(candidate).path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func workingDirectory(_ directory: String, _ output: NSErrorPointer) -> URL? {
        guard !directory.isEmpty else {
            fail("The game's working folder is not known.", output)
            return nil
        }
        let root = canonical(URL(fileURLWithPath: directory, isDirectory: true))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("The game's working folder is missing.", output)
            return nil
        }
        return root
    }

    private static func backupDirectory(_ root: URL, create: Bool, _ output: NSErrorPointer) -> URL? {
        let directory = root.appendingPathComponent("WTF/Backups", isDirectory: true)
        guard inside(root, directory) else {
            fail("The backup folder is outside the game's working folder.", output)
            return nil
        }
        if create {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { fail("The backup folder could not be created.", output); return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("The backup folder is missing.", output)
            return nil
        }
        return directory
    }

    // A backup's name is `WoW-UI-YYYY-MM-DDTHH-mm-ssZ`, with a numeric suffix if
    // two snapshots land inside one second, and it is never a path.
    private static func archiveName(at date: Date, in directory: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        let base = "WoW-UI-" + formatter.string(from: date)
        var name = base + ".zip"
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = base + "-\(suffix).zip"
            suffix += 1
        }
        return name
    }

    private static func backupNameIsSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") &&
            name.hasPrefix("WoW-UI-") && name.hasSuffix(".zip")
    }

    // MARK: - Walking

    private static func excludedDirectory(_ name: String, under path: String) -> Bool {
        if !excludedDirectories.contains(name) { return false }
        // `Backups` is the one exclusion that only means something at the top of
        // WTF: an add-on is allowed to contain a folder with that name.
        if name == "Backups" { return (path as NSString).deletingLastPathComponent == "WTF" }
        return true
    }

    private static func excludedFile(_ name: String) -> Bool {
        if excludedNames.contains(name) { return true }
        return excludedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(_ root: URL, _ output: NSErrorPointer) -> [Node]? {
        let manager = FileManager.default
        var nodes: [Node] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

        for name in roots {
            let rootURL = root.appendingPathComponent(name, isDirectory: true)
            guard inside(root, rootURL) else {
                fail("The game's \(name) folder is outside its working folder.", output)
                return nil
            }
            var isDirectory: ObjCBool = false
            if !manager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                // A snapshot always describes both roots, so a restore can never
                // leave the other one half-replaced.
                nodes.append(Node(path: name, url: rootURL, isDirectory: true, size: 0, digest: nil))
                continue
            }
            nodes.append(Node(path: name, url: rootURL, isDirectory: true, size: 0, digest: nil))
            guard let enumerator = manager.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                      options: [], errorHandler: { _, _ in true }) else {
                fail("The game's \(name) folder could not be read.", output)
                return nil
            }
            for case let url as URL in enumerator {
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: Set(keys)) }
                catch { fail("A file in the game's \(name) folder could not be read.", output); return nil }
                let itemName = url.lastPathComponent
                if values.isSymbolicLink == true {
                    fail("The game's \(name) folder contains a link, which a backup cannot follow.", output)
                    return nil
                }
                if values.isDirectory == true {
                    if excludedDirectory(itemName, under: enumeratorPath(url, root: root)) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let relative = enumeratorPath(url, root: root)
                    nodes.append(Node(path: relative, url: url, isDirectory: true, size: 0, digest: nil))
                    continue
                }
                guard values.isRegularFile == true else {
                    fail("The game's \(name) folder contains a file type a backup cannot carry.", output)
                    return nil
                }
                // Executables are game data, not UI state.
                if manager.isExecutableFile(atPath: url.path) { continue }
                if excludedFile(itemName) { continue }
                let size = UInt64(values.fileSize ?? 0)
                if size > fileLimit {
                    fail("A file in the game's \(name) folder is too large to back up.", output)
                    return nil
                }
                let digest: String
                do { digest = try sha256(of: url) }
                catch { fail("A file in the game's \(name) folder could not be read.", output); return nil }
                nodes.append(Node(path: enumeratorPath(url, root: root), url: url, isDirectory: false, size: size, digest: digest))
            }
        }
        return nodes.sorted { $0.path < $1.path }
    }

    private static func enumeratorPath(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    private static func manifestData(edition: String, created: Date, nodes: [Node]) -> Data? {
        let formatter = ISO8601DateFormatter()
        let files = nodes.filter { !$0.isDirectory }.map {
            FileEntry(path: $0.path, size: $0.size, sha256: $0.digest ?? "")
        }
        let manifest = Manifest(format: format, version: formatVersion, edition: edition,
                                created: formatter.string(from: created), entries: files.count, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(manifest)
    }

    // MARK: - Creation

    @objc(createBackupInWorkingDirectory:edition:error:)
    static func createBackup(inWorkingDirectory directory: String, edition: String,
                             error output: NSErrorPointer) -> String? {
        guard let root = workingDirectory(directory, output) else { return nil }
        guard let backups = backupDirectory(root, create: true, output) else { return nil }
        guard let nodes = collect(root, output) else { return nil }
        let created = Date()
        guard let manifest = manifestData(edition: edition, created: created, nodes: nodes) else {
            fail("The backup could not be described.", output)
            return nil
        }

        let temporary = backups.appendingPathComponent(".WoW-UI-\(UUID().uuidString).tmp.zip")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: temporary) }
        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            let date = created
            for node in nodes {
                if node.isDirectory {
                    let path = node.path.hasSuffix("/") ? node.path : node.path + "/"
                    try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0),
                                         modificationDate: date, permissions: 0o755,
                                         compressionMethod: .none) { _, _ in Data() }
                    continue
                }
                let handle = try FileHandle(forReadingFrom: node.url)
                defer { try? handle.close() }
                try archive.addEntry(with: node.path, type: .file, uncompressedSize: Int64(node.size),
                                     modificationDate: date, permissions: 0o644,
                                     compressionMethod: .deflate) { position, count in
                    try handle.seek(toOffset: UInt64(position))
                    return try handle.read(upToCount: count) ?? Data()
                }
            }
            try archive.addEntry(with: manifestName, type: .file, uncompressedSize: Int64(manifest.count),
                                 modificationDate: date, permissions: 0o644,
                                 compressionMethod: .deflate) { position, count in
                let start = Int(position)
                return manifest.subdata(in: start..<min(start + count, manifest.count))
            }
            // Close the archive by letting it leave scope before verification.
            _ = archive
        } catch {
            fail("The backup could not be written.", output)
            return nil
        }

        // Reopen and check every digest before the archive is allowed its name.
        guard verifyArchive(at: temporary, edition: edition, output) else { return nil }

        let name = archiveName(at: created, in: backups)
        let final = backups.appendingPathComponent(name)
        do { try manager.moveItem(at: temporary, to: final) }
        catch { fail("The backup could not be put in place.", output); return nil }
        return name
    }

    private static func readManifest(_ archive: Archive) throws -> Manifest {
        guard let entry = archive.first(where: { $0.path == manifestName && $0.type == .file }) else {
            throw NSError(domain: errorDomain, code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The archive has no backup manifest."])
        }
        var data = Data()
        _ = try archive.extract(entry, bufferSize: bufferSize, skipCRC32: true) { chunk in data.append(chunk) }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func verifyManifest(_ manifest: Manifest, edition: String, _ output: NSErrorPointer) -> Bool {
        guard manifest.format == format, manifest.version == formatVersion else {
            return fail("The archive was written by a different version of this app.", output)
        }
        guard manifest.edition == edition, !manifest.edition.isEmpty else {
            return fail("The archive belongs to a different game edition.", output)
        }
        guard manifest.entries == manifest.files.count else {
            return fail("The archive's manifest is inconsistent.", output)
        }
        return true
    }

    private static func verifyArchive(at url: URL, edition: String, _ output: NSErrorPointer) -> Bool {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            let manifest = try readManifest(archive)
            guard verifyManifest(manifest, edition: edition, output) else { return false }

            var seen = Set<String>()
            var files: [String: Entry] = [:]
            var total: UInt64 = 0
            var count = 0
            for entry in archive {
                guard entry.type == .file || entry.type == .directory else {
                    return fail("The archive contains an unsafe entry.", output)
                }
                count += 1
                guard count <= entryLimit else {
                    return fail("The archive has too many entries.", output)
                }
                guard entry.path == manifestName || pathIsInsideRoots(entry.path) else {
                    return fail("The archive contains a path outside WTF and Interface.", output)
                }
                let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
                guard seen.insert(key).inserted else {
                    return fail("The archive contains colliding paths.", output)
                }
                if entry.type == .file && entry.path != manifestName {
                    total += entry.uncompressedSize
                    guard entry.uncompressedSize <= fileLimit, total <= totalLimit else {
                        return fail("The archive exceeds the size limits.", output)
                    }
                    files[entry.path] = entry
                }
            }
            guard files.count == manifest.files.count else {
                return fail("The archive does not match its manifest.", output)
            }
            for file in manifest.files {
                guard let entry = files[file.path], entry.uncompressedSize == file.size else {
                    return fail("The archive does not match its manifest.", output)
                }
                var hasher = SHA256()
                var measured: UInt64 = 0
                _ = try archive.extract(entry, bufferSize: bufferSize, skipCRC32: true) { chunk in
                    measured += UInt64(chunk.count)
                    hasher.update(data: chunk)
                }
                guard measured == file.size else {
                    return fail("The archive's entry size does not match its manifest.", output)
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == file.sha256 else {
                    return fail("The archive failed its integrity check.", output)
                }
            }
            return true
        } catch {
            output?.pointee = error as NSError
            return false
        }
    }

    private static func pathIsInsideRoots(_ path: String) -> Bool {
        guard path.hasSuffix("/") == false else {
            let trimmed = String(path.dropLast())
            return pathIsInsideRoots(trimmed)
        }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        guard let first = parts.first.map(String.init), roots.contains(first) else { return false }
        // The backup's own folder is never part of a snapshot.
        if parts.count >= 2 && first == "WTF" && parts[1] == "Backups" { return false }
        return true
    }

    // MARK: - Discovery

    @objc(newestBackupInWorkingDirectory:error:)
    static func newestBackup(inWorkingDirectory directory: String, error output: NSErrorPointer) -> String? {
        guard let root = workingDirectory(directory, output) else { return nil }
        guard let backups = backupDirectory(root, create: false, output) else { return nil }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: backups.path) }
        catch { fail("The backup folder could not be read.", output); return nil }

        // Newest by the name's own timestamp and collision suffix - not by
        // plain string order, where `...Z.zip` sorts after `...Z-2.zip`. A
        // candidate that does not hold a complete manifest is skipped, so one
        // damaged ZIP does not hide the backup behind it.
        var best: (stamp: String, suffix: Int, name: String)?
        for name in names where backupNameIsSafe(name) {
            guard archiveIsReadable(backups.appendingPathComponent(name)) else { continue }
            let rank = snapshotRank(name)
            if let current = best {
                if rank.stamp > current.stamp || (rank.stamp == current.stamp && rank.suffix > current.suffix) {
                    best = (rank.stamp, rank.suffix, name)
                }
            } else {
                best = (rank.stamp, rank.suffix, name)
            }
        }
        guard let newest = best else {
            fail("No complete backup was found. Run Backup first.", output)
            return nil
        }
        return newest.name
    }

    private static func snapshotRank(_ name: String) -> (stamp: String, suffix: Int) {
        let base = name.hasSuffix(".zip") ? String(name.dropLast(4)) : name
        guard let z = base.range(of: "Z", options: .backwards) else { return (base, 1) }
        let stamp = String(base[..<z.upperBound])
        let rest = String(base[z.upperBound...])
        if rest.hasPrefix("-"), let suffix = Int(rest.dropFirst()) { return (stamp, suffix) }
        return (stamp, 1)
    }

    private static func archiveIsReadable(_ url: URL) -> Bool {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            let manifest = try readManifest(archive)
            return manifest.format == format && manifest.version == formatVersion &&
                manifest.entries == manifest.files.count
        } catch {
            return false
        }
    }

    // MARK: - Restore

    @objc(restoreBackupNamed:inWorkingDirectory:edition:error:)
    static func restoreBackup(named name: String, inWorkingDirectory directory: String,
                              edition: String, error output: NSErrorPointer) -> Bool {
        guard backupNameIsSafe(name) else {
            return fail("That is not a backup this app made.", output)
        }
        guard let root = workingDirectory(directory, output) else { return false }
        guard let backups = backupDirectory(root, create: false, output) else { return false }
        let archiveURL = backups.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            return fail("The selected backup is missing.", output)
        }
        guard verifyArchive(at: archiveURL, edition: edition, output) else { return false }

        let manager = FileManager.default
        let identifier = UUID().uuidString
        let staging = root.appendingPathComponent(".wolkaraforever-ui-restore-\(identifier)", isDirectory: true)
        let recoveryWTF = root.appendingPathComponent(".wolkaraforever-ui-old-WTF-\(identifier)", isDirectory: true)
        let recoveryInterface = root.appendingPathComponent(".wolkaraforever-ui-old-Interface-\(identifier)", isDirectory: true)
        guard inside(root, staging), inside(root, recoveryWTF), inside(root, recoveryInterface) else {
            return fail("The restore could not be placed beside the game's folders.", output)
        }
        let journalURL = root.appendingPathComponent(".wolkaraforever-ui-restore.json")

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            return fail("The restore could not be staged.", output)
        }
        defer { try? manager.removeItem(at: staging) }

        // Extract and re-check while writing. Only the staging tree is touched.
        guard extract(archiveURL: archiveURL, edition: edition, into: staging, output) else { return false }
        guard stagedRootsAreValid(staging, output) else { return false }

        // All snapshots survive a restore: the live Backups folder moves into the
        // staged one before anything is swapped.
        let liveBackups = root.appendingPathComponent("WTF/Backups", isDirectory: true)
        let stagedBackups = staging.appendingPathComponent("WTF/Backups", isDirectory: true)
        if manager.fileExists(atPath: liveBackups.path) {
            do {
                if manager.fileExists(atPath: stagedBackups.path) { try manager.removeItem(at: stagedBackups) }
                try manager.createDirectory(at: stagedBackups.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: liveBackups, to: stagedBackups)
            } catch {
                return fail("The existing backups could not be carried into the restore.", output)
            }
        }

        let journal = Journal(format: "wolkaraforever.ui.restore", version: 1,
                              staging: staging.lastPathComponent,
                              recoveryWTF: recoveryWTF.lastPathComponent,
                              recoveryInterface: recoveryInterface.lastPathComponent)
        do {
            let data = try JSONEncoder().encode(journal)
            try data.write(to: journalURL, options: .atomic)
        } catch {
            return fail("The restore could not be recorded.", output)
        }

        guard swap(root: root, staging: staging, recoveryWTF: recoveryWTF,
                   recoveryInterface: recoveryInterface, output) else {
            rollback(root: root, recoveryWTF: recoveryWTF, recoveryInterface: recoveryInterface)
            try? manager.removeItem(at: journalURL)
            return false
        }

        // Journal last: its absence is what says the swap completed.
        try? manager.removeItem(at: journalURL)
        try? manager.removeItem(at: recoveryWTF)
        try? manager.removeItem(at: recoveryInterface)
        return true
    }

    private static func extract(archiveURL: URL, edition: String, into staging: URL,
                                _ output: NSErrorPointer) -> Bool {
        do {
            let archive = try Archive(url: archiveURL, accessMode: .read)
            let manifest = try readManifest(archive)
            guard verifyManifest(manifest, edition: edition, output) else { return false }
            var expected: [String: FileEntry] = [:]
            for file in manifest.files { expected[file.path] = file }
            var total: UInt64 = 0
            var seen = Set<String>()
            var fileCount = 0
            var count = 0

            for entry in archive {
                if entry.path == manifestName { continue }
                guard entry.type == .file || entry.type == .directory else {
                    return fail("The archive contains an unsafe entry.", output)
                }
                count += 1
                guard count <= entryLimit else {
                    return fail("The archive has too many entries.", output)
                }
                guard pathIsInsideRoots(entry.path) else {
                    return fail("The archive contains a path outside WTF and Interface.", output)
                }
                let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
                guard seen.insert(key).inserted else {
                    return fail("The archive contains colliding paths.", output)
                }
                let destination = staging.appendingPathComponent(entry.path)
                guard inside(staging, destination) else {
                    return fail("The archive contains a path outside WTF and Interface.", output)
                }
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                guard let file = expected[entry.path], file.size == entry.uncompressedSize else {
                    return fail("The archive does not match its manifest.", output)
                }
                fileCount += 1
                total += entry.uncompressedSize
                guard entry.uncompressedSize <= fileLimit, total <= totalLimit else {
                    return fail("The archive exceeds the size limits.", output)
                }
                _ = try archive.extract(entry, to: destination)
                let written = try sha256(of: destination)
                guard written == file.sha256 else {
                    return fail("The archive failed its integrity check.", output)
                }
            }
            guard fileCount == manifest.files.count else {
                return fail("The archive does not match its manifest.", output)
            }
            return true
        } catch {
            output?.pointee = error as NSError
            return false
        }
    }

    private static func stagedRootsAreValid(_ staging: URL, _ output: NSErrorPointer) -> Bool {
        let contents: [String]
        do { contents = try FileManager.default.contentsOfDirectory(atPath: staging.path) }
        catch { return fail("The restored files could not be read.", output) }
        guard Set(contents) == Set(roots) else {
            return fail("The archive did not restore exactly WTF and Interface.", output)
        }
        return true
    }

    private static func swap(root: URL, staging: URL, recoveryWTF: URL, recoveryInterface: URL,
                             _ output: NSErrorPointer) -> Bool {
        let manager = FileManager.default
        let liveWTF = root.appendingPathComponent("WTF", isDirectory: true)
        let liveInterface = root.appendingPathComponent("Interface", isDirectory: true)
        do {
            if manager.fileExists(atPath: liveWTF.path) { try manager.moveItem(at: liveWTF, to: recoveryWTF) }
            if manager.fileExists(atPath: liveInterface.path) { try manager.moveItem(at: liveInterface, to: recoveryInterface) }
            try manager.moveItem(at: staging.appendingPathComponent("WTF"), to: liveWTF)
            try manager.moveItem(at: staging.appendingPathComponent("Interface"), to: liveInterface)
            return true
        } catch {
            fail("The restored settings could not be put in place.", output)
            return false
        }
    }

    private static func rollback(root: URL, recoveryWTF: URL, recoveryInterface: URL) {
        let manager = FileManager.default
        let liveWTF = root.appendingPathComponent("WTF", isDirectory: true)
        let liveInterface = root.appendingPathComponent("Interface", isDirectory: true)
        for (live, recovery) in [(liveWTF, recoveryWTF), (liveInterface, recoveryInterface)] {
            guard manager.fileExists(atPath: recovery.path) else { continue }
            try? manager.removeItem(at: live)
            try? manager.moveItem(at: recovery, to: live)
        }
    }

    // MARK: - Interrupted restore

    @objc(recoverInterruptedRestoreInWorkingDirectory:error:)
    static func recoverInterruptedRestore(inWorkingDirectory directory: String,
                                          error output: NSErrorPointer) -> Bool {
        guard let root = workingDirectory(directory, output) else { return false }
        let manager = FileManager.default
        let journalURL = root.appendingPathComponent(".wolkaraforever-ui-restore.json")
        guard manager.fileExists(atPath: journalURL.path) else {
            removeStaleRemnants(root)
            return true
        }
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.format == "wolkaraforever.ui.restore", journal.version == 1 else {
            try? manager.removeItem(at: journalURL)
            return true
        }
        let recoveryWTF = root.appendingPathComponent(journal.recoveryWTF, isDirectory: true)
        let recoveryInterface = root.appendingPathComponent(journal.recoveryInterface, isDirectory: true)
        let staging = root.appendingPathComponent(journal.staging, isDirectory: true)
        guard inside(root, recoveryWTF), inside(root, recoveryInterface), inside(root, staging) else {
            try? manager.removeItem(at: journalURL)
            return true
        }
        if manager.fileExists(atPath: recoveryWTF.path) || manager.fileExists(atPath: recoveryInterface.path) {
            // The swap did not finish. Put both roots back as they were: a
            // half-restored UI is worse than the one the user started with.
            rollback(root: root, recoveryWTF: recoveryWTF, recoveryInterface: recoveryInterface)
        }
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: journalURL)
        removeStaleRemnants(root)
        return true
    }

    private static func removeStaleRemnants(_ root: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".wolkaraforever-ui-restore-") || name.hasPrefix(".wolkaraforever-ui-old-") {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
