package cloud

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testProject = "demo-cloudgateway"
	testAPIKey  = "test-api-key"
)

var testNow = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

type exchange struct {
	method string
	path   string
	query  string
	header http.Header
	body   string
}

type fakeServer struct {
	*httptest.Server
	mu        sync.Mutex
	exchanges []exchange
}

func (s *fakeServer) recorded() []exchange {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]exchange(nil), s.exchanges...)
}

func newTestClient(t *testing.T, handler http.HandlerFunc) (*Client, *fakeServer) {
	t.Helper()
	server := &fakeServer{}
	server.Server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		server.mu.Lock()
		server.exchanges = append(server.exchanges, exchange{r.Method, r.URL.Path, r.URL.RawQuery, r.Header.Clone(), string(body)})
		server.mu.Unlock()
		r.Body = io.NopCloser(strings.NewReader(string(body)))
		handler(w, r)
	}))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	t.Cleanup(server.Close)
	client, err := New(Config{
		Origin:             "gocloudlaunch.com",
		FirebaseAPIKey:     testAPIKey,
		FirebaseProjectID:  testProject,
		FirebaseDatabaseID: "(default)",
		APIBaseURL:         server.URL,
		RegionalBaseURL:    func(regionID string) string { return server.URL + "/region/" + regionID },
		IdentityToolkitURL: server.URL,
		SecureTokenURL:     server.URL,
		FirestoreURL:       server.URL,
		Transport:          server.Client().Transport,
	})
	if err != nil {
		t.Fatal(err)
	}
	client.now = func() time.Time { return testNow }
	return client, server
}

func reply(status int, body string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}
}

func staticTokens(token Secret) TokenSource {
	return func(context.Context, Secret) (Secret, error) { return token, nil }
}

func wantKind(t *testing.T, err error, kind Kind) *Error {
	t.Helper()
	e, ok := errors.AsType[*Error](err)
	if !ok || e.Kind != kind {
		t.Fatalf("err = %v, want kind %v", err, kind)
	}
	return e
}

func idToken(t *testing.T, claims map[string]any) string {
	t.Helper()
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	return "eyJhbGciOiJSUzI1NiJ9." + base64.RawURLEncoding.EncodeToString(payload) + ".c2lnbmF0dXJl"
}

func userIDToken(t *testing.T, uid string) string {
	return idToken(t, map[string]any{
		"sub": uid, "user_id": uid, "aud": testProject, "iss": "https://securetoken.google.com/" + testProject,
		"exp": testNow.Add(time.Hour).Unix(), "auth_time": testNow.Unix(),
	})
}

