import AppKit
import CloudGatewayKit

@MainActor
final class CloudGatewayMacClientCreationDialog: NSObject, NSTextFieldDelegate {
    typealias Request = (regionId: String, clientName: String)

    private let alert = NSAlert()
    private let regionPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
    private let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    private var continuation: CheckedContinuation<Request?, Error>?
    private var regionsTask: Task<Void, Never>?
    private var modalTask: Task<Void, Never>?
    private var modalSession: NSApplication.ModalSession?

    override init() {
        super.init()
        alert.messageText = "Add VPN Client"
        alert.informativeText = "Create a client in the selected region."
        alert.addButton(withTitle: "Create").isEnabled = false
        alert.addButton(withTitle: "Cancel")
        regionPicker.addItem(withTitle: "Loading regions…")
        regionPicker.isEnabled = false
        nameField.placeholderString = "For example, Work Mac"
        nameField.toolTip = "Enter a client name with 1 to 80 characters"
        nameField.delegate = self
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Region"), regionPicker,
            NSTextField(labelWithString: "Display name"), nameField
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        NSLayoutConstraint.activate([
            regionPicker.widthAnchor.constraint(equalToConstant: 320),
            nameField.widthAnchor.constraint(equalToConstant: 320)
        ])
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.layout()
        alert.window.initialFirstResponder = nameField
    }

    func prompt(loadRegions: @escaping @MainActor () async throws -> [CloudGatewayRegion]) async throws -> Request? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                NSApplication.shared.activate()
                modalSession = NSApplication.shared.beginModalSession(for: alert.window)
                alert.window.makeFirstResponder(nameField)
                modalTask = Task { [weak self] in
                    guard let self else { return }
                    while let session = modalSession, !Task.isCancelled {
                        let response = NSApplication.shared.runModalSession(session)
                        guard response == .continue else {
                            complete(response)
                            return
                        }
                        // Yield between event passes so region loading can update the native alert
                        do { try await Task.sleep(for: .milliseconds(16)) }
                        catch { return }
                    }
                }
                regionsTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let regions = try await loadRegions()
                        try Task.checkCancellation()
                        populateRegions(regions)
                    } catch {
                        guard !Task.isCancelled else { return }
                        finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func controlTextDidChange(_ notification: Notification) { updateCreateButton() }

    private func populateRegions(_ regions: [CloudGatewayRegion]) {
        guard continuation != nil else { return }
        let available = CloudGatewayConfigSelection.sortedRegions(regions.filter {
            $0.enabled && $0.capacity?.isKnown == true && $0.capacity?.isAtCapacity == false
        })
        guard !available.isEmpty else {
            if regions.isEmpty {
                regionPicker.item(at: 0)?.title = "No enabled regions"
                regionPicker.toolTip = "No enabled regions are available"
            } else if regions.contains(where: { $0.capacity?.isKnown != true }) {
                regionPicker.item(at: 0)?.title = "Capacity unavailable"
                regionPicker.toolTip = "Unable to check region capacity. Cancel and try Add Client again"
            } else {
                regionPicker.item(at: 0)?.title = "No available capacity"
                regionPicker.toolTip = "No region currently has available client capacity"
            }
            return
        }
        regionPicker.removeAllItems()
        for region in available {
            let item = NSMenuItem(title: "\(region.displayName) · \(region.capacity?.displayText ?? "Capacity unavailable")",
                                  action: nil, keyEquivalent: "")
            item.representedObject = region.regionId
            regionPicker.menu?.addItem(item)
        }
        regionPicker.selectItem(at: 0)
        regionPicker.isEnabled = true
        updateCreateButton()
    }

    private func updateCreateButton() {
        guard regionPicker.isEnabled else { return }
        let clientName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.buttons[0].isEnabled = !clientName.isEmpty && clientName.unicodeScalars.count <= 80
    }

    private func complete(_ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn, alert.buttons[0].isEnabled,
              let regionId = regionPicker.selectedItem?.representedObject as? String else {
            finish(.success(nil))
            return
        }
        let clientName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientName.isEmpty, clientName.unicodeScalars.count <= 80 else {
            finish(.success(nil))
            return
        }
        finish(.success((regionId, clientName)))
    }

    private func finish(_ result: Result<Request?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        regionsTask?.cancel()
        regionsTask = nil
        modalTask?.cancel()
        modalTask = nil
        if let modalSession {
            NSApplication.shared.endModalSession(modalSession)
            self.modalSession = nil
        }
        alert.window.orderOut(nil)
        continuation.resume(with: result)
    }
}
