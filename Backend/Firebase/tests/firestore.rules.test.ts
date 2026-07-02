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

  // Seed with rules bypassed. isUser()/isAdmin() resolve off UserRoles docs.
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "UserRoles/user1"), { roleId: "user" });
    await setDoc(doc(db, "UserRoles/admin1"), { roleId: "admin" });
    await setDoc(doc(db, "Users/user1"), { email: "user1@example.com" });
    await setDoc(doc(db, "Roles/admin"), { label: "Admin" });
    await setDoc(doc(db, "Regions/us-1"), { enabled: true, displayName: "US 1", displayOrder: 1 });
    await setDoc(doc(db, "Regions/us-off"), { enabled: false, displayName: "Off", displayOrder: 2 });
    await setDoc(doc(db, "Regions/us-1/Instances/inst1"), { ownerUid: "user1" });
    await setDoc(doc(db, "Regions/us-1/Instances/inst2"), { ownerUid: "other" });
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
});

describe("every client write is denied — including admins", () => {
  // All paths reference seeded docs so update/delete fail on the rule, not on not-found.
  const writeTargets = [
    "Roles/admin",
    "UserRoles/user1",
    "Regions/us-1",
    "Users/user1",
    "Regions/us-1/Instances/inst1",
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
