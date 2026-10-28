package cloud

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/buildinfo"
)

// DeviceSecret is the per-attempt login proof. Keep it in memory for one attempt only
type DeviceSecret struct {
	bytes [32]byte
}

func NewDeviceSecret() (*DeviceSecret, error) {
	var s DeviceSecret
	if _, err := rand.Read(s.bytes[:]); err != nil {
		return nil, err
	}
	return &s, nil
}

// Hash is the lowercase hex SHA-256 sent at creation
func (s *DeviceSecret) Hash() string {
	sum := sha256.Sum256(s.bytes[:])
	return hex.EncodeToString(sum[:])
}

func (s *DeviceSecret) encoded() string {
	return base64.RawURLEncoding.EncodeToString(s.bytes[:])
}

func (DeviceSecret) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, "[redacted]") }

type DeviceCode struct {
	RequestID string
	// UserCode is six digits, including leading zeroes
	UserCode        string
	VerificationURL string
	ExpiresIn       time.Duration
	Interval        time.Duration
}

// DevicePoll is either pending with the next interval or approved with a custom token
type DevicePoll struct {
	Pending     bool
	Interval    time.Duration
	CustomToken Secret
}

var (
	deviceRequestIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
	userCodePattern        = regexp.MustCompile(`^[0-9]{6}$`)
)

// RequestDeviceCode starts a login attempt. Callers measure expiry from before the call
func (c *Client) RequestDeviceCode(ctx context.Context, secret *DeviceSecret) (DeviceCode, error) {
	const op = "device code"
	body, _ := json.Marshal(struct {
		DeviceSecretHash string `json:"deviceSecretHash"`
		DeviceName       string `json:"deviceName"`
	}{secret.Hash(), buildinfo.DeviceName})
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodPost, url: c.apiBase + "/api/device/code", body: body, limit: deviceBodyLimit,
	})
	if err != nil {
		return DeviceCode{}, err
	}
	if resp.status != http.StatusCreated {
		return DeviceCode{}, deviceError(op, resp)
	}
	var code struct {
		DeviceRequestID         string `json:"deviceRequestId"`
		UserCode                string `json:"userCode"`
		VerificationURI         string `json:"verificationUri"`
		VerificationURIComplete string `json:"verificationUriComplete"`
		ExpiresIn               int    `json:"expiresIn"`
		Interval                int    `json:"interval"`
	}
	invalid := &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
	if json.Unmarshal(resp.body, &code) != nil {
		return DeviceCode{}, invalid
	}
	if !deviceRequestIDPattern.MatchString(code.DeviceRequestID) ||
		!userCodePattern.MatchString(code.UserCode) ||
		code.ExpiresIn < 1 || code.ExpiresIn > 300 ||
		code.Interval < 5 || code.Interval > 300 ||
		!approvalURL(code.VerificationURI, c.origin, "/auth/code") ||
		!ValidApprovalURL(code.VerificationURIComplete, c.origin, code.DeviceRequestID, code.UserCode) {
		return DeviceCode{}, invalid
	}
	return DeviceCode{
		RequestID:       code.DeviceRequestID,
		UserCode:        code.UserCode,
		VerificationURL: code.VerificationURIComplete,
		ExpiresIn:       time.Duration(code.ExpiresIn) * time.Second,
		Interval:        time.Duration(code.Interval) * time.Second,
	}, nil
}

// PollDeviceToken redeems an approved attempt once. A lost approved reply needs a new attempt
func (c *Client) PollDeviceToken(ctx context.Context, requestID string, secret *DeviceSecret) (DevicePoll, error) {
	const op = "device token"
	if !deviceRequestIDPattern.MatchString(requestID) {
		return DevicePoll{}, &Error{Op: op, Kind: KindDeviceInvalid}
	}
	body, _ := json.Marshal(struct {
		DeviceRequestID string `json:"deviceRequestId"`
		DeviceSecret    string `json:"deviceSecret"`
	}{requestID, secret.encoded()})
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodPost, url: c.apiBase + "/api/device/token", body: body, limit: deviceBodyLimit,
	})
	if err != nil {
		return DevicePoll{}, err
	}
	invalid := &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
	switch resp.status {
	case http.StatusAccepted:
		var pending struct {
			State    string `json:"state"`
			Interval int    `json:"interval"`
		}
		if json.Unmarshal(resp.body, &pending) != nil || pending.State != "pending" ||
			pending.Interval < 5 || pending.Interval > 300 {
			return DevicePoll{}, invalid
		}
		return DevicePoll{Pending: true, Interval: time.Duration(pending.Interval) * time.Second}, nil
	case http.StatusOK:
		var approved struct {
			CustomToken string `json:"customToken"`
		}
		if json.Unmarshal(resp.body, &approved) != nil || approved.CustomToken == "" ||
			len(approved.CustomToken) > maxCustomToken {
			return DevicePoll{}, invalid
		}
		return DevicePoll{CustomToken: Secret(approved.CustomToken)}, nil
	}
	return DevicePoll{}, deviceError(op, resp)
}

func deviceError(op string, resp *response) error {
	e := &Error{Op: op, Status: resp.status, Code: apiErrorCode(resp.body)}
	switch resp.status {
	case http.StatusBadRequest:
		e.Kind = KindDeviceInvalid
	case http.StatusForbidden:
		e.Kind = KindDeviceDenied
	case http.StatusConflict:
		e.Kind = KindDeviceConsumed
	case http.StatusGone:
		e.Kind = KindDeviceExpired
	case http.StatusTooManyRequests:
		retryAfter, ok := parseRetryAfter(resp.header)
		if !ok {
			e.Kind = KindInvalidResponse
			return e
		}
		e.Kind = KindThrottled
		e.RetryAfter = retryAfter
	default:
		e.Kind = KindUnavailable
	}
	return e
}

func parseRetryAfter(header http.Header) (time.Duration, bool) {
	seconds, err := strconv.Atoi(header.Get("Retry-After"))
	if err != nil || seconds < 1 || seconds > 86_400 {
		return 0, false
	}
	return time.Duration(seconds) * time.Second, true
}

// ValidApprovalURL matches the macOS challenge check: https on the site origin with path /
// and the request ID and code in the fragment
func ValidApprovalURL(rawURL, origin, requestID, userCode string) bool {
	return deviceRequestIDPattern.MatchString(requestID) && userCodePattern.MatchString(userCode) &&
		approvalURL(rawURL, origin, "/auth/code?deviceRequestId="+requestID+"&userCode="+userCode)
}

func approvalURL(rawURL, origin, fragment string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	return u.Scheme == "https" && u.Hostname() == origin && (u.Port() == "" || u.Port() == "443") &&
		u.User == nil && u.Path == "/" && u.RawQuery == "" && !u.ForceQuery && u.Fragment == fragment
}
