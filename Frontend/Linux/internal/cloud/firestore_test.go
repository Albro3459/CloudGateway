package cloud

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"
)

const docsRoot = "projects/demo-cloudgateway/databases/(default)/documents/"

func regionDoc(id, fields string) string {
	return `{"document":{"name":"` + docsRoot + `Regions/` + id + `","fields":{` + fields + `}},"readTime":"2026-10-26T12:00:00Z"}`
}

func clientDocJSON(regionID, clientID, fields string) string {
	return `{"name":"` + docsRoot + `Regions/` + regionID + `/Instances/` + clientID + `","fields":{` + fields + `},` +
		`"createTime":"2026-10-01T00:00:00Z","updateTime":"2026-10-02T00:00:00Z"}`
}

func clientEntry(regionID, clientID, fields string) string {
	return `{"document":` + clientDocJSON(regionID, clientID, fields) + `,"readTime":"2026-10-26T12:00:00Z"}`
}

func clientFields(owner, status, config string) string {
	return `"ownerUid":{"stringValue":"` + owner + `"},"ownerEmail":{"stringValue":"` + owner + `@example.com"},` +
		`"clientName":{"stringValue":" Laptop "},"status":{"stringValue":"` + status + `"},` +
		`"wireguardConfig":` + config + `,"assignedTunnelIpv4":{"stringValue":"10.0.0.2/32"},` +
		`"serverEndpointHostname":{"stringValue":"wg.us-sanjose-1.gocloudlaunch.com"},` +
		`"updatedAt":{"timestampValue":"2026-10-02T03:04:05.123456Z"},"createdAt":{"timestampValue":"2026-10-01T00:00:00Z"},` +
		`"removedAt":{"nullValue":null},"lastErrorCode":{"nullValue":null}`
}

const configValue = `{"stringValue":"[Interface]\nPrivateKey = SECRET\n"}`

func firestoreHandler(regions, clients string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body := map[string]any{}
		_ = json.NewDecoder(r.Body).Decode(&body)
		from := fmt.Sprint(body["structuredQuery"].(map[string]any)["from"])
		if strings.Contains(from, "Regions") {
			reply(200, regions)(w, r)
			return
		}
		reply(200, clients)(w, r)
	}
}

