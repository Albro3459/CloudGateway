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
};
