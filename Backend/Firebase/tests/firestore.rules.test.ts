import { readFileSync } from "node:fs";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where,
} from "firebase/firestore";
import { afterAll, beforeAll, describe, it } from "vitest";

let testEnv: RulesTestEnvironment;

// Firestore instance for an authenticated uid / anonymous caller. Contexts are
// cheap; each test grabs a fresh one.
const authed = (uid: string) => testEnv.authenticatedContext(uid).firestore();
const unauthed = () => testEnv.unauthenticatedContext().firestore();

beforeAll(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "demo-cloudgateway",
    firestore: { rules: readFileSync("firestore.rules", "utf8") },
  });

  // Seed with rules bypassed. isUser()/isAdmin() resolve off UserRoles plus enabled Users docs.
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "UserRoles/user1"), { roleId: "user" });
    await setDoc(doc(db, "UserRoles/admin1"), { roleId: "admin" });
    await setDoc(doc(db, "UserRoles/disabled1"), { roleId: "user" });
    await setDoc(doc(db, "UserRoles/approver1"), { roleId: "user" });
    await setDoc(doc(db, "UserRoles/other1"), { roleId: "user" });
    await setDoc(doc(db, "UserRoles/nofield1"), { roleId: "user" });
    await setDoc(doc(db, "Users/user1"), { email: "user1@example.com", disabled: false });
    await setDoc(doc(db, "Users/admin1"), { email: "admin1@example.com", disabled: false });
    await setDoc(doc(db, "Users/disabled1"), { email: "disabled1@example.com", disabled: true });
    await setDoc(doc(db, "Users/approver1"), { email: "approver1@example.com", disabled: false });
    await setDoc(doc(db, "Users/other1"), { email: "other1@example.com", disabled: false });
    // A provisioned user whose Users doc predates the disabled field: absent must
    // read as "not disabled" so isUser() stays true.
    await setDoc(doc(db, "Users/nofield1"), { email: "nofield1@example.com" });
    await setDoc(doc(db, "Roles/admin"), { label: "Admin" });
    await setDoc(doc(db, "Regions/us-1"), { enabled: true, displayName: "US 1", displayOrder: 1 });
    await setDoc(doc(db, "Regions/us-off"), { enabled: false, displayName: "Off", displayOrder: 2 });
    await setDoc(doc(db, "Regions/us-1/Instances/inst1"), { ownerUid: "user1" });
    await setDoc(doc(db, "Regions/us-1/Instances/inst2"), { ownerUid: "other" });
    await setDoc(doc(db, "Regions/us-1/Instances/disabled-inst"), { ownerUid: "disabled1" });
    await setDoc(doc(db, "Regions/us-1/Instances/nofield-inst"), { ownerUid: "nofield1" });
    await setDoc(doc(db, "Mesh/us-1"), { regionId: "us-1", meshEnabled: true, peers: {} });
    await setDoc(doc(db, "Policy/us-1"), {
      regionId: "us-1",
      mapHashV4: "abc",
      mapHashV6: "def",
      rowCount: 0,
    });
    await setDoc(doc(db, "Counters/accountSlots"), { nextSlot: 1 });
    await setDoc(doc(db, "DeviceAuthRequests/0123456789abcdef0123456789abcdef"), {
      deviceSecretHash: "a".repeat(64),
      userCodeHash: "b".repeat(64),
      deviceName: "Test device",
      state: "approved",
      decidedUid: "approver1",
      approvedUid: "approver1",
      createdAt: new Date("2026-01-01T00:00:00Z"),
      decidedAt: new Date("2026-01-01T00:01:00Z"),
      expiresAt: new Date("2026-01-01T00:05:00Z"),
      nextPollAt: new Date("2026-01-01T00:00:05Z"),
    });
    await setDoc(doc(db, "DeviceAuthLimits/creation-source-digest"), {
      scope: "creation",
      attempts: [new Date("2026-01-01T00:00:00Z")],
      expiresAt: new Date("2026-01-01T00:05:00Z"),
    });
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

