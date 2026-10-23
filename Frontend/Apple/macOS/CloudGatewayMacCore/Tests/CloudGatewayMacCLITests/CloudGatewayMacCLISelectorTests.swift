import Foundation
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

private let firstUUID = "78ab8633-ae25-4287-885f-57bbbf6e7f63"
private let secondUUID = "4830b738-2823-4888-bf37-2918ae356ad5"
private let thirdUUID = "d1482e58-5202-4771-82ae-bb34a313c537"
private let firstConfig = "uid1/us-sanjose-1/" + firstUUID
private let secondConfig = "uid1/us-sanjose-1/" + secondUUID
private let thirdConfig = "uid1/us-chicago-1/" + thirdUUID

private func selectorState() -> CloudGatewayMacControllerState {
    cliState(clients: [
        cliClient(thirdConfig, regionName: "Chicago", order: 2, name: "Mac", owner: "owner@example.com"),
        cliClient(secondConfig, regionName: "California", order: 1, name: "Laptop", owner: "b@example.com",
                  ip: "10.0.0.3", connectionUrl: "192.0.2.10"),
        cliClient(firstConfig, regionName: "California", order: 1, name: "Desktop", owner: "a@example.com",
                  ip: "10.0.0.2", connectionUrl: "wg.us-sanjose-1.example.com", eligibility: .inactive),
    ], selected: secondConfig)
}

@MainActor
private func inventoryConfigs(_ harness: CLIHarness) throws -> [[String: Any]] {
    let data = try #require(harness.json?["data"] as? [String: Any])
    let regions = try #require(data["regions"] as? [[String: Any]])
    return try regions.flatMap { try #require($0["configs"] as? [[String: Any]]) }
}

@Test func cliParserSharesListAliasesAndParsesBothSelectorForms() throws {
    for alias in ["list", "ls"] {
        for flag in ["-l", "--long"] {
            let invocation = try CloudGatewayMacCLIParser.parse([alias, flag, "--region", "San Jose", "--refresh", "--json"])
            guard case .run(let command) = invocation.action else { Issue.record("Expected list"); return }
            #expect(command == .list(regionId: "San Jose", refresh: true, long: true))
            #expect(command.name == "list")
            #expect(invocation.isJSON)
        }
        for args in [["help", alias], [alias, "--help"]] {
            guard case .help(let topic) = try CloudGatewayMacCLIParser.parse(args).action else {
                Issue.record("Expected list help"); return
            }
            #expect(topic.name == "list")
        }
    }
    for name in ["up", "down"] {
        for operands in [[firstUUID.uppercased()], ["Chicago", "01"], ["San Jose", "2"]] {
            let invocation = try CloudGatewayMacCLIParser.parse([name] + operands)
            guard case .run(let command) = invocation.action else { Issue.record("Expected selector"); return }
            let selector: CloudGatewayMacCLISelector = operands.count == 1
                ? .client(UUID(uuidString: firstUUID)!) : .region(operands[0], index: Int(operands[1])!)
            #expect(command == (name == "up" ? .up(selector: selector) : .downTarget(selector)))
        }
        for operands in [["1"], [firstConfig], ["chicago", "0"], ["chicago", "-1"], ["chicago", "1.0"],
                         ["chicago", "+1"], ["chicago", "1e2"], ["chicago", "١"],
                         ["chicago", String(repeating: "9", count: 40)], ["chicago", "1", "extra"]] {
            #expect(throws: CloudGatewayMacCLIUsageFailure.self) {
                try CloudGatewayMacCLIParser.parse([name] + operands)
            }
        }
    }
    for args in [["status", "-l"], ["up", "--long"], ["version", "extra"], ["version", "-v"],
                 ["list", "-v"], ["down", "--version"], ["help", "version", "--long"]] {
        #expect(throws: CloudGatewayMacCLIUsageFailure.self) { try CloudGatewayMacCLIParser.parse(args) }
    }
}

