package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

// Account cache errors match CloudGatewayMacCacheError
var (
	ErrInvalidMetadata = errors.New("store: invalid account metadata")
	ErrUnavailable     = errors.New("store: account cache unavailable")
	ErrAccessDenied    = errors.New("store: account access denied")
)

type Role string

const (
	RoleUser  Role = "user"
	RoleAdmin Role = "admin"
)

const (
	statusActive  = "active"
	statusRemoved = "removed"

	maxConfigs        = 1000
	maxInventoryBytes = 5 << 20
)

// ConfigSnapshot is installed config metadata. The config itself lives in a secret record
type ConfigSnapshot struct {
	ClientID               string    `json:"clientId"`
	RegionID               string    `json:"regionId"`
	ClientName             string    `json:"clientName,omitempty"`
	RegionDisplayName      string    `json:"regionDisplayName"`
	Status                 string    `json:"status"`
	ConfigHash             string    `json:"configHash"`
	SecretReference        string    `json:"secretReference"`
	ReadAt                 time.Time `json:"readAt"`
	UpdatedAt              time.Time `json:"updatedAt,omitzero"`
	AssignedTunnelIPv4     string    `json:"assignedTunnelIpv4,omitempty"`
	ServerEndpointIPv4     string    `json:"serverEndpointIpv4,omitempty"`
	ServerEndpointHostname string    `json:"serverEndpointHostname,omitempty"`
}

type InstalledConfig struct {
	AccountID  string         `json:"accountId"`
	Identifier string         `json:"identifier"`
	Snapshot   ConfigSnapshot `json:"snapshot"`
}

// InventorySnapshot is one account's cached inventory. A nil SelectedMode
// means the saved mode is unreadable and stays unknown until set again
type InventorySnapshot struct {
	Configs            []InstalledConfig `json:"configs"`
	SelectedIdentifier string            `json:"selectedIdentifier,omitempty"`
	AccessAllowed      bool              `json:"accessAllowed"`
	SelectedMode       *ipc.Mode         `json:"selectedMode"`
}

