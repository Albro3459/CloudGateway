// Package cloud talks to the CloudGateway APIs, Firebase Auth, and Firestore
// over REST. Callers own retries, timing, and session state
package cloud

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"regexp"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
)

const (
	defaultTimeout   = 10 * time.Second
	apiBodyLimit     = 64 << 10
	deviceBodyLimit  = 32 << 10
	firestoreLimit   = 8 << 20
	maxCustomToken   = 16 << 10
	maxCredentialLen = 16 << 10
)

// Secret holds a token or config. Formatting it never prints the value; use string(s) to read it
type Secret string

func (Secret) String() string { return "[redacted]" }

func (s Secret) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, "[redacted]") }

// TokenSource returns a Firebase ID token for the signed-in account. After a 401,
// safe reads call it once more with the rejected token. A source returns a newer
// cached token when another caller already refreshed, and refreshes otherwise
type TokenSource func(ctx context.Context, rejected Secret) (Secret, error)

type Config struct {
	// Origin is the CloudGateway site host, such as gocloudlaunch.com
	Origin             string
	FirebaseAPIKey     string
	FirebaseProjectID  string
	FirebaseDatabaseID string
	UserAgent          string
	// Timeout bounds each HTTP exchange, including reading the body
	Timeout time.Duration
	// Base URL overrides for tests. Empty values use production hosts
	APIBaseURL         string
	RegionalBaseURL    func(regionID string) string
	IdentityToolkitURL string
	SecureTokenURL     string
	FirestoreURL       string
	Transport          http.RoundTripper
}

// DefaultConfig uses the public build configuration
func DefaultConfig() Config {
	return Config{
		Origin:             buildinfo.Origin,
		FirebaseAPIKey:     buildinfo.FirebaseAPIKey,
		FirebaseProjectID:  buildinfo.FirebaseProjectID,
		FirebaseDatabaseID: buildinfo.FirebaseDatabaseID,
	}
}

type Client struct {
	origin       string
	apiKey       string
	projectID    string
	databaseID   string
	userAgent    string
	timeout      time.Duration
	apiBase      string
	regionalBase func(string) string
	identityBase string
	secureBase   string
	firestore    string
	http         *http.Client
	now          func() time.Time
}

var (
	originPattern     = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)
	projectIDPattern  = regexp.MustCompile(`^[a-z][a-z0-9-]{4,61}[a-z0-9]$`)
	databaseIDPattern = regexp.MustCompile(`^(\(default\)|[a-z][a-z0-9-]{0,61}[a-z0-9])$`)
	regionIDPattern   = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	clientIDPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
)

