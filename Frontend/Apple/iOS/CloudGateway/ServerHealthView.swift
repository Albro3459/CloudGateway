import CloudGatewayAppCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Admin-only Server Health page: mesh membership toggles, link status derived
// from Mesh/*, and per-region client-peer sync results. The page owns
// confirm-and-run for Sync All Regions - there is no cross-page hand-off like
// the web's pendingRunSync, since opening this page and running the fan-out
// happen in the same place on iOS.
struct ServerHealthView: View {
    @ObservedObject var viewModel: CloudGatewayServerHealthViewModel
    let onClose: () -> Void
    @Environment(\.cloudGatewayTheme) private var theme
    @State private var isShowingSyncConfirm = false

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                content
            }
        }
        .foregroundStyle(theme.content)
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $isShowingSyncConfirm) {
            SyncAllRegionsConfirmSheet(
                regions: viewModel.enabledRegions,
                onConfirm: {
                    isShowingSyncConfirm = false
                    Task { await viewModel.syncAll() }
                },
                onCancel: {
                    isShowingSyncConfirm = false
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Server Health")
                .font(.headline)
                .foregroundStyle(theme.content)
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(NavTextButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.nav)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let bannerText = viewModel.bannerText {
                    MessageBanner(text: bannerText, style: .error, onDismiss: viewModel.dismissBanner)
                }

                if !viewModel.dataAvailable {
                    unavailablePanel
                } else {
                    headerPanel
                    meshMembershipPanel
                    meshLinksPanel
                    clientPeerSyncPanel
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .refreshable {
            await viewModel.load()
        }
    }

    private var unavailablePanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(theme.contentSecondary)
                        Text("Loading server health data...")
                            .font(.subheadline)
                            .foregroundStyle(theme.contentMuted)
                    }
                } else {
                    Text("Server health data is unavailable.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)

                    Button("Try again") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var headerPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Health")
                        .font(.title3.bold())
                        .foregroundStyle(theme.content)
                    Text("Mesh membership, link status, and client peer sync per region.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)
                    Text("Mesh status reflects durable configuration snapshots only; it does not prove a handshake or traffic reachability.")
                        .font(.caption)
                        .foregroundStyle(theme.contentMuted)
                }

                Button {
                    isShowingSyncConfirm = true
                } label: {
                    if viewModel.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(theme.content)
                            Text("Syncing...")
                        }
                    } else {
                        Label("Sync All Regions", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!viewModel.canSyncAll)
                .overlay {
                    if viewModel.anyPending {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.warningStrong, lineWidth: 2)
                    }
                }

                if viewModel.anyPending {
                    Text("Pending mesh changes - run Sync All Regions to apply them.")
                        .font(.subheadline)
                        .foregroundStyle(theme.warningStrong)
                }
            }
        }
    }

    private var meshMembershipPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Mesh membership",
                    subtitle: "Toggle mesh participation per region."
                )

                // Every region doc is shown, including disabled ones: a disabled
                // region can still have a live peer installed on another host.
                if viewModel.regions.isEmpty {
                    Text("No regions.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)
                } else {
                    FlowLayout(spacing: 10) {
                        ForEach(viewModel.regions) { region in
                            meshMembershipRow(region)
                        }
                    }
                }
            }
        }
    }

    private func meshMembershipRow(_ region: CloudGatewayMeshRegion) -> some View {
        let meshDoc = viewModel.meshDoc(for: region.regionId)
        let pending = CloudGatewayMeshStatus.isRegionMeshPending(region: region, meshDoc: meshDoc)
        let staleness = CloudGatewayMeshStatus.meshStaleness(updatedAt: meshDoc?.updatedAt)

        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { region.meshEnabled },
                set: { _ in Task { await viewModel.toggleMesh(region: region) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(theme.primary)
            .disabled(!region.enabled || !viewModel.canToggleMesh(region))
            .accessibilityLabel("Mesh enabled for \(region.displayName)")

            VStack(alignment: .leading, spacing: 4) {
                Text(region.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.content)

                if !region.enabled {
                    Text("Disabled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.contentSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.insetStrong)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                if pending {
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(theme.warningStrong)
                }

                Text(freshnessText(meshDoc: meshDoc, staleness: staleness))
                    .font(.caption)
                    .foregroundStyle(theme.contentMuted)
            }
        }
        .padding(10)
        .background(theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.edgeFaint, lineWidth: 1)
        }
    }

    private func freshnessText(meshDoc: CloudGatewayMeshDoc?, staleness: CloudGatewayMeshStaleness) -> String {
        guard let updatedAt = meshDoc?.updatedAt else { return "Never synced" }
        let formatted = updatedAt.formatted(date: .abbreviated, time: .shortened)
        return staleness == .stale ? "Last applied \(formatted) (stale)" : "Last applied \(formatted)"
    }

    private var meshLinksPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mesh")
                    .font(.title3.bold())
                    .foregroundStyle(theme.content)

                if viewModel.linkRows.isEmpty {
                    Text("Add another region to form mesh links.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)
                } else {
                    VStack(spacing: 8) {
                        ForEach(viewModel.linkRows) { row in
                            linkRow(row)
                        }
                    }
                }

                if !viewModel.warnings.isEmpty {
                    warningsSection
                }
            }
        }
    }

    private func linkRow(_ row: CloudGatewayMeshLinkRow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(formatLinkRowLabel(row))
                .font(.subheadline)
            if row.pending {
                Text("(pending)")
                    .font(.caption.italic())
            }
        }
        .foregroundStyle(linkRowForeground(row.status))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(linkRowBackground(row.status))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(linkRowBorder(row.status), lineWidth: 1)
        }
    }

    private func linkRowBackground(_ status: CloudGatewayMeshLinkStatus) -> Color {
        switch status {
        case .bothApplied: theme.successSoft
        case .stale: theme.dangerSoft
        case .oneSided: theme.warningSoft
        case .notSynced: theme.inset
        }
    }

    private func linkRowForeground(_ status: CloudGatewayMeshLinkStatus) -> Color {
        switch status {
        case .bothApplied: theme.successStrong
        case .stale: theme.dangerContent
        case .oneSided: theme.warningStrong
        case .notSynced: theme.contentSecondary
        }
    }

    private func linkRowBorder(_ status: CloudGatewayMeshLinkStatus) -> Color {
        switch status {
        case .bothApplied: theme.successSoftEdge
        case .stale: theme.dangerSoftEdge
        case .oneSided: theme.warningSoftEdge
        case .notSynced: theme.edgeSubtle
        }
    }

    // Port of the web's sideLabel: describes what one side of a link recorded
    // for the other, favoring "stale" over "applied" over the raw peer status.
    private func regionSideLabel(_ name: String, row: CloudGatewayMeshLinkRow, isSideA: Bool) -> String {
        let stale = isSideA ? row.aToBStale : row.bToAStale
        let current = isSideA ? row.aToBCurrent : row.bToACurrent
        let status = isSideA ? row.aToB : row.bToA
        if stale { return "\(name) stale" }
        if current { return "\(name) applied" }
        if let status { return "\(name) \(status.rawValue)" }
        return "\(name) not synced"
    }

    // Port of the web's formatLinkRowLabel. Region labels use meshLabel(for:)
    // so a disabled region reads "Name (disabled)", matching the web's use of
    // meshRegionLabels for this same row.
    private func formatLinkRowLabel(_ row: CloudGatewayMeshLinkRow) -> String {
        let aName = viewModel.meshLabel(for: row.regionAId)
        let bName = viewModel.meshLabel(for: row.regionBId)

        switch row.status {
        case .bothApplied:
            return "\(aName) \u{2194} \(bName) \u{00b7} both applied"
        case .stale:
            return "\(aName) \u{2194} \(bName) \u{00b7} stale \u{00b7} \(regionSideLabel(aName, row: row, isSideA: true)), \(regionSideLabel(bName, row: row, isSideA: false))"
        case .oneSided:
            return "\(aName) \u{2194} \(bName) \u{00b7} one-sided \u{00b7} \(regionSideLabel(aName, row: row, isSideA: true)), \(regionSideLabel(bName, row: row, isSideA: false))"
        case .notSynced:
            return "\(aName) \u{2194} \(bName) \u{00b7} not synced"
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Warnings")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.warningStrong)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.warnings) { warning in
                    Text(warningText(warning))
                        .font(.subheadline)
                        .foregroundStyle(theme.warningStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.warningSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.warningSoftEdge, lineWidth: 1)
        }
    }

    private func warningText(_ warning: CloudGatewayMeshWarning) -> String {
        let region = viewModel.meshLabel(for: warning.regionId)
        let peer = viewModel.meshLabel(for: warning.peerRegionId)
        let reason = formatWarningReason(warning.status, warning.reasonCode)
        let code = warning.reasonCode.map { " [\($0)]" } ?? ""
        let recorded = warning.appliedAt
            .map { " - recorded \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(region) skipped \(peer): \(reason)\(code)\(recorded)"
    }

    private var clientPeerSyncPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Client peer sync")
                    .font(.title3.bold())
                    .foregroundStyle(theme.content)

                if let syncResults = viewModel.syncResults {
                    VStack(spacing: 12) {
                        ForEach(syncResults) { outcome in
                            RegionSyncResultCard(
                                outcome: outcome,
                                displayName: viewModel.displayName(for: outcome.regionId)
                            )
                        }
                    }
                } else {
                    Text("Run Sync All Regions to see live results.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)
                }
            }
        }
    }
}