func TestDefaultURLs(t *testing.T) {
	cfg := DefaultConfig()
	cfg.FirebaseAPIKey, cfg.FirebaseProjectID = testAPIKey, testProject
	client, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if client.apiBase != "https://api.gocloudlaunch.com" ||
		client.regionalBase("us-sanjose-1") != "https://us-sanjose-1.gocloudlaunch.com" ||
		client.identityBase != "https://identitytoolkit.googleapis.com" ||
		client.secureBase != "https://securetoken.googleapis.com" ||
		client.firestore != "https://firestore.googleapis.com" ||
		client.documentsPath() != "projects/demo-cloudgateway/databases/(default)/documents" {
		t.Fatalf("client = %+v", client)
	}
	for _, bad := range []Config{
		{Origin: "https://gocloudlaunch.com", FirebaseAPIKey: "k", FirebaseProjectID: testProject, FirebaseDatabaseID: "(default)"},
		{Origin: "gocloudlaunch.com", FirebaseProjectID: testProject, FirebaseDatabaseID: "(default)"},
		{Origin: "gocloudlaunch.com", FirebaseAPIKey: "k", FirebaseProjectID: "../x", FirebaseDatabaseID: "(default)"},
		{Origin: "gocloudlaunch.com", FirebaseAPIKey: "k", FirebaseProjectID: testProject, FirebaseDatabaseID: "a/b"},
	} {
		if _, err := New(bad); err == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}

func testSecret() *DeviceSecret {
	var s DeviceSecret
	for i := range s.bytes {
		s.bytes[i] = 1
	}
	return &s
}

const (
	testRequestID = "0123456789abcdef0123456789abcdef"
	// SHA-256 of 32 bytes of 0x01
	testSecretHash = "72cd6e8422c407fb6d098690f1130b7ded7ec2f7f5e1d30bd9d521f015363793"
	testSecretWire = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
	approvalURL1   = "https://gocloudlaunch.com/#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281"
)

func deviceCodeBody(mutate func(map[string]any)) string {
	body := map[string]any{
		"deviceRequestId":         testRequestID,
		"userCode":                "004281",
		"verificationUri":         "https://gocloudlaunch.com/#/auth/code",
		"verificationUriComplete": approvalURL1,
		"expiresIn":               300,
		"interval":                5,
	}
	if mutate != nil {
		mutate(body)
	}
	data, _ := json.Marshal(body)
	return string(data)
}

func TestRequestDeviceCode(t *testing.T) {
	client, server := newTestClient(t, reply(http.StatusCreated, deviceCodeBody(nil)))
	code, err := client.RequestDeviceCode(t.Context(), testSecret())
	if err != nil {
		t.Fatal(err)
	}
	want := DeviceCode{RequestID: testRequestID, UserCode: "004281", VerificationURL: approvalURL1, ExpiresIn: 300 * time.Second, Interval: 5 * time.Second}
	if code != want {
		t.Fatalf("code = %+v", code)
	}
	got := server.recorded()[0]
	if got.method != http.MethodPost || got.path != "/api/device/code" || got.query != "" ||
		got.body != `{"deviceSecretHash":"`+testSecretHash+`","deviceName":"CloudGateway for Linux"}` ||
		got.header.Get("Content-Type") != "application/json" || got.header.Get("Cache-Control") != "no-store" ||
		got.header.Get("Authorization") != "" || !strings.HasPrefix(got.header.Get("User-Agent"), "CloudGateway-Linux/") {
		t.Fatalf("request = %+v", got)
	}
}

func TestRequestDeviceCodeRejectsInvalidChallenges(t *testing.T) {
	cases := map[string]func(map[string]any){
		"request ID": func(b map[string]any) { b["deviceRequestId"] = "0123456789ABCDEF0123456789ABCDEF" },
		"user code":  func(b map[string]any) { b["userCode"] = "4281" },
		"expiry":     func(b map[string]any) { b["expiresIn"] = 301 },
		"interval":   func(b map[string]any) { b["interval"] = 4 },
		"base URL":   func(b map[string]any) { b["verificationUri"] = "https://evil.example/#/auth/code" },
		"complete host": func(b map[string]any) {
			b["verificationUriComplete"] = strings.Replace(approvalURL1, "gocloudlaunch.com", "evil.example", 1)
		},
		"complete code": func(b map[string]any) {
			b["verificationUriComplete"] = strings.Replace(approvalURL1, "004281", "111111", 1)
		},
		"complete scheme": func(b map[string]any) {
			b["verificationUriComplete"] = strings.Replace(approvalURL1, "https", "http", 1)
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			client, _ := newTestClient(t, reply(http.StatusCreated, deviceCodeBody(mutate)))
			_, err := client.RequestDeviceCode(t.Context(), testSecret())
			wantKind(t, err, KindInvalidResponse)
		})
	}
}

func TestValidApprovalURL(t *testing.T) {
	cases := map[string]bool{
		approvalURL1: true,
		"https://gocloudlaunch.com:443/#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281":  true,
		"https://gocloudlaunch.com:8443/#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281": false,
		"https://gocloudlaunch.com/x#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281":     false,
		"https://gocloudlaunch.com/?a=b#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281":  false,
		"https://user@gocloudlaunch.com/#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281": false,
		"https://api.gocloudlaunch.com/#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281":  false,
		"https://gocloudlaunch.com/#/auth/code?userCode=004281&deviceRequestId=" + testRequestID:           false,
		"https://gocloudlaunch.com/#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281&x=1":  false,
		"https://gocloudlaunch.com#/auth/code?deviceRequestId=" + testRequestID + "&userCode=004281":       false,
	}
	for raw, want := range cases {
		if got := ValidApprovalURL(raw, "gocloudlaunch.com", testRequestID, "004281"); got != want {
			t.Errorf("ValidApprovalURL(%q) = %v", raw, got)
		}
	}
}

func TestPollDeviceToken(t *testing.T) {
	client, server := newTestClient(t, reply(http.StatusAccepted, `{"state":"pending","interval":7}`))
	poll, err := client.PollDeviceToken(t.Context(), testRequestID, testSecret())
	if err != nil || poll != (DevicePoll{Pending: true, Interval: 7 * time.Second}) {
		t.Fatalf("poll = %+v, %v", poll, err)
	}
	if got := server.recorded()[0]; got.path != "/api/device/token" ||
		got.body != `{"deviceRequestId":"`+testRequestID+`","deviceSecret":"`+testSecretWire+`"}` {
		t.Fatalf("request = %+v", got)
	}

	client, _ = newTestClient(t, reply(http.StatusOK, `{"customToken":"custom-token"}`))
	poll, err = client.PollDeviceToken(t.Context(), testRequestID, testSecret())
	if err != nil || poll.Pending || string(poll.CustomToken) != "custom-token" {
		t.Fatalf("poll = %+v, %v", poll, err)
	}
}