@MainActor
@Test func cliAllVersionAliasesStayLocalAndProduceIdenticalRecords() async {
    for isJSON in [false, true] {
        var outputs: [String] = []
        for alias in ["version", "--version", "-v"] {
            let harness = CLIHarness()
            #expect(await harness.run([alias] + (isJSON ? ["--json"] : [])) == 0)
            outputs.append(harness.output)
            #expect(harness.connects == 0)
            #expect(harness.actions.isEmpty)
        }
        #expect(Set(outputs).count == 1)
    }
    for args in [["version", "--help"], ["help", "version"], ["-v", "--help"]] {
        let harness = CLIHarness()
        #expect(await harness.run(args) == 0)
        #expect(harness.output.contains("Show the app version and build" ) || harness.output.contains("Control the CloudGateway VPN"))
        #expect(harness.connects == 0)
    }
    let invalid = CLIHarness()
    #expect(await invalid.run("--bogus", "ls", "--json") == 2)
    #expect(invalid.json?["command"] as? String == "list")
    #expect(invalid.connects == 0)
}

@MainActor
@Test func cliListsUseUUIDsAndIdenticalOrderingAcrossLayoutsAndJSON() async throws {
    let state = selectorState()
    let short = CLIHarness(state)
    #expect(await short.run("ls") == 0)
    #expect(short.output.contains("  1  Desktop (a@example.com)"))
    #expect(short.output.contains("  2  Laptop (b@example.com)"))
    #expect(short.output.contains("Chicago (us-chicago-1)\n  1  Mac"))
    #expect(!short.output.contains("uid1/"))
    #expect(!short.output.contains("10.0.0."))
    #expect(!short.output.contains("wg.us-sanjose-1"))
    let long = CLIHarness(state)
    #expect(await long.run("list", "--long") == 0)
    #expect(long.output.contains("  1  Desktop  inactive"))
    #expect(long.output.contains("  2  Laptop  selected"))
    #expect(long.output.contains("VPN id:          " + firstUUID))
    #expect(long.output.contains("Tunnel IP:       10.0.0.2\n"))
    #expect(long.output.contains("Connection URL:  wg.us-sanjose-1.example.com"))
    #expect(long.output.contains("Connection URL:  192.0.2.10"))
    #expect(!long.output.contains("/32"))
    #expect(!long.output.contains("uid1/"))
    var outputs: [String] = []
    for args in [["list", "--json"], ["ls", "-l", "--json"], ["list", "--long", "--json"]] {
        let harness = CLIHarness(state)
        #expect(await harness.run(args) == 0)
        outputs.append(harness.output)
        let configs = try inventoryConfigs(harness)
        #expect(configs.compactMap { $0["clientId"] as? String } == [firstUUID, secondUUID, thirdUUID])
        #expect(configs.compactMap { $0["configId"] as? String } == [firstConfig, secondConfig, thirdConfig])
        #expect(configs.compactMap { $0["index"] as? Int } == [1, 2, 1])
        #expect(configs.first?["internalIp"] as? String == "10.0.0.2")
        #expect(configs.first?["connectionUrl"] as? String == "wg.us-sanjose-1.example.com")
    }
    #expect(Set(outputs).count == 1)
    let choices = CloudGatewayMacCLIInventory(state, accountId: "uid1", regionId: nil, eligibleOnly: true)
    #expect(choices.regions[0].configs.map(\.index) == [2])
    #expect(choices.regions[1].configs.map(\.index) == [1])
    let uuidSelector = CloudGatewayMacCLISelector.client(try #require(UUID(uuidString: secondUUID.uppercased())))
    #expect(try CloudGatewayMacCLIInventoryOrder.resolve(uuidSelector, state: state, accountId: "uid1") == secondConfig)
    #expect(try CloudGatewayMacCLIInventoryOrder.resolve(.region("sanjose", index: 2), state: state, accountId: "uid1") == secondConfig)
    #expect(try CloudGatewayMacCLIInventoryOrder.resolve(.region("CHICAGO", index: 1), state: state, accountId: "uid1") == thirdConfig)
}

@MainActor
@Test func cliRegionFiltersRejectMissingAndAmbiguousInventoryInEveryListPath() async throws {
    for state in [selectorState(), cliState(), cliState(access: .offline, inventory: .cached)] {
        for alias in ["list", "ls"] {
            for isLong in [false, true] {
                for isJSON in [false, true] {
                    for refresh in [false, true] {
                        let harness = CLIHarness(state)
                        harness.onRequest = { request in
                            request.action == .awaitRefresh ? .init(state: state, refresh: .refreshed) : nil
                        }
                        let args = [alias, "--region", "missing"] + (isLong ? ["--long"] : [])
                            + (isJSON ? ["--json"] : []) + (refresh ? ["--refresh"] : [])
                        #expect(await harness.run(args) == 2)
                        if isJSON {
                            #expect(harness.json?["command"] as? String == "list")
                            #expect((harness.json?["error"] as? [String: Any])?["code"] as? String == "usage")
                        } else {
                            #expect(harness.diagnostics.contains("Region 'missing' is unavailable in this account's current inventory"))
                        }
                    }
                }
            }
        }
    }
    for value in ["us-sanjose-1", "California", "cALIFORNIA", "sanjose"] {
        let harness = CLIHarness(selectorState())
        #expect(await harness.run("ls", "--region", value, "--json") == 0)
        #expect(try inventoryConfigs(harness).compactMap { $0["index"] as? Int } == [1, 2])
        #expect((harness.json?["data"] as? [String: Any])?["regionId"] as? String == "us-sanjose-1")
    }
    let collision = cliState(clients: [
        cliClient(firstConfig, regionName: "Shared Name", name: "A"),
        cliClient("uid1/eu-sanjose-2/" + secondUUID, regionName: "Shared Name", name: "B"),
    ])
    for alias in ["sanjose", "Shared Name"] {
        let harness = CLIHarness(collision)
        #expect(await harness.run("list", "--region", alias, "--json") == 2)
        #expect((harness.json?["error"] as? [String: Any])?["message"] as? String
            == "Region '\(alias)' is ambiguous. Use a full region ID")
        #expect(harness.output.contains("us-sanjose-1"))
        #expect(harness.output.contains("eu-sanjose-2"))
    }
    let exact = CLIHarness(collision)
    #expect(await exact.run("list", "--region", "us-sanjose-1") == 0)
    let empty = CLIHarness(cliState())
    #expect(await empty.run("ls") == 0)
    #expect(empty.output.hasPrefix("No configs\n"))
}

