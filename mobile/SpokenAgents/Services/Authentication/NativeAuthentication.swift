import Foundation

@MainActor protocol NativeAuthentication {
    func cachedAccountKeys() throws -> [String]
    func acquireSilently(accountKey: String) async throws -> NativeIdentity
    func acquireInteractively() async throws -> NativeIdentity
    func remove(accountKey: String) throws
}