func TestPollDeviceTokenErrors(t *testing.T) {
	cases := []struct {
		name       string
		handler    http.HandlerFunc
		kind       Kind
		retryAfter time.Duration
	}{
		{"invalid", reply(400, `{"error":{"code":"DEVICE_AUTH_INVALID","message":"x","requestId":"r"}}`), KindDeviceInvalid, 0},
		{"denied", reply(403, `{"error":{"code":"DEVICE_AUTH_DENIED"}}`), KindDeviceDenied, 0},
		{"consumed", reply(409, `{"error":{"code":"DEVICE_AUTH_CONSUMED"}}`), KindDeviceConsumed, 0},
		{"expired", reply(410, `{"error":{"code":"DEVICE_AUTH_EXPIRED"}}`), KindDeviceExpired, 0},
		{"throttled", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Retry-After", "12")
			reply(429, `{"error":{"code":"DEVICE_AUTH_THROTTLED"}}`)(w, r)
		}, KindThrottled, 12 * time.Second},
		{"throttled without Retry-After", reply(429, `{}`), KindInvalidResponse, 0},
		{"unavailable", reply(503, `{"error":{"code":"DEVICE_AUTH_UNAVAILABLE"}}`), KindUnavailable, 0},
		{"pending interval", reply(202, `{"state":"pending","interval":301}`), KindInvalidResponse, 0},
		{"empty token", reply(200, `{"customToken":""}`), KindInvalidResponse, 0},
		{"oversized token", reply(200, `{"customToken":"`+strings.Repeat("a", maxCustomToken+1)+`"}`), KindInvalidResponse, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client, _ := newTestClient(t, tc.handler)
			_, err := client.PollDeviceToken(t.Context(), testRequestID, testSecret())
			if e := wantKind(t, err, tc.kind); e.RetryAfter != tc.retryAfter {
				t.Fatalf("retry after = %v", e.RetryAfter)
			}
		})
	}

	client, server := newTestClient(t, reply(202, `{}`))
	_, err := client.PollDeviceToken(t.Context(), "not-a-request", testSecret())
	wantKind(t, err, KindDeviceInvalid)
	if len(server.recorded()) != 0 {
		t.Fatal("invalid request ID was sent")
	}
}

func TestSignInWithCustomToken(t *testing.T) {
	token := userIDToken(t, "uid-1")
	client, server := newTestClient(t, reply(200, `{"kind":"identitytoolkit#VerifyCustomTokenResponse","idToken":"`+token+`","refreshToken":"refresh-1","expiresIn":"3600","isNewUser":false}`))
	session, err := client.SignInWithCustomToken(t.Context(), "custom-token")
	if err != nil {
		t.Fatal(err)
	}
	want := Session{IDToken: Secret(token), RefreshToken: "refresh-1", ExpiresAt: testNow.Add(time.Hour), UserID: "uid-1", ProjectID: testProject}
	if session != want {
		t.Fatalf("session = %+v", session)
	}
	got := server.recorded()[0]
	if got.method != http.MethodPost || got.path != "/v1/accounts:signInWithCustomToken" || got.query != "key="+testAPIKey ||
		got.body != `{"token":"custom-token","returnSecureToken":true}` || got.header.Get("Authorization") != "" {
		t.Fatalf("request = %+v", got)
	}
}

