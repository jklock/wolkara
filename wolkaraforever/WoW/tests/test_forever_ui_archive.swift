import Foundation
import Darwin
import CryptoKit
import ZIPFoundation

// Focused tests for the Forever UI archive: the production writer and restorer
// in ForeverUIArchive.swift, against temporary trees. No game and no device.

private var checks = 0
private func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func read(_ url: URL) -> String? {
    String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8)
}

private func write(_ url: URL, _ text: String) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

private struct FileEntry: Codable { let path: String; let size: UInt64; let sha256: String }
private struct Manifest: Codable {
    let format: String; let version: Int; let edition: String
    let created: String; let entries: Int; let files: [FileEntry]
}
private struct Journal: Codable {
    let format: String; let version: Int
    let staging: String; let recoveryWTF: String; let recoveryInterface: String
}

// Builds an archive by hand, with any entry paths and manifest the caller wants,
// so the reader's refusals can be exercised.
private func forge(at url: URL, entries: [(String, Data)], manifestFiles: [(String, Data)]?,
                   edition: String = "wow_classic_beta", duplicateManifest: Bool = false) throws {
    try? FileManager.default.removeItem(at: url)
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in entries {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             permissions: 0o644, compressionMethod: .deflate) { position, count in
            let start = Int(position)
            guard start < data.count else { return Data() }
            return data.subdata(in: start..<min(start + count, data.count))
        }
    }
    let files = (manifestFiles ?? entries).map {
        FileEntry(path: $0.0, size: UInt64($0.1.count), sha256: sha($0.1))
    }
    var listed = files
    if duplicateManifest, let first = files.first { listed.append(first) }
    let manifest = Manifest(format: "wolkaraforever.ui.backup", version: 1, edition: edition,
                            created: "2026-10-21T00:00:00Z", entries: listed.count, files: listed)
    let data = try JSONEncoder().encode(manifest)
    try archive.addEntry(with: ".wolkaraforever-ui-manifest.json", type: .file,
                         uncompressedSize: Int64(data.count), permissions: 0o644,
                         compressionMethod: .deflate) { position, count in
        let start = Int(position)
        guard start < data.count else { return Data() }
        return data.subdata(in: start..<min(start + count, data.count))
    }
}

private func entryPaths(_ url: URL) -> Set<String> {
    do {
        let archive = try Archive(url: url, accessMode: .read)
        return Set(archive.map { $0.path })
    } catch {
        return []
    }
}

