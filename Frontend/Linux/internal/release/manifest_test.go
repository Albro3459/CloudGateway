package release

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
)

const testHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

func testManifest() Manifest {
	return Manifest{
		SchemaVersion:  1,
		Version:        "1.0.1",
		IPCVersion:     1,
		StorageVersion: 1,
		Entries: []Entry{
			{Arch: "arm64", Kind: KindFile, Path: "bin/cloudgatewayd", Size: 7, SHA256: testHash},
			{Arch: "arm64", Kind: KindFile, Path: "bin/cloudgateway", Size: 6, SHA256: testHash},
			{Arch: "arm64", Kind: KindFile, Path: UnitName, Size: 5, SHA256: testHash},
			{Arch: "arm64", Kind: KindArchive, Path: "cloudgateway-linux-1.0.1-arm64.tar.gz", Size: 100, SHA256: testHash},
			{Arch: "amd64", Kind: KindArchive, Path: "cloudgateway-linux-1.0.1-amd64.tar.gz", Size: 99, SHA256: testHash},
			{Arch: "amd64", Kind: KindFile, Path: "bin/cloudgateway", Size: 6, SHA256: testHash},
			{Arch: "amd64", Kind: KindFile, Path: "bin/cloudgatewayd", Size: 7, SHA256: testHash},
			{Arch: "amd64", Kind: KindFile, Path: UnitName, Size: 5, SHA256: testHash},
		},
	}
}

func testKey(t *testing.T) (ed25519.PrivateKey, string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := EncodePublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	return private, encoded
}

func TestEncodeIsCanonicalAndSorted(t *testing.T) {
	data, err := testManifest().Encode()
	if err != nil {
		t.Fatal(err)
	}
	want := `{
  "schemaVersion": 1,
  "version": "1.0.1",
  "ipcVersion": 1,
  "storageVersion": 1,
  "entries": [
    {"arch":"amd64","kind":"archive","path":"cloudgateway-linux-1.0.1-amd64.tar.gz","size":99,"sha256":"` + testHash + `"},
    {"arch":"amd64","kind":"file","path":"bin/cloudgateway","size":6,"sha256":"` + testHash + `"},
    {"arch":"amd64","kind":"file","path":"bin/cloudgatewayd","size":7,"sha256":"` + testHash + `"},
    {"arch":"amd64","kind":"file","path":"cloudgatewayd.service","size":5,"sha256":"` + testHash + `"},
    {"arch":"arm64","kind":"archive","path":"cloudgateway-linux-1.0.1-arm64.tar.gz","size":100,"sha256":"` + testHash + `"},
    {"arch":"arm64","kind":"file","path":"bin/cloudgateway","size":6,"sha256":"` + testHash + `"},
    {"arch":"arm64","kind":"file","path":"bin/cloudgatewayd","size":7,"sha256":"` + testHash + `"},
    {"arch":"arm64","kind":"file","path":"cloudgatewayd.service","size":5,"sha256":"` + testHash + `"}
  ]
}
`
	if string(data) != want {
		t.Fatalf("encoded:\n%s\nwant:\n%s", data, want)
	}
	m, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	archive, ok := m.Archive("arm64")
	if !ok || archive.Size != 100 || len(m.Files("amd64")) != 3 || len(m.Files("arm64")) != 3 {
		t.Fatalf("archive %+v %v, files %d %d", archive, ok, len(m.Files("amd64")), len(m.Files("arm64")))
	}
}

func TestParseRejectsNonCanonicalAndInvalid(t *testing.T) {
	data, _ := testManifest().Encode()
	cases := map[string]string{
		"reformatted":   strings.Replace(string(data), `"version": "1.0.1"`, `"version":"1.0.1"`, 1),
		"unknown field": strings.Replace(string(data), `"schemaVersion": 1,`, `"schemaVersion": 1, "extra": 1,`, 1),
		"schema":        strings.Replace(string(data), `"schemaVersion": 1`, `"schemaVersion": 2`, 1),
		"version":       strings.ReplaceAll(string(data), "1.0.1", "1.0.01"),
		"traversal":     strings.Replace(string(data), `"bin/cloudgatewayd"`, `"bin/../cloudgatewayd"`, 1),
		"hash":          strings.Replace(string(data), testHash, strings.ToUpper(testHash), 1),
		"archive name":  strings.Replace(string(data), "cloudgateway-linux-1.0.1-amd64.tar.gz", "other.tar.gz", 1),
		"no executable": strings.Replace(string(data), `"path":"bin/cloudgateway",`, `"path":"bin/other",`, 1),
		"trailing data": string(data) + "{}",
	}
	for name, input := range cases {
		if _, err := Parse([]byte(input)); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}

func TestVerify(t *testing.T) {
	private, public := testKey(t)
	_, otherPublic := testKey(t)
	data, _ := testManifest().Encode()
	signature := ed25519.Sign(private, data)

	m, err := Verify(data, signature, public)
	if err != nil || m.Version != "1.0.1" {
		t.Fatalf("good signature: %+v %v", m, err)
	}
	tampered := []byte(strings.Replace(string(data), `"size":99`, `"size":98`, 1))
	if _, err := Verify(tampered, signature, public); !errors.Is(err, ErrBadSignature) {
		t.Errorf("tampered manifest: %v", err)
	}
	if _, err := Verify(data, signature, otherPublic); !errors.Is(err, ErrBadSignature) {
		t.Errorf("wrong key: %v", err)
	}
	if _, err := Verify(data, signature[:10], public); !errors.Is(err, ErrBadSignature) {
		t.Errorf("short signature: %v", err)
	}
	if _, err := Verify(data, signature, ""); !errors.Is(err, ErrNoPublicKey) {
		t.Errorf("empty pinned key: %v", err)
	}
	if _, err := Verify(data, signature, "not base64"); err == nil {
		t.Error("garbage key verified")
	}
}

func TestCodeHash(t *testing.T) {
	if got := CodeHash([]byte("abc")); got != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatalf("CodeHash = %s", got)
	}
}

func TestPublicKeyRoundTrip(t *testing.T) {
	// RFC 8032 test 1 public key in SubjectPublicKeyInfo form
	const encoded = "MCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
	key, err := ParsePublicKey(encoded)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := EncodePublicKey(key)
	if again != encoded {
		t.Fatalf("round trip = %s", again)
	}
}

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.0.0", "1.0.0", 0},
		{"1.0.1", "1.0.0", 1},
		{"1.0.9", "1.0.10", -1},
		{"1.10.0", "1.9.9", 1},
		{"2.0.0", "10.0.0", -1},
	}
	for _, c := range cases {
		if got, err := CompareVersions(c.a, c.b); err != nil || got != c.want {
			t.Errorf("CompareVersions(%s, %s) = %d, %v", c.a, c.b, got, err)
		}
	}
	for _, bad := range []string{"", "1.0", "1.0.0.0", "v1.0.0", "1.0.0-rc.1", "1.0.0+5", "01.0.0", "1..0", "1.0.-1"} {
		if ValidVersion(bad) {
			t.Errorf("ValidVersion(%q) = true", bad)
		}
	}
}