func TestRefreshSession(t *testing.T) {
	token := userIDToken(t, "uid-1")
	client, server := newTestClient(t, reply(200, `{"access_token":"`+token+`","expires_in":"3600","token_type":"Bearer","refresh_token":"refresh-2","id_token":"`+token+`","user_id":"uid-1","project_id":"123456789"}`))
	session, err := client.RefreshSession(t.Context(), "refresh-1")
	if err != nil {
		t.Fatal(err)
	}
	if session.RefreshToken != "refresh-2" || session.UserID != "uid-1" || session.ProjectID != testProject ||
		!session.ExpiresAt.Equal(testNow.Add(time.Hour)) {
		t.Fatalf("session = %+v", session)
	}
	got := server.recorded()[0]
	if got.path != "/v1/token" || got.query != "key="+testAPIKey ||
		got.header.Get("Content-Type") != "application/x-www-form-urlencoded" ||
		got.body != "grant_type=refresh_token&refresh_token=refresh-1" {
		t.Fatalf("request = %+v", got)
	}

	for name, body := range map[string]string{
		"user mismatch":    `{"expires_in":"3600","refresh_token":"r","id_token":"` + token + `","user_id":"uid-2"}`,
		"project mismatch": `{"expires_in":"3600","refresh_token":"r","id_token":"` + idToken(t, map[string]any{"sub": "uid-1", "aud": "other-project", "iss": "https://securetoken.google.com/other-project", "exp": 1}) + `"}`,
		"numeric expiry":   `{"expires_in":3600,"refresh_token":"r","id_token":"` + token + `"}`,
		"missing refresh":  `{"expires_in":"3600","id_token":"` + token + `"}`,
		"bad id token":     `{"expires_in":"3600","refresh_token":"r","id_token":"abc"}`,
	} {
		t.Run(name, func(t *testing.T) {
			client, _ := newTestClient(t, reply(200, body))
			_, err := client.RefreshSession(t.Context(), "refresh-1")
			wantKind(t, err, KindInvalidResponse)
		})
	}
}

func TestFirebaseAuthErrors(t *testing.T) {
	cases := []struct {
		message string
		kind    Kind
		code    string
	}{
		{"TOKEN_EXPIRED", KindSignInRequired, "TOKEN_EXPIRED"},
		{"USER_DISABLED", KindSignInRequired, "USER_DISABLED"},
		{"USER_NOT_FOUND", KindSignInRequired, "USER_NOT_FOUND"},
		{"INVALID_REFRESH_TOKEN", KindSignInRequired, "INVALID_REFRESH_TOKEN"},
		{"INVALID_ID_TOKEN", KindSignInRequired, "INVALID_ID_TOKEN"},
		{"INVALID_GRANT_TYPE", KindUnavailable, "INVALID_GRANT_TYPE"},
		{"MISSING_REFRESH_TOKEN", KindUnavailable, "MISSING_REFRESH_TOKEN"},
		{"PROJECT_NUMBER_MISMATCH", KindUnavailable, "PROJECT_NUMBER_MISMATCH"},
		{"INVALID_CUSTOM_TOKEN : The custom token format is incorrect. Please check the documentation.", KindUnavailable, "INVALID_CUSTOM_TOKEN"},
		{"API key not valid. Please pass a valid API key.", KindUnavailable, ""},
		{"QUOTA_EXCEEDED", KindUnavailable, "QUOTA_EXCEEDED"},
		{"TOKEN_EXPIREDX:", KindUnavailable, ""},
	}
	for _, tc := range cases {
		t.Run(tc.message, func(t *testing.T) {
			body, _ := json.Marshal(map[string]any{"error": map[string]any{"code": 400, "message": tc.message, "status": "INVALID_ARGUMENT"}})
			client, _ := newTestClient(t, reply(400, string(body)))
			_, err := client.RefreshSession(t.Context(), "refresh-1")
			if e := wantKind(t, err, tc.kind); e.Code != tc.code {
				t.Fatalf("code = %q", e.Code)
			}
			if strings.Contains(err.Error(), "documentation") || strings.Contains(err.Error(), "refresh-1") {
				t.Fatalf("error leaks body: %v", err)
			}
		})
	}
	for message, kind := range map[string]Kind{
		"INVALID_CUSTOM_TOKEN : The custom token format is incorrect.": KindSignInRequired,
		"CREDENTIAL_MISMATCH":                             KindUnavailable,
		"API key not valid. Please pass a valid API key.": KindUnavailable,
	} {
		body, _ := json.Marshal(map[string]any{"error": map[string]any{"code": 400, "message": message}})
		client, _ := newTestClient(t, reply(400, string(body)))
		_, err := client.SignInWithCustomToken(t.Context(), "custom")
		wantKind(t, err, kind)
	}
	client, _ := newTestClient(t, reply(500, `oops`))
	_, err := client.SignInWithCustomToken(t.Context(), "custom")
	wantKind(t, err, KindUnavailable)
}

