package cloud

import (
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Reference is a Firestore referenceValue document name
type Reference string

type GeoPoint struct {
	Latitude  float64
	Longitude float64
}

type document struct {
	name   string
	fields map[string]any
}

type rawDocument struct {
	Name   string                     `json:"name"`
	Fields map[string]json.RawMessage `json:"fields"`
}

type firestoreStatus struct {
	Status string `json:"status"`
}

var errMalformedValue = errors.New("malformed Firestore value")

// decodeValue converts the typed REST Value format into Go values: string, int64,
// float64, bool, time.Time, nil, []byte, Reference, GeoPoint, []any, and map[string]any
func decodeValue(raw json.RawMessage) (any, error) {
	var value map[string]json.RawMessage
	if json.Unmarshal(raw, &value) != nil || len(value) != 1 {
		return nil, errMalformedValue
	}
	for kind, data := range value {
		switch kind {
		case "nullValue":
			return nil, nil
		case "booleanValue":
			var v bool
			if err := unmarshalValue(data, &v); err != nil {
				return nil, err
			}
			return v, nil
		case "integerValue":
			var s string
			if err := unmarshalValue(data, &s); err != nil {
				return nil, err
			}
			v, err := strconv.ParseInt(s, 10, 64)
			if err != nil {
				return nil, errMalformedValue
			}
			return v, nil
		case "doubleValue":
			var v float64
			if json.Unmarshal(data, &v) == nil {
				return v, nil
			}
			var s string
			if err := unmarshalValue(data, &s); err != nil {
				return nil, err
			}
			switch s {
			case "NaN":
				return math.NaN(), nil
			case "Infinity":
				return math.Inf(1), nil
			case "-Infinity":
				return math.Inf(-1), nil
			}
			return nil, errMalformedValue
		case "timestampValue":
			var s string
			if err := unmarshalValue(data, &s); err != nil {
				return nil, err
			}
			v, err := time.Parse(time.RFC3339Nano, s)
			if err != nil {
				return nil, errMalformedValue
			}
			return v, nil
		case "stringValue":
			var v string
			if err := unmarshalValue(data, &v); err != nil {
				return nil, err
			}
			return v, nil
		case "bytesValue":
			var s string
			if err := unmarshalValue(data, &s); err != nil {
				return nil, err
			}
			v, err := base64.StdEncoding.DecodeString(s)
			if err != nil {
				return nil, errMalformedValue
			}
			return v, nil
		case "referenceValue":
			var v string
			if err := unmarshalValue(data, &v); err != nil {
				return nil, err
			}
			return Reference(v), nil
		case "geoPointValue":
			var v struct {
				Latitude  float64 `json:"latitude"`
				Longitude float64 `json:"longitude"`
			}
			if err := unmarshalValue(data, &v); err != nil {
				return nil, err
			}
			return GeoPoint(v), nil
		case "arrayValue":
			var v struct {
				Values []json.RawMessage `json:"values"`
			}
			if err := unmarshalValue(data, &v); err != nil {
				return nil, err
			}
			values := make([]any, len(v.Values))
			for i, item := range v.Values {
				decoded, err := decodeValue(item)
				if err != nil {
					return nil, err
				}
				values[i] = decoded
			}
			return values, nil
		case "mapValue":
			var v struct {
				Fields map[string]json.RawMessage `json:"fields"`
			}
			if err := unmarshalValue(data, &v); err != nil {
				return nil, err
			}
			return decodeFields(v.Fields)
		}
	}
	return nil, errMalformedValue
}

func unmarshalValue(data json.RawMessage, v any) error {
	if json.Unmarshal(data, v) != nil {
		return errMalformedValue
	}
	return nil
}

func decodeFields(raw map[string]json.RawMessage) (map[string]any, error) {
	fields := make(map[string]any, len(raw))
	for name, value := range raw {
		decoded, err := decodeValue(value)
		if err != nil {
			return nil, err
		}
		fields[name] = decoded
	}
	return fields, nil
}

func (c *Client) documentsPath() string {
	return "projects/" + c.projectID + "/databases/" + c.databaseID + "/documents"
}

// pathIDs returns the IDs after the documents root, which alternate collection and document
func (c *Client) pathIDs(name string) ([]string, bool) {
	rest, ok := strings.CutPrefix(name, c.documentsPath()+"/")
	if !ok {
		return nil, false
	}
	ids := strings.Split(rest, "/")
	for _, id := range ids {
		if id == "" {
			return nil, false
		}
	}
	return ids, true
}

func firestoreError(op string, resp *response) *Error {
	var status firestoreStatus
	var object struct {
		Error *firestoreStatus `json:"error"`
	}
	var array []struct {
		Error *firestoreStatus `json:"error"`
	}
	if json.Unmarshal(resp.body, &object) == nil && object.Error != nil {
		status = *object.Error
	} else if json.Unmarshal(resp.body, &array) == nil && len(array) > 0 && array[0].Error != nil {
		status = *array[0].Error
	}
	return firestoreStatusError(op, resp.status, status.Status)
}

// firestoreStatusError trusts only the Google error envelope's status, so a bare
// proxy 401/403/503 page is unavailable
func firestoreStatusError(op string, httpStatus int, status string) *Error {
	e := &Error{Op: op, Kind: KindUnavailable, Status: httpStatus, Code: safeCode(status)}
	switch status {
	case "PERMISSION_DENIED", "UNAUTHENTICATED":
		e.Kind = KindAccessDenied
	case "UNAVAILABLE", "DEADLINE_EXCEEDED":
		e.Kind = KindOffline
	}
	return e
}

// runQuery returns every document from one unpaged query. Stream entries without
// a document, such as a final readTime entry, are skipped
func (c *Client) runQuery(ctx context.Context, op string, token Secret, from, where map[string]any) ([]document, error) {
	structuredQuery := map[string]any{"from": []any{from}}
	if where != nil {
		structuredQuery["where"] = where
	}
	body, _ := json.Marshal(map[string]any{"structuredQuery": structuredQuery})
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodPost, url: c.firestore + "/v1/" + c.documentsPath() + ":runQuery",
		body: body, token: token, limit: firestoreLimit,
	})
	if err != nil {
		return nil, err
	}
	if resp.status != http.StatusOK {
		return nil, firestoreError(op, resp)
	}
	var entries []struct {
		Document *rawDocument     `json:"document"`
		Error    *firestoreStatus `json:"error"`
	}
	if json.Unmarshal(resp.body, &entries) != nil {
		return nil, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
	}
	documents := make([]document, 0, len(entries))
	for _, entry := range entries {
		if entry.Error != nil {
			return nil, firestoreStatusError(op, resp.status, entry.Error.Status)
		}
		if entry.Document == nil {
			continue
		}
		fields, err := decodeFields(entry.Document.Fields)
		if err != nil {
			return nil, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
		}
		documents = append(documents, document{name: entry.Document.Name, fields: fields})
	}
	return documents, nil
}