describe("reads stay allowed for the clients that use them", () => {
  it("user reads its own UserRoles but not another's; admin reads any", async () => {
    await assertSucceeds(getDoc(doc(authed("user1"), "UserRoles/user1")));
    await assertFails(getDoc(doc(authed("user1"), "UserRoles/admin1")));
    await assertSucceeds(getDoc(doc(authed("admin1"), "UserRoles/user1")));
  });

  it("only admins list Users", async () => {
    await assertSucceeds(getDocs(collection(authed("admin1"), "Users")));
    await assertFails(getDocs(collection(authed("user1"), "Users")));
  });

  it("owner reads its own Instance, not another's; admin reads any", async () => {
    await assertSucceeds(getDoc(doc(authed("user1"), "Regions/us-1/Instances/inst1")));
    await assertFails(getDoc(doc(authed("user1"), "Regions/us-1/Instances/inst2")));
    await assertSucceeds(getDoc(doc(authed("admin1"), "Regions/us-1/Instances/inst2")));
  });

  it("collectionGroup Instances: user filtered by ownerUid, admin unfiltered", async () => {
    await assertSucceeds(
      getDocs(query(collectionGroup(authed("user1"), "Instances"), where("ownerUid", "==", "user1"))),
    );
    await assertFails(
      getDocs(query(collectionGroup(authed("user1"), "Instances"), where("ownerUid", "==", "other"))),
    );
    await assertFails(getDocs(collectionGroup(authed("user1"), "Instances")));
    await assertSucceeds(getDocs(collectionGroup(authed("admin1"), "Instances")));
  });

  it("regions: provisioned sees enabled; disabled is admin-only; unauth and unprovisioned denied", async () => {
    await assertSucceeds(getDoc(doc(authed("user1"), "Regions/us-1")));
    await assertSucceeds(getDocs(query(collection(authed("user1"), "Regions"), where("enabled", "==", true))));
    await assertFails(getDoc(doc(authed("user1"), "Regions/us-off")));
    await assertFails(getDocs(collection(authed("user1"), "Regions")));
    await assertSucceeds(getDoc(doc(authed("admin1"), "Regions/us-off")));
    await assertSucceeds(getDocs(collection(authed("admin1"), "Regions")));
    await assertFails(getDoc(doc(unauthed(), "Regions/us-1")));
    await assertFails(getDoc(doc(authed("nouser"), "Regions/us-1")));
  });

  it("provisioned users with no disabled field are treated as enabled", async () => {
    await assertSucceeds(getDoc(doc(authed("nofield1"), "UserRoles/nofield1")));
    await assertSucceeds(getDoc(doc(authed("nofield1"), "Users/nofield1")));
    await assertSucceeds(getDoc(doc(authed("nofield1"), "Regions/us-1")));
    await assertSucceeds(getDoc(doc(authed("nofield1"), "Regions/us-1/Instances/nofield-inst")));
    await assertSucceeds(
      getDocs(query(collectionGroup(authed("nofield1"), "Instances"), where("ownerUid", "==", "nofield1"))),
    );
  });

  it("disabled provisioned users cannot read user-scoped data", async () => {
    await assertFails(getDoc(doc(authed("disabled1"), "UserRoles/disabled1")));
    await assertFails(getDoc(doc(authed("disabled1"), "Users/disabled1")));
    await assertFails(getDoc(doc(authed("disabled1"), "Regions/us-1")));
    await assertFails(getDoc(doc(authed("disabled1"), "Regions/us-1/Instances/disabled-inst")));
    await assertFails(
      getDocs(query(collectionGroup(authed("disabled1"), "Instances"), where("ownerUid", "==", "disabled1"))),
    );
  });

  it("mesh status: admin reads, non-admin and unauthenticated cannot", async () => {
    await assertSucceeds(getDoc(doc(authed("admin1"), "Mesh/us-1")));
    await assertSucceeds(getDocs(collection(authed("admin1"), "Mesh")));
    await assertFails(getDoc(doc(authed("user1"), "Mesh/us-1")));
    await assertFails(getDocs(collection(authed("user1"), "Mesh")));
    await assertFails(getDoc(doc(unauthed(), "Mesh/us-1")));
    await assertFails(getDocs(collection(unauthed(), "Mesh")));
  });

  it("policy status: admin reads, non-admin and unauthenticated cannot", async () => {
    await assertSucceeds(getDoc(doc(authed("admin1"), "Policy/us-1")));
    await assertSucceeds(getDocs(collection(authed("admin1"), "Policy")));
    await assertFails(getDoc(doc(authed("user1"), "Policy/us-1")));
    await assertFails(getDocs(collection(authed("user1"), "Policy")));
    await assertFails(getDoc(doc(unauthed(), "Policy/us-1")));
    await assertFails(getDocs(collection(unauthed(), "Policy")));
  });

  it("counters: no client, including admins, can read the account-slot allocator", async () => {
    await assertFails(getDoc(doc(authed("admin1"), "Counters/accountSlots")));
    await assertFails(getDoc(doc(authed("user1"), "Counters/accountSlots")));
    await assertFails(getDoc(doc(unauthed(), "Counters/accountSlots")));
  });
});