func TestCheckAccess(t *testing.T) {
	client, server := newTestClient(t, reply(200, `{"userId":"uid-1","email":null,"role":"admin"}`))
	access, err := client.CheckAccess(t.Context(), "uid-1", staticTokens("id-1"))
	if err != nil || access != (Access{UserID: "uid-1", Role: RoleAdmin}) {
		t.Fatalf("access = %+v, %v", access, err)
	}
	got := server.recorded()[0]
	if got.method != http.MethodPost || got.path != "/api/auth/check-access" || got.body != "{}" ||
		got.header.Get("Authorization") != "Bearer id-1" || got.header.Get("Content-Type") != "application/json" {
		t.Fatalf("request = %+v", got)
	}

	cases := []struct {
		name    string
		handler http.HandlerFunc
		kind    Kind
	}{
		{"forbidden", reply(403, `{"error":{"code":"USER_NOT_PROVISIONED"}}`), KindAccessDenied},
		{"proxy 403 page", reply(403, `<html>Access denied</html>`), KindUnavailable},
		{"proxy 401 page", reply(401, `<html>Unauthorized</html>`), KindUnavailable},
		{"403 with other code", reply(403, `{"error":{"code":"DEVICE_AUTH_DENIED"}}`), KindUnavailable},
		{"auth unavailable", reply(503, `{"error":{"code":"AUTH_UNAVAILABLE"}}`), KindUnavailable},
		{"other 503", reply(503, `<html>`), KindUnavailable},
		{"rejected", reply(400, `{}`), KindUnavailable},
		{"user mismatch", reply(200, `{"userId":"uid-2","role":"user"}`), KindInvalidResponse},
		{"unknown role", reply(200, `{"userId":"uid-1","role":"owner"}`), KindInvalidResponse},
		{"malformed", reply(200, `{`), KindInvalidResponse},
		{"oversized", reply(200, `{"userId":"uid-1","role":"user","pad":"`+strings.Repeat("a", apiBodyLimit)+`"}`), KindInvalidResponse},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client, _ := newTestClient(t, tc.handler)
			_, err := client.CheckAccess(t.Context(), "uid-1", staticTokens("id-1"))
			wantKind(t, err, tc.kind)
		})
	}
}

func TestCheckAccessRefreshesOnceAfter401(t *testing.T) {
	client, server := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer fresh" {
			reply(200, `{"userId":"uid-1","email":"a@example.com","role":"user"}`)(w, r)
			return
		}
		reply(401, `{"error":{"code":"AUTH_REQUIRED"}}`)(w, r)
	})
	var forced []bool
	tokens := func(_ context.Context, rejected Secret) (Secret, error) {
		force := rejected != ""
		forced = append(forced, force)
		if force {
			return "fresh", nil
		}
		return "stale", nil
	}
	access, err := client.CheckAccess(t.Context(), "uid-1", tokens)
	if err != nil || access.Email != "a@example.com" || fmt.Sprint(forced) != "[false true]" || len(server.recorded()) != 2 {
		t.Fatalf("access = %+v, %v, forced %v", access, err, forced)
	}

	forced = nil
	client, server = newTestClient(t, reply(401, `{"error":{"code":"AUTH_REQUIRED"}}`))
	_, err = client.CheckAccess(t.Context(), "uid-1", tokens)
	wantKind(t, err, KindAccessDenied)
	if len(server.recorded()) != 2 {
		t.Fatalf("requests = %d", len(server.recorded()))
	}

	client, server = newTestClient(t, reply(401, `<html>`))
	forced = nil
	_, err = client.CheckAccess(t.Context(), "uid-1", tokens)
	wantKind(t, err, KindUnavailable)
	if len(server.recorded()) != 1 || fmt.Sprint(forced) != "[false]" {
		t.Fatalf("proxy 401 refreshed: requests %d, forced %v", len(server.recorded()), forced)
	}

	sourceErr := &Error{Op: "token refresh", Kind: KindSignInRequired}
	client, _ = newTestClient(t, reply(401, `{"error":{"code":"AUTH_REQUIRED"}}`))
	_, err = client.CheckAccess(t.Context(), "uid-1", func(_ context.Context, rejected Secret) (Secret, error) {
		force := rejected != ""
		if force {
			return "", sourceErr
		}
		return "stale", nil
	})
	if err != sourceErr {
		t.Fatalf("err = %v", err)
	}
}

func TestCertificateFailuresAreUnavailable(t *testing.T) {
	_, server := newTestClient(t, reply(200, `{}`))
	// The default transport doesn't trust the test server, as with a wrong clock or an intercepting proxy
	client, err := New(Config{
		Origin: "gocloudlaunch.com", FirebaseAPIKey: testAPIKey, FirebaseProjectID: testProject, FirebaseDatabaseID: "(default)",
		APIBaseURL: server.URL, Transport: http.DefaultTransport.(*http.Transport).Clone(),
	})
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.CheckAccess(t.Context(), "uid-1", staticTokens("id-1"))

	wantKind(t, err, KindUnavailable)
}

