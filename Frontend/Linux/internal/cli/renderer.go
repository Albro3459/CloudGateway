package cli

import (
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/jsonout"
)

type renderer struct{ isStyled bool }

type row struct{ label, value string }

func (r renderer) render(d data) string {
	var lines []string
	switch d := d.(type) {
	case helpData:
		lines = r.help(d)
	case versionData:
		lines = []string{"CloudGateway " + d.version + " (" + d.build + ")"}
	case authStatus:
		lines = table(authRows(d))
	case modeStatus:
		lines = table(modeRows(d))
	case status:
		lines = r.status(d, true)
	case inventory:
		lines = r.inventory(d)
	case mutation:
		lines = append([]string{mutationSummary(d)},
			r.status(status{tunnel: d.tunnel, operation: &d.operation, update: d.update, mode: d.mode}, false)...)
		if d.choices != nil {
			lines = append(append(lines, "", "Available configs:"), r.inventory(*d.choices)...)
		}
	case refreshData:
		lines = []string{"Inventory refresh: " + label(string(d.result))}
		if d.inventory != nil {
			lines = append(append(lines, ""), r.inventory(*d.inventory)...)
		}
	case doctorReport:
		var b strings.Builder
		for _, check := range d.checks {
			b.WriteString("[" + string(check.status) + "] " + check.name + ": " + check.evidence + "\n")
			if check.suggestion != nil {
				b.WriteString("  " + *check.suggestion + "\n")
			}
		}
		return b.String()
	}
	var b strings.Builder
	for _, line := range lines {
		b.WriteString(line + "\n")
	}
	return b.String()
}

func (r renderer) renderError(e *cliError) string {
	if e.code == codeNetworkUnavailable {
		return "Waiting for network… Try again soon.\n"
	}
	text := "Error: " + sanitize(e.message) + "\n"
	if e.suggestion != nil {
		text += *e.suggestion + "\n"
	}
	return text
}

func mutationSummary(m mutation) string {
	switch {
	case m.operation.result == "start_requested":
		return "VPN start requested"
	case m.operation.result == "already_active":
		return "VPN already active"
	case m.operation.result == "completed":
		switch m.command {
		case "down":
			return "VPN stopped"
		case "logout":
			return "Signed out (VPN retained)"
		case "add":
			if m.creation != nil {
				return "Client created: " + m.creation.name + " (" + m.creation.regionID + ")"
			}
			return "Client created"
		case "update":
			return "CloudGateway update completed"
		case "remove":
			return "Client removed"
		case "mode":
			if m.requestedMode != "" {
				return "Routing mode selected: " + string(m.requestedMode)
			}
			return "Routing mode selected"
		}
	}
	if m.command == "update" {
		return "CloudGateway update " + m.operation.state
	}
	return "Command " + m.operation.state
}

func (r renderer) help(h helpData) []string {
	lines := []string{h.summary, "", "Usage: " + h.usage}
	section := func(title string, rows []row) {
		if len(rows) == 0 {
			return
		}
		width := 0
		for _, row := range rows {
			width = max(width, utf8.RuneCountInString(row.label))
		}
		lines = append(lines, "", r.bold(title)+":")
		for _, row := range rows {
			lines = append(lines, "  "+pad(row.label, width)+"  "+row.value)
		}
	}
	options := func(values []option) []row {
		var rows []row
		for _, o := range values {
			flags := strings.Join(o.flags(), ", ")
			if o.valueName() != "" {
				flags += " <" + o.valueName() + ">"
			}
			rows = append(rows, row{flags, o.summary()})
		}
		return rows
	}
	var commands []row
	for _, c := range h.commands {
		name := c.name
		if c.arguments != "" {
			name += " " + c.arguments
		}
		commands = append(commands, row{name, c.summary})
	}
	section("Commands", commands)
	section("Options", options(h.options))
	section("Common options", options(h.commonOptions))
	for _, block := range []struct {
		title string
		items []string
	}{{"Notes", h.notes}, {"Examples", h.examples}} {
		if len(block.items) > 0 {
			lines = append(lines, "", r.bold(block.title)+":")
			for _, item := range block.items {
				lines = append(lines, "  "+item)
			}
		}
	}
	return lines
}