describe("region meshEnabled toggle", () => {
  it("admin can flip meshEnabled alone", async () => {
    await assertSucceeds(updateDoc(doc(authed("admin1"), "Regions/us-1"), { meshEnabled: true }));
  });

  it("admin cannot change another field alone", async () => {
    await assertFails(updateDoc(doc(authed("admin1"), "Regions/us-1"), { displayName: "Changed" }));
  });

  it("admin cannot bundle another field with meshEnabled", async () => {
    await assertFails(
      updateDoc(doc(authed("admin1"), "Regions/us-1"), { meshEnabled: true, displayName: "Changed" }),
    );
  });

  it("admin cannot set meshEnabled to a non-boolean", async () => {
    await assertFails(updateDoc(doc(authed("admin1"), "Regions/us-1"), { meshEnabled: "yes" }));
  });

  it("a plain user cannot flip meshEnabled", async () => {
    await assertFails(updateDoc(doc(authed("user1"), "Regions/us-1"), { meshEnabled: true }));
  });

  it("admin cannot create a region doc via the meshEnabled-only rule", async () => {
    await assertFails(setDoc(doc(authed("admin1"), "Regions/us-new"), { meshEnabled: false }));
  });

  it("admin cannot delete a region doc", async () => {
    await assertFails(deleteDoc(doc(authed("admin1"), "Regions/us-1")));
  });
});

describe("every client write is denied — including admins", () => {
  // All paths reference seeded docs so update/delete fail on the rule, not on not-found.
  const writeTargets = [
    "Roles/admin",
    "UserRoles/user1",
    "Regions/us-1",
    "Users/user1",
    "Regions/us-1/Instances/inst1",
    "Mesh/us-1",
    "Policy/us-1",
    "Counters/accountSlots",
  ];

  for (const path of writeTargets) {
    for (const uid of ["user1", "admin1"]) {
      it(`${uid} cannot create/update/delete ${path}`, async () => {
        const db = authed(uid);
        await assertFails(setDoc(doc(db, path), { hacked: true }));
        await assertFails(updateDoc(doc(db, path), { hacked: true }));
        await assertFails(deleteDoc(doc(db, path)));
      });
    }
  }
});

describe("device authorization collections are API-only", () => {
  const clients = [
    { name: "anonymous", db: unauthed },
    { name: "normal user", db: () => authed("user1") },
    { name: "approving user", db: () => authed("approver1") },
    { name: "unrelated user", db: () => authed("other1") },
    { name: "admin", db: () => authed("admin1") },
    { name: "disabled user", db: () => authed("disabled1") },
    { name: "unprovisioned user", db: () => authed("nouser") },
  ];
  const collections = [
    {
      name: "DeviceAuthRequests",
      existingId: "0123456789abcdef0123456789abcdef",
      createId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      createData: { state: "pending" },
      updateData: { state: "denied" },
    },
    {
      name: "DeviceAuthLimits",
      existingId: "creation-source-digest",
      createId: "guess-user-digest",
      createData: { scope: "guesses", attempts: [] },
      updateData: { scope: "guesses" },
    },
  ];

  for (const client of clients) {
    for (const collectionPath of collections) {
      it(`${client.name} cannot read or write ${collectionPath.name}`, async () => {
        const db = client.db();
        await assertFails(getDoc(doc(db, `${collectionPath.name}/${collectionPath.existingId}`)));
        await assertFails(getDocs(collection(db, collectionPath.name)));
        await assertFails(setDoc(doc(db, `${collectionPath.name}/${collectionPath.createId}`), collectionPath.createData));
        await assertFails(
          updateDoc(doc(db, `${collectionPath.name}/${collectionPath.existingId}`), collectionPath.updateData),
        );
        await assertFails(deleteDoc(doc(db, `${collectionPath.name}/${collectionPath.existingId}`)));
      });
    }
  }
});