func TestTransportFailuresAreOffline(t *testing.T) {
	client, server := newTestClient(t, reply(200, `{}`))
	server.Close()
	_, err := client.CheckAccess(t.Context(), "uid-1", staticTokens("id-1"))
	if e := wantKind(t, err, KindOffline); e.Dispatched || errors.Unwrap(err) != nil {
		t.Fatalf("err = %#v", e)
	}

	client, _ = newTestClient(t, func(http.ResponseWriter, *http.Request) { time.Sleep(200 * time.Millisecond) })
	client.timeout = 20 * time.Millisecond
	_, err = client.CheckAccess(t.Context(), "uid-1", staticTokens("id-1"))
	wantKind(t, err, KindOffline)

	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	_, err = client.CheckAccess(ctx, "uid-1", staticTokens("id-1"))
	wantKind(t, err, KindCanceled)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v", err)
	}
}

func TestRedirectsAreNotFollowed(t *testing.T) {
	client, server := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/elsewhere" {
			reply(200, `{"userId":"uid-1","role":"user"}`)(w, r)
			return
		}
		http.Redirect(w, r, "/elsewhere", http.StatusTemporaryRedirect)
	})
	_, err := client.CheckAccess(t.Context(), "uid-1", staticTokens("id-1"))
	wantKind(t, err, KindUnavailable)
	if got := server.recorded(); len(got) != 1 || got[0].path != "/api/auth/check-access" {
		t.Fatalf("requests = %+v", got)
	}
}

func TestListRegions(t *testing.T) {
	client, server := newTestClient(t, reply(200, `{"regions":[{"regionId":"us-sanjose-1","displayName":"San Jose","displayOrder":1},{"regionId":"","displayName":"x","displayOrder":2}]}`))
	regions, err := client.ListRegions(t.Context())
	if err != nil || len(regions) != 1 || regions[0] != (Region{"us-sanjose-1", "San Jose", true, 1}) {
		t.Fatalf("regions = %+v, %v", regions, err)
	}
	if got := server.recorded()[0]; got.method != http.MethodGet || got.path != "/api/regions" || got.header.Get("Authorization") != "" {
		t.Fatalf("request = %+v", got)
	}
}

func TestFetchCapacity(t *testing.T) {
	client, server := newTestClient(t, reply(200, `{"regionId":"us-sanjose-1","capacityLimit":20,"allocatedClientCount":8}`))
	capacity, err := client.FetchCapacity(t.Context(), "us-sanjose-1", staticTokens("id-1"))
	if err != nil || capacity != (Capacity{Known: true, Limit: 20, Allocated: 8}) {
		t.Fatalf("capacity = %+v, %v", capacity, err)
	}
	if got := server.recorded()[0]; got.method != http.MethodGet || got.path != "/region/us-sanjose-1/api/capacity" ||
		got.header.Get("Authorization") != "Bearer id-1" {
		t.Fatalf("request = %+v", got)
	}

	for name, handler := range map[string]http.HandlerFunc{
		"region mismatch": reply(200, `{"regionId":"us-ashburn-1","capacityLimit":20,"allocatedClientCount":8}`),
		"missing field":   reply(200, `{"regionId":"us-sanjose-1","capacityLimit":20}`),
		"server error":    reply(500, `{"error":{"code":"INTERNAL_ERROR"}}`),
		"malformed":       reply(200, `[`),
		"proxy 403 page":  reply(403, `<html>`),
	} {
		t.Run(name, func(t *testing.T) {
			client, _ := newTestClient(t, handler)
			capacity, err := client.FetchCapacity(t.Context(), "us-sanjose-1", staticTokens("id-1"))
			if err != nil || capacity != (Capacity{}) {
				t.Fatalf("capacity = %+v, %v", capacity, err)
			}
		})
	}

	client, _ = newTestClient(t, reply(403, `{"error":{"code":"USER_NOT_PROVISIONED"}}`))
	_, err = client.FetchCapacity(t.Context(), "us-sanjose-1", staticTokens("id-1"))
	wantKind(t, err, KindAccessDenied)
}

const createdBody = `{"clientId":"6f77fd32-ecf5-4dd7-9d96-6bb84de92df1","regionId":"us-sanjose-1","clientName":"Laptop","status":"active",` +
	`"assignedTunnelIpv4":"10.0.0.2/32","assignedTunnelIpv6":"fd42:42:42::2/128","serverEndpointIpv4":"192.0.2.1",` +
	`"serverEndpointHostname":"wg.us-sanjose-1.gocloudlaunch.com","wireguardConfig":"[Interface]\nPrivateKey = SECRET\n"}`