// UnmarshalJSON defaults a missing mode to full and maps an invalid one to nil
func (s *InventorySnapshot) UnmarshalJSON(data []byte) error {
	var raw struct {
		Configs            *[]InstalledConfig `json:"configs"`
		SelectedIdentifier string             `json:"selectedIdentifier"`
		AccessAllowed      *bool              `json:"accessAllowed"`
		SelectedMode       json.RawMessage    `json:"selectedMode"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.Configs == nil || raw.AccessAllowed == nil {
		return errors.New("inventory snapshot is incomplete")
	}
	*s = InventorySnapshot{Configs: *raw.Configs, SelectedIdentifier: raw.SelectedIdentifier, AccessAllowed: *raw.AccessAllowed}
	if raw.SelectedMode == nil {
		s.SelectedMode = modePointer(ipc.ModeFull)
		return nil
	}
	var mode ipc.Mode
	if json.Unmarshal(raw.SelectedMode, &mode) == nil && validMode(mode) {
		s.SelectedMode = &mode
	}
	return nil
}

func emptySnapshot() InventorySnapshot {
	return InventorySnapshot{Configs: []InstalledConfig{}, SelectedMode: modePointer(ipc.ModeFull)}
}

func modePointer(mode ipc.Mode) *ipc.Mode { return &mode }

func validMode(mode ipc.Mode) bool { return mode == ipc.ModeFull || mode == ipc.ModeMesh }

// AuthorizedOption is one client from a complete, access-checked inventory refresh
type AuthorizedOption struct {
	ClientID               string
	RegionID               string
	ClientName             string
	RegionDisplayName      string
	Status                 string
	UpdatedAt              time.Time
	AssignedTunnelIPv4     string
	ServerEndpointIPv4     string
	ServerEndpointHostname string
	OwnerUID               string
	// Usable means the client is active with a config and its region is enabled
	Usable bool
	// ConfigHash is the canonical config hash. Required when Usable
	ConfigHash string
}

type inventoryPayload struct {
	Version                int               `json:"version"`
	AccountID              string            `json:"accountId"`
	Snapshot               InventorySnapshot `json:"snapshot"`
	AuthorizedConfigHashes map[string]string `json:"authorizedConfigHashes"`
	AuthorizedRole         Role              `json:"authorizedRole,omitempty"`
}

func emptyPayload(accountID string) inventoryPayload {
	return inventoryPayload{Version: 1, AccountID: accountID, Snapshot: emptySnapshot(), AuthorizedConfigHashes: map[string]string{}}
}

// AccountCache ports CloudGatewayMacAccountCache. Each account has its own
// inventory file, and a denial blocks offline use in memory even when it
// cannot be persisted
type AccountCache struct {
	dir      string
	readOnly bool
	now      func() time.Time
	mu       sync.Mutex
	denied   map[string]bool
	// drop receives secret references for configs a denial, downgrade, or
	// refresh revoked. Removal keeps them, like macOS
	drop func(references []string)
}

func newAccountCache(dir string) *AccountCache {
	return &AccountCache{dir: dir, now: time.Now, denied: map[string]bool{}}
}

func (c *AccountCache) Load(accountID string) (InventorySnapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	payload, err := c.load(accountID)
	if err != nil {
		return InventorySnapshot{}, err
	}
	return payload.Snapshot, nil
}

func (c *AccountCache) load(accountID string) (inventoryPayload, error) {
	if !ValidAccountID(accountID) {
		return inventoryPayload{}, ErrInvalidMetadata
	}
	if c.denied[accountID] {
		return emptyPayload(accountID), nil
	}
	data, err := readFile(c.path(accountID), maxInventoryBytes)
	switch {
	case errors.Is(err, ErrMissing):
		return emptyPayload(accountID), nil
	case errors.Is(err, errTooLarge):
		return inventoryPayload{}, ErrInvalidMetadata
	case err != nil:
		return inventoryPayload{}, fmt.Errorf("%w: %w", ErrUnavailable, err)
	}
	var payload inventoryPayload
	if json.Unmarshal(data, &payload) != nil {
		return inventoryPayload{}, ErrUnavailable
	}
	switch payload.AuthorizedRole {
	case "", RoleUser, RoleAdmin:
	default:
		return inventoryPayload{}, ErrUnavailable
	}
	if payload.Version != 1 || payload.AccountID != accountID || len(payload.Snapshot.Configs) > maxConfigs {
		return inventoryPayload{}, ErrInvalidMetadata
	}
	// A cache from before roles were recorded needs a complete authorized refresh
	if payload.AuthorizedRole == "" {
		return emptyPayload(accountID), nil
	}
	identifiers := map[string]bool{}
	for _, config := range payload.Snapshot.Configs {
		if !validConfig(config, accountID) || payload.AuthorizedConfigHashes[config.Identifier] != config.Snapshot.ConfigHash {
			return inventoryPayload{}, ErrInvalidMetadata
		}
		identifiers[config.Identifier] = true
	}
	snapshot := payload.Snapshot
	if len(identifiers) != len(snapshot.Configs) ||
		snapshot.SelectedIdentifier != "" && !identifiers[snapshot.SelectedIdentifier] ||
		!snapshot.AccessAllowed && len(snapshot.Configs) > 0 {
		return inventoryPayload{}, ErrInvalidMetadata
	}
	if payload.AuthorizedConfigHashes == nil {
		payload.AuthorizedConfigHashes = map[string]string{}
	}
	return payload, nil
}

// Save stores installed config metadata. The config hash must come from the
// account's latest complete authorization
func (c *AccountCache) Save(config InstalledConfig) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !validConfig(config, config.AccountID) {
		return ErrInvalidMetadata
	}
	payload, err := c.load(config.AccountID)
	if err != nil {
		return err
	}
	if !payload.Snapshot.AccessAllowed || payload.AuthorizedConfigHashes[config.Identifier] != config.Snapshot.ConfigHash {
		return ErrAccessDenied
	}
	configs := slices.DeleteFunc(payload.Snapshot.Configs, func(existing InstalledConfig) bool {
		return existing.Identifier == config.Identifier
	})
	payload.Snapshot.Configs = append(configs, config)
	if len(payload.Snapshot.Configs) > maxConfigs {
		return ErrInvalidMetadata
	}
	return c.write(payload)
}

// ObserveRole reports true when a confirmed user role after admin, or after
// an unknown role, denied and wiped the cache. The in-memory denial holds
// even when persisting it fails
func (c *AccountCache) ObserveRole(accountID string, role Role) (bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !ValidAccountID(accountID) {
		return false, ErrInvalidMetadata
	}
	if role != RoleUser {
		return false, nil
	}
	if payload, err := c.load(accountID); err == nil && payload.AuthorizedRole == RoleUser {
		return false, nil
	}
	if err := c.deny(accountID); err != nil {
		return false, err
	}
	return true, nil
}

// Authorize replaces the authorized config hashes from a complete refresh.
// Installed configs stay only while their hash is still authorized, and get
// the refreshed metadata
func (c *AccountCache) Authorize(accountID string, role Role, options []AuthorizedOption) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !ValidAccountID(accountID) || role != RoleUser && role != RoleAdmin {
		return ErrInvalidMetadata
	}
	var inventory []AuthorizedOption
	for _, option := range options {
		if option.Status != statusRemoved {
			inventory = append(inventory, option)
		}
	}
	if len(inventory) > maxConfigs {
		return ErrInvalidMetadata
	}
	if role != RoleAdmin {
		for _, option := range options {
			if option.OwnerUID != accountID {
				return ErrAccessDenied
			}
		}
	}
	payload, err := c.load(accountID)
	if err != nil {
		payload = emptyPayload(accountID)
	}
	payload.AuthorizedConfigHashes = map[string]string{}
	authorized := map[string]AuthorizedOption{}
	for _, option := range inventory {
		if !option.Usable {
			continue
		}
		identifier := accountID + "/" + option.RegionID + "/" + option.ClientID
		if _, ok := authorized[identifier]; ok || !validHash(option.ConfigHash) {
			return ErrInvalidMetadata
		}
		authorized[identifier] = option
		payload.AuthorizedConfigHashes[identifier] = option.ConfigHash
	}
	configs := []InstalledConfig{}
	var dropped []string
	for _, config := range payload.Snapshot.Configs {
		option, ok := authorized[config.Identifier]
		if !ok || option.ConfigHash != config.Snapshot.ConfigHash {
			dropped = append(dropped, config.Snapshot.SecretReference)
			continue
		}
		config.Snapshot = ConfigSnapshot{
			ClientID: option.ClientID, RegionID: option.RegionID, ClientName: option.ClientName,
			RegionDisplayName: option.RegionDisplayName, Status: option.Status,
			ConfigHash: config.Snapshot.ConfigHash, SecretReference: config.Snapshot.SecretReference,
			ReadAt: c.now().UTC(), UpdatedAt: option.UpdatedAt,
			AssignedTunnelIPv4: option.AssignedTunnelIPv4, ServerEndpointIPv4: option.ServerEndpointIPv4,
			ServerEndpointHostname: option.ServerEndpointHostname,
		}
		configs = append(configs, config)
	}
	payload.Snapshot.Configs = configs
	if !slices.ContainsFunc(configs, func(config InstalledConfig) bool {
		return config.Identifier == payload.Snapshot.SelectedIdentifier
	}) {
		payload.Snapshot.SelectedIdentifier = ""
	}
	payload.Snapshot.AccessAllowed = true
	payload.AuthorizedRole = role
	if err := c.write(payload); err != nil {
		return err
	}
	delete(c.denied, accountID)
	c.dropSecrets(dropped)
	return nil
}

func (c *AccountCache) Deny(accountID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.deny(accountID)
}

func (c *AccountCache) deny(accountID string) error {
	if !ValidAccountID(accountID) {
		return ErrInvalidMetadata
	}
	var dropped []string
	if payload, err := c.load(accountID); err == nil {
		for _, config := range payload.Snapshot.Configs {
			dropped = append(dropped, config.Snapshot.SecretReference)
		}
	}
	c.denied[accountID] = true
	if err := c.write(emptyPayload(accountID)); err != nil {
		return err
	}
	c.dropSecrets(dropped)
	return nil
}

// References reports whether an installed config of accountID uses reference.
// An unreadable cache counts as using it
func (c *AccountCache) References(accountID, reference string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	payload, err := c.load(accountID)
	if err != nil {
		return true
	}
	return slices.ContainsFunc(payload.Snapshot.Configs, func(config InstalledConfig) bool {
		return config.Snapshot.SecretReference == reference
	})
}

func (c *AccountCache) dropSecrets(references []string) {
	if c.drop != nil && len(references) > 0 {
		c.drop(references)
	}
}

func (c *AccountCache) Select(identifier, accountID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	payload, err := c.load(accountID)
	if err != nil {
		return err
	}
	if !payload.Snapshot.AccessAllowed || !slices.ContainsFunc(payload.Snapshot.Configs, func(config InstalledConfig) bool {
		return config.Identifier == identifier
	}) {
		return ErrInvalidMetadata
	}
	payload.Snapshot.SelectedIdentifier = identifier
	return c.write(payload)
}

func (c *AccountCache) SelectMode(mode ipc.Mode, accountID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !validMode(mode) {
		return ErrInvalidMetadata
	}
	payload, err := c.load(accountID)
	if err != nil {
		return err
	}
	if !payload.Snapshot.AccessAllowed {
		return ErrAccessDenied
	}
	payload.Snapshot.SelectedMode = &mode
	return c.write(payload)
}

// Evict durably revokes one client of accountID, installed or not, and
// returns the remaining snapshot
func (c *AccountCache) Evict(identifier, accountID string) (InventorySnapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !ValidAccountID(accountID) {
		return InventorySnapshot{}, ErrInvalidMetadata
	}
	if !ValidIdentifier(identifier) || strings.Split(identifier, "/")[0] != accountID {
		return InventorySnapshot{}, ErrInvalidMetadata
	}
	payload, err := c.load(accountID)
	if err != nil {
		return InventorySnapshot{}, err
	}
	payload.Snapshot.Configs = slices.DeleteFunc(payload.Snapshot.Configs, func(config InstalledConfig) bool {
		return config.Identifier == identifier
	})
	delete(payload.AuthorizedConfigHashes, identifier)
	if payload.Snapshot.SelectedIdentifier == identifier {
		payload.Snapshot.SelectedIdentifier = ""
	}
	if err := c.write(payload); err != nil {
		return InventorySnapshot{}, err
	}
	return payload.Snapshot, nil
}

func (c *AccountCache) write(payload inventoryPayload) error {
	if !ValidAccountID(payload.AccountID) {
		return ErrInvalidMetadata
	}
	if c.readOnly {
		return ErrReadOnly
	}
	if payload.Snapshot.Configs == nil {
		payload.Snapshot.Configs = []InstalledConfig{}
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrUnavailable, err)
	}
	if len(data) > maxInventoryBytes {
		return ErrInvalidMetadata
	}
	path := c.path(payload.AccountID)
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		return fmt.Errorf("%w: %w", ErrUnavailable, err)
	}
	if err := os.Mkdir(filepath.Dir(path), 0o700); err == nil {
		_ = syncDir(c.dir)
	} else if !os.IsExist(err) {
		return fmt.Errorf("%w: %w", ErrUnavailable, err)
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("%w: %w", ErrUnavailable, err)
	}
	if err := writeFile(path, data); err != nil {
		return fmt.Errorf("%w: %w", ErrUnavailable, err)
	}
	return nil
}

func (c *AccountCache) path(accountID string) string {
	sum := sha256.Sum256([]byte(accountID))
	return filepath.Join(c.dir, hex.EncodeToString(sum[:]), "inventory.json")
}

// ValidAccountID matches the account segment of a config identifier, so every
// signed-in account can name its configs
func ValidAccountID(accountID string) bool {
	return len(accountID) <= 128 && ValidComponent(accountID)
}

func validConfig(config InstalledConfig, accountID string) bool {
	snapshot := config.Snapshot
	return ValidAccountID(accountID) && config.AccountID == accountID &&
		snapshot.Status == statusActive && snapshot.ClientID != "" && snapshot.RegionID != "" &&
		config.Identifier == accountID+"/"+snapshot.RegionID+"/"+snapshot.ClientID &&
		validHash(snapshot.ConfigHash) && ValidSecretReference(snapshot.SecretReference)
}

func validHash(hash string) bool { return len(hash) == 64 && isLowerHex(hash) }

func isLowerHex(value string) bool {
	return !strings.ContainsFunc(value, func(r rune) bool { return (r < '0' || r > '9') && (r < 'a' || r > 'f') })
}

// isControl matches Foundation's controlCharacters set, categories Cc and Cf
func isControl(r rune) bool { return unicode.In(r, unicode.Cc, unicode.Cf) }

// ValidComponent is one region, client, or account segment of a config identifier
func ValidComponent(value string) bool {
	return value != "" && len(value) <= 256 && value != "." && value != ".." &&
		!strings.ContainsFunc(value, func(r rune) bool {
			return (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '-' && r != '_' && r != '.'
		})
}

// ValidIdentifier is the compound config ID signedInUID/regionId/clientId
func ValidIdentifier(value string) bool {
	parts := strings.Split(value, "/")
	return len(value) <= 1024 && len(parts) == 3 &&
		ValidComponent(parts[0]) && ValidComponent(parts[1]) && ValidComponent(parts[2])
}

// BoundedText is non-empty text within limit bytes and without control characters
func BoundedText(value string, limit int) bool {
	return value != "" && len(value) <= limit && !strings.ContainsFunc(value, isControl)
}
