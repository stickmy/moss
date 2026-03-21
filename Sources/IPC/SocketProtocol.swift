import Foundation

struct IPCCommand: Codable {
    let surfaceId: String
    let command: String
    let value: String?

    enum CodingKeys: String, CodingKey {
        case surfaceId = "surface_id"
        case command
        case value
    }
}

struct IPCResponse: Codable {
    let success: Bool
    let message: String
}
