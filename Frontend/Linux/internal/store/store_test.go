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

func openStore(t *testing.T) *Store {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func mode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode().Perm()
}

func TestOpenCreatesPrivateLayoutAndVersion(t *testing.T) {
	store := openStore(t)
	for _, dir := range []string{store.Dir(), filepath.Join(store.Dir(), "accounts"), filepath.Join(store.Dir(), "secrets")} {
		if got := mode(t, dir); got != 0o700 {
			t.Fatalf("%s mode = %o", dir, got)
		}
	}
	data, err := os.ReadFile(filepath.Join(store.Dir(), "storage.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"storageVersion":1}` {
		t.Fatalf("storage.json = %s", data)
	}
	if got := mode(t, filepath.Join(store.Dir(), "storage.json")); got != 0o600 {
		t.Fatalf("storage.json mode = %o", got)
	}
}

func TestOpenTightensDirectoryMode(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(dir); err != nil {
		t.Fatal(err)
	}
	if got := mode(t, dir); got != 0o700 {
		t.Fatalf("mode = %o", got)
	}
}

func TestOpenRefusesNewerStorageAndRejectsMalformedVersion(t *testing.T) {
	for _, test := range []struct {
		contents string
		want     error
	}{
		{`{"storageVersion":2}`, ErrNewerStorage},
		{`{"storageVersion":0}`, ErrUnreadable},
		{`not json`, ErrUnreadable},
	} {
		dir := filepath.Join(t.TempDir(), "state")
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "storage.json"), []byte(test.contents), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Open(dir); !errors.Is(err, test.want) {
			t.Fatalf("%s: err = %v, want %v", test.contents, err, test.want)
		}
		data, _ := os.ReadFile(filepath.Join(dir, "storage.json"))
		if string(data) != test.contents {
			t.Fatalf("storage.json rewritten to %s", data)
		}
	}
}

