import AppKit

@MainActor
public final class CloudGatewayMacClientReviewDialog: NSObject, NSMenuDelegate {
    private let alert = NSAlert()
    let regionPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
    let configPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private var selection: CloudGatewayMacClientReviewSelection
    private var continuation: CheckedContinuation<String?, Error>?
    private var isTrackingPicker = false

    public init(snapshot: CloudGatewayMacControllerView) {
        selection = .init(snapshot: snapshot)
        super.init()
        alert.messageText = "Review client"
        alert.informativeText = "Select a region, then the config you want to delete. Deletion cannot be undone."
        alert.addButton(withTitle: "Delete").isEnabled = false
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        regionPicker.target = self
        regionPicker.action = #selector(regionChanged)
        configPicker.target = self
        configPicker.action = #selector(configChanged)
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Region"), regionPicker,
            NSTextField(labelWithString: "Config"), configPicker, explanation
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        NSLayoutConstraint.activate([
            regionPicker.widthAnchor.constraint(equalToConstant: 360),
            configPicker.widthAnchor.constraint(equalToConstant: 360),
            explanation.widthAnchor.constraint(equalToConstant: 360)
        ])
        render()
        regionPicker.menu?.delegate = self
        configPicker.menu?.delegate = self
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.layout()
        alert.window.initialFirstResponder = regionPicker
    }

    public func update(snapshot: CloudGatewayMacControllerView, isSnapshotFresh: Bool, isCurrentBuild: Bool) {
        selection.update(snapshot: snapshot, isSnapshotFresh: isSnapshotFresh, isCurrentBuild: isCurrentBuild)
        guard selection.isValid else { finish(.success(nil)); return }
        render()
    }

    public func prompt() async throws -> String? {
        try Task.checkCancellation()
        guard selection.isValid else { return nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // AppKit's modal loop must run outside the main dispatch queue to allow snapshot updates
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.continuation != nil else { return }
                        NSApplication.shared.activate()
                        let response = self.alert.runModal()
                        let identifier = response == .alertFirstButtonReturn && self.selection.canDelete
                            ? self.selection.identifier : nil
                        self.finish(.success(identifier))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    @objc private func regionChanged() {
        selection.selectRegion(regionPicker.selectedItem?.representedObject as? String)
        render()
    }

    @objc private func configChanged() {
        selection.selectClient(configPicker.selectedItem?.representedObject as? String)
        render()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isTrackingPicker = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        isTrackingPicker = false
        // Keep the selected item alive until AppKit dispatches its action
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    private func render() {
        if !isTrackingPicker {
            update(regionPicker, placeholder: selection.groups.isEmpty ? "No clients" : "Select region…",
                   items: selection.groups.map { ($0.regionId, "\($0.title) (\($0.regionId))") },
                   selected: selection.regionId)
            update(configPicker, placeholder: "Select config…",
                   items: selection.rows.map { ($0.identifier, "\($0.title) · \($0.identifier)") },
                   selected: selection.identifier)
        }
        explanation.stringValue = selection.message
        configPicker.toolTip = selection.identifier
        alert.buttons[0].isEnabled = selection.canDelete
        if !isTrackingPicker, let stack = alert.accessoryView {
            stack.setFrameSize(stack.fittingSize)
            alert.layout()
        }
    }

    private func update(_ picker: NSPopUpButton, placeholder: String,
                        items: [(id: String, title: String)], selected: String?) {
        let existing = picker.itemArray
        let matches = existing.count == items.count + 1 && existing.first?.title == placeholder
            && zip(existing.dropFirst(), items).allSatisfy {
                $0.title == $1.title && $0.representedObject as? String == $1.id
            }
        if !matches {
            picker.removeAllItems()
            picker.addItem(withTitle: placeholder)
            for entry in items {
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.representedObject = entry.id
                picker.menu?.addItem(item)
            }
        }
        let item = selected.flatMap { selected in
            picker.itemArray.first { $0.representedObject as? String == selected }
        } ?? picker.item(at: 0)
        if picker.selectedItem !== item { picker.select(item) }
        picker.isEnabled = !items.isEmpty
    }

    private func finish(_ result: Result<String?, Error>) {
        selection.invalidate()
        guard let continuation else { return }
        self.continuation = nil
        if NSApplication.shared.modalWindow === alert.window { NSApplication.shared.abortModal() }
        alert.window.orderOut(nil)
        continuation.resume(with: result)
    }
}