func TestCreateClient(t *testing.T) {
	client, server := newTestClient(t, reply(200, createdBody))
	created, err := client.CreateClient(t.Context(), "us-sanjose-1", "  Laptop \n", "id-1")
	if err != nil {
		t.Fatal(err)
	}
	if created.ClientID != "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1" || created.ClientName != "Laptop" || created.Status != StatusActive ||
		created.AssignedTunnelIPv6 != "fd42:42:42::2/128" || created.ServerEndpointHostname != "wg.us-sanjose-1.gocloudlaunch.com" ||
		string(created.WireGuardConfig) != "[Interface]\nPrivateKey = SECRET\n" {
		t.Fatalf("created = %+v", created)
	}
	if strings.Contains(fmt.Sprintf("%v %+v %#v", created, created, created), "SECRET") {
		t.Fatal("formatted reply leaks config")
	}
	got := server.recorded()
	if len(got) != 1 || got[0].method != http.MethodPost || got[0].path != "/region/us-sanjose-1/api/clients" ||
		got[0].body != `{"regionId":"us-sanjose-1","clientName":"Laptop"}` || got[0].header.Get("Authorization") != "Bearer id-1" ||
		got[0].header.Get("Idempotency-Key") != "" {
		t.Fatalf("requests = %+v", got)
	}
}

func TestCreateClientErrors(t *testing.T) {
	cases := []struct {
		name    string
		handler http.HandlerFunc
		kind    Kind
		code    string
	}{
		{"limit", reply(409, `{"error":{"code":"LIMIT_REACHED","message":"Client limit reached for this region.","requestId":"r"}}`), KindRejected, CodeLimitReached},
		{"capacity", reply(409, `{"error":{"code":"CAPACITY_REACHED"}}`), KindRejected, CodeCapacityReached},
		{"region disabled", reply(400, `{"error":{"code":"REGION_DISABLED"}}`), KindRejected, CodeRegionDisabled},
		{"unauthorized", reply(401, `{"error":{"code":"AUTH_REQUIRED"}}`), KindAccessDenied, CodeAuthRequired},
		{"not provisioned", reply(403, `{"error":{"code":"USER_NOT_PROVISIONED"}}`), KindAccessDenied, CodeUserNotProvisioned},
		{"auth unavailable", reply(503, `{"error":{"code":"AUTH_UNAVAILABLE"}}`), KindUnavailable, CodeAuthUnavailable},
		{"proxy 403 page", reply(403, `<html>`), KindUnavailable, ""},
		{"proxy 400 page", reply(400, `<html>`), KindUnavailable, ""},
		{"apply failed", reply(500, `{"error":{"code":"WIREGUARD_APPLY_FAILED"}}`), KindUnavailable, CodeWireGuardApplyFailed},
		{"bad code", reply(500, `{"error":{"code":"lower case <script>"}}`), KindUnavailable, ""},
		{"missing config", reply(200, strings.Replace(createdBody, `"[Interface]\nPrivateKey = SECRET\n"`, `""`, 1)), KindInvalidResponse, ""},
		{"wrong region", reply(200, strings.Replace(createdBody, `"regionId":"us-sanjose-1"`, `"regionId":"us-ashburn-1"`, 1)), KindInvalidResponse, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client, server := newTestClient(t, tc.handler)
			_, err := client.CreateClient(t.Context(), "us-sanjose-1", "Laptop", "id-1")
			e := wantKind(t, err, tc.kind)
			if e.Code != tc.code || !e.Dispatched || len(server.recorded()) != 1 {
				t.Fatalf("err = %#v", e)
			}
			if strings.Contains(err.Error(), "limit reached") || strings.Contains(err.Error(), "id-1") {
				t.Fatalf("error leaks body or token: %v", err)
			}
		})
	}

	client, server := newTestClient(t, reply(200, createdBody))
	for _, name := range []string{" ", strings.Repeat("é", 81)} {
		_, err := client.CreateClient(t.Context(), "us-sanjose-1", name, "id-1")
		if e := wantKind(t, err, KindRejected); e.Dispatched {
			t.Fatal("local validation reported dispatch")
		}
	}
	_, err := client.CreateClient(t.Context(), "us-sanjose-1.evil.example/", "Laptop", "id-1")
	wantKind(t, err, KindRejected)
	if len(server.recorded()) != 0 {
		t.Fatal("invalid create was sent")
	}
}