func authRows(a authStatus) []row {
	summary := map[string]string{
		"signed_out": "Signed out",
		"retained":   "Session retained, access not verified",
		"restoring":  "Restoring session (pending)",
		"online":     "Signed in (online)",
		"offline":    "Signed in (offline, using cached authorization)",
		"denied":     "Access denied",
	}[a.state]
	account := "none"
	if a.accountID != nil {
		account = *a.accountID
	}
	rows := []row{{"Auth", summary}, {"Account", account}, {"Access", a.access}, {"Credentials", a.credentials}}
	if a.loginPending {
		rows = append(rows, row{"Login", "in progress"})
	}
	return rows
}

func modeRows(m modeStatus) []row {
	active := m.activeMode
	if active == "" {
		active = "unknown"
		if m.tunnelState == "disconnected" && m.observation == "current" {
			active = "none"
		}
	}
	selected := m.selectedMode
	if selected == "" {
		selected = "unavailable"
	}
	return []row{{"Selected mode", selected}, {"Active mode", active},
		{"Mode observation", observationLabel(m.observation, m.observedAt)}}
}

var updatePhaseLabels = map[string]string{
	"prepared":           "prepared, awaiting execution confirmation",
	"stopping":           "stopping the captured VPN and waiting for confirmed stop",
	"activating":         "restarting the daemon onto the installed release",
	"approval_required":  "macOS approval required (operation still running)",
	"restart_required":   "Mac restart required (operation still running)",
	"checking_readiness": "checking daemon readiness",
	"reconnecting":       "requesting a start of the captured config",
	"completed":          "completed",
	"failed":             "failed",
	"superseded":         "superseded by a changed installed release",
}

func (r renderer) status(s status, includesSession bool) []string {
	t := s.tunnel
	rows := []row{{"VPN", t.state}, {"Observation", observationLabel(t.observation, t.observedAt)}}
	if t.configID != nil {
		rows = append(rows, row{"Config", *t.configID})
	}
	// Linux only: a connected server that stopped answering often moved to a new IP
	if t.state == "connected" && s.serverResponding != nil && !*s.serverResponding {
		rows = append(rows, row{"Server", "not responding. Run: cloudgateway refresh"})
	}
	if op := s.operation; op != nil {
		detail := op.id + " " + op.state
		if op.result != "" {
			detail += ", " + label(op.result)
		}
		if op.configID != nil {
			detail += " for " + *op.configID
		}
		if op.warning != "" {
			message := label(op.warning)
			if op.warning == "reconnect_suppression_not_persisted" {
				message = "Reconnect suppression cannot be guaranteed after daemon restart because it could not be saved"
			}
			detail += " (" + message + ")"
		}
		rows = append(rows, row{"Operation", detail})
		if op.failure != nil {
			rows = append(rows, row{"Result", sanitize(op.failure.message)})
		}
	} else {
		rows = append(rows, row{"Operation", "none retained"})
	}
	if u := s.update; u != nil {
		rows = append(rows, row{"Update", u.id + " " + updatePhaseLabels[u.phase]},
			row{"Target", u.version + " (" + u.build + ")"})
		if u.configID != "" {
			rows = append(rows, row{"Update config", u.configID})
		}
		switch {
		case u.reconnect && u.phase == "completed":
			rows = append(rows, row{"Reconnect", "start submitted or same config already active. See observed VPN state above"})
		case u.reconnect:
			rows = append(rows, row{"Reconnect", "captured config, subject to readiness and current authorization"})
		default:
			rows = append(rows, row{"Reconnect", "disabled"})
		}
		if u.err != nil {
			rows = append(rows, row{"Update error", sanitize(u.err.message)})
		}
		if u.warning != nil {
			rows = append(rows, row{"Update warning", sanitize(u.warning.message)})
		}
	}
	lines := table(rows)
	if s.mode != nil {
		lines = append(lines, table(modeRows(*s.mode))...)
	} else if includesSession {
		lines = append(lines, table([]row{{"Mode", "unavailable"}})...)
	}
	if includesSession {
		if s.auth != nil {
			lines = append(lines, table(authRows(*s.auth))...)
		} else {
			lines = append(lines, table([]row{{"Auth", "unavailable"}})...)
		}
	}
	return lines
}

