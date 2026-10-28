package cloud

import (
	"strings"
	"time"
)

const defaultDisplayOrder = 1000

type ClientStatus string

const (
	StatusCreating ClientStatus = "creating"
	StatusActive   ClientStatus = "active"
	StatusFailed   ClientStatus = "failed"
	StatusRemoved  ClientStatus = "removed"
)

func (s ClientStatus) valid() bool {
	switch s {
	case StatusCreating, StatusActive, StatusFailed, StatusRemoved:
		return true
	}
	return false
}

type Region struct {
	RegionID     string
	DisplayName  string
	Enabled      bool
	DisplayOrder int
}

// ClientDoc mirrors CloudGatewayClient. WireGuardConfig is empty when the document has none
type ClientDoc struct {
	ClientID               string
	ClientName             string
	RegionID               string
	Status                 ClientStatus
	WireGuardConfig        Secret
	AssignedTunnelIPv4     string
	ServerEndpointIPv4     string
	ServerEndpointHostname string
	UpdatedAt              time.Time
	OwnerUID               string
	OwnerEmail             string
}

func (c ClientDoc) DisplayName() string {
	if c.ClientName == "" {
		return c.ClientID
	}
	return c.ClientName
}

func (c ClientDoc) HasUsableConfig() bool {
	return c.Status == StatusActive && strings.TrimSpace(string(c.WireGuardConfig)) != ""
}

// Option mirrors CloudGatewayClientOption. Region is nil when the client's region is not enabled
type Option struct {
	Client ClientDoc
	Region *Region
}

func (o Option) RegionDisplayName() string {
	if o.Region == nil {
		return o.Client.RegionID
	}
	return o.Region.DisplayName
}

func (o Option) DisplayOrder() int {
	if o.Region == nil {
		return defaultDisplayOrder
	}
	return o.Region.DisplayOrder
}

func (o Option) RegionEnabled() bool { return o.Region != nil && o.Region.Enabled }

type Inventory struct {
	Regions []Region
	Options []Option
}

// JoinOptions pairs clients with their regions and drops removed clients, in client order
func JoinOptions(clients []ClientDoc, regions []Region) []Option {
	regionsByID := make(map[string]*Region, len(regions))
	for i := range regions {
		regionsByID[regions[i].RegionID] = &regions[i]
	}
	options := make([]Option, 0, len(clients))
	for _, client := range clients {
		if client.Status == StatusRemoved {
			continue
		}
		options = append(options, Option{Client: client, Region: regionsByID[client.RegionID]})
	}
	return options
}
