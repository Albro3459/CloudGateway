import CloudGatewayMacCore
import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

@Test func loginRequestsRequireAttemptAndOriginAndDoNotReserveVPNOperations() throws {
    let id = UUID()
    let begin = CloudGatewayMacControllerRequest(action: .beginLogin, id: id, loginOrigin: .cli)
    let encoded = try CloudGatewayMacControllerProtocol.encodeRequest(begin, appVersion: "1", appBuild: "1")
    let decoded = try CloudGatewayMacControllerProtocol.decodeRequest(encoded, appVersion: "1", appBuild: "1")
    #expect(decoded.id == id)
    #expect(decoded.loginOrigin == .cli)
    #expect(!decoded.action.requiresConfirmation)
    for action in [CloudGatewayMacControllerRequest.Action.loginStatus, .cancelLogin] {
        let request = CloudGatewayMacControllerRequest(action: action, contextId: id)
        _ = try CloudGatewayMacControllerProtocol.encodeRequest(request, appVersion: "1", appBuild: "1")
        #expect(!action.requiresConfirmation)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
            try CloudGatewayMacControllerProtocol.encodeRequest(.init(action: action), appVersion: "1", appBuild: "1")
        }
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.encodeRequest(.init(action: .beginLogin), appVersion: "1", appBuild: "1")
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerProtocol.encodeRequest(.init(action: .snapshot, loginOrigin: .menu), appVersion: "1", appBuild: "1")
    }
}

@Test func loginReplyKeepsApprovalDataOutsideCompatibleStatusAndOperationRecords() throws {
    let id = UUID()
    let url = URL(string: "https://gocloudlaunch.com/#/auth/code?deviceRequestId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&userCode=000012")!
    let status = CloudGatewayMacLoginStatus(attemptId: id, origin: .cli, phase: .waitingForApproval,
                                          challenge: .init(userCode: "000012", verificationURL: url, remainingSeconds: 100))
    let data = CloudGatewayMacControllerProtocol.encodeReply(.init(login: status), appVersion: "1", appBuild: "1",
                                                             instanceId: UUID(), action: .loginStatus)
    let reply = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: "1", appBuild: "1", action: .loginStatus)
    #expect(reply.login == status)
    #expect(reply.operation == nil)
    let prohibited = CloudGatewayMacControllerProtocol.encodeReply(.init(login: status), appVersion: "1", appBuild: "1",
                                                                   instanceId: UUID(), action: .status)
    let rejected = try CloudGatewayMacControllerProtocol.decodeReply(prohibited, appVersion: "1", appBuild: "1", action: .status)
    #expect(rejected.error == .invalidRequest)
    #expect(!String(decoding: prohibited, as: UTF8.self).contains("000012"))
}

@Test func loginReplyRejectsMalformedChallengeAndInconsistentTerminalPhase() throws {
    for status in [
        CloudGatewayMacLoginStatus(attemptId: UUID(), origin: .cli, phase: .finished),
        .init(attemptId: UUID(), origin: .cli, phase: .requestingCode, result: .authorized),
        .init(attemptId: UUID(), origin: .cli, phase: .waitingForApproval),
        .init(attemptId: UUID(), origin: .cli, phase: .waitingForApproval,
              challenge: .init(userCode: "000012\n", verificationURL: URL(string: "https://gocloudlaunch.com/")!, remainingSeconds: 100)),
    ] {
        let data = CloudGatewayMacControllerProtocol.encodeReply(.init(login: status), appVersion: "1", appBuild: "1",
                                                                 instanceId: UUID(), action: .loginStatus)
        #expect(try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: "1", appBuild: "1", action: .loginStatus).error == .invalidRequest)
    }
}
