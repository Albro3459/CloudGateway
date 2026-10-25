import CloudGatewayMacCore
import Foundation
import Testing
@testable import CloudGatewayMacControllerIPC

@MainActor
private final class RequestReceiptStore {
    enum Failure: Error { case write }

    var now = Date(timeIntervalSince1970: 1_000)
    var data: Data?
    var failWrites = false
    var writes = 0

    func make() throws -> CloudGatewayMacControllerRequests {
        try CloudGatewayMacControllerRequests(data: data, now: { self.now }) { data in
            self.writes += 1
            if self.failWrites { throw Failure.write }
            self.data = data
        }
    }
}

@MainActor
@Test func controllerRequestsStopSurvivesFullDurableReceiptsAndWriteFailure() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    for _ in 0..<64 {
        let request = CloudGatewayMacControllerRequest(action: .signIn)
        _ = try requests.accept(request)
        requests.finish(id: request.id, state: .completed)
    }
    let durableData = store.data
    let writes = store.writes
    store.failWrites = true
    let stop = CloudGatewayMacControllerRequest(action: .turnOff)
    #expect(try requests.accept(stop).state == .accepted)
    #expect(try requests.lookup(stop)?.state == .accepted)
    #expect(requests.finish(id: stop.id, state: .running).state == .running)
    #expect(requests.finish(id: stop.id, state: .completed).state == .completed)
    #expect(requests.operation(id: stop.id).state == .completed)
    #expect(requests.latest?.id == stop.id)
    #expect(store.writes == writes)
    #expect(store.data == durableData)
    #expect(throws: CloudGatewayMacControllerFailure.unavailable) {
        try requests.accept(.init(action: .signIn))
    }
}

@MainActor
@Test func controllerRequestsFailedAdmissionDoesNotConsumeFinalDurableSlot() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    for _ in 0..<63 { _ = try requests.accept(.init(action: .signIn)) }
    let previous = requests.latest
    let durableData = store.data
    let request = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/client")
    store.failWrites = true
    #expect(throws: RequestReceiptStore.Failure.self) { try requests.accept(request) }
    #expect(try requests.lookup(request) == nil)
    #expect(requests.latest == previous)
    #expect(store.data == durableData)
    store.failWrites = false
    #expect(try requests.accept(request).state == .accepted)
    #expect(try requests.lookup(request)?.id == request.id)
    #expect(throws: CloudGatewayMacControllerFailure.unavailable) {
        try requests.accept(.init(action: .signIn))
    }
}

@MainActor
@Test(arguments: [CloudGatewayMacControllerOperation.State.accepted, .running])
func controllerRequestsReconstructionMarksUnfinishedWorkUnknown(state: CloudGatewayMacControllerOperation.State) throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    let request = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/client")
    _ = try requests.accept(request)
    if state == .running { requests.finish(id: request.id, state: state) }
    let restored = try store.make()
    #expect(try restored.lookup(request)?.state == .unknown)
    #expect(restored.operation(id: request.id).state == .unknown)
    #expect(restored.latest == nil)
}

@MainActor
@Test func controllerRequestsKnownOutcomeSurvivesWriteFailureUntilReceiptExpires() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    let request = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/client")
    _ = try requests.accept(request)
    requests.finish(id: request.id, state: .running)
    store.failWrites = true
    let writes = store.writes
    #expect(requests.finish(id: request.id, state: .completed).state == .completed)
    #expect(try requests.lookup(request)?.state == .completed)
    #expect(store.writes == writes)
    let restored = try store.make()
    #expect(try restored.lookup(request)?.state == .unknown)
    store.now.addTimeInterval(600)
    #expect(try restored.lookup(request) == nil)
    #expect(restored.operation(id: request.id).state == .unknown)
}

@MainActor
@Test func controllerRequestsRejectIdentifierReuseWithChangedPayload() throws {
    let requests = try RequestReceiptStore().make()
    let id = UUID()
    _ = try requests.accept(.init(action: .connect, id: id, identifier: "account/region/first"))
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try requests.lookup(.init(action: .connect, id: id, identifier: "account/region/second"))
    }
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try requests.accept(.init(action: .turnOff, id: id))
    }
    let stopId = UUID()
    _ = try requests.accept(.init(action: .turnOff, id: stopId))
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try requests.lookup(.init(action: .turnOff, id: stopId, identifier: "account/region/first"))
    }
}

