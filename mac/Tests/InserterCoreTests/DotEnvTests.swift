import XCTest
@testable import InserterCore

final class DotEnvTests: XCTestCase {
    func testParsesKeyValueLines() {
        let env = DotEnv.parse("""
        # comment
        A=1
        export B = two
        C="three words"
        D='x y'
        E=

        not a line
        1BAD=x
        """)
        XCTAssertEqual(env["A"], "1")
        XCTAssertEqual(env["B"], "two")
        XCTAssertEqual(env["C"], "three words")
        XCTAssertEqual(env["D"], "x y")
        XCTAssertEqual(env["E"], "")
        XCTAssertNil(env["1BAD"])
        XCTAssertEqual(env.count, 5)
    }

    func testPortPrecedenceIsFlagThenEnvironmentThenFile() {
        let name = DotEnv.portVariable
        XCTAssertEqual(try DotEnv.port(flag: "4001", environment: [name: "4002"], dotEnv: [name: "4003"]).get(), 4001)
        XCTAssertEqual(try DotEnv.port(flag: nil, environment: [name: "4002"], dotEnv: [name: "4003"]).get(), 4002)
        XCTAssertEqual(try DotEnv.port(flag: nil, environment: [name: ""], dotEnv: [name: "4003"]).get(), 4003)
    }

    func testNoPortAnywhereMeansTheDefaultSoAFreshCheckoutNeedsNoEnvFile() {
        XCTAssertEqual(DotEnv.port(flag: nil, environment: [:], dotEnv: [:]), .success(UInt16(InserterDefaults.port)))
        XCTAssertEqual(DotEnv.port(flag: nil, environment: [DotEnv.portVariable: ""], dotEnv: [:]), .success(UInt16(InserterDefaults.port)))
    }

    func testInvalidPortsAreReported() {
        XCTAssertEqual(DotEnv.port(flag: "abc", environment: [:], dotEnv: [:]), .failure(.invalid("abc")))
        XCTAssertEqual(DotEnv.port(flag: "0", environment: [:], dotEnv: [:]), .failure(.invalid("0")))
        XCTAssertEqual(DotEnv.port(flag: "70000", environment: [:], dotEnv: [:]), .failure(.invalid("70000")))
        XCTAssertTrue(PortError.invalid("abc").description.contains("abc"))
    }

    func testFindsTheNearestEnvAboveADirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dotenv-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "\(DotEnv.portVariable)=4100\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DotEnv.load(from: deep)[DotEnv.portVariable], "4100")
        try "\(DotEnv.portVariable)=4200\n".write(to: root.appendingPathComponent("a/.env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DotEnv.load(from: deep)[DotEnv.portVariable], "4200")
    }
}
