import Combine
import Foundation

/// Admin Server Health page state: mesh membership, mesh link status, mesh
/// warnings, and the all-region sync fan-out. Deliberately simpler than
/// `CloudGatewayViewModel`'s config state: no revision stamps or override map
/// for toggles - see `toggleMesh` for what makes the simpler model correct.
@MainActor
public final class CloudGatewayServerHealthViewModel: ObservableObject {
    @Published public private(set) var regions = [CloudGatewayMeshRegion]()
    @Published public private(set) var meshDocs = [String: CloudGatewayMeshDoc]()
    @Published public private(set) var linkRows = [CloudGatewayMeshLinkRow]()
    @Published public private(set) var warnings = [CloudGatewayMeshWarning]()
    @Published public private(set) var anyPending = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSyncing = false
    @Published public private(set) var dataAvailable = false
    @Published public private(set) var syncResults: [CloudGatewayRegionSyncOutcome]?
    @Published public private(set) var bannerText: String?
    @Published public private(set) var togglingRegionIds = Set<String>()

    private let service: any CloudGatewayServicing
    // A load() (or the post-sync mesh re-read) landed while a toggle was in
    // flight and was dropped to protect the toggle's optimistic value. Set so
    // the page still catches up once every in-flight toggle has cleared,
    // instead of staying stale until the next manual refresh.
    private var reloadPendingAfterToggle = false
    // Monotonic counter for every fetch-and-apply (load, the post-toggle
    // reload, syncAll's re-read). Two fetches can resolve out of order - a
    // slow pull-to-refresh finishing after a toggle's own reload - so a
    // resolving fetch only applies its results if it is still the newest one
    // issued, alongside (not instead of) the existing togglingRegionIds/uid
    // guards.
    private var loadGeneration = 0

    private func beginLoadGeneration() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    public init(service: any CloudGatewayServicing) {
        self.service = service
    }

    public var enabledRegions: [CloudGatewayMeshRegion] {
        regions.filter(\.enabled)
    }

    public var canSyncAll: Bool {
        !isSyncing && !enabledRegions.isEmpty && togglingRegionIds.isEmpty
    }

    public func canToggleMesh(_ region: CloudGatewayMeshRegion) -> Bool {
        region.enabled && !isSyncing && !togglingRegionIds.contains(region.regionId)
    }

    public func displayName(for regionId: String) -> String {
        regions.first { $0.regionId == regionId }?.displayName ?? regionId
    }

    public func meshLabel(for regionId: String) -> String {
        guard let region = regions.first(where: { $0.regionId == regionId }) else {
            return regionId
        }
        return region.enabled ? region.displayName : "\(region.displayName) (disabled)"
    }

    public func meshDoc(for regionId: String) -> CloudGatewayMeshDoc? {
        meshDocs[regionId]
    }

    public func dismissBanner() {
        bannerText = nil
    }

    public func load() async {
        let uid = service.currentUser?.uid
        let generation = beginLoadGeneration()
        isLoading = true
        defer { isLoading = false }
        do {
            let (fetchedRegions, fetchedMeshDocs) = try await fetchMeshState()
            guard service.currentUser?.uid == uid, generation == loadGeneration else { return }
            guard togglingRegionIds.isEmpty else {
                reloadPendingAfterToggle = true
                return
            }
            apply(regions: fetchedRegions, meshDocs: fetchedMeshDocs)
        } catch {
            guard service.currentUser?.uid == uid, generation == loadGeneration else { return }
            bannerText = "Unable to load server health data."
        }
    }

    // Deliberately simple: the only guards are "not already toggling this
    // region" and "not syncing" (mirrors canToggleMesh). A load() that lands
    // mid-toggle is dropped rather than reconciled against an override map,
    // and a fresh load is issued once every toggle has cleared - either from
    // this toggle's own success path or from reloadPendingAfterToggle once
    // the last one finishes.
    public func toggleMesh(region: CloudGatewayMeshRegion) async {
        guard region.enabled, !isSyncing, !togglingRegionIds.contains(region.regionId) else {
            return
        }
        let uid = service.currentUser?.uid
        let regionId = region.regionId
        let originalValue = region.meshEnabled
        let newValue = !originalValue
        togglingRegionIds.insert(regionId)
        setLocalMeshEnabled(regionId: regionId, enabled: newValue)

        var succeeded = false
        do {
            try await service.setRegionMeshEnabled(regionId: regionId, enabled: newValue)
            if service.currentUser?.uid == uid {
                succeeded = true
            }
        } catch {
            if service.currentUser?.uid == uid {
                setLocalMeshEnabled(regionId: regionId, enabled: originalValue)
                bannerText = "Unable to update \(region.displayName)."
            }
        }

        // Both the success and failure paths above fall through to this
        // bookkeeping even on a uid mismatch, so a pending catch-up reload
        // is always consumed instead of leaking the flag forever.
        togglingRegionIds.remove(regionId)
        let shouldCatchUpStaleLoad = togglingRegionIds.isEmpty && reloadPendingAfterToggle
        if shouldCatchUpStaleLoad {
            reloadPendingAfterToggle = false
        }
        if succeeded || shouldCatchUpStaleLoad {
            await load()
        }
    }