func TestWriteDispatchReporting(t *testing.T) {
	client, server := newTestClient(t, reply(200, createdBody))
	server.Close()
	_, err := client.CreateClient(t.Context(), "us-sanjose-1", "Laptop", "id-1")
	if e := wantKind(t, err, KindOffline); e.Dispatched {
		t.Fatal("refused connection reported dispatch")
	}

	client, server = newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			conn.Close()
		}
	})
	_, err = client.CreateClient(t.Context(), "us-sanjose-1", "Laptop", "id-1")
	if e := wantKind(t, err, KindOffline); !e.Dispatched {
		t.Fatal("lost reply did not report dispatch")
	}
	err = client.DeleteClient(t.Context(), "us-sanjose-1", "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1", "owner-uid", "id-1")
	if e := wantKind(t, err, KindOffline); !e.Dispatched {
		t.Fatal("lost delete reply did not report dispatch")
	}
	if got := len(server.recorded()); got != 2 {
		t.Fatalf("writes sent %d times, want once each", got)
	}
}

func TestDeleteClient(t *testing.T) {
	const clientID = "6f77fd32-ecf5-4dd7-9d96-6bb84de92df1"
	client, server := newTestClient(t, reply(200, `{"userId":"owner-uid","clientId":"`+clientID+`","regionId":"us-sanjose-1","status":"removed"}`))
	if err := client.DeleteClient(t.Context(), "us-sanjose-1", clientID, "owner-uid", "id-1"); err != nil {
		t.Fatal(err)
	}
	got := server.recorded()[0]
	if got.method != http.MethodDelete || got.path != "/region/us-sanjose-1/api/clients/"+clientID ||
		got.body != `{"userId":"owner-uid","regionId":"us-sanjose-1"}` || got.header.Get("Authorization") != "Bearer id-1" {
		t.Fatalf("request = %+v", got)
	}

	for name, tc := range map[string]struct {
		handler http.HandlerFunc
		kind    Kind
	}{
		"not found":     {reply(404, `{"error":{"code":"CLIENT_NOT_FOUND"}}`), KindNotFound},
		"proxy 404":     {reply(404, `<html>`), KindUnavailable},
		"forbidden":     {reply(403, `{"error":{"code":"ADMIN_REQUIRED"}}`), KindAccessDenied},
		"wrong client":  {reply(200, `{"userId":"owner-uid","clientId":"other","regionId":"us-sanjose-1","status":"removed"}`), KindInvalidResponse},
		"wrong owner":   {reply(200, `{"userId":"uid-2","clientId":"`+clientID+`","regionId":"us-sanjose-1","status":"removed"}`), KindInvalidResponse},
		"not removed":   {reply(200, `{"userId":"owner-uid","clientId":"`+clientID+`","regionId":"us-sanjose-1","status":"active"}`), KindInvalidResponse},
		"internal":      {reply(500, `{"error":{"code":"FIREBASE_WRITE_FAILED"}}`), KindUnavailable},
		"in-progress":   {reply(409, `{"error":{"code":"SYNC_IN_PROGRESS"}}`), KindRejected},
		"rate limited":  {reply(429, `{}`), KindThrottled},
		"cloud gateway": {reply(502, `<html>`), KindUnavailable},
	} {
		t.Run(name, func(t *testing.T) {
			client, _ := newTestClient(t, tc.handler)
			err := client.DeleteClient(t.Context(), "us-sanjose-1", clientID, "owner-uid", "id-1")
			if e := wantKind(t, err, tc.kind); !e.Dispatched {
				t.Fatal("reply did not report dispatch")
			}
		})
	}

	client, server = newTestClient(t, reply(200, `{}`))
	err := client.DeleteClient(t.Context(), "us-sanjose-1", "../account", "owner-uid", "id-1")
	wantKind(t, err, KindRejected)
	if len(server.recorded()) != 0 {
		t.Fatal("invalid delete was sent")
	}
}

func TestSecretsAreRedacted(t *testing.T) {
	session := Session{IDToken: "id-secret", RefreshToken: "refresh-secret", UserID: "uid-1"}
	secret := testSecret()
	for _, output := range []string{
		fmt.Sprint(session), fmt.Sprintf("%+v", session), fmt.Sprintf("%#v", session), fmt.Sprintf("%s %q %x", session.IDToken, session.IDToken, session.IDToken),
		fmt.Sprintf("%v %+v %x", secret, *secret, secret), session.RefreshToken.String(),
	} {
		if strings.Contains(output, "secret") || strings.Contains(output, testSecretWire) || strings.Contains(output, "010101") {
			t.Fatalf("output leaks secret: %s", output)
		}
	}
}