// Direct port of the web's formatWarningReason. Every reason code plus the
// two status fallbacks (skipped-overlap / skipped-incomplete).
private func formatWarningReason(_ status: CloudGatewayMeshPeerStatus, _ reasonCode: String?) -> String {
    let reasons: [String: String] = [
        "invalid-endpoint-port": "endpoint port is invalid",
        "duplicate-public-key": "public key is duplicated by another region",
        "missing-public-key": "public key is missing",
        "invalid-public-key": "public key is invalid",
        "missing-endpoint-hostname": "endpoint hostname is missing",
        "invalid-endpoint-hostname": "endpoint hostname is invalid",
        "missing-network-v4": "tunnel IPv4 network is missing",
        "invalid-network-v4": "tunnel IPv4 network is invalid",
        "missing-network-v6": "tunnel IPv6 network is missing",
        "invalid-network-v6": "tunnel IPv6 network is invalid",
        "outside-aggregate": "tunnel network is outside the mesh aggregate",
        "local-network-invalid": "regional host local-network configuration rejects this tunnel network",
        "overlap-local": "claimed subnet overlaps the local region",
        "overlap-candidate": "claimed subnet overlaps another region",
    ]
    if let reasonCode, let reason = reasons[reasonCode] {
        return reason
    }
    return status == .skippedOverlap
        ? "claimed subnet overlaps another region"
        : "mesh peer was skipped because required metadata is incomplete or invalid"
}

