import Foundation

enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case running
    case waiting
    case idle
    case error
    case none
}
