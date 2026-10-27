package cli

import (
	"strconv"
	"strings"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

type regionRow struct{ id, name string }

func inventoryRegionRows(regions [][]ipc.Client) []regionRow {
	rows := make([]regionRow, 0, len(regions))
	for _, clients := range regions {
		rows = append(rows, regionRow{clients[0].RegionID, clients[0].RegionName})
	}
	return rows
}

// resolveRegion prefers an exact case-sensitive ID, then a trimmed lowercase display name or city alias
func resolveRegion(value string, rows []regionRow, scope string) (string, error) {
	for _, row := range rows {
		if row.id == value {
			return row.id, nil
		}
	}
	normalized := strings.ToLower(strings.TrimSpace(value))
	var matches []regionRow
	for _, row := range rows {
		components := strings.FieldsFunc(row.id, func(r rune) bool { return r == '-' })
		city := ""
		if len(components) >= 3 {
			city = strings.Join(components[1:len(components)-1], "-")
		}
		if strings.ToLower(strings.TrimSpace(row.name)) == normalized || (city != "" && strings.ToLower(city) == normalized) {
			matches = append(matches, row)
		}
	}
	if len(matches) == 1 {
		return matches[0].id, nil
	}
	candidates := matches
	if len(matches) == 0 {
		candidates = rows
	}
	labels := make([]string, 0, len(candidates))
	for _, row := range candidates {
		labels = append(labels, sanitize(row.id)+" ("+sanitize(row.name)+")")
	}
	available := strings.Join(labels, ", ")
	if available == "" {
		available = "none"
	}
	message := "Region '" + sanitize(value) + "' is unavailable in " + scope
	if len(matches) > 0 {
		message = "Region '" + sanitize(value) + "' is ambiguous. Use a full region ID"
	}
	return "", newError(codeUsage, message, "Available regions: "+available)
}

func resolveInventoryRegion(value string, s ipc.State, accountID string) (string, error) {
	return resolveRegion(value, inventoryRegionRows(orderedRegions(s, accountID)), "this account's current inventory")
}

// resolveSelector maps a selector to the compound config ID once, from settled inventory
func resolveSelector(sel selector, s ipc.State, accountID string) (string, error) {
	regions := orderedRegions(s, accountID)
	if sel.clientID != "" {
		var matches []string
		for _, clients := range regions {
			for _, client := range clients {
				if id, ok := parseUUID(client.ClientID); ok && id == sel.clientID {
					matches = append(matches, client.Identifier)
				}
			}
		}
		switch len(matches) {
		case 1:
			return matches[0], nil
		case 0:
			return "", newError(codeConfigUnavailable,
				"Client UUID '"+sel.clientID+"' is unavailable in this account's current inventory", "")
		}
		return "", newError(codeConfigUnavailable,
			"Client UUID '"+sel.clientID+"' is ambiguous. Use a region and index from `cloudgateway ls`", "")
	}
	regionID, err := resolveRegion(sel.region, inventoryRegionRows(regions), "this account's current inventory")
	if err != nil {
		return "", err
	}
	var clients []ipc.Client
	for _, group := range regions {
		if group[0].RegionID == regionID {
			clients = group
		}
	}
	if sel.index <= 0 || sel.index > len(clients) {
		return "", newError(codeUsage, "Index "+strconv.Itoa(sel.index)+" is out of range for "+regionID,
			"Use an index from 1 to "+strconv.Itoa(len(clients))+". Run: cloudgateway ls")
	}
	return clients[sel.index-1].Identifier, nil
}