@main
struct ForeverUIArchiveTests {
    static func main() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("forever-ui-tests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: work) }
        let root = work.appendingPathComponent("_classic_beta_")
        let wtf = root.appendingPathComponent("WTF")
        let interface = root.appendingPathComponent("Interface")

        write(wtf.appendingPathComponent("Config.wtf"), "SET portal \"eu\"\nSET gxResolution \"1\"\n")
        write(wtf.appendingPathComponent("Account/ACC/SavedVariables/Addon.lua"), "-- saved\n")
        write(wtf.appendingPathComponent("Bindings-cache.wtf"), "bindings\n")
        write(wtf.appendingPathComponent("Backups/old.zip"), "old snapshot")
        write(wtf.appendingPathComponent("Cache/cache.bin"), "cache")
        write(wtf.appendingPathComponent("session.log"), "log")
        write(interface.appendingPathComponent("AddOns/A/A.toc"), "## Title: A\n")
        write(interface.appendingPathComponent("AddOns/A/a.lua"), "-- lua\n")

        // --- creation: a name, a manifest, and only UI state inside
        var error: NSError?
        guard let first = TKForeverUIArchive.createBackup(inWorkingDirectory: root.path,
                                                          edition: "wow_classic_beta", error: &error) else {
            check(false, "create: \(String(describing: error))"); return
        }
        check(first.hasPrefix("WoW-UI-") && first.hasSuffix(".zip"), "name shape: \(first)")
        let firstURL = wtf.appendingPathComponent("Backups/\(first)")
        check(manager.fileExists(atPath: firstURL.path), "archive is in WTF/Backups")
        let paths = entryPaths(firstURL)
        check(paths.contains("WTF/Config.wtf") && paths.contains("WTF/Account/ACC/SavedVariables/Addon.lua"),
              "UI state is archived")
        check(paths.contains("Interface/AddOns/A/A.toc"), "add-ons are archived")
        check(!paths.contains(where: { $0.hasPrefix("WTF/Backups") }), "backups are excluded")
        check(!paths.contains(where: { $0.hasPrefix("WTF/Cache") }), "cache is excluded")
        check(!paths.contains("WTF/session.log"), "logs are excluded")
        check(paths.contains(".wolkaraforever-ui-manifest.json"), "manifest is present")

        // --- two snapshots in one second still get distinct names
        guard let second = TKForeverUIArchive.createBackup(inWorkingDirectory: root.path,
                                                           edition: "wow_classic_beta", error: &error) else {
            check(false, "second create: \(String(describing: error))"); return
        }
        check(second != first, "collision-safe names: \(first) vs \(second)")
        guard let newestBefore = TKForeverUIArchive.newestBackup(inWorkingDirectory: root.path, error: &error) else {
            check(false, "newest: \(String(describing: error))"); return
        }
        check(newestBefore == second, "newest is the latest snapshot")

        // --- a newer file that is not a backup does not hide the real one
        try Data("not a zip".utf8).write(to: wtf.appendingPathComponent("Backups/WoW-UI-2999-01-01T00-00-00Z.zip"))
        guard let newestValid = TKForeverUIArchive.newestBackup(inWorkingDirectory: root.path, error: &error) else {
            check(false, "newest with a damaged candidate: \(String(describing: error))"); return
        }
        check(newestValid == second, "damaged newer ZIP is skipped")

        // --- restore puts the snapshot back and keeps every snapshot
        write(wtf.appendingPathComponent("Config.wtf"), "CHANGED\n")
        write(interface.appendingPathComponent("AddOns/New/New.toc"), "## Title: New\n")
        write(wtf.appendingPathComponent("Backups/keep.zip"), "another snapshot")
        check(TKForeverUIArchive.restoreBackup(named: first, inWorkingDirectory: root.path,
                                               edition: "wow_classic_beta", error: &error),
              "restore: \(String(describing: error))")
        check(read(wtf.appendingPathComponent("Config.wtf")) == "SET portal \"eu\"\nSET gxResolution \"1\"\n",
              "restored config")
        check(!manager.fileExists(atPath: interface.appendingPathComponent("AddOns/New").path),
              "an add-on added after the snapshot is gone")
        check(manager.fileExists(atPath: wtf.appendingPathComponent("Backups/keep.zip").path),
              "snapshots made after the backup survive the restore")
        check(manager.fileExists(atPath: wtf.appendingPathComponent("Backups/old.zip").path),
              "snapshots that existed at backup time survive too")
        check(read(interface.appendingPathComponent("AddOns/A/A.toc")) == "## Title: A\n", "add-on restored")

        // --- refusals leave the live UI untouched
        let before = read(wtf.appendingPathComponent("Config.wtf"))
        let bad = wtf.appendingPathComponent("Backups/WoW-UI-2000-01-01T00-00-00Z.zip")
        try forge(at: bad, entries: [("../outside.txt", Data("x".utf8))],
                  manifestFiles: [("../outside.txt", Data("x".utf8))], edition: "wow_classic_beta")
        check(!TKForeverUIArchive.restoreBackup(named: bad.lastPathComponent,
                                                inWorkingDirectory: root.path,
                                                edition: "wow_classic_beta", error: &error),
              "traversal entry is refused")
        check(!manager.fileExists(atPath: work.appendingPathComponent("outside.txt").path), "nothing escaped")
        check(read(wtf.appendingPathComponent("Config.wtf")) == before, "live UI unchanged after refusal")

        let duplicate = wtf.appendingPathComponent("Backups/WoW-UI-2000-01-02T00-00-00Z.zip")
        try forge(at: duplicate, entries: [("WTF/a.txt", Data("a".utf8))],
                  manifestFiles: [("WTF/a.txt", Data("a".utf8))], edition: "wow_classic_beta",
                  duplicateManifest: true)
        check(!TKForeverUIArchive.restoreBackup(named: duplicate.lastPathComponent,
                                                inWorkingDirectory: root.path,
                                                edition: "wow_classic_beta", error: &error),
              "duplicate manifest paths are refused")

        let wrongEdition = wtf.appendingPathComponent("Backups/WoW-UI-2000-01-03T00-00-00Z.zip")
        try forge(at: wrongEdition, entries: [("WTF/a.txt", Data("a".utf8))],
                  manifestFiles: [("WTF/a.txt", Data("a".utf8))], edition: "wow_classic_era")
        check(!TKForeverUIArchive.restoreBackup(named: wrongEdition.lastPathComponent,
                                                inWorkingDirectory: root.path,
                                                edition: "wow_classic_beta", error: &error),
              "another edition's archive is refused")

        let wrongDigest = wtf.appendingPathComponent("Backups/WoW-UI-2000-01-04T00-00-00Z.zip")
        try forge(at: wrongDigest, entries: [("WTF/a.txt", Data("a".utf8))],
                  manifestFiles: [("WTF/a.txt", Data("different".utf8))], edition: "wow_classic_beta")
        check(!TKForeverUIArchive.restoreBackup(named: wrongDigest.lastPathComponent,
                                                inWorkingDirectory: root.path,
                                                edition: "wow_classic_beta", error: &error),
              "a digest mismatch is refused")

        let oversized = wtf.appendingPathComponent("Backups/WoW-UI-2000-01-05T00-00-00Z.zip")
        try forge(at: oversized, entries: [("WTF/a.txt", Data("a".utf8))], manifestFiles: [],
                  edition: "wow_classic_beta")
        check(!TKForeverUIArchive.restoreBackup(named: oversized.lastPathComponent,
                                                inWorkingDirectory: root.path,
                                                edition: "wow_classic_beta", error: &error),
              "an archive that does not match its manifest is refused")

        // --- the writer refuses links and special files
        let target = wtf.appendingPathComponent("Config.wtf")
        let link = wtf.appendingPathComponent("Config-link.wtf")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        check(TKForeverUIArchive.createBackup(inWorkingDirectory: root.path,
                                              edition: "wow_classic_beta", error: &error) == nil,
              "a symlink stops a backup")
        try manager.removeItem(at: link)
        let fifo = wtf.appendingPathComponent("pipe")
        check(mkfifo(fifo.path, 0o600) == 0, "make a FIFO")
        check(TKForeverUIArchive.createBackup(inWorkingDirectory: root.path,
                                              edition: "wow_classic_beta", error: &error) == nil,
              "a special file stops a backup")
        try manager.removeItem(at: fifo)

        // --- an interrupted swap is rolled back at the next launch
        let recovery = work.appendingPathComponent("rollback/_classic_beta_")
        write(recovery.appendingPathComponent("WTF/marker"), "OLD")
        write(recovery.appendingPathComponent("Interface/marker"), "OLD")
        write(recovery.appendingPathComponent(".wolkaraforever-ui-old-WTF-1/marker"), "NEW")
        write(recovery.appendingPathComponent(".wolkaraforever-ui-old-Interface-1/marker"), "NEW")
        let journal = Journal(format: "wolkaraforever.ui.restore", version: 1,
                             staging: ".wolkaraforever-ui-restore-1",
                             recoveryWTF: ".wolkaraforever-ui-old-WTF-1",
                             recoveryInterface: ".wolkaraforever-ui-old-Interface-1")
        try JSONEncoder().encode(journal).write(to: recovery.appendingPathComponent(".wolkaraforever-ui-restore.json"))
        check(TKForeverUIArchive.recoverInterruptedRestore(inWorkingDirectory: recovery.path, error: &error),
              "recovery runs")
        check(read(recovery.appendingPathComponent("WTF/marker")) == "NEW", "the old WTF came back")
        check(read(recovery.appendingPathComponent("Interface/marker")) == "NEW", "the old Interface came back")
        check(!manager.fileExists(atPath: recovery.appendingPathComponent(".wolkaraforever-ui-old-WTF-1").path),
              "recovery directories are cleaned up")
        check(!manager.fileExists(atPath: recovery.appendingPathComponent(".wolkaraforever-ui-restore.json").path),
              "the journal is removed")

        // --- a completed swap only needs its journal cleaned up
        let complete = work.appendingPathComponent("complete/_classic_beta_")
        write(complete.appendingPathComponent("WTF/marker"), "RESTORED")
        let done = Journal(format: "wolkaraforever.ui.restore", version: 1,
                          staging: ".wolkaraforever-ui-restore-2",
                          recoveryWTF: ".wolkaraforever-ui-old-WTF-2",
                          recoveryInterface: ".wolkaraforever-ui-old-Interface-2")
        try JSONEncoder().encode(done).write(to: complete.appendingPathComponent(".wolkaraforever-ui-restore.json"))
        check(TKForeverUIArchive.recoverInterruptedRestore(inWorkingDirectory: complete.path, error: &error),
              "completed recovery runs")
        check(read(complete.appendingPathComponent("WTF/marker")) == "RESTORED", "a completed restore stays")
        check(!manager.fileExists(atPath: complete.appendingPathComponent(".wolkaraforever-ui-restore.json").path),
              "a completed journal is removed")

        print("FOREVER_UI_ARCHIVE_PASS: \(checks) checks: creation, exclusions, naming, validity, restore, retention, traversal, duplicates, editions, digests, links, special files and journal recovery.")
    }
}