func TestFetchInventoryForUser(t *testing.T) {
	regions := `[` +
		regionDoc("us-sanjose-1", `"regionId":{"stringValue":"us-sanjose-1"},"displayName":{"stringValue":"San Jose"},"enabled":{"booleanValue":true},"displayOrder":{"integerValue":"2"},"capacityLimit":{"integerValue":"20"}`) + `,` +
		regionDoc("us-ashburn-1", `"displayName":{"stringValue":"Ashburn"},"enabled":{"booleanValue":true}`) + `,` +
		regionDoc("eu-mismatch-1", `"regionId":{"stringValue":"other"},"displayName":{"stringValue":"Mismatch"},"enabled":{"booleanValue":true}`) + `,` +
		regionDoc("eu-noname-1", `"enabled":{"booleanValue":true}`) + `,` +
		`{"readTime":"2026-10-26T12:00:00Z"}]`
	clients := `[` +
		clientEntry("us-sanjose-1", "c1", `"clientId":{"stringValue":"c1"},"regionId":{"stringValue":"us-sanjose-1"},`+clientFields("uid-1", "active", configValue)) + `,` +
		clientEntry("us-ashburn-1", "c2", clientFields("uid-1", "creating", `{"nullValue":null}`)) + `,` +
		clientEntry("ap-tokyo-1", "c3", clientFields("uid-1", "failed", configValue)) + `,` +
		clientEntry("us-sanjose-1", "c4", clientFields("uid-1", "removed", configValue)) + `,` +
		clientEntry("us-sanjose-1", "c5", clientFields("uid-2", "active", configValue)) + `,` +
		clientEntry("us-sanjose-1", "c6", `"clientId":{"stringValue":"other"},`+clientFields("uid-1", "active", configValue)) + `,` +
		clientEntry("us-sanjose-1", "c7", `"regionId":{"stringValue":"us-ashburn-1"},`+clientFields("uid-1", "active", configValue)) + `,` +
		clientEntry("us-sanjose-1", "c8", clientFields("uid-1", "deleted", configValue)) + `,` +
		`{"readTime":"2026-10-26T12:00:00Z","skippedResults":1}]`
	client, server := newTestClient(t, firestoreHandler(regions, clients))
	inventory, err := client.FetchInventory(t.Context(), "uid-1", RoleUser, staticTokens("id-1"))
	if err != nil {
		t.Fatal(err)
	}

	wantRegions := []Region{{"us-sanjose-1", "San Jose", true, 2}, {"us-ashburn-1", "Ashburn", true, 1000}}
	if fmt.Sprint(inventory.Regions) != fmt.Sprint(wantRegions) {
		t.Fatalf("regions = %+v", inventory.Regions)
	}
	var rows []string
	for _, option := range inventory.Options {
		rows = append(rows, fmt.Sprintf("%s %s %s %d %v %v", option.Client.ClientID, option.Client.Status,
			option.RegionDisplayName(), option.DisplayOrder(), option.RegionEnabled(), option.Client.HasUsableConfig()))
	}
	want := []string{
		"c1 active San Jose 2 true true",
		"c2 creating Ashburn 1000 true false",
		"c3 failed ap-tokyo-1 1000 false false",
	}
	if fmt.Sprint(rows) != fmt.Sprint(want) {
		t.Fatalf("options = %q", rows)
	}
	c1 := inventory.Options[0].Client
	if c1.ClientName != "Laptop" || c1.DisplayName() != "Laptop" || c1.OwnerUID != "uid-1" || c1.OwnerEmail != "uid-1@example.com" ||
		c1.AssignedTunnelIPv4 != "10.0.0.2/32" || c1.ServerEndpointHostname != "wg.us-sanjose-1.gocloudlaunch.com" ||
		!c1.UpdatedAt.Equal(time.Date(2026, 10, 2, 3, 4, 5, 123456000, time.UTC)) ||
		string(c1.WireGuardConfig) != "[Interface]\nPrivateKey = SECRET\n" {
		t.Fatalf("client = %+v", c1)
	}
	if strings.Contains(fmt.Sprintf("%+v", inventory), "SECRET") {
		t.Fatal("formatted inventory leaks config")
	}

	var bodies []string
	for _, got := range server.recorded() {
		if got.method != http.MethodPost || got.path != "/v1/"+docsRoot[:len(docsRoot)-1]+":runQuery" ||
			got.header.Get("Authorization") != "Bearer id-1" {
			t.Fatalf("request = %+v", got)
		}
		bodies = append(bodies, got.body)
	}
	wantBodies := map[string]bool{
		`{"structuredQuery":{"from":[{"collectionId":"Regions"}],"where":{"fieldFilter":{"field":{"fieldPath":"enabled"},"op":"EQUAL","value":{"booleanValue":true}}}}}`:                            true,
		`{"structuredQuery":{"from":[{"allDescendants":true,"collectionId":"Instances"}],"where":{"fieldFilter":{"field":{"fieldPath":"ownerUid"},"op":"EQUAL","value":{"stringValue":"uid-1"}}}}}`: true,
	}
	if len(bodies) != 2 || !wantBodies[bodies[0]] || !wantBodies[bodies[1]] || bodies[0] == bodies[1] {
		t.Fatalf("bodies = %q", bodies)
	}
}

func TestFetchInventoryForAdmin(t *testing.T) {
	clients := `[` + clientEntry("us-sanjose-1", "c5", clientFields("uid-2", "active", configValue)) + `]`
	client, server := newTestClient(t, firestoreHandler(`[]`, clients))
	inventory, err := client.FetchInventory(t.Context(), "uid-1", RoleAdmin, staticTokens("id-1"))
	if err != nil || len(inventory.Options) != 1 || inventory.Options[0].Client.OwnerUID != "uid-2" || inventory.Options[0].Region != nil {
		t.Fatalf("inventory = %+v, %v", inventory, err)
	}
	for _, got := range server.recorded() {
		if strings.Contains(got.body, "Instances") &&
			got.body != `{"structuredQuery":{"from":[{"allDescendants":true,"collectionId":"Instances"}]}}` {
			t.Fatalf("admin query = %s", got.body)
		}
	}
}

