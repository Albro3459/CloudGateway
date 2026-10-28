package cli

import (
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

type option int

const fullModeNotice = "Full mode is experimental on Linux. DHCP-provided DNS search domains may prevent connection. Run: cloudgateway doctor. To return to Mesh, use: cloudgateway mode mesh"

const (
	optHelp option = iota
	optJSON
	optNonInteractive
	optTimeout
	optVersion
	optNoQR
	optRegion
	optRefresh
	optOperation
	optLong
	optAllowDisconnect
	optYes
)

var allOptions = []option{optHelp, optJSON, optNonInteractive, optTimeout, optVersion, optNoQR,
	optRegion, optRefresh, optOperation, optLong, optAllowDisconnect, optYes}

var commonOptions = []option{optHelp, optJSON, optNonInteractive, optTimeout}

func (o option) flags() []string {
	switch o {
	case optHelp:
		return []string{"-h", "--help"}
	case optJSON:
		return []string{"--json"}
	case optNonInteractive:
		return []string{"--non-interactive"}
	case optTimeout:
		return []string{"--timeout"}
	case optVersion:
		return []string{"-v", "--version"}
	case optNoQR:
		return []string{"--no-qr"}
	case optRegion:
		return []string{"--region"}
	case optRefresh:
		return []string{"--refresh"}
	case optOperation:
		return []string{"--operation"}
	case optLong:
		return []string{"-l", "--long"}
	case optAllowDisconnect:
		return []string{"--allow-disconnect"}
	}
	return []string{"--yes"}
}

func (o option) lastFlag() string {
	flags := o.flags()
	return flags[len(flags)-1]
}

// valueName is "" for boolean flags
func (o option) valueName() string {
	switch o {
	case optTimeout:
		return "seconds"
	case optRegion:
		return "region"
	case optOperation:
		return "operation-id"
	}
	return ""
}

func (o option) summary() string {
	switch o {
	case optHelp:
		return "Show help for the current command"
	case optJSON:
		return "Print versioned JSON records, one per line, without decoration or shortcuts"
	case optNonInteractive:
		return "Disable keyboard shortcuts and prompts, even in a terminal"
	case optTimeout:
		return "Stop waiting after this many seconds (default 30). Confirmed VPN work keeps running"
	case optVersion:
		return "Show the CloudGateway version and build"
	case optNoQR:
		return "Hide the QR code. The approval link and code still print"
	case optRegion:
		return "Show only configs in this region"
	case optRefresh:
		return "Fetch current inventory before listing"
	case optOperation:
		return "Look up a retained operation by ID"
	case optLong:
		return "Show VPN details for each config"
	case optAllowDisconnect:
		return "Accepted for compatibility. Linux updates keep the VPN connected"
	}
	return "Required: acknowledge permanent cloud client deletion"
}

type topicKind int

const (
	kindRoot topicKind = iota
	kindAuth
	kindAuthLogin
	kindAuthStatus
	kindAuthLogout
	kindMode
	kindModeStatus
	kindModeFull
	kindModeMesh
	kindList
	kindStatus
	kindUp
	kindDown
	kindAdd
	kindRemove
	kindUpdate
	kindRefresh
	kindDoctor
	kindVersion
	kindHelp
)

type topic struct {
	kind      topicKind
	path      []string
	arguments string
	options   []option
	summary   string
	notes     []string
	examples  []string
}

func (t topic) name() string { return strings.Join(t.path, " ") }

func (t topic) usage() string {
	words := append([]string{"cloudgateway"}, t.path...)
	if t.arguments != "" {
		words = append(words, t.arguments)
	}
	if t.kind == kindRoot || t.kind == kindAuth {
		return strings.Join(append(words, "<command>", "[options]"), " ")
	}
	for _, o := range t.options {
		if o == optYes {
			words = append(words, "--yes")
		} else if o.valueName() != "" {
			words = append(words, "["+o.lastFlag()+" <"+o.valueName()+">]")
		} else {
			words = append(words, "["+o.lastFlag()+"]")
		}
	}
	return strings.Join(append(words, "[options]"), " ")
}

func (t topic) subtopics() []topic {
	var result []topic
	for _, other := range topics {
		switch t.kind {
		case kindRoot:
			if len(other.path) > 0 && other.kind != kindAuth {
				result = append(result, other)
			}
		case kindAuth, kindMode:
			if len(other.path) == 2 && other.path[0] == t.path[0] {
				result = append(result, other)
			}
		}
	}
	return result
}

var topics = []topic{
	{kind: kindRoot, options: []option{optVersion},
		summary: "Control the CloudGateway VPN on this machine",
		notes: []string{
			"Linux defaults to Mesh. Full mode is experimental and may require cloud-provider DNS configuration",
			"Use a client UUID or a region and row index to select a config. `ls` is an alias of `list`",
			"Request acceptance reserves work. `up` succeeds after start submission or if already active. " +
				"`down` succeeds only after a confirmed stop. Check `status` for the observed tunnel state",
			"Exit codes: 0 success, 1 internal failure, 2 usage, 3 sign-in or access denied, 4 setup, permissions, or version, " +
				"5 config or selection, 6 network or service, 7 busy, 8 deadline, 9 VPN operation failed, " +
				"10 operation result unknown, 130 interrupted",
		},
		examples: []string{"cloudgateway auth status", "cloudgateway list --json", "cloudgateway help up"}},
	{kind: kindAuth, path: []string{"auth"},
		summary:  "Sign in, check, or sign out of the shared CloudGateway session",
		examples: []string{"cloudgateway auth status"}},
	{kind: kindAuthLogin, path: []string{"auth", "login"}, options: []option{optNoQR},
		summary:  "Sign in with device approval on any browser",
		notes:    []string{"The approval link and code print right away. Approve on this machine or another device"},
		examples: []string{"cloudgateway auth login", "cloudgateway auth login --no-qr"}},
	{kind: kindAuthStatus, path: []string{"auth", "status"},
		summary:  "Show sign-in, access verification, and credential state",
		notes:    []string{"A retained identity does not mean access is currently verified"},
		examples: []string{"cloudgateway auth status --json"}},
	{kind: kindAuthLogout, path: []string{"auth", "logout"},
		summary:  "Sign out, keeping the running VPN and saved configs",
		notes:    []string{"Logout does not disconnect. Run `cloudgateway down` to stop the VPN"},
		examples: []string{"cloudgateway auth logout"}},
	{kind: kindMode, path: []string{"mode"}, arguments: "[status | full | mesh]",
		summary: "Show or change this account's routing mode on this machine",
		notes: []string{"Without a subcommand, shows the selected and observed active mode",
			"Mesh is the default on Linux. The selected mode is saved per account",
			"Changing mode while connected restarts the same client. Confirmed work continues after timeout or interruption",
			"After acceptance, use status --operation to check an uncertain result before retrying"},
		examples: []string{"cloudgateway mode", "cloudgateway mode mesh", "cloudgateway mode full"}},
	{kind: kindModeStatus, path: []string{"mode", "status"},
		summary:  "Show the selected preference and observed active routing mode",
		notes:    []string{"A saved preference does not prove the running tunnel applied it"},
		examples: []string{"cloudgateway mode status --json"}},
	{kind: kindModeFull, path: []string{"mode", "full"},
		summary:  "Route internet and mesh traffic through the VPN (experimental on Linux)",
		notes:    []string{"Saves the preference while disconnected. Restarts the same client while connected", fullModeNotice},
		examples: []string{"cloudgateway mode full"}},
	{kind: kindModeMesh, path: []string{"mode", "mesh"},
		summary:  "Route only CloudGateway mesh traffic through the VPN",
		notes:    []string{"Saves the preference while disconnected. Restarts the same client while connected"},
		examples: []string{"cloudgateway mode mesh"}},
	{kind: kindList, path: []string{"list"}, options: []option{optRegion, optRefresh, optLong},
		summary: "Show authorized configs grouped by region",
		notes: []string{"Waits for stale daemon inventory to refresh",
			"Offline, only this account's saved configs are listed",
			"Regions accept a full ID, display name, or city alias such as sanjose",
			"Indices restart at 1 in each region. Rerun `ls` after inventory changes. Use a UUID in scripts"},
		examples: []string{"cloudgateway ls", "cloudgateway ls -l", "cloudgateway list --region sanjose --json"}},
	{kind: kindStatus, path: []string{"status"}, options: []option{optOperation},
		summary:  "Show the observed VPN state, routing mode, auth, active update, and latest command result",
		notes:    []string{"A successful status read does not mean the VPN is connected"},
		examples: []string{"cloudgateway status", "cloudgateway status --operation <operation-id>"}},
	{kind: kindUp, path: []string{"up"}, arguments: "[<client-uuid> | <region> <index>]",
		summary: "Request a VPN start for an authorized config",
		notes: []string{
			"Without a selector, `up` uses this account's last selection",
			"Regions accept a full ID, display name, or city alias. Quote names containing spaces",
			"Success means the daemon accepted the start request, not that the tunnel connected",
		},
		examples: []string{"cloudgateway up", "cloudgateway up <client-uuid>", "cloudgateway up chicago 1"}},
	{kind: kindDown, path: []string{"down"}, arguments: "[<client-uuid> | <region> <index>]",
		summary:  "Stop the CloudGateway VPN, even while signed out",
		notes:    []string{"Saved configs stay on this machine", "A selector stops only that config and requires sign-in"},
		examples: []string{"cloudgateway down", "cloudgateway down chicago 1"}},
	{kind: kindAdd, path: []string{"add"}, arguments: "<region> <name>",
		summary: "Create a named client without connecting the VPN",
		notes: []string{
			"The client name is required, with at most 80 characters. Quote names containing spaces",
			"Regions accept a full ID, display name, or city alias such as sanjose",
			"Uses enabled regions with available capacity, including regions where you have no clients",
			"Creation leaves the VPN unchanged. Run `cloudgateway ls` to find the new client UUID",
			"After acceptance, check the operation before retrying an uncertain result to avoid duplicates",
		},
		examples: []string{`cloudgateway add sanjose "Build server"`, `cloudgateway add us-sanjose-1 "Work VM" --json`}},
	{kind: kindRemove, path: []string{"remove"}, arguments: "<client-uuid> | <region> <index>", options: []option{optYes},
		summary: "Permanently remove a cloud client and its inactive local VPN profile",
		notes: []string{
			"An explicit selector and --yes are required. No last selection or terminal prompt is used",
			"Regions accept a full ID, display name, or city alias. Rerun `ls` before using a region index. Use UUIDs in scripts",
			"Disabled, configless, and never-installed clients can be removed. Online authorization is required",
			"An active client must be disconnected first. Removal does not disconnect a VPN or delete retained secrets",
			"The accepted ID prints before execution is confirmed. Output failure leaves the reservation unconfirmed",
			"After confirmation, timeout, Ctrl-C, or SSH loss detaches observation while daemon work can continue",
			"Check uncertain results with status --operation. If still unknown, refresh online inventory and inspect the original client UUID before another manual removal attempt",
		},
		examples: []string{"cloudgateway remove <client-uuid> --yes", "cloudgateway remove chicago 1 --yes",
			"cloudgateway remove <client-uuid> --yes --json --non-interactive",
			"cloudgateway status --operation <operation-id>"}},
	{kind: kindUpdate, path: []string{"update"}, options: []option{optAllowDisconnect},
		summary: "Activate the CloudGateway release installed on this machine",
		notes: []string{
			"Restarts the daemon onto the installed release. Does not download or install a release",
			"A matching release succeeds without a restart. The VPN stays connected while the daemon restarts",
			"--allow-disconnect is accepted for compatibility and has no effect",
			"The accepted ID prints before execution is confirmed. Output failure before confirmation leaves work unconfirmed",
			"Waits up to 300 seconds by default. After confirmation, timeout, Ctrl-C, or SSH loss detaches observation. The daemon keeps running the update",
			"Use status --operation to follow an accepted update, including across the daemon restart",
		},
		examples: []string{"cloudgateway update", "cloudgateway update --json",
			"ssh my-server cloudgateway update",
			"cloudgateway status --operation <operation-id>"}},
	{kind: kindRefresh, path: []string{"refresh"},
		summary:  "Recheck access and fetch current inventory without reconnecting",
		examples: []string{"cloudgateway refresh"}},
	{kind: kindDoctor, path: []string{"doctor"},
		summary:  "Inspect setup, permissions, auth, and service reachability",
		examples: []string{"cloudgateway doctor --json"}},
	{kind: kindVersion, path: []string{"version"},
		summary:  "Show the CloudGateway version and build",
		notes:    []string{"Aliases: --version, -v. Completes locally without connecting to the daemon"},
		examples: []string{"cloudgateway version", "cloudgateway -v --json"}},
	{kind: kindHelp, path: []string{"help"}, arguments: "[command...]",
		summary:  "Show help for a command",
		examples: []string{"cloudgateway help auth login"}},
}

type commandKind int

const (
	cmdAuthLogin commandKind = iota
	cmdAuthStatus
	cmdAuthLogout
	cmdModeStatus
	cmdSetMode
	cmdList
	cmdStatus
	cmdUp
	cmdDown
	cmdDownTarget
	cmdAdd
	cmdRemove
	cmdUpdate
	cmdRefresh
	cmdDoctor
)

// selector names a config by client UUID, or by region and 1-based index
type selector struct {
	clientID string
	region   string
	index    int
}

type command struct {
	kind            commandKind
	showsQR         bool
	mode            ipc.Mode
	regionID        string
	refresh         bool
	long            bool
	operationID     string
	selector        *selector
	addRegion       string
	addName         string
	allowDisconnect bool
}

func (c command) name() string {
	switch c.kind {
	case cmdAuthLogin:
		return "auth login"
	case cmdAuthStatus:
		return "auth status"
	case cmdAuthLogout:
		return "auth logout"
	case cmdModeStatus:
		return "mode status"
	case cmdSetMode:
		return "mode " + string(c.mode)
	case cmdList:
		return "list"
	case cmdStatus:
		return "status"
	case cmdUp:
		return "up"
	case cmdDown, cmdDownTarget:
		return "down"
	case cmdAdd:
		return "add"
	case cmdRemove:
		return "remove"
	case cmdUpdate:
		return "update"
	case cmdRefresh:
		return "refresh"
	}
	return "doctor"
}

type actionKind int

const (
	actionRun actionKind = iota
	actionHelp
	actionVersion
)

type invocation struct {
	action           actionKind
	topic            topic
	command          command
	isJSON           bool
	isNonInteractive bool
	// timeout is 0 for the command's own default, since login waits for the server's code expiry
	timeout time.Duration
}

type usageFailure struct {
	message string
	command string
}

const maximumTimeout = 86_400.0

func parse(arguments []string) (invocation, *usageFailure) {
	named := namedWords(arguments)
	var words []string
	flags := map[option]bool{}
	values := map[option]string{}
	for i := 0; i < len(arguments); i++ {
		token := arguments[i]
		if len(token) <= 1 || !strings.HasPrefix(token, "-") {
			words = append(words, token)
			continue
		}
		name, inline, hasInline := token, "", false
		if strings.HasPrefix(token, "--") {
			if before, after, found := strings.Cut(token, "="); found {
				name, inline, hasInline = before, after, true
			}
		}
		o, ok := optionNamed(name)
		if !ok {
			return invocation{}, failure("Unknown option "+quoted(token), named)
		}
		if o.valueName() == "" {
			if hasInline {
				return invocation{}, failure(name+" does not take a value", named)
			}
			flags[o] = true
			continue
		}
		value := inline
		if !hasInline {
			if i+1 < len(arguments) {
				i++
				value = arguments[i]
			}
		}
		if value == "" || strings.HasPrefix(value, "-") {
			return invocation{}, failure(name+" needs a value", named)
		}
		if _, exists := values[o]; exists {
			return invocation{}, failure(name+" can only be given once", named)
		}
		values[o] = value
	}

	isHelpCommand := len(words) > 0 && words[0] == "help"
	commandWords := words
	if isHelpCommand {
		commandWords = words[1:]
	}
	if len(commandWords) > 0 && commandWords[0] == "ls" {
		commandWords = append([]string{"list"}, commandWords[1:]...)
	}
	t := matchTopic(commandWords, false)
	operands := commandWords[len(t.path):]
	if isHelpCommand {
		if len(operands) > 0 {
			return invocation{}, failure("Unknown help topic "+quoted(strings.Join(commandWords, " ")), named)
		}
	} else if err := validate(operands, t); err != nil {
		return invocation{}, err
	}

	allowed := commonOptions
	if !isHelpCommand {
		allowed = append(slices.Clone(commonOptions), t.options...)
	}
	for _, o := range allOptions {
		_, hasValue := values[o]
		if (!flags[o] && !hasValue) || slices.Contains(allowed, o) {
			continue
		}
		name := o.lastFlag()
		switch {
		case o == optVersion:
			return invocation{}, failure("--version is only valid without a command", named)
		case isHelpCommand:
			return invocation{}, failure(name+" is not valid for help", named)
		case t.kind == kindRoot:
			return invocation{}, failure(name+" needs a command", named)
		}
		return invocation{}, failure(name+" is not valid for "+t.name(), named)
	}
	inv := invocation{topic: t, isJSON: flags[optJSON], isNonInteractive: flags[optNonInteractive]}
	if value, ok := values[optTimeout]; ok {
		seconds, valid := parseSeconds(value)
		if !valid || math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds <= 0 || seconds > maximumTimeout {
			return invocation{}, failure("--timeout needs a positive number of seconds, up to 86400", named)
		}
		// A positive value that rounds below a nanosecond still times out at once instead of taking the default
		inv.timeout = max(time.Duration(seconds*float64(time.Second)), 1)
	}

	if isHelpCommand || flags[optHelp] {
		inv.action = actionHelp
		return inv, nil
	}
	if flags[optVersion] {
		inv.action = actionVersion
		return inv, nil
	}
	var cmd command
	switch t.kind {
	case kindRoot, kindHelp:
		inv.action = actionHelp
		return inv, nil
	case kindVersion:
		inv.action = actionVersion
		return inv, nil
	case kindAuth:
		return invocation{}, failure("Missing auth command. Use login, status, or logout", named)
	case kindAuthLogin:
		cmd = command{kind: cmdAuthLogin, showsQR: !flags[optNoQR]}
	case kindAuthStatus:
		cmd = command{kind: cmdAuthStatus}
	case kindAuthLogout:
		cmd = command{kind: cmdAuthLogout}
	case kindMode, kindModeStatus:
		cmd = command{kind: cmdModeStatus}
	case kindModeFull:
		cmd = command{kind: cmdSetMode, mode: ipc.ModeFull}
	case kindModeMesh:
		cmd = command{kind: cmdSetMode, mode: ipc.ModeMesh}
	case kindList:
		cmd = command{kind: cmdList, refresh: flags[optRefresh], long: flags[optLong]}
		if value, ok := values[optRegion]; ok {
			if !validRegion(value) {
				return invocation{}, failure("Invalid region '"+sanitize(value)+"'", named)
			}
			cmd.regionID = value
		}
	case kindStatus:
		cmd = command{kind: cmdStatus}
		if value, ok := values[optOperation]; ok {
			id, valid := parseUUID(value)
			if !valid {
				return invocation{}, failure("Invalid operation ID "+quoted(value), named)
			}
			cmd.operationID = id
		}
	case kindUp:
		sel, err := parseSelector(operands, t)
		if err != nil {
			return invocation{}, err
		}
		cmd = command{kind: cmdUp, selector: sel}
	case kindDown:
		sel, err := parseSelector(operands, t)
		if err != nil {
			return invocation{}, err
		}
		cmd = command{kind: cmdDown}
		if sel != nil {
			cmd = command{kind: cmdDownTarget, selector: sel}
		}
	case kindRemove:
		sel, err := parseSelector(operands, t)
		if err != nil {
			return invocation{}, err
		}
		if sel == nil {
			return invocation{}, failure("Removal requires a client UUID or <region> <positive index> from `cloudgateway ls`", named)
		}
		if !flags[optYes] {
			return invocation{}, failure("Removal requires --yes to acknowledge permanent cloud client deletion", named)
		}
		cmd = command{kind: cmdRemove, selector: sel}
	case kindAdd:
		region, name, err := parseCreation(operands, t)
		if err != nil {
			return invocation{}, err
		}
		cmd = command{kind: cmdAdd, addRegion: region, addName: name}
	case kindUpdate:
		cmd = command{kind: cmdUpdate, allowDisconnect: flags[optAllowDisconnect]}
	case kindRefresh:
		cmd = command{kind: cmdRefresh}
	case kindDoctor:
		cmd = command{kind: cmdDoctor}
	}
	inv.command = cmd
	return inv, nil
}

// parseSeconds follows Swift's strtod-based Double(String): decimal or hex, with hex exponents
// optional and no digit separators
func parseSeconds(value string) (float64, bool) {
	if strings.Contains(value, "_") {
		return 0, false
	}
	lower := strings.ToLower(strings.TrimPrefix(value, "+"))
	if strings.HasPrefix(lower, "0x") && !strings.Contains(lower, "p") {
		value += "p0"
	}
	seconds, err := strconv.ParseFloat(value, 64)
	return seconds, err == nil
}

func optionNamed(name string) (option, bool) {
	for _, o := range allOptions {
		if slices.Contains(o.flags(), name) {
			return o, true
		}
	}
	return 0, false
}

// matchTopic finds the longest topic path that prefixes words. Root matches everything unless excluded
func matchTopic(words []string, skipRoot bool) topic {
	best, found := topics[0], false
	for _, t := range topics {
		if skipRoot && len(t.path) == 0 {
			continue
		}
		if len(words) >= len(t.path) && slices.Equal(words[:len(t.path)], t.path) && (!found || len(t.path) > len(best.path)) {
			best, found = t, true
		}
	}
	if skipRoot && !found {
		return topic{kind: -1}
	}
	return best
}

func validate(operands []string, t topic) *usageFailure {
	if len(operands) == 0 {
		return nil
	}
	operand := operands[0]
	switch t.kind {
	case kindRoot:
		return failure("Unknown command "+quoted(operand), nil)
	case kindAuth:
		return failure("Unknown auth command "+quoted(operand), t.path)
	case kindMode:
		return failure("Unknown mode "+quoted(operand)+". Use status, full, or mesh", t.path)
	case kindUp, kindDown, kindRemove:
		_, err := parseSelector(operands, t)
		return err
	case kindAdd:
		_, _, err := parseCreation(operands, t)
		return err
	}
	return failure("Unexpected argument "+quoted(operand), t.path)
}

func validRegion(value string) bool {
	return strings.TrimSpace(value) != "" && len(value) <= 512 && value == sanitize(value) && !strings.Contains(value, "/")
}

func parseSelector(operands []string, t topic) (*selector, *usageFailure) {
	if len(operands) == 0 {
		return nil, nil
	}
	if len(operands) == 1 {
		if id, ok := parseUUID(operands[0]); ok {
			return &selector{clientID: id}, nil
		}
	}
	if len(operands) == 2 && validRegion(operands[0]) && isASCIIDigits(operands[1]) {
		if index, err := strconv.ParseInt(operands[1], 10, 64); err == nil && index > 0 {
			return &selector{region: operands[0], index: int(index)}, nil
		}
	}
	return nil, failure("Use a client UUID or <region> <positive index> from `cloudgateway ls`", t.path)
}

func isASCIIDigits(value string) bool {
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		if value[i] < '0' || value[i] > '9' {
			return false
		}
	}
	return true
}

