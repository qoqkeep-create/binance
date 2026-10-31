import Foundation

struct APIEnvelope<Payload: Decodable>: Decodable {
    let code: String?
    let message: String?
    let data: Payload?
    let isSuccess: Bool

    private enum CodingKeys: String, CodingKey {
        case code
        case success
        case message
        case msg
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        code = Self.decodeCode(from: container)
        let success = try container.decodeIfPresent(
            Bool.self,
            forKey: .success
        )
        message = try container.decodeIfPresent(
            String.self,
            forKey: .message
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .msg
        )

        isSuccess = Self.evaluateSuccess(code: code, success: success)

        if isSuccess {
            data = try container.decodeIfPresent(
                Payload.self,
                forKey: .data
            )
        } else {
            data = nil
        }
    }

    private static func decodeCode(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        if let stringCode = try? container.decodeIfPresent(
            String.self,
            forKey: .code
        ) {
            return stringCode
        }

        if let integerCode = try? container.decodeIfPresent(
            Int.self,
            forKey: .code
        ) {
            return String(integerCode)
        }

        return nil
    }

    private static func evaluateSuccess(
        code: String?,
        success: Bool?
    ) -> Bool {
        if let success {
            return success
        }

        guard let code else {
            return true
        }

        return ["0", "200", "OK", "SUCCESS"].contains(
            code.uppercased()
        )
    }
}
