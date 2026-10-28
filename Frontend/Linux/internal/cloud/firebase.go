package cloud

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Session is a Firebase Auth credential set. UserID and ProjectID come from the
// ID token so callers can check account and project continuity
type Session struct {
	IDToken      Secret
	RefreshToken Secret
	ExpiresAt    time.Time
	UserID       string
	ProjectID    string
}

type IDTokenClaims struct {
	UserID    string
	ProjectID string
	ExpiresAt time.Time
	AuthTime  time.Time
}

// Firebase Auth codes that mean these credentials are no longer usable. Request
// and configuration errors, such as PROJECT_NUMBER_MISMATCH or a bad API key, stay
// unavailable so a misconfigured release can't sign every host out
var signInRequiredCodes = map[string]bool{
	"TOKEN_EXPIRED":         true,
	"USER_DISABLED":         true,
	"USER_NOT_FOUND":        true,
	"INVALID_REFRESH_TOKEN": true,
	"INVALID_ID_TOKEN":      true,
}

// SignInWithCustomToken exchanges the device flow's custom token for a session
func (c *Client) SignInWithCustomToken(ctx context.Context, customToken Secret) (Session, error) {
	const op = "custom token sign-in"
	if customToken == "" || len(customToken) > maxCustomToken {
		return Session{}, &Error{Op: op, Kind: KindInvalidResponse}
	}
	body, _ := json.Marshal(struct {
		Token             string `json:"token"`
		ReturnSecureToken bool   `json:"returnSecureToken"`
	}{string(customToken), true})
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodPost,
		url:  c.identityBase + "/v1/accounts:signInWithCustomToken?key=" + url.QueryEscape(c.apiKey),
		body: body, limit: apiBodyLimit,
	})
	if err != nil {
		return Session{}, err
	}
	if resp.status != http.StatusOK {
		e := firebaseAuthError(op, resp)
		if e.Code == "INVALID_CUSTOM_TOKEN" {
			e.Kind = KindSignInRequired
		}
		return Session{}, e
	}
	var result struct {
		IDToken      string `json:"idToken"`
		RefreshToken string `json:"refreshToken"`
		ExpiresIn    string `json:"expiresIn"`
	}
	if json.Unmarshal(resp.body, &result) != nil {
		return Session{}, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
	}
	return c.session(op, result.IDToken, result.RefreshToken, result.ExpiresIn, "")
}

// RefreshSession rotates credentials through the Secure Token API. Callers serialize
// refreshes and persist the returned refresh token
func (c *Client) RefreshSession(ctx context.Context, refreshToken Secret) (Session, error) {
	const op = "token refresh"
	if refreshToken == "" || len(refreshToken) > maxCredentialLen {
		return Session{}, &Error{Op: op, Kind: KindSignInRequired}
	}
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {string(refreshToken)}}
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodPost, url: c.secureBase + "/v1/token?key=" + url.QueryEscape(c.apiKey),
		body: []byte(form.Encode()), contentType: "application/x-www-form-urlencoded", limit: apiBodyLimit,
	})
	if err != nil {
		return Session{}, err
	}
	if resp.status != http.StatusOK {
		return Session{}, firebaseAuthError(op, resp)
	}
	var result struct {
		IDToken      string `json:"id_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    string `json:"expires_in"`
		UserID       string `json:"user_id"`
	}
	if json.Unmarshal(resp.body, &result) != nil {
		return Session{}, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
	}
	return c.session(op, result.IDToken, result.RefreshToken, result.ExpiresIn, result.UserID)
}

func (c *Client) session(op, idToken, refreshToken, expiresIn, userID string) (Session, error) {
	invalid := &Error{Op: op, Kind: KindInvalidResponse, Status: http.StatusOK}
	seconds, err := strconv.Atoi(expiresIn)
	if err != nil || seconds < 1 || seconds > 86_400 || refreshToken == "" || len(refreshToken) > maxCredentialLen ||
		len(idToken) > maxCredentialLen {
		return Session{}, invalid
	}
	claims, err := ParseIDToken(Secret(idToken))
	if err != nil || claims.ProjectID != c.projectID || (userID != "" && userID != claims.UserID) {
		return Session{}, invalid
	}
	return Session{
		IDToken:      Secret(idToken),
		RefreshToken: Secret(refreshToken),
		ExpiresAt:    c.now().Add(time.Duration(seconds) * time.Second),
		UserID:       claims.UserID,
		ProjectID:    claims.ProjectID,
	}, nil
}

// ParseIDToken decodes Firebase ID token claims without verifying the signature.
// TLS to Google is the trust boundary, and the backend verifies every token it receives
func ParseIDToken(idToken Secret) (IDTokenClaims, error) {
	invalid := &Error{Op: "id token", Kind: KindInvalidResponse}
	parts := strings.Split(string(idToken), ".")
	if len(parts) != 3 {
		return IDTokenClaims{}, invalid
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return IDTokenClaims{}, invalid
	}
	var claims struct {
		Subject  string `json:"sub"`
		Audience string `json:"aud"`
		Issuer   string `json:"iss"`
		Expires  int64  `json:"exp"`
		AuthTime int64  `json:"auth_time"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.Subject == "" || len(claims.Subject) > 128 ||
		claims.Audience == "" || claims.Issuer != "https://securetoken.google.com/"+claims.Audience || claims.Expires <= 0 {
		return IDTokenClaims{}, invalid
	}
	result := IDTokenClaims{UserID: claims.Subject, ProjectID: claims.Audience, ExpiresAt: time.Unix(claims.Expires, 0)}
	if claims.AuthTime > 0 {
		result.AuthTime = time.Unix(claims.AuthTime, 0)
	}
	return result, nil
}

func firebaseAuthError(op string, resp *response) *Error {
	var envelope struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(resp.body, &envelope)
	// Messages are a bare code or "CODE : detail"
	code, _, _ := strings.Cut(envelope.Error.Message, " : ")
	e := &Error{Op: op, Kind: KindUnavailable, Status: resp.status, Code: safeCode(code)}
	if signInRequiredCodes[e.Code] {
		e.Kind = KindSignInRequired
	}
	return e
}