func TestFetchInventoryErrors(t *testing.T) {
	denied := `[{"error":{"code":403,"message":"Missing or insufficient permissions.","status":"PERMISSION_DENIED"}}]`
	cases := []struct {
		name    string
		handler http.HandlerFunc
		kind    Kind
	}{
		{"denial beats sibling outage", func(w http.ResponseWriter, r *http.Request) {
			body := map[string]any{}
			_ = json.NewDecoder(r.Body).Decode(&body)
			if strings.Contains(fmt.Sprint(body), "Regions") {
				reply(503, `{"error":{"code":503,"status":"UNAVAILABLE"}}`)(w, r)
				return
			}
			reply(403, denied)(w, r)
		}, KindAccessDenied},
		{"unavailable", reply(503, `{"error":{"code":503,"status":"UNAVAILABLE"}}`), KindOffline},
		{"deadline", reply(504, `{"error":{"code":504,"status":"DEADLINE_EXCEEDED"}}`), KindOffline},
		{"proxy 503 page", reply(503, `<html>`), KindUnavailable},
		{"proxy 403 page", reply(403, `<html>`), KindUnavailable},
		{"proxy 401 page", reply(401, `<html>`), KindUnavailable},
		{"unauthenticated", reply(401, `{"error":{"code":401,"status":"UNAUTHENTICATED"}}`), KindAccessDenied},
		{"internal", reply(500, `{"error":{"code":500,"status":"INTERNAL"}}`), KindUnavailable},
		{"index needed", reply(400, `{"error":{"code":400,"status":"FAILED_PRECONDITION"}}`), KindUnavailable},
		{"stream error", reply(200, `[{"readTime":"2026-10-26T12:00:00Z"},{"error":{"code":403,"status":"PERMISSION_DENIED"}}]`), KindAccessDenied},
		{"malformed stream", reply(200, `{"document":{}}`), KindInvalidResponse},
		{"malformed value", reply(200, `[`+clientEntry("r", "c", `"status":{"integerValue":5}`)+`]`), KindInvalidResponse},
		{"oversized", reply(200, `["`+strings.Repeat("a", firestoreLimit)+`"]`), KindInvalidResponse},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client, _ := newTestClient(t, tc.handler)
			_, err := client.FetchInventory(t.Context(), "uid-1", RoleUser, staticTokens("id-1"))
			wantKind(t, err, tc.kind)
			if strings.Contains(err.Error(), "insufficient") {
				t.Fatalf("error leaks body: %v", err)
			}
		})
	}

	client, server := newTestClient(t, reply(200, `[]`))
	_, err := client.FetchInventory(t.Context(), "uid-1", Role("owner"), staticTokens("id-1"))
	wantKind(t, err, KindAccessDenied)
	if len(server.recorded()) != 0 {
		t.Fatal("unverified role queried Firestore")
	}
}

func TestFetchInventoryRefreshesOnceAfter401(t *testing.T) {
	client, server := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fresh" {
			reply(401, `{"error":{"code":401,"status":"UNAUTHENTICATED"}}`)(w, r)
			return
		}
		reply(200, `[]`)(w, r)
	})
	refreshes := 0
	_, err := client.FetchInventory(t.Context(), "uid-1", RoleUser, func(_ context.Context, force bool) (Secret, error) {
		if force {
			refreshes++
			return "fresh", nil
		}
		return "stale", nil
	})
	if err != nil || refreshes != 1 || len(server.recorded()) != 4 {
		t.Fatalf("err = %v, refreshes %d, requests %d", err, refreshes, len(server.recorded()))
	}
}

