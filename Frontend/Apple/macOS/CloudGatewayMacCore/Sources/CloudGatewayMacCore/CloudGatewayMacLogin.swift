import Foundation

public enum CloudGatewayMacLoginOrigin: String, Codable, Sendable {
    case menu, cli
}

public struct CloudGatewayMacLoginStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case restoring, requestingCode, waitingForApproval, exchangingToken, finished
    }

    public enum Result: String, Codable, Sendable {
        case authorized, busy, cancelled, expired, denied, unavailable, invalidResponse, offline, signInRequired
    }

    public struct Challenge: Codable, Equatable, Sendable {
        public let userCode: String
        public let verificationURL: URL
        public let remainingSeconds: Int

        public init(userCode: String, verificationURL: URL, remainingSeconds: Int) {
            self.userCode = userCode
            self.verificationURL = verificationURL
            self.remainingSeconds = remainingSeconds
        }
    }

    public let attemptId: UUID
    public let origin: CloudGatewayMacLoginOrigin
    public let phase: Phase
    public let challenge: Challenge?
    public let result: Result?

    public init(attemptId: UUID, origin: CloudGatewayMacLoginOrigin, phase: Phase,
                challenge: Challenge? = nil, result: Result? = nil) {
        self.attemptId = attemptId
        self.origin = origin
        self.phase = phase
        self.challenge = challenge
        self.result = result
    }
}
