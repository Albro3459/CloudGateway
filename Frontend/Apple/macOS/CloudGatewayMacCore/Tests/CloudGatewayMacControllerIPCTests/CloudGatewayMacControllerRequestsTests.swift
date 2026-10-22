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
@Test func controllerRequestsFailedOutcomeWritePreventsReplayUntilReceiptExpires() throws {
    let store = RequestReceiptStore()
    let requests = try store.make()
    let request = CloudGatewayMacControllerRequest(action: .connect, identifier: "account/region/client")
    _ = try requests.accept(request)
    requests.finish(id: request.id, state: .running)
    store.failWrites = true
    #expect(requests.finish(id: request.id, state: .completed).state == .unknown)
    #expect(try requests.lookup(request)?.state == .unknown)
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
    _ = try requests.accept(.init(action: .turnOff, id: id))
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try requests.lookup(.init(action: .turnOff, id: id, identifier: "account/region/first"))
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