func New(cfg Config) (*Client, error) {
	if !originPattern.MatchString(cfg.Origin) {
		return nil, errors.New("cloud: invalid origin")
	}
	if cfg.FirebaseAPIKey == "" {
		return nil, errors.New("cloud: missing Firebase API key")
	}
	if !projectIDPattern.MatchString(cfg.FirebaseProjectID) {
		return nil, errors.New("cloud: invalid Firebase project ID")
	}
	if !databaseIDPattern.MatchString(cfg.FirebaseDatabaseID) {
		return nil, errors.New("cloud: invalid Firestore database ID")
	}
	c := &Client{
		origin:       cfg.Origin,
		apiKey:       cfg.FirebaseAPIKey,
		projectID:    cfg.FirebaseProjectID,
		databaseID:   cfg.FirebaseDatabaseID,
		userAgent:    cfg.UserAgent,
		timeout:      cfg.Timeout,
		apiBase:      cfg.APIBaseURL,
		regionalBase: cfg.RegionalBaseURL,
		identityBase: cfg.IdentityToolkitURL,
		secureBase:   cfg.SecureTokenURL,
		firestore:    cfg.FirestoreURL,
		now:          time.Now,
	}
	if c.userAgent == "" {
		c.userAgent = "CloudGateway-Linux/" + buildinfo.Version
	}
	if c.timeout <= 0 {
		c.timeout = defaultTimeout
	}
	if c.apiBase == "" {
		c.apiBase = "https://api." + cfg.Origin
	}
	if c.regionalBase == nil {
		c.regionalBase = func(regionID string) string { return "https://" + regionID + "." + cfg.Origin }
	}
	if c.identityBase == "" {
		c.identityBase = "https://identitytoolkit.googleapis.com"
	}
	if c.secureBase == "" {
		c.secureBase = "https://securetoken.googleapis.com"
	}
	if c.firestore == "" {
		c.firestore = "https://firestore.googleapis.com"
	}
	transport := cfg.Transport
	if transport == nil {
		defaultTransport := http.DefaultTransport.(*http.Transport).Clone()
		defaultTransport.MaxResponseHeaderBytes = 64 << 10
		transport = defaultTransport
	}
	c.http = &http.Client{
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return c, nil
}

// CloseIdleConnections drops pooled connections so later requests follow new routes
func (c *Client) CloseIdleConnections() { c.http.CloseIdleConnections() }

type request struct {
	op          string
	method      string
	url         string
	body        []byte
	contentType string
	token       Secret
	limit       int64
	// write marks a mutation. Its errors report whether bytes may have reached the server
	write bool
}

type response struct {
	status int
	header http.Header
	body   []byte
}

func (c *Client) send(ctx context.Context, r request) (*response, error) {
	if err := ctx.Err(); err != nil {
		return nil, &Error{Op: r.op, Kind: KindCanceled, cause: err}
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	// handshakeFailed catches a reset or close during the TLS handshake, as when
	// a firewall blocks the server name, which macOS reports as a TLS failure
	var dispatched, handshakeFailed atomic.Bool
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GotConn:          func(httptrace.GotConnInfo) { dispatched.Store(r.write) },
		TLSHandshakeDone: func(_ tls.ConnectionState, err error) { handshakeFailed.Store(err != nil) },
	})
	var body io.Reader
	if r.body != nil {
		body = bytes.NewReader(r.body)
	}
	req, err := http.NewRequestWithContext(ctx, r.method, r.url, body)
	if err != nil {
		return nil, &Error{Op: r.op, Kind: KindUnavailable}
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Cache-Control", "no-store")
	req.Header.Set("User-Agent", c.userAgent)
	if r.body != nil {
		contentType := r.contentType
		if contentType == "" {
			contentType = "application/json"
		}
		req.Header.Set("Content-Type", contentType)
	}
	if r.token != "" {
		req.Header.Set("Authorization", "Bearer "+string(r.token))
	}
	resp, err := c.http.Do(req)
	if err != nil {
		failure := transportError(parent, r.op, dispatched.Load(), err)
		var timeout interface{ Timeout() bool }
		if failure.Kind == KindOffline && handshakeFailed.Load() && !(errors.As(err, &timeout) && timeout.Timeout()) {
			failure.Kind = KindUnavailable
		}
		return nil, failure
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, r.limit+1))
	if err != nil {
		return nil, transportError(parent, r.op, r.write, err)
	}
	if int64(len(data)) > r.limit {
		return nil, &Error{Op: r.op, Kind: KindInvalidResponse, Status: resp.StatusCode, Dispatched: r.write}
	}
	return &response{status: resp.StatusCode, header: resp.Header, body: data}, nil
}

func transportError(parent context.Context, op string, dispatched bool, err error) *Error {
	if err := parent.Err(); err != nil {
		return &Error{Op: op, Kind: KindCanceled, Dispatched: dispatched, cause: err}
	}
	if offline(err) {
		return &Error{Op: op, Kind: KindOffline, Dispatched: dispatched}
	}
	return &Error{Op: op, Kind: KindUnavailable, Dispatched: dispatched}
}

// offline ports the macOS URL errors that count as offline: no network, a lost
// connection, a timeout, a host that refuses or can't be reached, and a failed
// DNS lookup. TLS, certificate, proxy, and protocol errors are unavailable, so
// a wrong clock or an intercepting proxy never allows cached offline starts
func offline(err error) bool {
	var dns *net.DNSError
	var op *net.OpError
	var timeout interface{ Timeout() bool }
	switch {
	case errors.As(err, &op) && op.Op == "proxyconnect":
		// macOS doesn't list proxy failures
		return false
	case errors.As(err, &dns):
		return true
	case errors.As(err, &timeout) && timeout.Timeout():
		return true
	case errors.As(err, &op) && op.Op == "dial":
		return true
	}
	for _, lost := range []error{syscall.ECONNREFUSED, syscall.ECONNRESET, syscall.ECONNABORTED, syscall.ENETUNREACH,
		syscall.EHOSTUNREACH, syscall.ENETDOWN, syscall.EPIPE, io.ErrUnexpectedEOF, io.EOF} {
		if errors.Is(err, lost) {
			return true
		}
	}
	return false
}

// readWithRefresh runs a safe authenticated read and repeats it once with a forced
// token refresh after a real 401 AUTH_REQUIRED or Firestore UNAUTHENTICATED
func readWithRefresh[T any](ctx context.Context, tokens TokenSource, read func(Secret) (T, error)) (T, error) {
	token, err := tokens(ctx, "")
	if err != nil {
		var zero T
		return zero, err
	}
	value, err := read(token)
	if e, ok := errors.AsType[*Error](err); !ok || e.Kind != KindAccessDenied ||
		(e.Code != CodeAuthRequired && e.Code != "UNAUTHENTICATED") {
		return value, err
	}
	token, err = tokens(ctx, token)
	if err != nil {
		var zero T
		return zero, err
	}
	return read(token)
}
