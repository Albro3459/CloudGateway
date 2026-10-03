import AppKit
import CloudGatewayKit

@MainActor
final class CloudGatewayMacClientCreationDialog: NSObject, NSWindowDelegate {
    typealias Request = (regionId: String, clientName: String)

    private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let regionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading available regions…")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private var continuation: CheckedContinuation<Request?, Error>?
    private var regionsTask: Task<Void, Never>?

    override init() {
        super.init()
        panel.title = "Add VPN Client"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        regionPicker.addItem(withTitle: "Choose a region")
        regionPicker.isEnabled = false
        nameField.placeholderString = "For example, Work Mac"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        createButton.target = self
        createButton.action = #selector(createClient)
        createButton.keyEquivalent = "\r"
        createButton.isEnabled = false
        panel.defaultButtonCell = createButton.cell as? NSButtonCell
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSView()
        for button in [cancelButton, createButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            buttons.addSubview(button)
        }
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Region"), regionPicker,
            NSTextField(labelWithString: "Display name"), nameField, statusLabel, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            regionPicker.widthAnchor.constraint(equalToConstant: 320),
            nameField.widthAnchor.constraint(equalToConstant: 320),
            statusLabel.widthAnchor.constraint(equalToConstant: 320),
            statusLabel.heightAnchor.constraint(equalToConstant: 36),
            buttons.widthAnchor.constraint(equalToConstant: 320),
            buttons.heightAnchor.constraint(equalToConstant: 32),
            createButton.trailingAnchor.constraint(equalTo: buttons.trailingAnchor),
            createButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: buttons.centerYAnchor)
        ])
        stack.setFrameSize(stack.fittingSize)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.initialFirstResponder = nameField
    }

    func prompt(loadRegions: @escaping @MainActor () async throws -> [CloudGatewayRegion]) async throws -> Request? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                panel.center()
                NSApplication.shared.activate()
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(nameField)
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func populateRegions(_ regions: [CloudGatewayRegion]) {
        guard continuation != nil else { return }
        let available = CloudGatewayConfigSelection.sortedRegions(regions.filter {
            $0.enabled && $0.capacity?.isKnown == true && $0.capacity?.isAtCapacity == false
        })
        guard !available.isEmpty else {
            if regions.isEmpty {
                statusLabel.stringValue = "No enabled regions are available"
            } else if regions.contains(where: { $0.capacity?.isKnown != true }) {
                statusLabel.stringValue = "Unable to check region capacity. Cancel and try Add Client again"
            } else {
                statusLabel.stringValue = "No region currently has available client capacity"
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
        createButton.isEnabled = true
        statusLabel.stringValue = ""
    }

    @objc private func createClient() {
        guard createButton.isEnabled, let regionId = regionPicker.selectedItem?.representedObject as? String else { return }
        let clientName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientName.isEmpty, clientName.unicodeScalars.count <= 80 else {
            statusLabel.stringValue = "Enter a client name with 1 to 80 characters"
            statusLabel.textColor = .systemRed
            panel.makeFirstResponder(nameField)
            return
        }
        finish(.success((regionId, clientName)))
    }

    @objc private func cancel() { finish(.success(nil)) }

    private func finish(_ result: Result<Request?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        regionsTask?.cancel()
        regionsTask = nil
        panel.delegate = nil
        panel.orderOut(nil)
        continuation.resume(with: result)
    }
}
