package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/ipc"
)

func mustParse(t *testing.T, arguments ...string) invocation {
	t.Helper()
	inv, failure := parse(arguments)
	if failure != nil {
		t.Fatalf("%q: %s", arguments, failure.message)
	}
	return inv
}

func helpTopic(t *testing.T, arguments ...string) string {
	t.Helper()
	inv := mustParse(t, arguments...)
	if inv.action != actionHelp {
		t.Fatalf("%q: not help", arguments)
	}
	return inv.topic.name()
}

func TestParserShowsHelpForEveryDocumentedHelpForm(t *testing.T) {
	cases := map[string][]string{
		"":            {},
		"auth login":  {"help", "auth", "login"},
		"auth":        {"auth", "-h"},
		"up":          {"up", "--help"},
		"add":         {"help", "add", "--json"},
		"status":      {"--json", "help", "status"},
		"mode":        {"help", "mode", "--json"},
		"mode status": {"mode", "status", "--help", "--json"},
		"list":        {"ls", "--help"},
		"remove":      {"remove", "--yes", "--help"},
		"version":     {"version", "--help"},
	}
	for want, arguments := range cases {
		expectEqual(t, strings.Join(arguments, " "), helpTopic(t, arguments...), want)
	}
	for _, arguments := range [][]string{{"help"}, {"-h"}, {"--help"}, {"-v", "--help"}} {
		expectEqual(t, strings.Join(arguments, " "), helpTopic(t, arguments...), "")
	}
	for _, arguments := range [][]string{{"auth", "login", "--help"}, {"help", "auth", "login"}} {
		expectEqual(t, strings.Join(arguments, " "), helpTopic(t, arguments...), "auth login")
	}
	expectEqual(t, "remove uuid -h", helpTopic(t, "remove", "78ab8633-ae25-4287-885f-57bbbf6e7f63", "-h"), "remove")
}

func TestParserAcceptsCommandsWithFlagsBeforeOrAfterWords(t *testing.T) {
	clientID := "78ab8633-ae25-4287-885f-57bbbf6e7f63"
	cases := []struct {
		arguments []string
		want      command
	}{
		{[]string{"auth", "status"}, command{kind: cmdAuthStatus}},
		{[]string{"--json", "auth", "status"}, command{kind: cmdAuthStatus}},
		{[]string{"auth", "--json", "status"}, command{kind: cmdAuthStatus}},
		{[]string{"auth", "login", "--no-qr"}, command{kind: cmdAuthLogin}},
		{[]string{"auth", "login"}, command{kind: cmdAuthLogin, showsQR: true}},
		{[]string{"auth", "logout"}, command{kind: cmdAuthLogout}},
		{[]string{"mode"}, command{kind: cmdModeStatus}},
		{[]string{"mode", "status"}, command{kind: cmdModeStatus}},
		{[]string{"mode", "mesh", "--json"}, command{kind: cmdSetMode, mode: ipc.ModeMesh}},
		{[]string{"--non-interactive", "mode", "full"}, command{kind: cmdSetMode, mode: ipc.ModeFull}},
		{[]string{"list"}, command{kind: cmdList}},
		{[]string{"list", "--region", "us-east-1", "--refresh"}, command{kind: cmdList, regionID: "us-east-1", refresh: true}},
		{[]string{"--region=eu_west.2", "list"}, command{kind: cmdList, regionID: "eu_west.2"}},
		{[]string{"ls", "-l", "--region", "San Jose", "--refresh", "--json", "-l"}, command{kind: cmdList, regionID: "San Jose", refresh: true, long: true}},
		{[]string{"status"}, command{kind: cmdStatus}},
		{[]string{"status", "--operation", "6F9619FF-8B86-D011-B42D-00C04FC964FF"}, command{kind: cmdStatus, operationID: "6f9619ff-8b86-d011-b42d-00c04fc964ff"}},
		{[]string{"down"}, command{kind: cmdDown}},
		{[]string{"refresh"}, command{kind: cmdRefresh}},
		{[]string{"doctor", "--non-interactive"}, command{kind: cmdDoctor}},
		{[]string{"update"}, command{kind: cmdUpdate}},
		{[]string{"update", "--allow-disconnect", "--allow-disconnect"}, command{kind: cmdUpdate, allowDisconnect: true}},
		{[]string{"add", "sanjose", "Mac mini"}, command{kind: cmdAdd, addRegion: "sanjose", addName: "Mac mini"}},
		{[]string{"--json", "add", "us-sanjose-1", "  Work VM  ", "--timeout", "60"}, command{kind: cmdAdd, addRegion: "us-sanjose-1", addName: "Work VM"}},
		{[]string{"add", "California", strings.Repeat("é", 80)}, command{kind: cmdAdd, addRegion: "California", addName: strings.Repeat("é", 80)}},
	}
	for _, tc := range cases {
		inv := mustParse(t, tc.arguments...)
		if inv.action != actionRun || inv.command.kind != tc.want.kind || inv.command.showsQR != tc.want.showsQR ||
			inv.command.mode != tc.want.mode || inv.command.regionID != tc.want.regionID || inv.command.refresh != tc.want.refresh ||
			inv.command.long != tc.want.long || inv.command.operationID != tc.want.operationID ||
			inv.command.addRegion != tc.want.addRegion || inv.command.addName != tc.want.addName ||
			inv.command.allowDisconnect != tc.want.allowDisconnect {
			t.Errorf("%q: got %+v", tc.arguments, inv.command)
		}
	}
	up := mustParse(t, "up", strings.ToUpper(clientID)).command
	if up.kind != cmdUp || *up.selector != (selector{clientID: clientID}) {
		t.Errorf("up uuid: %+v", up)
	}
	for _, name := range []string{"up", "down"} {
		for operands, want := range map[[2]string]selector{
			{"Chicago", "01"}: {region: "Chicago", index: 1}, {"San Jose", "2"}: {region: "San Jose", index: 2},
			{"chicago", "0009223372036854775807"}: {region: "chicago", index: 9223372036854775807},
		} {
			cmd := mustParse(t, name, operands[0], operands[1]).command
			if cmd.selector == nil || *cmd.selector != want || (name == "down") != (cmd.kind == cmdDownTarget) {
				t.Errorf("%s %v: %+v", name, operands, cmd)
			}
		}
	}
	if mustParse(t, "up").command.selector != nil {
		t.Error("bare up has a selector")
	}
	remove := mustParse(t, "--json", "--yes", "remove", "San Jose", "02", "--timeout=2.5", "--non-interactive")
	if remove.command.kind != cmdRemove || *remove.command.selector != (selector{region: "San Jose", index: 2}) ||
		!remove.isJSON || !remove.isNonInteractive || remove.timeout != 2500*time.Millisecond || remove.command.name() != "remove" {
		t.Errorf("remove: %+v", remove)
	}
}

