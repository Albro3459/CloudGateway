package cloud

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"
)

// Kind classifies a failure for session, inventory, and mutation policy
type Kind int

const (
	// KindUnavailable is a service failure or unexpected status. It never grants offline access
	KindUnavailable Kind = iota + 1
	// KindInvalidResponse is a reply that failed validation. Treat it like KindUnavailable
	// except where the device flow reports invalid_response separately
	KindInvalidResponse
	// KindOffline is a transport failure, timeout, or explicit auth outage. Retain the session
	KindOffline
	// KindAccessDenied is an actual 401/403 or Firestore permission denial
	KindAccessDenied
	// KindSignInRequired means Firebase rejected the retained credentials
	KindSignInRequired
	KindNotFound
	// KindRejected is a 4xx refusal with a known outcome, such as LIMIT_REACHED
	KindRejected
	// KindCanceled means the caller's context ended
	KindCanceled
	KindThrottled
	KindDeviceInvalid
	KindDeviceDenied
	KindDeviceExpired
	KindDeviceConsumed
)

var kindNames = map[Kind]string{
	KindUnavailable:     "unavailable",
	KindInvalidResponse: "invalid response",
	KindOffline:         "offline",
	KindAccessDenied:    "access denied",
	KindSignInRequired:  "sign-in required",
	KindNotFound:        "not found",
	KindRejected:        "rejected",
	KindCanceled:        "canceled",
	KindThrottled:       "throttled",
	KindDeviceInvalid:   "device request invalid",
	KindDeviceDenied:    "device request denied",
	KindDeviceExpired:   "device request expired",
	KindDeviceConsumed:  "device request consumed",
}

func (k Kind) String() string {
	if name, ok := kindNames[k]; ok {
		return name
	}
	return fmt.Sprintf("kind(%d)", int(k))
}

// CloudGateway API error codes from Backend/API/src/enums.py
const (
	CodeAuthRequired           = "AUTH_REQUIRED"
	CodeAuthUnavailable        = "AUTH_UNAVAILABLE"
	CodeAdminRequired          = "ADMIN_REQUIRED"
	CodeUserNotProvisioned     = "USER_NOT_PROVISIONED"
	CodeInvalidRequest         = "INVALID_REQUEST"
	CodeRegionDisabled         = "REGION_DISABLED"
	CodeRegionMismatch         = "REGION_MISMATCH"
	CodeLimitReached           = "LIMIT_REACHED"
	CodeCapacityReached        = "CAPACITY_REACHED"
	CodeClientNotFound         = "CLIENT_NOT_FOUND"
	CodeWireGuardApplyFailed   = "WIREGUARD_APPLY_FAILED"
	CodeFirebaseWriteFailed    = "FIREBASE_WRITE_FAILED"
	CodeRoleDefaultMissing     = "ROLE_DEFAULT_MISSING"
	CodeAccountSlotUnavailable = "ACCOUNT_SLOT_UNAVAILABLE"
	CodeInternalError          = "INTERNAL_ERROR"
)

// Error carries only safe metadata. It never holds response bodies, tokens, or secrets
type Error struct {
	Op     string
	Kind   Kind
	Status int
	// Code is an uppercase API, Firebase Auth, or Firestore status code when the reply had one
	Code       string
	RetryAfter time.Duration
	// Dispatched reports whether a write may have reached the server. Only writes set it
	Dispatched bool
	cause      error
}

func (e *Error) Error() string {
	message := "cloud: " + e.Op + ": " + e.Kind.String()
	switch {
	case e.Status != 0 && e.Code != "":
		message += fmt.Sprintf(" (HTTP %d %s)", e.Status, e.Code)
	case e.Status != 0:
		message += fmt.Sprintf(" (HTTP %d)", e.Status)
	case e.Code != "":
		message += " (" + e.Code + ")"
	}
	return message
}

// Unwrap exposes only context errors, since transport errors can embed request URLs
func (e *Error) Unwrap() error { return e.cause }

// KindOf returns the classification of err, or 0 when err is nil
func KindOf(err error) Kind {
	if err == nil {
		return 0
	}
	if e, ok := errors.AsType[*Error](err); ok {
		return e.Kind
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return KindCanceled
	}
	return KindUnavailable
}

var errorCodePattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)

func safeCode(code string) string {
	if errorCodePattern.MatchString(code) {
		return code
	}
	return ""
}
