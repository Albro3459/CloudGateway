// Firestore document shapes for the shared regional VPN platform.
// These are documentation types, not runtime validators.

export type FirestoreTimestamp = unknown;

export type FirebaseRole = "user" | "admin";

export type FirebaseClientStatus = "creating" | "active" | "failed" | "removed";

export type FirebaseOperationResult = "success" | "failed" | "noop";

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
    userClientLimit: number;
    activeClientCount: number;
    displayOrder?: number;
    healthStatus?: string;
    updatedAt: FirestoreTimestamp;
};

export type FirebaseUserDoc = {
    uid: string;
    email: string;
    createdAt: FirestoreTimestamp;
    disabled?: boolean;
};

export type FirebaseUserRegionDoc = {
    regionId: string;
    updatedAt: FirestoreTimestamp;
};

export type FirebaseRoleDoc = {
    role: FirebaseRole;
    updatedAt: FirestoreTimestamp;
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
        "{regionId}": FirebaseRegionDoc;
    };
    Roles: {
        "{uid}": FirebaseRoleDoc;
    };
    Users: {
        "{uid}": 
            FirebaseUserDoc & 
            {
                Regions: {
                    "{regionId}": 
                        FirebaseUserRegionDoc & 
                        {
                            Instances: {
                                "{clientId}": FirebaseClientDoc;
                            };
                        };
                };
            };
    };
};