func TestParserReadsCommonOptions(t *testing.T) {
	inv := mustParse(t, "--timeout", "2.5", "status", "--json", "--non-interactive")
	if inv.timeout != 2500*time.Millisecond || !inv.isJSON || !inv.isNonInteractive {
		t.Fatalf("%+v", inv)
	}
	expectEqual(t, "default timeout", mustParse(t, "status").timeout, 0)
	expectEqual(t, "login timeout", mustParse(t, "auth", "login").timeout, 0)
	expectEqual(t, "max timeout", mustParse(t, "--timeout=86400", "status").timeout, 86_400*time.Second)
	expectEqual(t, "version", mustParse(t, "--version", "--json").action, actionVersion)
	expectEqual(t, "version word", mustParse(t, "version").action, actionVersion)
	expectEqual(t, "-v", mustParse(t, "-v").action, actionVersion)
}

func TestParserRejectsMalformedInvocations(t *testing.T) {
	cases := []struct {
		arguments []string
		message   string
	}{
		{[]string{"bogus"}, "Unknown command 'bogus'"},
		{[]string{"mode", "bogus"}, "Unknown mode 'bogus'. Use status, full, or mesh"},
		{[]string{"mode", "Mesh"}, "Unknown mode 'Mesh'. Use status, full, or mesh"},
		{[]string{"mode", "full", "extra"}, "Unexpected argument 'extra'"},
		{[]string{"mode", "status", "--operation", "6f9619ff-8b86-d011-b42d-00c04fc964ff"}, "--operation is not valid for mode status"},
		{[]string{"list", "--bogus"}, "Unknown option '--bogus'"},
		{[]string{"--controller"}, "Unknown option '--controller'"},
		{[]string{"list", "--region"}, "--region needs a value"},
		{[]string{"--region", "--json", "list"}, "--region needs a value"},
		{[]string{"list", "--region="}, "--region needs a value"},
		{[]string{"list", "--region", "a", "--region", "b"}, "--region can only be given once"},
		{[]string{"--timeout", "5", "status", "--timeout=6"}, "--timeout can only be given once"},
		{[]string{"status", "--operation", "not-a-uuid"}, "Invalid operation ID 'not-a-uuid'"},
		{[]string{"status", "--operation", "{6f9619ff-8b86-d011-b42d-00c04fc964ff}"}, "Invalid operation ID '{6f9619ff-8b86-d011-b42d-00c04fc964ff}'"},
		{[]string{"status", "--operation", "6f9619ff8b86d011b42d00c04fc964ff"}, "Invalid operation ID '6f9619ff8b86d011b42d00c04fc964ff'"},
		{[]string{"list", "--region", "us/east"}, "Invalid region 'us/east'"},
		{[]string{"up", "uid1/region"}, "Use a client UUID or <region> <positive index> from `cloudgateway ls`"},
		{[]string{"up", "uid1/region/client", "extra"}, "Use a client UUID or <region> <positive index> from `cloudgateway ls`"},
		{[]string{"list", "extra"}, "Unexpected argument 'extra'"},
		{[]string{"--timeout", "0", "status"}, "--timeout needs a positive number of seconds, up to 86400"},
		{[]string{"--timeout", "nan", "status"}, "--timeout needs a positive number of seconds, up to 86400"},
		{[]string{"--timeout", "inf", "status"}, "--timeout needs a positive number of seconds, up to 86400"},
		{[]string{"--timeout", "86401", "status"}, "--timeout needs a positive number of seconds, up to 86400"},
		{[]string{"--timeout", "-1", "status"}, "--timeout needs a value"},
		{[]string{"--timeout=-1", "status"}, "--timeout needs a value"},
		{[]string{"status", "--region", "x"}, "--region is not valid for status"},
		{[]string{"--refresh"}, "--refresh needs a command"},
		{[]string{"list", "--version"}, "--version is only valid without a command"},
		{[]string{"help", "--version"}, "--version is only valid without a command"},
		{[]string{"help", "list", "--refresh"}, "--refresh is not valid for help"},
		{[]string{"--json=yes", "status"}, "--json does not take a value"},
		{[]string{"remove", "78ab8633-ae25-4287-885f-57bbbf6e7f63", "--yes=false"}, "--yes does not take a value"},
		{[]string{"auth"}, "Missing auth command. Use login, status, or logout"},
		{[]string{"auth", "bogus"}, "Unknown auth command 'bogus'"},
		{[]string{"help", "bogus"}, "Unknown help topic 'bogus'"},
		{[]string{"help", "auth", "status", "extra"}, "Unknown help topic 'auth status extra'"},
		{[]string{"--\x1b[31m"}, "Unknown option '-- [31m'"},
		{[]string{"remove", "78ab8633-ae25-4287-885f-57bbbf6e7f63"}, "Removal requires --yes to acknowledge permanent cloud client deletion"},
		{[]string{"remove", "--yes"}, "Removal requires a client UUID or <region> <positive index> from `cloudgateway ls`"},
		{[]string{"add", "sanjose", "Mac\nmini"}, "Client name must contain 1 to 80 characters without control characters"},
		{[]string{"add", "sanjose"}, "Use add <region> <name>. A region and client name are required"},
	}
	for _, tc := range cases {
		_, failure := parse(tc.arguments)
		if failure == nil || failure.message != tc.message {
			t.Errorf("%q: got %+v, want %q", tc.arguments, failure, tc.message)
		}
	}
	commands := []struct {
		arguments []string
		command   string
	}{
		{[]string{"list", "--bogus"}, "list"},
		{[]string{"auth", "status", "extra"}, "auth status"},
		{[]string{"--bogus", "list"}, "list"},
		{[]string{"--bogus", "ls"}, "list"},
		{[]string{"--timeout", "0", "auth", "status"}, "auth status"},
		{[]string{"--region", "list", "bogus"}, ""},
		{[]string{"--bogus"}, ""},
		{[]string{"help", "bogus"}, "help"},
		{[]string{"mode", "FULL"}, "mode"},
	}
	for _, tc := range commands {
		_, failure := parse(tc.arguments)
		if failure == nil || failure.command != tc.command {
			t.Errorf("%q: got %+v, want command %q", tc.arguments, failure, tc.command)
		}
	}
}

