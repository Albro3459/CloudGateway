package cloud

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"
)

type Role string

const (
	RoleUser  Role = "user"
	RoleAdmin Role = "admin"
)

type Access struct {
	UserID string
	// Email is empty when the account has none
	Email string
	Role  Role
}

type Capacity struct {
	Known     bool
	Limit     int
	Allocated int
}

// CreatedClient is the create reply. WireGuardConfig is private key material
type CreatedClient struct {
	ClientID               string
	RegionID               string
	ClientName             string
	Status                 ClientStatus
	AssignedTunnelIPv4     string
	AssignedTunnelIPv6     string
	ServerEndpointIPv4     string
	ServerEndpointHostname string
	WireGuardConfig        Secret
}

func apiErrorCode(body []byte) string {
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &envelope) != nil {
		return ""
	}
	return safeCode(envelope.Error.Code)
}

// Auth denial codes from Backend/API/src/errors.py. A 401/403 without one, such
// as an edge proxy page, is not a denial
var deniedCodes = map[string]bool{CodeAuthRequired: true, CodeAdminRequired: true, CodeUserNotProvisioned: true}

// apiError trusts only the API's own error envelope. AUTH_UNAVAILABLE stays
// unavailable because access is unconfirmed until a check succeeds
func apiError(op string, resp *response, write bool) *Error {
	e := &Error{Op: op, Kind: KindUnavailable, Status: resp.status, Code: apiErrorCode(resp.body), Dispatched: write}
	switch {
	case (resp.status == http.StatusUnauthorized || resp.status == http.StatusForbidden) && deniedCodes[e.Code]:
		e.Kind = KindAccessDenied
	case resp.status == http.StatusNotFound && e.Code == CodeClientNotFound:
		e.Kind = KindNotFound
	case resp.status == http.StatusTooManyRequests:
		e.Kind = KindThrottled
		e.RetryAfter, _ = parseRetryAfter(resp.header)
	case resp.status >= 400 && resp.status < 500 && resp.status != http.StatusUnauthorized &&
		resp.status != http.StatusForbidden && e.Code != "":
		e.Kind = KindRejected
	}
	return e
}

// CheckAccess confirms product access for uid. API auth denials deny access,
// transport failures are offline, and everything else is unavailable
func (c *Client) CheckAccess(ctx context.Context, uid string, tokens TokenSource) (Access, error) {
	const op = "check access"
	return readWithRefresh(ctx, tokens, func(token Secret) (Access, error) {
		resp, err := c.send(ctx, request{
			op: op, method: http.MethodPost, url: c.apiBase + "/api/auth/check-access",
			body: []byte("{}"), token: token, limit: apiBodyLimit,
		})
		if err != nil {
			return Access{}, err
		}
		if resp.status != http.StatusOK {
			e := apiError(op, resp, false)
			if e.Kind != KindAccessDenied {
				e.Kind = KindUnavailable
			}
			return Access{}, e
		}
		var result struct {
			UserID string  `json:"userId"`
			Email  *string `json:"email"`
			Role   Role    `json:"role"`
		}
		if json.Unmarshal(resp.body, &result) != nil || result.UserID != uid ||
			(result.Role != RoleUser && result.Role != RoleAdmin) {
			return Access{}, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
		}
		access := Access{UserID: result.UserID, Role: result.Role}
		if result.Email != nil {
			access.Email = *result.Email
		}
		return access, nil
	})
}

// ListRegions reads the public enabled-region list used for creation
func (c *Client) ListRegions(ctx context.Context) ([]Region, error) {
	const op = "list regions"
	resp, err := c.send(ctx, request{op: op, method: http.MethodGet, url: c.apiBase + "/api/regions", limit: apiBodyLimit})
	if err != nil {
		return nil, err
	}
	if resp.status != http.StatusOK {
		return nil, apiError(op, resp, false)
	}
	var result struct {
		Regions []struct {
			RegionID     string `json:"regionId"`
			DisplayName  string `json:"displayName"`
			DisplayOrder *int   `json:"displayOrder"`
		} `json:"regions"`
	}
	if json.Unmarshal(resp.body, &result) != nil || result.Regions == nil {
		return nil, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status}
	}
	regions := make([]Region, 0, len(result.Regions))
	for _, region := range result.Regions {
		if region.RegionID == "" || region.DisplayName == "" || region.DisplayOrder == nil {
			continue
		}
		regions = append(regions, Region{
			RegionID: region.RegionID, DisplayName: region.DisplayName, Enabled: true, DisplayOrder: *region.DisplayOrder,
		})
	}
	return regions, nil
}