@MainActor
@Test func cliLongOfflineDetailsShowUnavailableAndSanitizeMetadata() async {
    let state = cliState(access: .offline, inventory: .cached, clients: [
        cliClient(firstConfig, regionName: "California", name: "Mac", ip: nil, source: .cache),
        cliClient(secondConfig, regionName: "California", name: "Other", ip: "10.0.0.3",
                  connectionUrl: "wg.example.com\u{1B}[31m\u{202E}", source: .cache),
    ])
    let harness = CLIHarness(state)
    #expect(await harness.run("ls", "-l") == 0)
    #expect(harness.output.contains("Tunnel IP:       Unavailable"))
    #expect(harness.output.contains("Connection URL:  Unavailable"))
    #expect(harness.output.contains("Owner email:     Unknown"))
    #expect(harness.output.contains("Connection URL:  wg.example.com [31m "))
    #expect(!harness.output.contains("\u{1B}"))
    #expect(!harness.output.contains("\u{202E}"))
    #expect(harness.output.hasSuffix("Offline: showing this account's saved configs from cached authorization\n"))
}

@MainActor
@Test func cliSelectorsFailBeforeReservingAndNeverFallBackToBareStop() async {
    for command in ["up", "down"] {
        for (operands, exit) in [([thirdUUID], Int32(5)), (["missing", "1"], 2), (["sanjose", "3"], 2)] {
            let harness = CLIHarness(cliState(clients: [cliClient(firstConfig, regionName: "California", name: "Mac")], selected: firstConfig))
            #expect(await harness.run([command] + operands + ["--json"]) == exit)
            #expect(!harness.actions.contains(.connect))
            #expect(!harness.actions.contains(.disconnectClient))
            #expect(!harness.actions.contains(.turnOff))
            #expect(!harness.actions.contains(.confirmOperation))
        }
        let signedOut = CLIHarness(cliState(account: nil, retained: false))
        #expect(await signedOut.run(command, firstUUID) == 3)
        #expect(!signedOut.actions.contains(.turnOff))
        #expect(!signedOut.actions.contains(.disconnectClient))
        let duplicate = CLIHarness(cliState(clients: [
            cliClient(firstConfig, regionName: "California", name: "Mac"),
            cliClient("uid1/us-chicago-1/" + firstUUID.uppercased(), regionName: "Chicago", name: "Other"),
        ]))
        #expect(await duplicate.run(command, firstUUID) == 5)
        #expect(duplicate.diagnostics.contains("ambiguous"))
        #expect(!duplicate.actions.contains(.connect))
        #expect(!duplicate.actions.contains(.disconnectClient))
    }
}