func TestWriteFileReplacesAtomicallyWithoutLeftovers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "record.json")
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(path, []byte("new")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "new" {
		t.Fatalf("data = %q, err = %v", data, err)
	}
	if got := mode(t, path); got != 0o600 {
		t.Fatalf("mode = %o", got)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("entries = %v", entries)
	}
	// A failed rename leaves the original and removes the temporary file
	if err := os.Mkdir(filepath.Join(dir, "blocked"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "blocked", "child"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(filepath.Join(dir, "blocked"), []byte("x")); err == nil {
		t.Fatal("expected rename over a non-empty directory to fail")
	}
	entries, _ = os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatalf("entries after failure = %v", entries)
	}
}

func TestReadFileBoundsSizeAndSeparatesMissing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "record")
	if _, err := readFile(path, 4); !errors.Is(err, ErrMissing) {
		t.Fatalf("missing err = %v", err)
	}
	if err := os.WriteFile(path, []byte("12345"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readFile(path, 4); !errors.Is(err, ErrUnreadable) || !errors.Is(err, errTooLarge) {
		t.Fatalf("oversized err = %v", err)
	}
	if _, err := readFile(dir, 4); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("directory err = %v", err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() != 0 {
		if _, err := readFile(path, 8); !errors.Is(err, ErrUnreadable) || errors.Is(err, ErrMissing) {
			t.Fatalf("unreadable err = %v", err)
		}
	}
}

func TestCredentialsRoundTripAndRedaction(t *testing.T) {
	store := openStore(t)
	if _, err := store.LoadCredentials(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	credentials := Credentials{AccountID: "uid-1", ProjectID: "project", Generation: 3, RefreshToken: "refresh-secret"}
	if err := store.SaveCredentials(credentials); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.LoadCredentials()
	if err != nil || loaded != credentials {
		t.Fatalf("loaded = %v, err = %v", loaded, err)
	}
	for _, text := range []string{
		fmt.Sprint(loaded), fmt.Sprintf("%v %+v %#v %s %q", loaded, loaded, loaded, loaded.RefreshToken, loaded.RefreshToken),
	} {
		if strings.Contains(text, "refresh-secret") {
			t.Fatalf("formatted credentials leak the token: %s", text)
		}
	}
	if got := mode(t, filepath.Join(store.Dir(), "credentials.json")); got != 0o600 {
		t.Fatalf("mode = %o", got)
	}
	if err := store.ClearCredentials(); err != nil {
		t.Fatal(err)
	}
	if err := store.ClearCredentials(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.LoadCredentials(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	if err := store.SaveCredentials(Credentials{AccountID: "uid-1", ProjectID: "project"}); err == nil {
		t.Fatal("saved credentials without a token")
	}
}

func TestCorruptCredentialsErrorOmitsContents(t *testing.T) {
	store := openStore(t)
	if err := os.WriteFile(filepath.Join(store.Dir(), "credentials.json"), []byte(`{"refreshToken":"secret-token`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := store.LoadCredentials()
	if !errors.Is(err, ErrUnreadable) || errors.Is(err, ErrMissing) || strings.Contains(err.Error(), "secret") {
		t.Fatalf("err = %v", err)
	}
}

// Logout persists the revoked generation and cleanup marker before clearing
// credentials. A crash between the steps leaves enough to finish on restart
func TestLogoutOrderSurvivesCrashBeforeCredentialsClear(t *testing.T) {
	store := openStore(t)
	if err := store.SaveSession(Session{Generation: 1, AccountID: "uid-1"}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveCredentials(Credentials{AccountID: "uid-1", ProjectID: "project", Generation: 1, RefreshToken: "token"}); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveSession(Session{Generation: 2, RevokedThrough: 1, LogoutCleanup: true}); err != nil {
		t.Fatal(err)
	}

	reopened, err := Open(store.Dir())
	if err != nil {
		t.Fatal(err)
	}
	session, err := reopened.LoadSession()
	if err != nil {
		t.Fatal(err)
	}
	credentials, err := reopened.LoadCredentials()
	if err != nil {
		t.Fatal(err)
	}
	if !session.LogoutCleanup || !session.Revoked(credentials.Generation) || session.Revoked(2) {
		t.Fatalf("session = %+v, credentials generation = %d", session, credentials.Generation)
	}
	if err := reopened.ClearCredentials(); err != nil {
		t.Fatal(err)
	}
	if err := reopened.SaveSession(Session{Generation: 2, RevokedThrough: 1}); err != nil {
		t.Fatal(err)
	}
	if err := reopened.SaveSession(Session{Generation: 3, RevokedThrough: 0}); !errors.Is(err, ErrStale) {
		t.Fatalf("revocation moved backwards: %v", err)
	}
	if err := reopened.SaveSession(Session{Generation: 1, RevokedThrough: 1}); !errors.Is(err, ErrStale) {
		t.Fatalf("generation moved backwards: %v", err)
	}
	if session, _ := reopened.LoadSession(); session != (Session{Generation: 2, RevokedThrough: 1}) {
		t.Fatalf("session = %+v", session)
	}
}

func TestSecretRecords(t *testing.T) {
	store := openStore(t)
	record := SecretRecord{ConfigID: "uid/us-a/client-a", ConfigHash: strings.Repeat("a", 64), Config: "[Interface]\nPrivateKey = secret-key\n"}
	reference, err := store.PutSecret(record)
	if err != nil {
		t.Fatal(err)
	}
	if !ValidSecretReference(reference) {
		t.Fatalf("reference = %q", reference)
	}
	other, err := store.PutSecret(record)
	if err != nil || other == reference {
		t.Fatalf("second reference = %q, err = %v", other, err)
	}
	loaded, err := store.GetSecret(reference)
	if err != nil || loaded != record {
		t.Fatalf("loaded = %v, err = %v", loaded, err)
	}
	if text := fmt.Sprintf("%v %+v", loaded, loaded); strings.Contains(text, "secret-key") {
		t.Fatalf("formatted record leaks the config: %s", text)
	}
	if got := mode(t, filepath.Join(store.Dir(), "secrets", reference)); got != 0o600 {
		t.Fatalf("mode = %o", got)
	}
	if err := store.DeleteSecret(reference); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteSecret(reference); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetSecret(reference); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	for _, reference := range []string{"../storage.json", "ABCDEF0123456789ABCDEF0123456789", "short"} {
		if _, err := store.GetSecret(reference); !errors.Is(err, ErrMissing) {
			t.Fatalf("%s: err = %v", reference, err)
		}
		if err := store.DeleteSecret(reference); err == nil {
			t.Fatalf("%s: deleted", reference)
		}
	}
	if _, err := store.PutSecret(SecretRecord{ConfigID: "uid/us-a", ConfigHash: record.ConfigHash, Config: "x"}); err == nil {
		t.Fatal("stored a record with an invalid config ID")
	}
	if err := os.WriteFile(filepath.Join(store.Dir(), "secrets", other), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetSecret(other); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("err = %v", err)
	}
}

func TestIntentMissingUnreadableAndRevisions(t *testing.T) {
	store := openStore(t)
	if _, err := store.LoadIntent(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	intent := Intent{
		Revision: 1, AccountID: "uid", SessionGeneration: 2, ProfileID: "uid/us-a/client-a",
		SecretReference: "0123456789abcdef0123456789abcdef", ConfigHash: strings.Repeat("a", 64),
		Mode: ipc.ModeFull, Phase: PhaseRunning, Journal: json.RawMessage(`{"interface":"cg0"}`),
	}
	if err := store.SaveIntent(intent); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.LoadIntent()
	if err != nil || !reflect.DeepEqual(loaded, intent) {
		t.Fatalf("loaded = %+v, err = %v", loaded, err)
	}
	if err := store.SaveIntent(Intent{Revision: 1, Phase: PhaseStopped, Suppression: SuppressDown}); !errors.Is(err, ErrStale) {
		t.Fatalf("err = %v", err)
	}
	stop := Intent{Revision: 2, Phase: PhaseStopping, Suppression: SuppressDown}
	if err := store.SaveIntent(stop); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveIntent(Intent{Revision: 3, Phase: "paused"}); err == nil {
		t.Fatal("saved an invalid phase")
	}

	path := filepath.Join(store.Dir(), "intent.json")
	for _, contents := range []string{`{"revision":`, `{"revision":4,"phase":"paused"}`, `{"revision":4,"phase":"stopped","suppression":"reboot"}`} {
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := store.LoadIntent(); !errors.Is(err, ErrUnreadable) || errors.Is(err, ErrMissing) {
			t.Fatalf("%s: err = %v", contents, err)
		}
	}
	// Recovery can replace an unreadable intent
	if err := store.SaveIntent(Intent{Revision: 1, Phase: PhaseStopped, Suppression: SuppressResolverFailure}); err != nil {
		t.Fatal(err)
	}
}

func TestReceiptsAndUpdateRecord(t *testing.T) {
	store := openStore(t)
	if _, err := store.LoadReceipts(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	if err := store.SaveReceipts([]byte(`{"receipts":{}}`)); err != nil {
		t.Fatal(err)
	}
	if data, err := store.LoadReceipts(); err != nil || string(data) != `{"receipts":{}}` {
		t.Fatalf("data = %s, err = %v", data, err)
	}

	if _, err := store.LoadUpdate(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	created := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	record := UpdateRecord{
		ID: "6f9619ff-8b86-d011-b42d-00cf4fc964ff", Phase: ipc.UpdateActivating,
		Target:    ipc.BuildIdentity{Version: "1.0.1", Build: "1.0.1", CodeHash: strings.Repeat("c", 64)},
		CreatedAt: created, UpdatedAt: created.Add(time.Second), Warning: "inventory_not_refreshed",
	}
	if err := store.SaveUpdate(record); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.LoadUpdate()
	if err != nil || loaded != record {
		t.Fatalf("loaded = %+v, err = %v", loaded, err)
	}
	if status := loaded.Status(); status.Operation() != (ipc.Operation{ID: record.ID, State: ipc.OperationRunning}) || status.Warning != "inventory_not_refreshed" {
		t.Fatalf("status = %+v", status)
	}
	if err := store.ClearUpdate(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.LoadUpdate(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
}

func TestUnreadableSessionKeepsGenerationFloor(t *testing.T) {
	store := openStore(t)
	must(t, store.SaveSession(Session{Generation: 4, AccountID: "uid-1", RevokedThrough: 3}))
	must(t, store.SaveCredentials(Credentials{AccountID: "uid-1", ProjectID: "project", Generation: 4, RefreshToken: "token"}))
	must(t, store.SaveIntent(Intent{Revision: 1, AccountID: "uid-1", SessionGeneration: 5, Phase: PhaseRunning}))
	path := filepath.Join(store.Dir(), "session.json")
	must(t, os.WriteFile(path, []byte(`{"generation":`), 0o600))

	for _, stale := range []Session{
		{Generation: 1, AccountID: "uid-1"},
		{Generation: 5, RevokedThrough: 5},
		{Generation: 6, RevokedThrough: 4},
	} {
		expectErr(t, store.SaveSession(stale), ErrStale)
	}
	recovered, err := store.RecoverSession()
	if err != nil || recovered != (Session{Generation: 6, RevokedThrough: 5}) {
		t.Fatalf("recovered = %+v, err = %v", recovered, err)
	}
	if loaded, err := store.LoadSession(); err != nil || loaded != recovered {
		t.Fatalf("loaded = %+v, err = %v", loaded, err)
	}
	if again, err := store.RecoverSession(); err != nil || again != recovered {
		t.Fatalf("readable record changed: %+v, %v", again, err)
	}
	must(t, store.SaveSession(Session{Generation: 7, AccountID: "uid-1", RevokedThrough: 5}))
}

func TestMissingSessionStartsAboveSavedGenerations(t *testing.T) {
	store := openStore(t)
	must(t, store.SaveSession(Session{Generation: 1, AccountID: "uid-1"}))
	fresh := openStore(t)
	recovered, err := fresh.RecoverSession()
	if err != nil || recovered != (Session{Generation: 1}) {
		t.Fatalf("fresh = %+v, err = %v", recovered, err)
	}
	must(t, fresh.SaveCredentials(Credentials{AccountID: "uid-1", ProjectID: "project", Generation: 2, RefreshToken: "token"}))
	must(t, fresh.ClearCredentials())
	must(t, fresh.SaveCredentials(Credentials{AccountID: "uid-1", ProjectID: "project", Generation: 2, RefreshToken: "token"}))
	must(t, os.Remove(filepath.Join(fresh.Dir(), "session.json")))
	expectErr(t, fresh.SaveSession(Session{Generation: 2, AccountID: "uid-1"}), ErrStale)
	if recovered, err := fresh.RecoverSession(); err != nil || recovered != (Session{Generation: 3, RevokedThrough: 2}) {
		t.Fatalf("recovered = %+v, err = %v", recovered, err)
	}
}

func TestOpenRemovesLeftoverTemporaryWrites(t *testing.T) {
	store := openStore(t)
	config, option := fixture("user-a", "client-a")
	cache := store.Accounts()
	must(t, cache.Authorize("user-a", RoleUser, []AuthorizedOption{option}))
	must(t, cache.Save(config))
	accountDir := filepath.Dir(cache.path("user-a"))
	reference, err := store.PutSecret(SecretRecord{ConfigID: "user-a/us-a/client-a", ConfigHash: hashA, Config: "key"})
	must(t, err)
	// Leftovers as CreateTemp names them when a crash interrupts writeFile
	leftovers := []string{
		filepath.Join(store.Dir(), ".credentials.json.tmp-123"),
		filepath.Join(store.Dir(), "secrets", "."+reference+".tmp-456"),
		filepath.Join(accountDir, ".inventory.json.tmp-789"),
	}
	for _, path := range leftovers {
		must(t, os.WriteFile(path, []byte("partial"), 0o600))
	}
	keep := filepath.Join(store.Dir(), ".hidden")
	must(t, os.WriteFile(keep, nil, 0o600))
	if _, err := Open(store.Dir()); err != nil {
		t.Fatal(err)
	}
	for _, path := range leftovers {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("%s survived: %v", path, err)
		}
	}
	if _, err := os.Lstat(keep); err != nil {
		t.Fatal("removed a file without the temp marker")
	}
	if _, err := store.GetSecret(reference); err != nil {
		t.Fatal(err)
	}
	if len(load(t, cache, "user-a").Configs) != 1 {
		t.Fatal("inventory lost")
	}
	// writeFile names its temporary files with the marker Open removes
	entries, _ := os.ReadDir(store.Dir())
	for _, entry := range entries {
		if strings.Contains(entry.Name(), ".tmp-") {
			t.Fatalf("leftover %s", entry.Name())
		}
	}
}

func TestOpenForCleanupReadsAnyVersionWithoutWriting(t *testing.T) {
	store := openStore(t)
	intent := Intent{Revision: 3, Phase: PhaseRunning, Journal: json.RawMessage(`{"interface":"cg0"}`)}
	must(t, store.SaveIntent(intent))
	versionPath := filepath.Join(store.Dir(), "storage.json")

	current, err := OpenForCleanup(store.Dir())
	if err != nil || current.ReadOnly() {
		t.Fatalf("current version: readOnly = %v, err = %v", current != nil && current.ReadOnly(), err)
	}
	for _, contents := range []string{`{"storageVersion":2}`, `garbage`} {
		must(t, os.WriteFile(versionPath, []byte(contents), 0o600))
		cleanup, err := OpenForCleanup(store.Dir())
		if err != nil || !cleanup.ReadOnly() {
			t.Fatalf("%s: err = %v", contents, err)
		}
		loaded, err := cleanup.LoadIntent()
		if err != nil || string(loaded.Journal) != `{"interface":"cg0"}` {
			t.Fatalf("%s: intent = %+v, err = %v", contents, loaded, err)
		}
		expectErr(t, cleanup.SaveIntent(Intent{Revision: 4, Phase: PhaseStopped}), ErrReadOnly)
		expectErr(t, cleanup.ClearCredentials(), ErrReadOnly)
		expectErr(t, cleanup.SaveReceipts(nil), ErrReadOnly)
		expectErr(t, cleanup.Accounts().Deny("user-a"), ErrReadOnly)
		if data, _ := os.ReadFile(versionPath); string(data) != contents {
			t.Fatal("cleanup rewrote storage.json")
		}
	}
	missing := filepath.Join(t.TempDir(), "absent")
	cleanup, err := OpenForCleanup(missing)
	if err != nil || !cleanup.ReadOnly() {
		t.Fatalf("missing dir: err = %v", err)
	}
	if _, err := cleanup.LoadIntent(); !errors.Is(err, ErrMissing) {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Lstat(missing); !os.IsNotExist(err) {
		t.Fatal("cleanup created the state dir")
	}
}

func TestSecretRedactionCoversExportedFields(t *testing.T) {
	type wrapper struct {
		Credentials *Credentials
		Records     []SecretRecord
		Tokens      map[string]Secret
	}
	value := wrapper{
		Credentials: &Credentials{AccountID: "uid", RefreshToken: "token-1"},
		Records:     []SecretRecord{{Config: "token-2"}},
		Tokens:      map[string]Secret{"a": "token-3"},
	}
	for _, text := range []string{fmt.Sprintf("%v %+v %#v", value, value, value), fmt.Sprintf("%v %s", *value.Credentials, Secret("token-4"))} {
		if strings.Contains(text, "token-") {
			t.Fatalf("leaked: %s", text)
		}
	}
}

func TestOSReadFailureKeepsSessionRecord(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads files without permission")
	}
	store := openStore(t)
	saved := Session{Generation: 4, AccountID: "uid-1", RevokedThrough: 3}
	must(t, store.SaveSession(saved))
	path := filepath.Join(store.Dir(), "session.json")
	must(t, os.Chmod(path, 0))

	_, err := store.RecoverSession()

	expectErr(t, err, ErrUnreadable)
	must(t, os.Chmod(path, 0o600))
	if loaded, err := store.LoadSession(); err != nil || loaded != saved {
		t.Fatalf("loaded = %+v, err = %v", loaded, err)
	}
}

func TestLogoutRebuildsAnUnreadableSessionRecord(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads files without permission")
	}
	store := openStore(t)
	must(t, store.SaveSession(Session{Generation: 4, AccountID: "uid-1", RevokedThrough: 3}))
	path := filepath.Join(store.Dir(), "session.json")
	must(t, os.Chmod(path, 0))

	// The daemon still knows generation 6 from memory
	rebuilt, err := store.RebuildSession(6)

	if err != nil || rebuilt != (Session{Generation: 7, RevokedThrough: 6}) {
		t.Fatalf("rebuilt = %+v, err = %v", rebuilt, err)
	}
	if loaded, err := store.LoadSession(); err != nil || loaded != rebuilt {
		t.Fatalf("loaded = %+v, err = %v", loaded, err)
	}
}

func TestUnreadableFloorBlocksSessionRebuild(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads files without permission")
	}
	store := openStore(t)
	must(t, store.SaveCredentials(Credentials{AccountID: "uid-1", ProjectID: "project", Generation: 4, RefreshToken: "token"}))
	must(t, os.WriteFile(filepath.Join(store.Dir(), "session.json"), []byte(`{"generation":`), 0o600))
	credentials := filepath.Join(store.Dir(), "credentials.json")
	must(t, os.Chmod(credentials, 0))

	_, err := store.RecoverSession()

	expectErr(t, err, ErrIO)
	expectErr(t, store.SaveSession(Session{Generation: 2}), ErrIO)
	must(t, os.Chmod(credentials, 0o600))
	recovered, err := store.RecoverSession()
	if err != nil || recovered != (Session{Generation: 5, RevokedThrough: 4}) {
		t.Fatalf("recovered = %+v, err = %v", recovered, err)
	}
}