func parseCreation(operands []string, t topic) (string, string, *usageFailure) {
	if len(operands) != 2 || !validRegion(operands[0]) {
		return "", "", failure("Use add <region> <name>. A region and client name are required", t.path)
	}
	name := strings.TrimSpace(operands[1])
	if name == "" || utf8.RuneCountInString(name) > 80 || len(name) > 320 || name != sanitize(name) {
		return "", "", failure("Client name must contain 1 to 80 characters without control characters", t.path)
	}
	return operands[0], name, nil
}

// parseUUID accepts only the 36-character hyphenated form, in either case, and returns it lowercased
func parseUUID(value string) (string, bool) {
	if len(value) != 36 {
		return "", false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if c != '-' {
				return "", false
			}
		case (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F'):
			return "", false
		}
	}
	return strings.ToLower(value), true
}

// namedWords finds command words up front so an early usage error still names its command
func namedWords(arguments []string) []string {
	var words []string
	for i := 0; i < len(arguments); i++ {
		token := arguments[i]
		if len(token) <= 1 || !strings.HasPrefix(token, "-") {
			words = append(words, token)
			continue
		}
		if o, ok := optionNamed(token); ok && o.valueName() != "" {
			i++
		}
	}
	return words
}

func failure(message string, words []string) *usageFailure {
	if len(words) > 0 && words[0] == "help" {
		words = []string{"help"}
	}
	if len(words) > 0 && words[0] == "ls" {
		words = append([]string{"list"}, words[1:]...)
	}
	t := matchTopic(words, true)
	if t.kind < 0 {
		return &usageFailure{message: message}
	}
	return &usageFailure{message: message, command: t.name()}
}

func quoted(value string) string { return "'" + sanitize(value) + "'" }