@MainActor
@Test func cliScopedMutationsReserveOnceAndKeepResolvedTargetThroughInventoryChanges() async throws {
    for command in ["up", "down"] {
        for operands in [[secondUUID.uppercased()], ["sanjose", "2"]] {
            let harness = CLIHarness(selectorState())
            let action: CloudGatewayMacControllerRequest.Action = command == "up" ? .connect : .disconnectClient
            var reserved: UUID?
            harness.onRequest = { request in
                if request.action == action {
                    #expect(request.identifier == secondConfig)
                    reserved = request.id
                    harness.states = [cliState(clients: [cliClient(firstConfig, regionName: "California", name: "Only client")])]
                    return .init(operation: .init(id: request.id, state: .accepted))
                }
                if request.action == .confirmOperation {
                    #expect(request.contextId == reserved)
                    return .init(status: harness.status, operation: .init(id: request.contextId!, state: .running))
                }
                if request.action == .operation {
                    #expect(request.contextId == reserved)
                    return .init(state: harness.states[0], operation: .init(id: request.contextId!, state: .completed),
                                 outcome: command == "up" ? .startRequested(identifier: secondConfig, warning: nil) : .completed(warning: nil))
                }
                return nil
            }
            #expect(await harness.run([command] + operands + ["--json"]) == 0)
            #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, action, .confirmOperation, .operation])
            #expect(!harness.actions.contains(.turnOff))
            let records = try harness.output.split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            #expect(records.count == 2)
            #expect(records.last?["operationId"] as? String == reserved?.uuidString.lowercased())
        }
    }
}

@MainActor
@Test func cliTargetedStopRequiresCurrentBuildAndSharesSnapshotDeadline() async {
    let incompatible = CLIHarness(selectorState())
    incompatible.lifecycle = .draining
    #expect(await incompatible.run("down", secondUUID, "--json") == 4)
    #expect(!incompatible.actions.contains(.snapshot))
    #expect(!incompatible.actions.contains(.disconnectClient))
    let hung = CLIHarness(selectorState())
    hung.hungActions = [.snapshot]
    #expect(await hung.run("down", "sanjose", "2", "--timeout", "1", "--json") == 8)
    #expect(!hung.actions.contains(.disconnectClient))
    let refreshing = CLIHarness(cliState(inventory: .refreshing))
    refreshing.states.append(selectorState())
    var identifier: String?
    refreshing.onRequest = { request in
        if request.action == .disconnectClient {
            identifier = request.identifier
            return .init(operation: .init(id: request.id, state: .accepted))
        }
        if request.action == .confirmOperation {
            return .init(status: refreshing.status, operation: .init(id: request.contextId!, state: .completed), outcome: .completed(warning: nil))
        }
        return nil
    }
    #expect(await refreshing.run("down", "sanjose", "2") == 0)
    #expect(identifier == secondConfig)
    #expect(refreshing.actions.filter { $0 == .snapshot }.count == 2)
}

@MainActor
@Test func cliRefreshResolvesRegionsOnlyAfterTheCorrelatedInventorySettles() async {
    let harness = CLIHarness()
    var attempts = 0
    harness.onRequest = { request in
        guard request.action == .awaitRefresh else { return nil }
        attempts += 1
        return .init(state: attempts == 1 ? cliState(inventory: .refreshing) : selectorState(),
                     refresh: attempts == 1 ? .timedOut : .refreshed)
    }
    #expect(await harness.run("ls", "--refresh", "--region", "sanjose", "-l", "--json") == 0)
    #expect(attempts == 2)
    #expect(harness.json?["command"] as? String == "list")
    #expect((harness.json?["data"] as? [String: Any])?["regionId"] as? String == "us-sanjose-1")
}