func TestParserRejectsInvalidSelectorsNamesAndOptionPlacement(t *testing.T) {
	uuid := "78ab8633-ae25-4287-885f-57bbbf6e7f63"
	for _, name := range []string{"up", "down"} {
		for _, operands := range [][]string{{"1"}, {"uid1/us-east-1/" + uuid}, {"chicago", "0"}, {"chicago", "-1"}, {"chicago", "1.0"},
			{"chicago", "+1"}, {"chicago", "1e2"}, {"chicago", "١"}, {"chicago", strings.Repeat("9", 40)}, {"chicago", "1", "extra"},
			{"{" + uuid + "}"}, {"urn:uuid:" + uuid}, {strings.ReplaceAll(uuid, "-", "")}, {uuid[:35] + "g"}} {
			if _, failure := parse(append([]string{name}, operands...)); failure == nil || failure.command != name {
				t.Errorf("%s %q: %+v", name, operands, failure)
			}
		}
	}
	for _, arguments := range [][]string{
		{"remove"}, {"remove", "--yes"}, {"remove", uuid}, {"remove", "chicago", "1"}, {"remove", "chicago", "--yes"},
		{"remove", uuid, "extra", "--yes"}, {"remove", "uid1/us-east-1/" + uuid, "--yes"}, {"remove", "chicago", "0", "--yes"},
		{"remove", "chicago", "1.0", "--yes"}, {"remove", "chicago", "+1", "--yes"}, {"remove", "chicago", "١", "--yes"},
		{"remove", "chicago", strings.Repeat("9", 40), "--yes"}, {"remove", uuid, "--yes=false"}, {"remove", uuid, "--yes=true"},
		{"remove", uuid, "--yes="}, {"remove", uuid, "--yes", "--allow-disconnect"}, {"remove", uuid, "--yes", "--refresh"},
		{"add"}, {"add", "sanjose"}, {"add", "sanjose", ""}, {"add", "sanjose", "   "}, {"add", "sanjose", "Mac", "extra"},
		{"add", "us/sanjose", "Mac"}, {"add", "sanjose", strings.Repeat("a", 81)}, {"add", "sanjose", "Mac\x1b[31m"},
		{"add", "sanjose", "Mac‮"}, {"add", "sanjose", "Mac", "--allow-disconnect"}, {"add", strings.Repeat("r", 513), "Mac"},
	} {
		if _, failure := parse(arguments); failure == nil || failure.command != arguments[0] {
			t.Errorf("%q: %+v", arguments, failure)
		}
	}
	for _, arguments := range [][]string{{"status", "-l"}, {"up", "--long"}, {"version", "extra"}, {"version", "-v"}, {"list", "-v"},
		{"down", "--version"}, {"help", "version", "--long"}, {"update", "client"}, {"update", "--allow-disconnect=yes"},
		{"up", "--allow-disconnect"}, {"doctor", "--allow-disconnect"}, {"help", "update", "--allow-disconnect"}, {"--allow-disconnect"}} {
		if _, failure := parse(arguments); failure == nil {
			t.Errorf("%q parsed", arguments)
		}
	}
	for _, arguments := range [][]string{{"up", uuid}, {"down", uuid}, {"add", "chicago", "Mac"}, {"auth", "logout"}, {"auth", "login"},
		{"list"}, {"status"}, {"update"}, {"refresh"}, {"doctor"}, {"version"}, {}, {"help", "remove"}} {
		if _, failure := parse(append(arguments, "--yes")); failure == nil {
			t.Errorf("%q accepted --yes", arguments)
		}
	}
}