// FetchInventory reads enabled regions and the account's clients together, then
// joins them. Only a verified admin reads every owner's clients. Removed clients
// and documents with mismatched paths, owners, or statuses are dropped
func (c *Client) FetchInventory(ctx context.Context, uid string, role Role, tokens TokenSource) (Inventory, error) {
	if uid == "" || (role != RoleUser && role != RoleAdmin) {
		return Inventory{}, &Error{Op: "inventory", Kind: KindAccessDenied}
	}
	return readWithRefresh(ctx, tokens, func(token Secret) (Inventory, error) {
		var regionDocs, clientDocs []document
		var regionErr, clientErr error
		var wg sync.WaitGroup
		wg.Go(func() {
			regionDocs, regionErr = c.runQuery(ctx, "regions query", token,
				map[string]any{"collectionId": "Regions"},
				equalFilter("enabled", map[string]any{"booleanValue": true}))
		})
		wg.Go(func() {
			var where map[string]any
			if role != RoleAdmin {
				where = equalFilter("ownerUid", map[string]any{"stringValue": uid})
			}
			clientDocs, clientErr = c.runQuery(ctx, "clients query", token,
				map[string]any{"collectionId": "Instances", "allDescendants": true}, where)
		})
		wg.Wait()
		// A sibling transport failure must not hide a received denial or a 401 that needs a refresh
		for _, err := range []error{regionErr, clientErr} {
			if e, ok := errors.AsType[*Error](err); ok && e.Kind == KindAccessDenied {
				return Inventory{}, err
			}
		}
		if regionErr != nil {
			return Inventory{}, regionErr
		}
		if clientErr != nil {
			return Inventory{}, clientErr
		}
		var inventory Inventory
		for _, doc := range regionDocs {
			if region, ok := c.region(doc); ok {
				inventory.Regions = append(inventory.Regions, region)
			}
		}
		var clients []ClientDoc
		for _, doc := range clientDocs {
			if client, ok := c.clientDoc(doc); ok && (role == RoleAdmin || client.OwnerUID == uid) {
				clients = append(clients, client)
			}
		}
		inventory.Options = JoinOptions(clients, inventory.Regions)
		return inventory, nil
	})
}