@MainActor
@Test func cliEligibleErrorChoicesKeepIndicesFromTheFullInventory() async throws {
    let harness = CLIHarness(selectorState())
    harness.onRequest = { request in
        if request.action == .connect { return .init(operation: .init(id: request.id, state: .accepted)) }
        if request.action == .confirmOperation {
            return .init(status: harness.status, operation: .init(id: request.contextId!, state: .failed),
                         outcome: .failed(.selectionUnavailable))
        }
        return nil
    }
    #expect(await harness.run("up", "--json") == 5)
    let line = try #require(harness.output.split(separator: "\n").last)
    let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let choices = try #require((record["data"] as? [String: Any])?["choices"] as? [String: Any])
    let regions = try #require(choices["regions"] as? [[String: Any]])
    let configs = try #require(regions.first?["configs"] as? [[String: Any]])
    #expect(configs.count == 1)
    #expect(configs.first?["clientId"] as? String == secondUUID)
    #expect(configs.first?["index"] as? Int == 2)
    #expect(configs.first?["connectionUrl"] as? String == "192.0.2.10")
}

@Test func cliOrderingIsDeterministicAndExactRegionIDsWinAliasCollisions() throws {
    let clients = [
        cliClient(thirdConfig, regionName: "us-sanjose-1", order: 2, name: "A"),
        cliClient(secondConfig, regionName: "California", order: 1, name: "Same", owner: "a@example.com"),
        cliClient(firstConfig, regionName: "California", order: 1, name: "Same", owner: "a@example.com"),
        cliClient("uid1/us-sanjose-1/" + thirdUUID, regionName: "California", order: 1, name: "A", owner: "z@example.com"),
    ]
    for rows in [clients, Array(clients.reversed()), Array(clients.dropFirst()) + [clients[0]]] {
        let state = cliState(clients: rows)
        let regions = CloudGatewayMacCLIInventoryOrder.regions(state, accountId: "uid1")
        #expect(regions[0].map(\.identifier) == [secondConfig, firstConfig, "uid1/us-sanjose-1/" + thirdUUID])
        #expect(try CloudGatewayMacCLIInventoryOrder.region("us-sanjose-1", in: regions) == "us-sanjose-1")
        let inventory = CloudGatewayMacCLIInventory(state, accountId: "uid1", regionId: nil)
        #expect(inventory.regions[0].configs.map(\.configId) == regions[0].map(\.identifier))
        for index in 1...3 {
            #expect(try CloudGatewayMacCLIInventoryOrder.resolve(.region("California", index: index), state: state, accountId: "uid1")
                == inventory.regions[0].configs[index - 1].configId)
        }
    }
}

@MainActor
@Test func cliAccountChangesNeverReinterpretTheReservedSelector() async {
    for command in ["up", "down"] {
        let harness = CLIHarness(selectorState())
        let action: CloudGatewayMacControllerRequest.Action = command == "up" ? .connect : .disconnectClient
        harness.onRequest = { request in
            if request.action == action {
                #expect(request.identifier == secondConfig)
                harness.states = [cliState(account: "uid2", clients: [
                    cliClient("uid2/us-sanjose-1/" + secondUUID, regionName: "California", name: "Other account"),
                ])]
                return .init(operation: .init(id: request.id, state: .accepted))
            }
            if request.action == .confirmOperation {
                return .init(state: harness.states[0], operation: .init(id: request.contextId!, state: .failed),
                             outcome: .failed(.signInRequired))
            }
            return nil
        }
        #expect(await harness.run(command, "sanjose", "2", "--json") == 3)
        #expect(harness.actions == [.lifecycle, .userActivity, .snapshot, action, .confirmOperation])
        #expect(!harness.output.contains("uid2/"))
        #expect(!harness.actions.contains(.turnOff))
    }
}

@Test func cliLongRendererStripsCIDRWhileKeepingMachineMetadata() throws {
    let original = cliState(clients: [cliClient(firstConfig, regionName: "California", name: "Mac")])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var clients = try #require(object["clients"] as? [[String: Any]])
    clients[0]["internalIp"] = "10.0.0.2/32"
    object["clients"] = clients
    let state = try JSONDecoder().decode(CloudGatewayMacControllerState.self, from: JSONSerialization.data(withJSONObject: object))
    let inventory = CloudGatewayMacCLIInventory(state, accountId: "uid1", regionId: nil, isLong: true)
    let rendered = CloudGatewayMacCLIRenderer(isStyled: false).render(.inventory(inventory))
    #expect(rendered.contains("Tunnel IP:       10.0.0.2\n"))
    #expect(!rendered.contains("/32"))
    #expect(inventory.regions[0].configs[0].internalIp == "10.0.0.2/32")
}
