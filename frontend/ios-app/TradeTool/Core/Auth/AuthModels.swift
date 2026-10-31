import Foundation

struct AuthUser: Codable, Equatable {
    let id: String
    let email: String
    let displayName: String
    let canViewReferenceNotifications: Bool?
    var isAdmin: Bool? = nil
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let user: AuthUser
}

struct LoginRequestBody: Encodable {
    let agreed = true
    let account: String
    let password: String
}

struct RegisterRequestBody: Encodable {
    let agreed = true
    var confirm_password: String { password }
    enum CodingKeys: String, CodingKey { case account, password, agreed, confirm_password }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account); try c.encode(password, forKey: .password)
        try c.encode(agreed, forKey: .agreed); try c.encode(password, forKey: .confirm_password)
    }
    let account: String
    let password: String
}