    public func syncAll() async {
        guard !isSyncing, !enabledRegions.isEmpty, togglingRegionIds.isEmpty else { return }
        let uid = service.currentUser?.uid
        let regionIds = enabledRegions.map(\.regionId)
        isSyncing = true
        defer { isSyncing = false }

        let idToken: String
        do {
            idToken = try await service.idToken()
        } catch {
            guard service.currentUser?.uid == uid else { return }
            bannerText = "Unable to sync regions."
            return
        }
        guard service.currentUser?.uid == uid else { return }

        // One token fetched immediately before the fan-out and reused across
        // all of it - no mid-fan-out refresh or retry. An expiry surfaces as
        // that region's own failure card.
        let outcomes = await service.syncRegions(regionIds: regionIds, idToken: idToken)
        guard service.currentUser?.uid == uid else { return }
        syncResults = outcomes

        // The fan-out response is ephemeral; Mesh/* is the durable state the
        // link rows render, so re-read it once the fan-out settles. No
        // togglingRegionIds guard here: toggleMesh refuses to start while
        // isSyncing (held for this whole function via defer), so a toggle
        // can never be in flight at this point.
        let generation = beginLoadGeneration()
        guard let (fetchedRegions, fetchedMeshDocs) = try? await fetchMeshState() else {
            return
        }
        guard service.currentUser?.uid == uid, generation == loadGeneration else { return }
        apply(regions: fetchedRegions, meshDocs: fetchedMeshDocs)
    }

    // `async let` on a non-Sendable @MainActor-isolated service existential
    // does not typecheck under Swift 6 strict concurrency (the child task
    // can't statically prove it stays on the actor), so this uses unstructured
    // Tasks instead - still concurrent, since each awaits a suspension point
    // independently while `self` stays pinned to the main actor throughout.
    private func fetchMeshState() async throws -> ([CloudGatewayMeshRegion], [String: CloudGatewayMeshDoc]) {
        let regionsTask = Task { try await service.fetchMeshRegions() }
        let meshDocsTask = Task { try await service.fetchMeshDocs() }
        return (try await regionsTask.value, try await meshDocsTask.value)
    }

    private func apply(regions: [CloudGatewayMeshRegion], meshDocs: [String: CloudGatewayMeshDoc]) {
        self.regions = regions
        self.meshDocs = meshDocs
        recomputeDerivedState()
        dataAvailable = true
    }

    private func recomputeDerivedState() {
        linkRows = CloudGatewayMeshStatus.buildMeshLinkRows(regions: regions, meshDocs: meshDocs)
        warnings = CloudGatewayMeshStatus.collectMeshWarnings(meshDocs)
        anyPending = CloudGatewayMeshStatus.hasAnyMeshPending(regions: regions, meshDocs: meshDocs)
    }

    private func setLocalMeshEnabled(regionId: String, enabled: Bool) {
        guard let index = regions.firstIndex(where: { $0.regionId == regionId }) else { return }
        let region = regions[index]
        regions[index] = CloudGatewayMeshRegion(
            regionId: region.regionId,
            displayName: region.displayName,
            enabled: region.enabled,
            displayOrder: region.displayOrder,
            meshEnabled: enabled,
            wireguardPublicKey: region.wireguardPublicKey,
            wireguardEndpointHostname: region.wireguardEndpointHostname,
            wireguardPort: region.wireguardPort,
            tunnelNetworkV4: region.tunnelNetworkV4,
            tunnelNetworkV6: region.tunnelNetworkV6
        )
        recomputeDerivedState()
    }
}