@MainActor
@Test func controllerRequestsDoNotPersistResultsOrStopState() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    let command = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/client")
    _ = try requests.accept(command)
    requests.finish(id: command.id, state: .completed)
    let stop = CloudGatewayMacControllerRequest(action: .turnOff)
    _ = try requests.accept(stop)
    requests.finish(id: stop.id, state: .unknown)
    #expect(try requests.lookup(stop) == nil)
    #expect(try requests.accept(stop).state == .accepted)
    let data = try #require(store.data)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("completed"))
    #expect(!text.contains("connect"))
    #expect(!text.contains("account/region/client"))
    #expect(!text.contains(stop.id.uuidString))
    let restored = try store.make()
    #expect(restored.latest == nil)
    #expect(restored.operation(id: command.id).state == .unknown)
    #expect(restored.operation(id: stop.id).state == .unknown)
}

@MainActor
@Test func controllerRequestsRetainOnlyLatestResultWithoutLosingAntiReplayReceipts() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    let first = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/first")
    let second = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/second")
    _ = try requests.accept(first)
    requests.finish(id: first.id, state: .completed)
    _ = try requests.accept(second)
    requests.finish(id: second.id, state: .completed)
    #expect(requests.operation(id: first.id).state == .unknown)
    #expect(try requests.lookup(first)?.state == .unknown)
    #expect(requests.operation(id: second.id).state == .completed)
    #expect(requests.latest?.id == second.id)
    #expect(requests.finish(id: first.id, state: .failed).state == .unknown)
    #expect(requests.latest?.id == second.id)
}

@MainActor
@Test(arguments: [false, true], [false, true])
func controllerRequestsKeepCreationAndStopResultsIndependent(stopFirst: Bool, creationFinishesFirst: Bool) throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    var sessions = CloudGatewayMacSessionFence()
    sessions.changeAccount(to: "account")
    let session = sessions.currentToken
    let add = CloudGatewayMacControllerRequest(action: .createClient, regionId: "region", clientName: "Mac", contextId: UUID())
    let stop = CloudGatewayMacControllerRequest(action: .disconnectClient, identifier: "account/region/client")
    for request in stopFirst ? [stop, add] : [add, stop] {
        #expect(try requests.accept(request).state == .accepted)
        requests.finish(id: request.id, state: .running)
    }
    let first = creationFinishesFirst ? add : stop
    let second = creationFinishesFirst ? stop : add
    requests.finish(id: first.id, state: .completed, outcome: .completed(warning: nil), session: session)
    #expect(requests.operation(id: second.id).state == .running)
    store.now.addTimeInterval(601)
    #expect(requests.operation(id: first.id).state == .unknown)
    #expect(requests.latest?.id == second.id)
    requests.finish(id: second.id, state: .completed, outcome: .completed(warning: nil), session: session)
    #expect(try requests.lookup(second)?.state == .completed)
    #expect(requests.outcome(id: second.id, session: session) == .completed(warning: nil))
    sessions.changeAccount(to: "other")
    #expect(requests.outcome(id: second.id, session: sessions.currentToken) == nil)
    store.now.addTimeInterval(600)
    #expect(requests.latest == nil)
}

@MainActor
@Test(arguments: [false, true])
func controllerRequestsRejectCrossSlotIdentifierCollisions(stopFirst: Bool) throws {
    let requests = try RequestReceiptStore().make()
    let id = UUID()
    let add = CloudGatewayMacControllerRequest(action: .createClient, id: id, regionId: "region", clientName: "Mac", contextId: UUID())
    let stop = CloudGatewayMacControllerRequest(action: .turnOff, id: id)
    let first = stopFirst ? stop : add
    let second = stopFirst ? add : stop
    _ = try requests.accept(first)
    for state in [CloudGatewayMacControllerOperation.State.accepted, .running, .completed] {
        requests.finish(id: id, state: state)
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) { try requests.lookup(second) }
        #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) { try requests.accept(second) }
        #expect(requests.operation(id: id).state == state)
    }
}

@MainActor
@Test func controllerRequestsStopDoesNotEraseCreationWhenDurableStorageIsFullOrUnavailable() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    let add = CloudGatewayMacControllerRequest(action: .createClient, regionId: "region", clientName: "Mac", contextId: UUID())
    _ = try requests.accept(add)
    requests.finish(id: add.id, state: .running)
    for _ in 0..<63 {
        let request = CloudGatewayMacControllerRequest(action: .signIn)
        _ = try requests.accept(request)
        requests.finish(id: request.id, state: .completed)
    }
    store.failWrites = true
    let stop = CloudGatewayMacControllerRequest(action: .turnOff)
    #expect(try requests.accept(stop).state == .accepted)
    requests.finish(id: stop.id, state: .completed, outcome: .completed(warning: nil))
    #expect(try requests.lookup(add)?.state == .running)
    #expect(requests.operation(id: stop.id).state == .completed)
    let restored = try store.make()
    #expect(try restored.lookup(add)?.state == .unknown)
    #expect(try restored.lookup(stop) == nil)
}
