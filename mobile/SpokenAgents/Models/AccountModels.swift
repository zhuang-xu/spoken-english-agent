import Foundation

struct NativeIdentity {
    let accountKey: String
    let token: String
}

enum AccountFailure: Error, Equatable {
    case signedOut, changed, configuration, invalidIdentity, bindingUnavailable
}
