// Package release defines the signed Linux release manifest and reads the
// identity of installed releases
package release

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// PublicKey is the pinned Ed25519 release key as base64 DER SubjectPublicKeyInfo,
// which is also the body of its PEM form. cloudgateway-release keygen prints it
// and build stamps it into install.sh. Releases can't be built or verified while it's empty
const PublicKey = ""

const (
	SchemaVersion = 1
	ManifestName  = "manifest.json"
	SignatureName = "manifest.json.sig"
	UnitName      = "cloudgatewayd.service"

	KindArchive = "archive"
	KindFile    = "file"

	// maxNumber bounds every manifest number to 18 digits, which install.sh
	// matches and bash arithmetic holds
	maxNumber = 999_999_999_999_999_999
)

var (
	Arches      = []string{"amd64", "arm64"}
	Executables = []string{"bin/cloudgateway", "bin/cloudgatewayd"}
	// requiredFiles must appear in every architecture's file list
	requiredFiles = append(slices.Clone(Executables), UnitName)

	ErrNoPublicKey  = errors.New("release: no pinned public key. Run cloudgateway-release keygen and set release.PublicKey")
	ErrBadSignature = errors.New("release: manifest signature does not verify")
	ErrMalformed    = errors.New("release: malformed manifest")

	pathPattern   = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$`)
	sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// Manifest binds a release version to its compatibility versions and the size
// and SHA-256 of every published archive and installed file. Its canonical
// encoding keeps one entry per line so install.sh can parse it without jq
type Manifest struct {
	SchemaVersion  int     `json:"schemaVersion"`
	Version        string  `json:"version"`
	IPCVersion     int     `json:"ipcVersion"`
	StorageVersion int     `json:"storageVersion"`
	Entries        []Entry `json:"entries"`
}

// Entry is a release archive, named by Path, or a file inside it, relative to the release directory
type Entry struct {
	Arch   string `json:"arch"`
	Kind   string `json:"kind"`
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

func ArchiveName(version, arch string) string {
	return "cloudgateway-linux-" + version + "-" + arch + ".tar.gz"
}

// CodeHash is the lowercase hex SHA-256 of the exact signed manifest bytes
func CodeHash(manifest []byte) string {
	sum := sha256.Sum256(manifest)
	return hex.EncodeToString(sum[:])
}

func ParsePublicKey(encoded string) (ed25519.PublicKey, error) {
	if encoded == "" {
		return nil, ErrNoPublicKey
	}
	der, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("release: public key is not base64: %w", err)
	}
	key, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, fmt.Errorf("release: parse public key: %w", err)
	}
	public, ok := key.(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("release: public key is not Ed25519")
	}
	return public, nil
}

func EncodePublicKey(key ed25519.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// Verify checks the detached signature over the exact manifest bytes before
// parsing anything they claim
func Verify(manifest, signature []byte, publicKey string) (Manifest, error) {
	key, err := ParsePublicKey(publicKey)
	if err != nil {
		return Manifest{}, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(key, manifest, signature) {
		return Manifest{}, ErrBadSignature
	}
	return Parse(manifest)
}

// Parse accepts only a valid manifest in canonical encoding. Call it on bytes
// whose signature has already been verified
func Parse(data []byte) (Manifest, error) {
	if len(data) > maxManifestBytes {
		return Manifest{}, fmt.Errorf("%w: larger than %d bytes", ErrMalformed, maxManifestBytes)
	}
	var m Manifest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&m); err != nil {
		return Manifest{}, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	canonical, err := m.Encode()
	if err != nil {
		return Manifest{}, err
	}
	if !bytes.Equal(canonical, data) {
		return Manifest{}, fmt.Errorf("%w: not in canonical encoding", ErrMalformed)
	}
	return m, nil
}

// Encode validates m and writes its canonical form, with entries sorted by
// architecture, archive first, then path
func (m Manifest) Encode() ([]byte, error) {
	if err := m.validate(); err != nil {
		return nil, err
	}
	entries := slices.Clone(m.Entries)
	slices.SortFunc(entries, func(a, b Entry) int {
		return strings.Compare(a.Arch+"\x00"+a.Kind+"\x00"+a.Path, b.Arch+"\x00"+b.Kind+"\x00"+b.Path)
	})
	var out bytes.Buffer
	fmt.Fprintf(&out, "{\n  \"schemaVersion\": %d,\n  \"version\": %q,\n  \"ipcVersion\": %d,\n  \"storageVersion\": %d,\n  \"entries\": [\n",
		m.SchemaVersion, m.Version, m.IPCVersion, m.StorageVersion)
	for i, entry := range entries {
		line, err := json.Marshal(entry)
		if err != nil {
			return nil, err
		}
		out.WriteString("    ")
		out.Write(line)
		if i < len(entries)-1 {
			out.WriteByte(',')
		}
		out.WriteByte('\n')
	}
	out.WriteString("  ]\n}\n")
	return out.Bytes(), nil
}

// Archive returns the archive entry for arch
func (m Manifest) Archive(arch string) (Entry, bool) {
	for _, entry := range m.Entries {
		if entry.Arch == arch && entry.Kind == KindArchive {
			return entry, true
		}
	}
	return Entry{}, false
}

// Files returns the installed files for arch
func (m Manifest) Files(arch string) []Entry {
	var files []Entry
	for _, entry := range m.Entries {
		if entry.Arch == arch && entry.Kind == KindFile {
			files = append(files, entry)
		}
	}
	return files
}

func (m Manifest) validate() error {
	malformed := func(format string, args ...any) error {
		return fmt.Errorf("%w: %s", ErrMalformed, fmt.Sprintf(format, args...))
	}
	switch {
	case m.SchemaVersion != SchemaVersion:
		return malformed("schema version %d", m.SchemaVersion)
	case !ValidVersion(m.Version):
		return malformed("version %q", m.Version)
	case m.IPCVersion < 1 || m.IPCVersion > maxNumber:
		return malformed("ipc version %d", m.IPCVersion)
	case m.StorageVersion < 1 || m.StorageVersion > maxNumber:
		return malformed("storage version %d", m.StorageVersion)
	}
	seen := map[string]bool{}
	arches := map[string]bool{}
	for _, entry := range m.Entries {
		switch {
		case !slices.Contains(Arches, entry.Arch):
			return malformed("architecture %q", entry.Arch)
		case entry.Kind != KindArchive && entry.Kind != KindFile:
			return malformed("kind %q", entry.Kind)
		case !pathPattern.MatchString(entry.Path) || slices.Contains(strings.Split(entry.Path, "/"), ".."):
			return malformed("path %q", entry.Path)
		case entry.Kind == KindArchive && entry.Path != ArchiveName(m.Version, entry.Arch):
			return malformed("archive name %q", entry.Path)
		case entry.Size < 0 || entry.Size > maxNumber || entry.Kind == KindArchive && entry.Size == 0:
			return malformed("size %d for %s", entry.Size, entry.Path)
		case !sha256Pattern.MatchString(entry.SHA256):
			return malformed("sha256 for %s", entry.Path)
		}
		key := entry.Arch + "\x00" + entry.Kind + "\x00" + entry.Path
		if seen[key] {
			return malformed("duplicate %s %s", entry.Arch, entry.Path)
		}
		seen[key] = true
		arches[entry.Arch] = true
	}
	if len(arches) == 0 {
		return malformed("no architectures")
	}
	for arch := range arches {
		if !seen[arch+"\x00"+KindArchive+"\x00"+ArchiveName(m.Version, arch)] {
			return malformed("no %s archive", arch)
		}
		for _, path := range requiredFiles {
			if !seen[arch+"\x00"+KindFile+"\x00"+path] {
				return malformed("no %s %s", arch, path)
			}
		}
	}
	return nil
}

// ValidVersion accepts release versions in MAJOR.MINOR.PATCH form without
// leading zeros, pre-release, or build metadata, and up to 18 digits per part
func ValidVersion(version string) bool {
	_, ok := parseVersion(version)
	return ok
}

// CompareVersions orders two release versions by SemVer precedence
func CompareVersions(a, b string) (int, error) {
	left, ok := parseVersion(a)
	if !ok {
		return 0, fmt.Errorf("release: invalid version %q", a)
	}
	right, ok := parseVersion(b)
	if !ok {
		return 0, fmt.Errorf("release: invalid version %q", b)
	}
	return slices.Compare(left[:], right[:]), nil
}

func parseVersion(version string) ([3]uint64, bool) {
	var parts [3]uint64
	fields := strings.Split(version, ".")
	if len(fields) != 3 {
		return parts, false
	}
	for i, field := range fields {
		if field == "" || len(field) > 18 || len(field) > 1 && field[0] == '0' || strings.TrimLeft(field, "0123456789") != "" {
			return parts, false
		}
		n, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			return parts, false
		}
		parts[i] = n
	}
	return parts, true
}
