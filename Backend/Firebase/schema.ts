// Firestore document shapes for the shared regional VPN platform.
// These are documentation types, not runtime validators.

export type FirestoreTimestamp = unknown;

export type FirebaseRole = "user" | "admin";

export type FirebaseClientStatus = "creating" | "active" | "failed" | "removed";

export type FirebaseOperationResult = "success" | "failed" | "noop";

export type FirebaseMeshPeerStatus = "applied" | "skipped-overlap" | "skipped-incomplete";

export type FirebaseMeshPeerReasonCode =
    | "missing-public-key"
    | "invalid-public-key"
    | "missing-endpoint-hostname"
    | "invalid-endpoint-hostname"
    | "invalid-endpoint-port"
    | "missing-network-v4"
    | "invalid-network-v4"
    | "missing-network-v6"
    | "invalid-network-v6"
    | "outside-aggregate"
    | "duplicate-public-key"
    | "local-network-invalid"
    | "overlap-local"
    | "overlap-candidate";

export type FirebaseRegionDoc = {
    regionId: string;
    displayName: string;
    enabled: boolean;
    wireguardEndpointIpv4: string;
    wireguardEndpointIpv6: string | null;
    wireguardEndpointHostname: string;
    wireguardPort: number;
    wireguardDnsIpv4: string;
    wireguardDnsIpv6: string;
    wireguardPublicKey: string;
    capacityLimit: number;
    tunnelNetworkV4: string;
    tunnelNetworkV6: string;
    meshEnabled?: boolean;
    displayOrder?: number;
    healthStatus?: string;
    // Per-region monotonic index into the tunnel network, advanced on every
    // allocation. Replaces lowest-free-address reuse; paired so a client's v4
    // and v6 addresses share an index. v4 wraps at the top of the host range,
    // v6 never does.
    tunnelIndexV4?: number;
    tunnelIndexV6?: number;
    updatedAt: FirestoreTimestamp;
};

type FirebaseMeshPeerMetadata = {
    endpointHostname: string;
    endpointPort: number;
    publicKey: string;
    allowedNetworkV4: string;
    allowedNetworkV6: string;
    appliedAt: FirestoreTimestamp;
};

export type FirebaseMeshPeerEntry =
    | (FirebaseMeshPeerMetadata & {
        status: "applied";
        reasonCode?: FirebaseMeshPeerReasonCode | string;
    })
    | (FirebaseMeshPeerMetadata & {
        status: "skipped-overlap";
        reasonCode: FirebaseMeshPeerReasonCode | string;
    })
    | {
        status: "skipped-incomplete";
        endpointHostname?: string;
        endpointPort?: number;
        publicKey?: string;
        allowedNetworkV4?: string;
        allowedNetworkV6?: string;
        reasonCode: FirebaseMeshPeerReasonCode | string;
        appliedAt: FirestoreTimestamp;
    };

export type FirebaseMeshDoc = {
    regionId: string;
    meshEnabled: boolean;
    updatedAt: FirestoreTimestamp;
    peers: Record<string, FirebaseMeshPeerEntry>;
};

// Account-scoped ACL status, one per region. Observability only: written by
// each region's host via the Admin SDK after a policy reconcile pass, and
// describes what the live nftables map on that host actually contains, not
// what the region intended to apply.
export type FirebasePolicyDoc = {
    regionId: string;
    mapHashV4: string;
    mapHashV6: string;
    rowCount: number;
    // Always written null since the Wave 3 ordering remediation - cross-process
    // ordering is enforced by the policy flock itself, not a counter. Kept only
    // so the document shape is stable until Wave 5 removes it.
    appliedSequence: number | null;
    // Max updatedAt across the applied snapshot; the freshness signal, unlike
    // the hashes it stays meaningful even if maps are ever allowed to differ
    // between regions.
    dataVintage: FirestoreTimestamp | null;
    updatedAt: FirestoreTimestamp;
};

export type FirebaseRoleDoc = {
    roleId: FirebaseRole;
    defaultPerRegionClientLimit: number | null;
    updatedAt: FirestoreTimestamp;
};

export type FirebaseUserRoleDoc = {
    uid: string;
    roleId: FirebaseRole;
    perRegionClientLimit?: number | null;
    updatedAt: FirestoreTimestamp;
};

export type FirebaseUserDoc = {
    uid: string;
    email: string;
    createdAt: FirestoreTimestamp;
    disabled?: boolean;
    // Opaque account-scoped ACL identifier, allocated once from Counters/accountSlots
    // and never reused. Hosts key their client-to-client filter on this, not on uid.
    accountSlot?: number;
};

export type FirebaseClientDoc = {
    clientId: string;
    ownerUid: string;
    ownerEmail: string;
    clientName: string;
    regionId: string;
    status: FirebaseClientStatus;
    assignedTunnelIpv4: string;
    assignedTunnelIpv6: string;
    serverEndpointIpv4: string;
    serverEndpointHostname: string;
    serverPublicKey: string;
    clientPublicKey: string;
    wireguardConfig: string | null;
    createdAt: FirestoreTimestamp;
    updatedAt: FirestoreTimestamp;
    removedAt: FirestoreTimestamp | null;
    lastErrorCode: string | null;
    lastErrorMessage: string | null;
};

// Document id is always "accountSlots". Admin-SDK-only allocator for
// accountSlot; nextSlot only ever increments, never reused.
export type FirebaseCounterDoc = {
    nextSlot: number;
    updatedAt: FirestoreTimestamp;
};

export type FirebaseDocumentTree = {
    Regions: {
        "{regionId}": FirebaseRegionDoc & {
            Instances: {
                "{clientId}": FirebaseClientDoc;
            };
        };
    };
    Roles: {
        "{roleId}": FirebaseRoleDoc;
    };
    UserRoles: {
        "{uid}": FirebaseUserRoleDoc;
    };
    Users: {
        "{uid}": FirebaseUserDoc;
    };
    Mesh: {
        "{regionId}": FirebaseMeshDoc;
    };
    Policy: {
        "{regionId}": FirebasePolicyDoc;
    };
    Counters: {
        accountSlots: FirebaseCounterDoc;
    };
};