func TestFetchInventoryRefreshesAfterStreamUnauthenticated(t *testing.T) {
	clients := `[` + clientEntry("us-sanjose-1", "c1", clientFields("uid-1", "active", configValue)) + `]`
	expired := `[` + clientEntry("us-sanjose-1", "c1", clientFields("uid-1", "active", configValue)) +
		`,{"error":{"code":401,"message":"token expired","status":"UNAUTHENTICATED"}}]`
	client, server := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer fresh" {
			firestoreHandler(`[]`, clients)(w, r)
			return
		}
		firestoreHandler(`[]`, expired)(w, r)
	})
	var forced []bool
	inventory, err := client.FetchInventory(t.Context(), "uid-1", RoleUser, func(_ context.Context, force bool) (Secret, error) {
		forced = append(forced, force)
		if force {
			return "fresh", nil
		}
		return "stale", nil
	})
	if err != nil || len(inventory.Options) != 1 || fmt.Sprint(forced) != "[false true]" || len(server.recorded()) != 4 {
		t.Fatalf("inventory = %+v, err %v, forced %v, requests %d", inventory, err, forced, len(server.recorded()))
	}

	client, _ = newTestClient(t, firestoreHandler(`[]`, expired))
	forced = nil
	_, err = client.FetchInventory(t.Context(), "uid-1", RoleUser, func(_ context.Context, force bool) (Secret, error) {
		forced = append(forced, force)
		return "stale", nil
	})
	if e := wantKind(t, err, KindAccessDenied); e.Code != "UNAUTHENTICATED" || fmt.Sprint(forced) != "[false true]" {
		t.Fatalf("err = %#v, forced %v", e, forced)
	}
}

func TestDecodeValue(t *testing.T) {
	cases := map[string]any{
		`{"nullValue":null}`:                                                   nil,
		`{"booleanValue":true}`:                                                true,
		`{"integerValue":"-9007199254740993"}`:                                 int64(-9007199254740993),
		`{"doubleValue":1.5}`:                                                  1.5,
		`{"doubleValue":"Infinity"}`:                                           math.Inf(1),
		`{"timestampValue":"2026-10-26T12:00:00.5Z"}`:                          time.Date(2026, 10, 26, 12, 0, 0, 500000000, time.UTC),
		`{"timestampValue":"2026-10-26T05:00:00-07:00"}`:                       time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC),
		`{"stringValue":"a"}`:                                                  "a",
		`{"bytesValue":"AQI="}`:                                                []byte{1, 2},
		`{"referenceValue":"projects/p/databases/d/documents/Regions/r"}`:      Reference("projects/p/databases/d/documents/Regions/r"),
		`{"geoPointValue":{"latitude":1.5,"longitude":-2}}`:                    GeoPoint{1.5, -2},
		`{"arrayValue":{}}`:                                                    []any{},
		`{"arrayValue":{"values":[{"integerValue":"1"},{"stringValue":"x"}]}}`: []any{int64(1), "x"},
		`{"mapValue":{}}`:                                                      map[string]any{},
		`{"mapValue":{"fields":{"a":{"mapValue":{"fields":{"b":{"booleanValue":false}}}}}}}`: map[string]any{"a": map[string]any{"b": false}},
	}
	for raw, want := range cases {
		got, err := decodeValue(json.RawMessage(raw))
		if err != nil {
			t.Fatalf("%s: %v", raw, err)
		}
		if gotTime, ok := got.(time.Time); ok {
			if !gotTime.Equal(want.(time.Time)) {
				t.Fatalf("%s = %v", raw, got)
			}
			continue
		}
		if fmt.Sprintf("%#v", got) != fmt.Sprintf("%#v", want) {
			t.Fatalf("%s = %#v, want %#v", raw, got, want)
		}
	}
	if got, err := decodeValue(json.RawMessage(`{"doubleValue":"NaN"}`)); err != nil || !math.IsNaN(got.(float64)) {
		t.Fatalf("NaN = %v, %v", got, err)
	}
	for _, raw := range []string{
		`{}`, `{"stringValue":"a","booleanValue":true}`, `{"integerValue":5}`, `{"integerValue":"1.5"}`,
		`{"integerValue":"9223372036854775808"}`, `{"doubleValue":"nan"}`, `{"timestampValue":"yesterday"}`,
		`{"booleanValue":"true"}`, `{"bytesValue":"%%%"}`, `{"vectorValue":{}}`, `{"arrayValue":{"values":[{}]}}`,
		`{"mapValue":{"fields":{"a":{"stringValue":1}}}}`, `"plain"`, `null`,
	} {
		if _, err := decodeValue(json.RawMessage(raw)); err == nil {
			t.Fatalf("%s decoded", raw)
		}
	}
}