// FetchCapacity mirrors macOS: access denial, cancellation, and token source
// errors fail, and every other failure or mismatched reply is unknown capacity
func (c *Client) FetchCapacity(ctx context.Context, regionID string, tokens TokenSource) (Capacity, error) {
	const op = "capacity"
	if !regionIDPattern.MatchString(regionID) {
		return Capacity{}, &Error{Op: op, Kind: KindRejected}
	}
	return readWithRefresh(ctx, tokens, func(token Secret) (Capacity, error) {
		resp, err := c.send(ctx, request{
			op: op, method: http.MethodGet, url: c.regionalBase(regionID) + "/api/capacity", token: token, limit: apiBodyLimit,
		})
		if err != nil {
			if KindOf(err) == KindCanceled {
				return Capacity{}, err
			}
			return Capacity{}, nil
		}
		if resp.status != http.StatusOK {
			if e := apiError(op, resp, false); e.Kind == KindAccessDenied {
				return Capacity{}, e
			}
			return Capacity{}, nil
		}
		var result struct {
			RegionID             string `json:"regionId"`
			CapacityLimit        *int   `json:"capacityLimit"`
			AllocatedClientCount *int   `json:"allocatedClientCount"`
		}
		if json.Unmarshal(resp.body, &result) != nil || result.RegionID != regionID ||
			result.CapacityLimit == nil || result.AllocatedClientCount == nil ||
			*result.CapacityLimit < 0 || *result.AllocatedClientCount < 0 {
			return Capacity{}, nil
		}
		return Capacity{Known: true, Limit: *result.CapacityLimit, Allocated: *result.AllocatedClientCount}, nil
	})
}

// CreateClient sends one create request and never retries. Every failure that
// may have reached the server has Dispatched set, so its outcome is unknown
// unless the error proves otherwise
func (c *Client) CreateClient(ctx context.Context, regionID, clientName string, idToken Secret) (CreatedClient, error) {
	const op = "create client"
	clientName = strings.TrimSpace(clientName)
	if !regionIDPattern.MatchString(regionID) || clientName == "" || utf8.RuneCountInString(clientName) > 80 {
		return CreatedClient{}, &Error{Op: op, Kind: KindRejected, Code: CodeInvalidRequest}
	}
	body, _ := json.Marshal(struct {
		RegionID   string `json:"regionId"`
		ClientName string `json:"clientName"`
	}{regionID, clientName})
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodPost, url: c.regionalBase(regionID) + "/api/clients",
		body: body, token: idToken, limit: apiBodyLimit, write: true,
	})
	if err != nil {
		return CreatedClient{}, err
	}
	if resp.status != http.StatusOK {
		return CreatedClient{}, apiError(op, resp, true)
	}
	var result struct {
		ClientID               string       `json:"clientId"`
		RegionID               string       `json:"regionId"`
		ClientName             string       `json:"clientName"`
		Status                 ClientStatus `json:"status"`
		AssignedTunnelIPv4     string       `json:"assignedTunnelIpv4"`
		AssignedTunnelIPv6     string       `json:"assignedTunnelIpv6"`
		ServerEndpointIPv4     string       `json:"serverEndpointIpv4"`
		ServerEndpointHostname string       `json:"serverEndpointHostname"`
		WireGuardConfig        string       `json:"wireguardConfig"`
	}
	if json.Unmarshal(resp.body, &result) != nil || !clientIDPattern.MatchString(result.ClientID) ||
		result.RegionID != regionID || !result.Status.valid() || strings.TrimSpace(result.WireGuardConfig) == "" {
		return CreatedClient{}, &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status, Dispatched: true}
	}
	return CreatedClient{
		ClientID:               result.ClientID,
		RegionID:               result.RegionID,
		ClientName:             result.ClientName,
		Status:                 result.Status,
		AssignedTunnelIPv4:     result.AssignedTunnelIPv4,
		AssignedTunnelIPv6:     result.AssignedTunnelIPv6,
		ServerEndpointIPv4:     result.ServerEndpointIPv4,
		ServerEndpointHostname: result.ServerEndpointHostname,
		WireGuardConfig:        Secret(result.WireGuardConfig),
	}, nil
}

// DeleteClient removes ownerUID's client once, without account cleanup. A nil
// error means the server confirmed the removed status for the exact target
func (c *Client) DeleteClient(ctx context.Context, regionID, clientID, ownerUID string, idToken Secret) error {
	const op = "delete client"
	if !regionIDPattern.MatchString(regionID) || !clientIDPattern.MatchString(clientID) || ownerUID == "" {
		return &Error{Op: op, Kind: KindRejected, Code: CodeInvalidRequest}
	}
	body, _ := json.Marshal(struct {
		UserID   string `json:"userId"`
		RegionID string `json:"regionId"`
	}{ownerUID, regionID})
	resp, err := c.send(ctx, request{
		op: op, method: http.MethodDelete, url: c.regionalBase(regionID) + "/api/clients/" + clientID,
		body: body, token: idToken, limit: apiBodyLimit, write: true,
	})
	if err != nil {
		return err
	}
	if resp.status != http.StatusOK {
		return apiError(op, resp, true)
	}
	var result struct {
		UserID   string       `json:"userId"`
		ClientID string       `json:"clientId"`
		RegionID string       `json:"regionId"`
		Status   ClientStatus `json:"status"`
	}
	if json.Unmarshal(resp.body, &result) != nil || result.UserID != ownerUID || result.ClientID != clientID ||
		result.RegionID != regionID || result.Status != StatusRemoved {
		return &Error{Op: op, Kind: KindInvalidResponse, Status: resp.status, Dispatched: true}
	}
	return nil
}
