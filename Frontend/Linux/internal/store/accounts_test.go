package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

var (
	hashA     = strings.Repeat("a", 64)
	hashB     = strings.Repeat("b", 64)
	fixedTime = time.Unix(1, 0).UTC()
)

func newCache(t *testing.T) *AccountCache {
	t.Helper()
	cache := openStore(t).Accounts()
	cache.now = func() time.Time { return fixedTime }
	return cache
}

func reopen(cache *AccountCache) *AccountCache {
	reopened := newAccountCache(cache.dir)
	reopened.now = cache.now
	return reopened
}

func fixture(accountID, clientID string) (InstalledConfig, AuthorizedOption) {
	config := InstalledConfig{
		AccountID: accountID, Identifier: accountID + "/us-a/" + clientID,
		Snapshot: ConfigSnapshot{
			ClientID: clientID, RegionID: "us-a", ClientName: "Mac", RegionDisplayName: "US", Status: "active",
			ConfigHash: hashA, SecretReference: "0123456789abcdef0123456789abcdef", ReadAt: fixedTime,
		},
	}
	option := AuthorizedOption{
		ClientID: clientID, RegionID: "us-a", ClientName: "Mac", RegionDisplayName: "US", Status: "active",
		OwnerUID: accountID, Usable: true, ConfigHash: hashA,
	}
	return config, option
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func load(t *testing.T, cache *AccountCache, accountID string) InventorySnapshot {
	t.Helper()
	snapshot, err := cache.Load(accountID)
	must(t, err)
	return snapshot
}

func expectErr(t *testing.T, err, want error) {
	t.Helper()
	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func modePtr(mode ipc.Mode) *ipc.Mode { return &mode }

// breakAccountDir swaps the account directory for a file so writes fail, and returns a restore func
func breakAccountDir(t *testing.T, cache *AccountCache, accountID string) func() {
	t.Helper()
	dir := filepath.Dir(cache.path(accountID))
	backup := filepath.Join(cache.dir, "backup")
	must(t, os.Rename(dir, backup))
	must(t, os.WriteFile(dir, nil, 0o600))
	return func() {
		must(t, os.Rename(dir, filepath.Join(cache.dir, "blocker")))
		must(t, os.Rename(backup, dir))
	}
}

func TestAccountCacheStoresMetadataAndSelectionWithoutConfigMaterial(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Select(config.Identifier, "user-a"))
	restored := load(t, reopen(cache), "user-a")
	want := InventorySnapshot{Configs: []InstalledConfig{config}, SelectedIdentifier: config.Identifier, AccessAllowed: true, SelectedMode: modePtr(ipc.ModeFull)}
	if !reflect.DeepEqual(restored, want) {
		t.Fatalf("restored = %+v", restored)
	}
	entries, _ := os.ReadDir(cache.dir)
	if len(entries) != 1 || entries[0].Name() != "fc95297aa4f56781f0decb7d4bf59b1447f09b3611039b80188b1c6beb03ee6a" {
		t.Fatalf("entries = %v", entries)
	}
	dir := filepath.Join(cache.dir, entries[0].Name())
	if got := mode(t, dir); got != 0o700 {
		t.Fatalf("dir mode = %o", got)
	}
	if got := mode(t, filepath.Join(dir, "inventory.json")); got != 0o600 {
		t.Fatalf("file mode = %o", got)
	}
	data, err := os.ReadFile(filepath.Join(dir, "inventory.json"))
	must(t, err)
	for _, text := range []string{"PrivateKey", "wireGuardConfig", "customToken"} {
		if strings.Contains(string(data), text) {
			t.Fatalf("cache contains %s", text)
		}
	}
}

func TestAccountCacheDoesNotShareInventoryOrSelectionBetweenAccounts(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Select(config.Identifier, "user-a"))
	other := load(t, cache, "user-b")
	if len(other.Configs) != 0 || other.SelectedIdentifier != "" || other.AccessAllowed {
		t.Fatalf("other = %+v", other)
	}
	expectErr(t, cache.Select(config.Identifier, "user-b"), ErrInvalidMetadata)
	if got := load(t, cache, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestExplicitDenialPersistsAndLateInstallationCannotRestoreOfflineAccess(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Deny("user-a"))
	expectErr(t, cache.Save(config), ErrAccessDenied)
	restored := load(t, reopen(cache), "user-a")
	if len(restored.Configs) != 0 || restored.AccessAllowed {
		t.Fatalf("restored = %+v", restored)
	}
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	if !load(t, cache, "user-a").AccessAllowed {
		t.Fatal("access not restored")
	}
}

func TestDenialStillBlocksOfflineCacheWhenPersistenceFails(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	restore := breakAccountDir(t, cache, "user-a")
	expectErr(t, cache.Deny("user-a"), ErrUnavailable)
	restore()
	denied := load(t, cache, "user-a")
	if denied.AccessAllowed || len(denied.Configs) != 0 {
		t.Fatalf("denied = %+v", denied)
	}
	expectErr(t, cache.Save(config), ErrAccessDenied)
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	if got := load(t, cache, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestSuccessfulRefreshPrunesRevokedOrRotatedInstalledConfigs(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Select(config.Identifier, "user-a"))
	rotated := option
	rotated.ConfigHash = hashB
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{rotated}))
	if snapshot := load(t, cache, "user-a"); len(snapshot.Configs) != 0 || snapshot.SelectedIdentifier != "" {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	expectErr(t, cache.Save(config), ErrAccessDenied)
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Authorize("user-a", RoleUser, nil))
	if snapshot := load(t, cache, "user-a"); len(snapshot.Configs) != 0 {
		t.Fatalf("snapshot = %+v", snapshot)
	}
}