func (c *Client) region(doc document) (Region, bool) {
	ids, ok := c.pathIDs(doc.name)
	if !ok || len(ids) != 2 || ids[0] != "Regions" {
		return Region{}, false
	}
	enabled, _ := doc.fields["enabled"].(bool)
	name := stringField(doc.fields, "displayName")
	if regionID, present := doc.fields["regionId"]; present && regionID != ids[1] {
		return Region{}, false
	}
	if !enabled || name == "" {
		return Region{}, false
	}
	return Region{RegionID: ids[1], DisplayName: name, Enabled: true, DisplayOrder: displayOrder(doc.fields["displayOrder"])}, true
}

func (c *Client) clientDoc(doc document) (ClientDoc, bool) {
	ids, ok := c.pathIDs(doc.name)
	if !ok || len(ids) != 4 || ids[0] != "Regions" || ids[2] != "Instances" {
		return ClientDoc{}, false
	}
	status := ClientStatus(stringField(doc.fields, "status"))
	clientID := cmp.Or(stringField(doc.fields, "clientId"), ids[3])
	regionID := cmp.Or(stringField(doc.fields, "regionId"), ids[1])
	if !status.valid() || clientID != ids[3] || regionID != ids[1] {
		return ClientDoc{}, false
	}
	config, _ := doc.fields["wireguardConfig"].(string)
	updatedAt, _ := doc.fields["updatedAt"].(time.Time)
	return ClientDoc{
		ClientID:               clientID,
		ClientName:             stringField(doc.fields, "clientName"),
		RegionID:               regionID,
		Status:                 status,
		WireGuardConfig:        Secret(config),
		AssignedTunnelIPv4:     stringField(doc.fields, "assignedTunnelIpv4"),
		ServerEndpointIPv4:     stringField(doc.fields, "serverEndpointIpv4"),
		ServerEndpointHostname: stringField(doc.fields, "serverEndpointHostname"),
		UpdatedAt:              updatedAt,
		OwnerUID:               stringField(doc.fields, "ownerUid"),
		OwnerEmail:             cmp.Or(stringField(doc.fields, "ownerEmail"), stringField(doc.fields, "email")),
	}, true
}

// stringField trims a string field and treats blank or non-string values as absent
func stringField(fields map[string]any, name string) string {
	value, _ := fields[name].(string)
	return strings.TrimSpace(value)
}

func equalFilter(field string, value map[string]any) map[string]any {
	return map[string]any{"fieldFilter": map[string]any{
		"field": map[string]any{"fieldPath": field}, "op": "EQUAL", "value": value,
	}}
}

func displayOrder(value any) int {
	switch v := value.(type) {
	case int64:
		if v >= math.MinInt32 && v <= math.MaxInt32 {
			return int(v)
		}
	case float64:
		if v >= math.MinInt32 && v <= math.MaxInt32 {
			return int(v)
		}
	}
	return defaultDisplayOrder
}