func (r renderer) inventory(inv inventory) []string {
	var lines []string
	if len(inv.regions) == 0 {
		if inv.regionID != "" {
			lines = append(lines, "No configs in region "+inv.regionID)
		} else {
			lines = append(lines, "No configs")
		}
	}
	stale := inv.profileObservation == "stale"
	for _, reg := range inv.regions {
		if len(lines) > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, r.bold(reg.name+" ("+reg.regionID+")"))
		names := make([]string, len(reg.configs))
		nameWidth, idWidth, indexWidth := 0, 0, 0
		for i, c := range reg.configs {
			names[i] = c.name
			if c.owner != nil {
				names[i] = c.name + " (" + *c.owner + ")"
			}
			nameWidth = max(nameWidth, utf8.RuneCountInString(names[i]))
			idWidth = max(idWidth, utf8.RuneCountInString(c.clientID))
			indexWidth = max(indexWidth, len(strconv.Itoa(c.index)))
		}
		for i, c := range reg.configs {
			var labels []string
			if c.tunnel != "" && (c.tunnel != "disconnected" || stale) {
				tunnelLabel := c.tunnel
				if stale {
					tunnelLabel += " (stale)"
				}
				labels = append(labels, tunnelLabel)
			}
			if c.cloudState != "active" {
				labels = append(labels, c.cloudState)
			}
			if c.eligibility != "eligible" {
				labels = append(labels, label(c.eligibility))
			}
			if c.selected {
				labels = append(labels, "selected")
			}
			prefix := "  " + pad(strconv.Itoa(c.index), indexWidth)
			if inv.isLong {
				line := prefix + "  " + c.name
				if len(labels) > 0 {
					line += "  " + strings.Join(labels, ", ")
				}
				lines = append(lines, line)
				var ip *string
				if c.internalIP != nil {
					if parts := strings.FieldsFunc(*c.internalIP, func(r rune) bool { return r == '/' }); len(parts) > 0 {
						ip = &parts[0]
					}
				}
				details := []row{{"VPN id", c.clientID}, {"Tunnel IP", orDefault(ip, "Unavailable")},
					{"Connection URL", orDefault(c.connectionURL, "Unavailable")}, {"Owner email", orDefault(c.owner, "Unknown")}}
				for _, detail := range table(details) {
					lines = append(lines, "     "+detail)
				}
			} else {
				columns := []string{prefix, pad(names[i], nameWidth), pad(c.clientID, idWidth)}
				if len(labels) > 0 {
					columns = append(columns, strings.Join(labels, ", "))
				}
				lines = append(lines, strings.Join(columns, "  "))
			}
		}
	}
	lines = append(lines, "", "Tunnel observation: "+observationLabel(inv.profileObservation, inv.profilesObservedAt))
	if inv.scope == "installed" {
		lines = append(lines, "Offline: showing this account's saved configs from cached authorization")
	} else {
		lines = append(lines, "Inventory: "+inv.freshness)
	}
	return lines
}

func table(rows []row) []string {
	width := 0
	for _, row := range rows {
		width = max(width, utf8.RuneCountInString(row.label))
	}
	lines := make([]string, len(rows))
	for i, row := range rows {
		lines[i] = pad(row.label+":", width+1) + "  " + row.value
	}
	return lines
}

func pad(text string, width int) string {
	return text + strings.Repeat(" ", max(0, width-utf8.RuneCountInString(text)))
}

func orDefault(value *string, fallback string) string {
	if value == nil {
		return fallback
	}
	return *value
}

func (r renderer) bold(text string) string {
	if r.isStyled {
		return "\x1b[1m" + text + "\x1b[0m"
	}
	return text
}

func label(value string) string { return strings.ReplaceAll(value, "_", " ") }

func observationLabel(observation string, observedAt *time.Time) string {
	observed := ""
	if observedAt != nil {
		observed = " at " + observedAt.UTC().Format(jsonout.DateFormat)
	}
	switch observation {
	case "current":
		return "current" + observed
	case "stale":
		return "stale, last observed" + observed
	}
	return "unavailable"
}
