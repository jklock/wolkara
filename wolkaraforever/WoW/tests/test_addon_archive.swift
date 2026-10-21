import Foundation

@_silgen_name("TestRealAddonImport")
func testImport(_ fixtures: UnsafePointer<CChar>, _ temporary: UnsafePointer<CChar>) -> Int32

@main
struct ArchiveTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let extracted = ["valid", "nested", "special-file"]
        let tocPath = ["valid": "Fixture/Fixture.toc", "nested": "Wrapper/Fixture/Fixture.toc", "special-file": "Fixture/Fixture.toc"]
        for name in ["valid", "nested", "special-file", "traversal", "absolute", "double", "dot", "colon", "control", "case", "unicode", "symlink", "corrupt", "invalid", "file-directory", "oversized-file", "too-many", "lying-size"] {
            let output = work.appendingPathComponent(name)
            var error: NSError?
            let ok = TKAddonArchive.extract(archiveURL: root.appendingPathComponent(name + ".zip"), to: output, error: &error)
            let expected = extracted.contains(name)
            check(ok == expected, "\(name): expected \(expected), got \(ok), error \(String(describing: error))")
            if expected {
                let contents = try String(contentsOf: output.appendingPathComponent(tocPath[name]!), encoding: .utf8)
                check(contents.contains("## Title: WolkaraForever Fixture"), "\(name): bytes round trip")
            } else {
                check(error != nil, "\(name): reports the failure")
                check(!FileManager.default.fileExists(atPath: output.path), "\(name): no partial extraction")
            }
        }
        // The entry that says it is a FIFO is an ordinary file on disk.
        let special = try work.appendingPathComponent("special-file/Fixture/fifo").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        check(special.isRegularFile == true && special.isSymbolicLink != true, "a FIFO entry lands as a regular file")
        // A header that under-reports its size passes every declared-size check, so what has
        // to refuse it is the count of bytes that actually came out - and it must refuse it
        // before any of it is on disk.
        var lying: NSError?
        let lyingDestination = work.appendingPathComponent("lying-size-again")
        check(!TKAddonArchive.extract(archiveURL: root.appendingPathComponent("lying-size.zip"), to: lyingDestination, error: &lying), "a lying size header is refused")
        check(lying?.localizedDescription.contains("expands past") == true, "because it expands past what it declares, got: \(String(describing: lying))")
        check(!FileManager.default.fileExists(atPath: lyingDestination.path), "and nothing of it was written")
        // A caller's existing directory must never be removed on extraction failure.
        let existing = work.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        var error: NSError?
        check(!TKAddonArchive.extract(archiveURL: root.appendingPathComponent("file-directory.zip"), to: existing, error: &error), "existing destination refused")
        check(FileManager.default.fileExists(atPath: sentinel.path), "existing data preserved")
        let importResult = root.path.withCString { fixtures in
            work.appendingPathComponent("import").path.withCString { temporary in testImport(fixtures, temporary) }
        }
        check(importResult == 0, "real import lifecycle")
        print("ADDON ARCHIVE PASS: \(checks) checks, production Swift and pinned ZIPFoundation")
    }
}
