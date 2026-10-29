import EnteBridge
import Foundation

struct Input: Decodable {
    let endpoint: String
    let email: String
    let password: String
    let now_unix_ms: Int64
}

struct OutputCode: Encodable, Equatable {
    let issuer: String
    let current: String
    let next: String
    let kind: String
    let period_secs: UInt64
    let remaining_ms: UInt64
    let trashed: Bool

    init(_ code: CodeView) {
        issuer = code.issuer
        current = code.current
        next = code.next
        switch code.kind {
        case .totp: kind = "totp"
        case .steam: kind = "steam"
        case .hotp: kind = "hotp"
        }
        period_secs = code.periodSecs
        remaining_ms = code.remainingMs
        trashed = code.display.trashed
    }
}

enum SmokeError: Error {
    case unexpectedLoginStep
    case missingAuthenticatorKey
    case restartMismatch
    case displayMismatch
}

@main
struct Smoke {
    static func main() async throws {
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let config = Config(apiOrigin: input.endpoint, clientPackage: "io.ente.auth.menubar", userAgent: "ente-menubar-swift-smoke")
        let flow = try LoginFlow(config: config)
        guard case .password = try await flow.prepare(email: input.email) else {
            throw SmokeError.unexpectedLoginStep
        }
        guard case let .complete(session) = try await flow.submitPassword(password: input.password) else {
            throw SmokeError.unexpectedLoginStep
        }
        let vault = try Vault(config: config, session: session, cache: nil)
        guard try await vault.sync().hasAuthenticatorKey else {
            throw SmokeError.missingAuthenticatorKey
        }
        let codes = try vault.codes(nowUnixMs: input.now_unix_ms)
        guard let primary = codes.first(where: { $0.issuer == "RFC" }),
              primary.display.pinned,
              primary.display.tags == ["work", "comma, + # 😀"],
              primary.display.note == "literal%2C, + # 😀",
              primary.display.iconSrc == "custom", primary.display.iconId == "saved",
              primary.display.tapCount == 7, primary.display.lastUsedAt == 123456 else {
            throw SmokeError.displayMismatch
        }
        let restarted = try Vault(config: config, session: session, cache: vault.exportCache())
        guard restarted.email() == input.email else { throw SmokeError.restartMismatch }
        let output = codes.map(OutputCode.init).sorted { $0.issuer < $1.issuer }
        let restored = try restarted.codes(nowUnixMs: input.now_unix_ms).map(OutputCode.init).sorted { $0.issuer < $1.issuer }
        guard output == restored else { throw SmokeError.restartMismatch }
        let json = try JSONEncoder().encode(output)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data([10]))
    }
}