private struct SyncAllRegionsConfirmSheet: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let regions: [CloudGatewayMeshRegion]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ThemedPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sync All Regions")
                            .font(.title2.bold())
                            .foregroundStyle(theme.content)
                        Spacer()
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconNavButtonStyle())
                        .accessibilityLabel("Close sync all regions")
                    }

                    Text("Reconciles client peers and mesh links across every enabled region. Regions you left unchecked are synced too: their cross-region peers and routes are removed.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if regions.isEmpty {
                        Text("No enabled regions to sync.")
                            .font(.subheadline)
                            .foregroundStyle(theme.contentMuted)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(regions) { region in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(region.displayName)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(theme.content)
                                        Text(region.regionId)
                                            .font(.caption)
                                            .foregroundStyle(theme.contentMuted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(theme.inset)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                        .frame(maxHeight: 280)
                    }

                    HStack(spacing: 12) {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Sync \(regions.count) region\(regions.count == 1 ? "" : "s")", action: onConfirm)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(regions.isEmpty)
                    }
                }
            }
            .padding(16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// Per-region client-peer sync result card, ported from RegionSyncCard.tsx.
// SECURITY: `response.log` carries user emails, client names, client IDs,
// public keys, and tunnel IPs. It is only ever rendered on-screen (behind an
// explicit "View log" disclosure) or exported through ShareLink - never
// written to disk, printed, or logged by this code.
struct RegionSyncResultCard: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let outcome: CloudGatewayRegionSyncOutcome
    let displayName: String
    @State private var showLog = false

    private var title: String {
        "\(displayName) (\(outcome.regionId))"
    }

    var body: some View {
        switch outcome.result {
        case .alreadyRunning:
            alreadyRunningCard
        case .failure(let message, let requestId, let isIncompatibleResponse):
            failureCard(message: message, requestId: requestId, isIncompatibleResponse: isIncompatibleResponse)
        case .success(let response):
            successCard(response)
        }
    }

    private var alreadyRunningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.content)
            Text("A sync is already running on this region \u{2014} try again shortly.")
                .font(.subheadline)
                .foregroundStyle(theme.warningStrong)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.warningSoftEdge, lineWidth: 1)
        }
    }

    private func failureCard(message: String, requestId: String?, isIncompatibleResponse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.content)
                Spacer()
                Text(isIncompatibleResponse ? "Incompatible response" : "Failed")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.danger)
                    .foregroundStyle(theme.content)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.dangerContent)

            if isIncompatibleResponse {
                Text("The sync result was discarded because the regional API returned an unsupported shape.")
                    .font(.caption)
                    .foregroundStyle(theme.contentMuted)
            }

            if let requestId {
                Text("Request ID: \(requestId)")
                    .font(.caption)
                    .foregroundStyle(theme.contentMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.danger, lineWidth: 1)
        }
    }

    private func successCard(_ response: CloudGatewayRegionSyncResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.content)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(response.meshEnabled ? "Mesh enabled" : "Mesh disabled")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(response.meshEnabled ? theme.successSoft : theme.inset)
                        .foregroundStyle(response.meshEnabled ? theme.successStrong : theme.contentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(syncedAtText(response.syncedAt))
                        .font(.caption)
                        .foregroundStyle(theme.contentMuted)
                }
            }

            FlowLayout(spacing: 8) {
                countChip("Added", response.added)
                countChip("Updated", response.updated)
                countChip("Removed", response.removed)
            }

            FlowLayout(spacing: 8) {
                countChip("Mesh applied", response.meshApplied)
                countChip("Mesh added", response.meshAdded)
                countChip("Mesh updated", response.meshUpdated)
                countChip("Mesh removed", response.meshRemoved)
                countChip("Mesh skipped", response.meshSkipped)
                countChip("Routes added", response.meshRoutesAdded)
                countChip("Routes removed", response.meshRoutesRemoved)
            }

            if response.noChanges {
                Text("No changes were required.")
                    .font(.subheadline)
                    .foregroundStyle(theme.contentMuted)
            }

            if response.meshStatusWritten == false {
                Text("This region reconciled successfully, but could not save its mesh status snapshot. The mesh link status shown above and on this page may be out of date until the next successful sync.")
                    .font(.subheadline)
                    .foregroundStyle(theme.warningStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !response.meshPeers.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(response.meshPeers, id: \.regionId) { peer in
                        meshPeerChip(peer)
                    }
                }
            }

            HStack(spacing: 10) {
                Button(showLog ? "Hide log" : "View log") {
                    showLog.toggle()
                }
                .buttonStyle(SecondaryButtonStyle())

                // A custom Transferable has no implicit ShareLink preview; the title
                // stays to the region id so no log content leaks into the share sheet.
                ShareLink(
                    item: SyncLogExport(regionId: outcome.regionId, syncedAt: response.syncedAt, log: response.log),
                    preview: SharePreview("\(outcome.regionId) sync log")
                ) {
                    Label("Share .log", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if showLog {
                ScrollView {
                    Text(response.log)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.contentSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(10)
                .background(theme.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.edgeSubtle, lineWidth: 1)
        }
    }

    private func countChip(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .foregroundStyle(theme.contentSecondary)
            Text("\(value)")
                .fontWeight(.semibold)
                .foregroundStyle(theme.content)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func meshPeerChip(_ peer: CloudGatewayRegionSyncMeshPeer) -> some View {
        let applied = peer.status == .applied
        return Text(peerChipText(peer))
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(applied ? theme.successSoft : theme.warningSoft)
            .foregroundStyle(applied ? theme.successStrong : theme.warningStrong)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(applied ? theme.successSoftEdge : theme.warningSoftEdge, lineWidth: 1)
            }
    }

    private func peerChipText(_ peer: CloudGatewayRegionSyncMeshPeer) -> String {
        let reason = peer.reasonCode.map { " (\($0))" } ?? ""
        return "\(peer.regionId): \(peer.status.rawValue)\(reason)"
    }

    private func syncedAtText(_ raw: String) -> String {
        guard let date = CloudGatewayRegionSyncParsing.syncedAtDate(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// Exports the sync log as a `.log` file via ShareLink only. Content is held
// in memory and handed to the system share sheet; this type never writes to
// disk, prints, or logs the (sensitive) log text itself.
private struct SyncLogExport: Transferable {
    let regionId: String
    let syncedAt: String
    let log: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { export in
            Data(export.log.utf8)
        }
        .suggestedFileName { export in
            export.filename
        }
    }

    private var filename: String {
        "sync_log_\(regionId)_\(Self.filenameTimestamp(for: syncedAt)).log"
    }

    private static func filenameTimestamp(for syncedAt: String) -> String {
        let date = CloudGatewayRegionSyncParsing.syncedAtDate(syncedAt) ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let year = components.year ?? 1970
        return "\(year)\(pad(components.month))\(pad(components.day))-\(pad(components.hour))\(pad(components.minute))\(pad(components.second))"
    }
}
