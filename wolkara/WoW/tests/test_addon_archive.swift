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
        for name in ["valid", "nested", "traversal", "absolute", "double", "dot", "colon", "control", "case", "unicode", "symlink", "corrupt", "invalid", "file-directory", "oversized-file", "too-many"] {
            let output = work.appendingPathComponent(name)
            var error: NSError?
            let ok = TKAddonArchive.extract(archiveURL: root.appendingPathComponent(name + ".zip"), to: output, error: &error)
            let expected = name == "valid" || name == "nested"
            check(ok == expected, "\(name): expected \(expected), got \(ok), error \(String(describing: error))")
            if expected {
                let path = name == "valid" ? "Fixture/Fixture.toc" : "Wrapper/Fixture/Fixture.toc"
                let contents = try String(contentsOf: output.appendingPathComponent(path), encoding: .utf8)
                check(contents.contains("## Title: Wolkara Fixture"), "\(name): bytes round trip")
            } else {
                check(error != nil, "\(name): reports the failure")
                check(!FileManager.default.fileExists(atPath: output.path), "\(name): no partial extraction")
            }
        }
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