func TestHelpTopicsUseSharedDefinitions(t *testing.T) {
	list := newHelp(mustParse(t, "help", "list").topic)
	expectEqual(t, "list usage", list.usage, "cloudgateway list [--region <region>] [--refresh] [--long] [options]")
	expectEqual(t, "remove usage", mustParse(t, "help", "remove").topic.usage(),
		"cloudgateway remove <client-uuid> | <region> <index> --yes [options]")
	expectEqual(t, "root usage", mustParse(t).topic.usage(), "cloudgateway <command> [options]")
	expectEqual(t, "auth usage", mustParse(t, "help", "auth").topic.usage(), "cloudgateway auth <command> [options]")
	var names []string
	for _, c := range newHelp(mustParse(t).topic).commands {
		names = append(names, c.name)
	}
	expectEqual(t, "root commands", strings.Join(names, ","),
		"auth login,auth status,auth logout,mode,mode status,mode full,mode mesh,list,status,up,down,add,remove,update,refresh,doctor,version,help")
	names = nil
	for _, c := range newHelp(mustParse(t, "help", "mode").topic).commands {
		names = append(names, c.name)
	}
	expectEqual(t, "mode commands", strings.Join(names, ","), "mode status,mode full,mode mesh")
}

func TestTimeoutFollowsSwiftNumberGrammar(t *testing.T) {
	for value, want := range map[string]time.Duration{
		"0x10": 16 * time.Second, "0x1c.6": 28375 * time.Millisecond, "0X1Cp0": 28 * time.Second, "0x1p-1": 500 * time.Millisecond,
		"+5": 5 * time.Second, ".5": 500 * time.Millisecond, "5.": 5 * time.Second, "1e2": 100 * time.Second,
		// Positive values below a nanosecond time out at once instead of taking the default
		"1e-10": 1, "4.9e-324": 1,
	} {
		expectEqual(t, value, mustParse(t, "status", "--timeout", value).timeout, want)
	}
	for _, value := range []string{"1_0", "0x_1p0", "0x", "0xp0", " 5", "5 ", "1e", "0x1g", "1e400", "1e-400", "infinity", "0x1p17"} {
		if _, failure := parse([]string{"status", "--timeout", value}); failure == nil ||
			failure.message != "--timeout needs a positive number of seconds, up to 86400" {
			t.Errorf("%q: %+v", value, failure)
		}
	}
	h := newHarness(t, testState())
	expectExit(t, h.run("status", "--timeout", "1e-10", "--json"), 8)
	expectEqual(t, "code", field(h.last(), "error", "code"), any("timeout"))
}
