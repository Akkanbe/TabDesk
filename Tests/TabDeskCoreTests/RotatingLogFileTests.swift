import Foundation
import Testing
import TabDeskCore

struct RotatingLogFileTests {
    private func withLog(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("test.log"))
    }

    @Test func exactLimitDoesNotRotateAndOnlyThreeBackupsRemain() throws {
        try withLog { url in
            let log = RotatingLogFile(fileURL: url, maxBytes: 8)
            try log.append("aaaa")
            try log.append("bbbb")
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
            for digit in 1...4 { try log.append(String(repeating: String(digit), count: 8)) }
            #expect(try String(contentsOf: url, encoding: .utf8) == "44444444")
            #expect(try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8) == "33333333")
            #expect(try String(contentsOf: url.appendingPathExtension("2"), encoding: .utf8) == "22222222")
            #expect(try String(contentsOf: url.appendingPathExtension("3"), encoding: .utf8) == "11111111")
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("4").path))
        }
    }

    @Test func restartRotatesExistingOversizedFile() throws {
        try withLog { url in
            try Data(repeating: 65, count: 100).write(to: url)
            try RotatingLogFile(fileURL: url, maxBytes: 8).append("new")
            #expect(try Data(contentsOf: url.appendingPathExtension("1")).count == 100)
            #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        }
    }

    @Test func oversizedUnicodeEntryIsBoundedAndRemainsUTF8() throws {
        try withLog { url in
            try RotatingLogFile(fileURL: url, maxBytes: 64).append(String(repeating: "日本語😀", count: 100))
            let data = try Data(contentsOf: url)
            #expect(data.count <= 64)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("[log entry truncated]"))
        }
    }

    @Test func rotationFailurePreservesCurrentLogAndRecovers() throws {
        try withLog { url in
            let log = RotatingLogFile(fileURL: url, maxBytes: 8)
            try log.append("12345678")
            let obstacle = url.appendingPathExtension("3")
            try FileManager.default.createDirectory(at: obstacle, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try log.append("new") }
            #expect(try String(contentsOf: url, encoding: .utf8) == "12345678")
            #expect(FileManager.default.fileExists(atPath: obstacle.path))
            try FileManager.default.removeItem(at: obstacle)
            try log.append("new")
            #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        }
    }

    @Test func concurrentAppendsDoNotLoseOrInterleaveLines() throws {
        try withLog { url in
            let log = RotatingLogFile(fileURL: url)
            let errors = Locked<[String]>([])
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                do { try log.append("line-\(index)\n") }
                catch { errors.withValue { $0.append(String(describing: error)) } }
            }
            #expect(errors.current.isEmpty)
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(lines.count == 100)
            #expect(Set(lines) == Set((0..<100).map { "line-\($0)" }))
        }
    }
}