func TestRefreshUpdatesOfflineNamesWithoutReplacingInstalledSecret(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Select(config.Identifier, "user-a"))
	renamed := option
	renamed.ClientName = "Renamed Mac"
	renamed.RegionDisplayName = "Renamed Region"
	renamed.UpdatedAt = time.Unix(50, 0).UTC()
	renamed.ServerEndpointHostname = "wg.example.com"
	later := time.Unix(100, 0).UTC()
	cache.now = func() time.Time { return later }
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{renamed}))
	restored := load(t, cache, "user-a")
	want := config
	want.Snapshot.ClientName = "Renamed Mac"
	want.Snapshot.RegionDisplayName = "Renamed Region"
	want.Snapshot.UpdatedAt = time.Unix(50, 0).UTC()
	want.Snapshot.ServerEndpointHostname = "wg.example.com"
	want.Snapshot.ReadAt = later
	if !reflect.DeepEqual(restored.Configs, []InstalledConfig{want}) || restored.SelectedIdentifier != config.Identifier {
		t.Fatalf("restored = %+v", restored)
	}
}

func TestDuplicateAuthorizationDoesNotReplaceValidCache(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	expectErr(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option, option}), ErrInvalidMetadata)
	invalid := option
	invalid.ConfigHash = "ABC"
	expectErr(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{invalid}), ErrInvalidMetadata)
	if got := load(t, cache, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestRemovedClientHistoryDoesNotBlockLiveInventoryOrRetainRemovedConfigs(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	var history []AuthorizedOption
	for index := range 1001 {
		history = append(history, AuthorizedOption{ClientID: fmt.Sprintf("removed-%d", index), RegionID: "us-a", Status: "removed", OwnerUID: "user-a"})
	}
	must(t, cache.Authorize("user-a", RoleUser, append(history, option)))
	must(t, cache.Save(config))
	if got := load(t, reopen(cache), "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
	must(t, cache.Authorize("user-a", RoleUser, history))
	if got := load(t, cache, "user-a").Configs; len(got) != 0 {
		t.Fatalf("configs = %+v", got)
	}
	expectErr(t, cache.Save(config), ErrAccessDenied)
}

func TestLiveInventoryLimitStillRejectsOverflowWithoutChangingAuthorization(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	var overflow []AuthorizedOption
	for index := range 1001 {
		active := option
		active.ClientID = fmt.Sprintf("active-%d", index)
		overflow = append(overflow, active)
	}
	expectErr(t, cache.Authorize("user-a", RoleUser, overflow), ErrInvalidMetadata)
	if got := load(t, cache, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestCacheRejectsUnboundConfigsAndSecretReferences(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	forged := config
	forged.AccountID = "user-b"
	expectErr(t, cache.Save(forged), ErrInvalidMetadata)
	_, err := cache.Load("")
	expectErr(t, err, ErrInvalidMetadata)
	for _, reference := range []string{"invalid", "0123456789ABCDEF0123456789ABCDEF", "6f9619ff-8b86-d011-b42d-00cf4fc964ff"} {
		malformed := config
		malformed.Snapshot.SecretReference = reference
		expectErr(t, cache.Save(malformed), ErrInvalidMetadata)
	}
	inactive := config
	inactive.Snapshot.Status = "creating"
	expectErr(t, cache.Save(inactive), ErrInvalidMetadata)
	must(t, cache.Save(config))
	if got := load(t, cache, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestAdminDowngradeBlocksTransportFallbackAndPersistsAcrossRestart(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	option.OwnerUID = "other-owner"
	must(t, cache.Authorize("user-a", RoleAdmin, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Select(config.Identifier, "user-a"))
	invalidated, err := cache.ObserveRole("user-a", RoleUser)
	if err != nil || !invalidated {
		t.Fatalf("invalidated = %v, err = %v", invalidated, err)
	}
	denied := load(t, cache, "user-a")
	if len(denied.Configs) != 0 || denied.SelectedIdentifier != "" || denied.AccessAllowed {
		t.Fatalf("denied = %+v", denied)
	}
	expectErr(t, cache.Save(config), ErrAccessDenied)
	if restored := load(t, reopen(cache), "user-a"); !reflect.DeepEqual(restored, denied) {
		t.Fatalf("restored = %+v", restored)
	}
	must(t, cache.Authorize("user-a", RoleUser, nil))
	if !load(t, cache, "user-a").AccessAllowed {
		t.Fatal("access not restored")
	}
}

func TestObservingUnchangedOrUpgradedRolePreservesOfflineInventory(t *testing.T) {
	for _, test := range []struct{ authorized, observed Role }{
		{RoleUser, RoleUser}, {RoleAdmin, RoleAdmin}, {RoleUser, RoleAdmin},
	} {
		cache := newCache(t)
		config, option := fixture("user-a", "client-a")
		must(t, cache.Authorize("user-a", test.authorized, []AuthorizedOption{option}))
		must(t, cache.Save(config))
		must(t, cache.Select(config.Identifier, "user-a"))
		saved := load(t, cache, "user-a")
		invalidated, err := cache.ObserveRole("user-a", test.observed)
		if err != nil || invalidated {
			t.Fatalf("%v: invalidated = %v, err = %v", test, invalidated, err)
		}
		if got := load(t, cache, "user-a"); !reflect.DeepEqual(got, saved) || !got.AccessAllowed {
			t.Fatalf("%v: snapshot = %+v", test, got)
		}
	}
}

func TestLegacyCacheWithoutRoleRequiresCompleteAuthorizedRefresh(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleAdmin, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.Select(config.Identifier, "user-a"))
	path := cache.path("user-a")
	var legacy map[string]any
	data, _ := os.ReadFile(path)
	must(t, json.Unmarshal(data, &legacy))
	delete(legacy, "authorizedRole")
	data, _ = json.Marshal(legacy)
	must(t, os.WriteFile(path, data, 0o600))
	reopened := reopen(cache)
	restored := load(t, reopened, "user-a")
	if len(restored.Configs) != 0 || restored.SelectedIdentifier != "" || restored.AccessAllowed {
		t.Fatalf("restored = %+v", restored)
	}
	expectErr(t, reopened.Save(config), ErrAccessDenied)
	must(t, reopened.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, reopened.Save(config))
	if got := load(t, reopened, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestUserAuthorizationRejectsAnotherOwnersOptionsWithoutChangingCache(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	foreign := option
	foreign.OwnerUID = "other-owner"
	expectErr(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{foreign}), ErrAccessDenied)
	if got := load(t, cache, "user-a").Configs; !reflect.DeepEqual(got, []InstalledConfig{config}) {
		t.Fatalf("configs = %+v", got)
	}
}

func TestDowngradeBlocksOfflineCacheEvenWhenDenialPersistenceFails(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	option.OwnerUID = "other-owner"
	must(t, cache.Authorize("user-a", RoleAdmin, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	restore := breakAccountDir(t, cache, "user-a")
	_, err := cache.ObserveRole("user-a", RoleUser)
	expectErr(t, err, ErrUnavailable)
	restore()
	if denied := load(t, cache, "user-a"); len(denied.Configs) != 0 || denied.AccessAllowed {
		t.Fatalf("denied = %+v", denied)
	}
	expectErr(t, cache.Save(config), ErrAccessDenied)
}

func TestEvictionPreservesOtherClientsAuthorizationRoleAndSelection(t *testing.T) {
	for _, role := range []Role{RoleUser, RoleAdmin} {
		for _, selectedTarget := range []bool{false, true} {
			cache := newCache(t)
			target, targetOption := fixture("user-a", "client-a")
			remaining, remainingOption := fixture("user-a", "client-b")
			otherAccount, otherOption := fixture("user-b", "client-a")
			must(t, cache.Authorize("user-a", role, []AuthorizedOption{targetOption, remainingOption}))
			must(t, cache.Save(target))
			must(t, cache.Save(remaining))
			selected := remaining.Identifier
			if selectedTarget {
				selected = target.Identifier
			}
			must(t, cache.Select(selected, "user-a"))
			must(t, cache.Authorize("user-b", RoleUser, []AuthorizedOption{otherOption}))
			must(t, cache.Save(otherAccount))
			must(t, cache.Select(otherAccount.Identifier, "user-b"))
			otherBefore := load(t, cache, "user-b")

			evicted, err := cache.Evict(target.Identifier, "user-a")
			must(t, err)
			wantSelection := remaining.Identifier
			if selectedTarget {
				wantSelection = ""
			}
			if !reflect.DeepEqual(evicted.Configs, []InstalledConfig{remaining}) || evicted.SelectedIdentifier != wantSelection || !evicted.AccessAllowed {
				t.Fatalf("evicted = %+v", evicted)
			}
			reopened := reopen(cache)
			if got := load(t, reopened, "user-a"); !reflect.DeepEqual(got, evicted) {
				t.Fatalf("reopened = %+v", got)
			}
			if got := load(t, reopened, "user-b"); !reflect.DeepEqual(got, otherBefore) {
				t.Fatalf("other = %+v", got)
			}
			if invalidated, err := reopened.ObserveRole("user-a", role); err != nil || invalidated {
				t.Fatalf("observe same role = %v, %v", invalidated, err)
			}
			expectErr(t, reopened.Save(target), ErrAccessDenied)
			expectErr(t, reopened.Select(target.Identifier, "user-a"), ErrInvalidMetadata)
			must(t, reopened.Save(remaining))
			must(t, reopened.Select(remaining.Identifier, "user-a"))
			if got := load(t, reopened, "user-a").SelectedIdentifier; got != remaining.Identifier {
				t.Fatalf("selection = %q", got)
			}
			if invalidated, _ := reopened.ObserveRole("user-a", RoleUser); invalidated != (role == RoleAdmin) {
				t.Fatalf("role %s: invalidated = %v", role, invalidated)
			}
		}
	}
}

func TestEvictionRevokesANeverInstalledClientAndIsIdempotent(t *testing.T) {
	cache := newCache(t)
	target, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	evicted, err := cache.Evict(target.Identifier, "user-a")
	must(t, err)
	want := InventorySnapshot{Configs: []InstalledConfig{}, AccessAllowed: true, SelectedMode: modePtr(ipc.ModeFull)}
	if !reflect.DeepEqual(evicted, want) {
		t.Fatalf("evicted = %+v", evicted)
	}
	reopened := reopen(cache)
	expectErr(t, reopened.Save(target), ErrAccessDenied)
	again, err := reopened.Evict(target.Identifier, "user-a")
	if err != nil || !reflect.DeepEqual(again, want) {
		t.Fatalf("again = %+v, err = %v", again, err)
	}
	must(t, reopened.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, reopened.Save(target))
	if got := load(t, reopened, "user-a"); !reflect.DeepEqual(got.Configs, []InstalledConfig{target}) || got.SelectedIdentifier != "" {
		t.Fatalf("snapshot = %+v", got)
	}
}

func TestEvictionRejectsInvalidNamespacesWithoutChangingCache(t *testing.T) {
	for _, identifier := range []string{
		"user-b/us-a/client-a", "user-a/us-a/", "user-a//client-a", "/us-a/client-a",
		"user-a/us-a/client-a/extra", "user-a/../client-a", "user-a/./client-a",
		"user-a/us a/client-a", "user-a/us-a/client\na", "user-a/us-a/clïent-a",
		"user-a/us-a/" + strings.Repeat("a", 257), "user-a-prefix/us-a/client-a",
	} {
		cache := newCache(t)
		config, option := fixture("user-a", "client-a")
		must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
		must(t, cache.Save(config))
		must(t, cache.Select(config.Identifier, "user-a"))
		before := load(t, cache, "user-a")
		_, err := cache.Evict(identifier, "user-a")
		expectErr(t, err, ErrInvalidMetadata)
		if got := load(t, cache, "user-a"); !reflect.DeepEqual(got, before) {
			t.Fatalf("%q changed the cache", identifier)
		}
		must(t, cache.Save(config))
	}
}

func TestEvictionRejectsInvalidAccountNamespaces(t *testing.T) {
	cache := newCache(t)
	for _, accountID := range []string{"", "user\na", "user/a", ".", "..", strings.Repeat("a", 129)} {
		_, err := cache.Evict(accountID+"/us-a/client-a", accountID)
		expectErr(t, err, ErrInvalidMetadata)
	}
}

func TestEvictionReportsFailedPersistenceAndLeavesExistingCacheIntact(t *testing.T) {
	cache := newCache(t)
	target, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(target))
	must(t, cache.Select(target.Identifier, "user-a"))
	before := load(t, cache, "user-a")
	restore := breakAccountDir(t, cache, "user-a")
	_, err := cache.Evict(target.Identifier, "user-a")
	expectErr(t, err, ErrUnavailable)
	restore()
	if got := load(t, reopen(cache), "user-a"); !reflect.DeepEqual(got, before) {
		t.Fatalf("snapshot = %+v", got)
	}
}

func TestEvictionDoesNotOverwriteAnInvalidPayload(t *testing.T) {
	cache := newCache(t)
	target, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(target))
	path := cache.path("user-a")
	var payload map[string]any
	data, _ := os.ReadFile(path)
	must(t, json.Unmarshal(data, &payload))
	payload["authorizedConfigHashes"] = map[string]string{}
	invalid, _ := json.Marshal(payload)
	must(t, os.WriteFile(path, invalid, 0o600))
	_, err := cache.Evict(target.Identifier, "user-a")
	expectErr(t, err, ErrInvalidMetadata)
	if data, _ := os.ReadFile(path); string(data) != string(invalid) {
		t.Fatal("eviction rewrote the invalid payload")
	}
}

func TestAccountRoutingPreferencePersistsAcrossRefreshAndAccounts(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	must(t, cache.SelectMode(ipc.ModeMesh, "user-a"))
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	reopened := reopen(cache)
	restored := load(t, reopened, "user-a")
	if *restored.SelectedMode != ipc.ModeMesh || !reflect.DeepEqual(restored.Configs, []InstalledConfig{config}) {
		t.Fatalf("restored = %+v", restored)
	}
	if got := load(t, reopened, "user-b").SelectedMode; *got != ipc.ModeFull {
		t.Fatalf("other mode = %v", *got)
	}
	expectErr(t, reopened.SelectMode(ipc.ModeMesh, "user-b"), ErrAccessDenied)
	expectErr(t, reopened.SelectMode("split", "user-a"), ErrInvalidMetadata)
}

func TestRoutingPreferenceLegacyDefaultsAndInvalidValuesStayUnknown(t *testing.T) {
	var legacy InventorySnapshot
	must(t, json.Unmarshal([]byte(`{"configs":[],"accessAllowed":true}`), &legacy))
	if legacy.SelectedMode == nil || *legacy.SelectedMode != ipc.ModeFull {
		t.Fatalf("legacy mode = %v", legacy.SelectedMode)
	}
	for _, invalid := range []string{`"unsupported"`, `null`, `42`} {
		var snapshot InventorySnapshot
		must(t, json.Unmarshal([]byte(`{"configs":[],"accessAllowed":true,"selectedMode":`+invalid+`}`), &snapshot))
		if snapshot.SelectedMode != nil {
			t.Fatalf("%s: mode = %v", invalid, *snapshot.SelectedMode)
		}
		data, err := json.Marshal(snapshot)
		must(t, err)
		var roundTrip InventorySnapshot
		must(t, json.Unmarshal(data, &roundTrip))
		if roundTrip.SelectedMode != nil {
			t.Fatalf("%s: round trip mode = %v", invalid, *roundTrip.SelectedMode)
		}
	}
	var incomplete InventorySnapshot
	if json.Unmarshal([]byte(`{"accessAllowed":true}`), &incomplete) == nil {
		t.Fatal("decoded a snapshot without configs")
	}
}

func TestInvalidStoredRoutingPreferenceSurvivesRefreshUntilExplicitlyRepaired(t *testing.T) {
	cache := newCache(t)
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	path := cache.path("user-a")
	var payload map[string]any
	data, _ := os.ReadFile(path)
	must(t, json.Unmarshal(data, &payload))
	payload["snapshot"].(map[string]any)["selectedMode"] = "unsupported"
	data, _ = json.Marshal(payload)
	must(t, os.WriteFile(path, data, 0o600))
	reopened := reopen(cache)
	if mode := load(t, reopened, "user-a").SelectedMode; mode != nil {
		t.Fatalf("mode = %v", *mode)
	}
	must(t, reopened.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	restored := load(t, reopened, "user-a")
	if restored.SelectedMode != nil || !reflect.DeepEqual(restored.Configs, []InstalledConfig{config}) {
		t.Fatalf("restored = %+v", restored)
	}
	must(t, reopened.SelectMode(ipc.ModeMesh, "user-a"))
	if mode := load(t, reopened, "user-a").SelectedMode; *mode != ipc.ModeMesh {
		t.Fatalf("mode = %v", *mode)
	}
}

func TestCorruptOrOversizedInventoryIsUnavailableOrInvalid(t *testing.T) {
	cache := newCache(t)
	_, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	path := cache.path("user-a")
	must(t, os.WriteFile(path, []byte(`{"version":`), 0o600))
	_, err := cache.Load("user-a")
	expectErr(t, err, ErrUnavailable)
	must(t, os.WriteFile(path, make([]byte, maxInventoryBytes+1), 0o600))
	_, err = cache.Load("user-a")
	expectErr(t, err, ErrInvalidMetadata)
	// A failed read falls back to a fresh payload on the next complete authorization
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	if !load(t, cache, "user-a").AccessAllowed {
		t.Fatal("authorization did not replace the oversized cache")
	}
}

// installSecret saves a secret record for config and binds config to it
func installSecret(t *testing.T, st *Store, config InstalledConfig) InstalledConfig {
	t.Helper()
	reference, err := st.PutSecret(SecretRecord{ConfigID: config.Identifier, ConfigHash: config.Snapshot.ConfigHash, Config: "[Interface]"})
	must(t, err)
	config.Snapshot.SecretReference = reference
	must(t, st.Accounts().Save(config))
	return config
}

func secretExists(st *Store, reference string) bool {
	_, err := st.GetSecret(reference)
	return err == nil
}

func TestRevokedConfigsDropSecretsExceptTheRunningOne(t *testing.T) {
	st := openStore(t)
	cache := st.Accounts()
	configA, optionA := fixture("user-a", "client-a")
	configB, optionB := fixture("user-a", "client-b")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{optionA, optionB}))
	configA = installSecret(t, st, configA)
	configB = installSecret(t, st, configB)
	must(t, st.SaveIntent(Intent{Revision: 1, AccountID: "user-a", ProfileID: configB.Identifier,
		SecretReference: configB.Snapshot.SecretReference, Phase: PhaseRunning}))

	// A rotated hash revokes both installs, but the running tunnel still needs B
	rotatedA, rotatedB := optionA, optionB
	rotatedA.ConfigHash, rotatedB.ConfigHash = hashB, hashB
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{rotatedA, rotatedB}))

	if secretExists(st, configA.Snapshot.SecretReference) {
		t.Fatal("rotated config kept its secret")
	}
	if !secretExists(st, configB.Snapshot.SecretReference) {
		t.Fatal("running config lost its secret")
	}
}

func TestDenialDropsSecretsAndRemovalKeepsThem(t *testing.T) {
	st := openStore(t)
	cache := st.Accounts()
	configA, optionA := fixture("user-a", "client-a")
	configB, optionB := fixture("user-a", "client-b")
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{optionA, optionB}))
	configA = installSecret(t, st, configA)
	configB = installSecret(t, st, configB)

	_, err := cache.Evict(configA.Identifier, "user-a")
	must(t, err)
	must(t, cache.Deny("user-a"))

	if !secretExists(st, configA.Snapshot.SecretReference) {
		t.Fatal("removal deleted the retained secret")
	}
	if secretExists(st, configB.Snapshot.SecretReference) {
		t.Fatal("denial kept an installed secret")
	}
}

func TestAccountIDsMustFitConfigIdentifiers(t *testing.T) {
	cache := newCache(t)
	for _, id := range []string{"user:a", "user@example.com", "a|b", "..", strings.Repeat("a", 129)} {
		expectErr(t, cache.Deny(id), ErrInvalidMetadata)
	}
	must(t, cache.Deny("Zx9_firebase-uid.1"))
}

func TestDowngradeDropsSecretsUnlessTheIntentIsUnreadable(t *testing.T) {
	st := openStore(t)
	cache := st.Accounts()
	config, option := fixture("user-a", "client-a")
	must(t, cache.Authorize("user-a", RoleAdmin, []AuthorizedOption{option}))
	config = installSecret(t, st, config)
	// Without a readable intent the running tunnel's record can't be told apart
	must(t, os.WriteFile(filepath.Join(st.Dir(), "intent.json"), []byte("{"), 0o600))

	if _, err := cache.ObserveRole("user-a", RoleUser); err != nil {
		t.Fatal(err)
	}

	if !secretExists(st, config.Snapshot.SecretReference) {
		t.Fatal("record deleted without a readable intent")
	}
	must(t, os.Remove(filepath.Join(st.Dir(), "intent.json")))
	must(t, cache.Authorize("user-a", RoleAdmin, []AuthorizedOption{option}))
	config = installSecret(t, st, config)
	if _, err := cache.ObserveRole("user-a", RoleUser); err != nil {
		t.Fatal(err)
	}
	if secretExists(st, config.Snapshot.SecretReference) {
		t.Fatal("downgrade kept the record")
	}
}
