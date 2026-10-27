package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Albro3459/CloudGateway/Frontend/Linux/install"
	"github.com/Albro3459/CloudGateway/Frontend/Linux/internal/release"
)

// installEnv runs install.sh unprivileged against a temp root with stub
// system commands, using CLOUDGATEWAY_INSTALL_TEST_ROOT
type installEnv struct {
	t      *testing.T
	base   string
	root   string
	stubs  string
	log    string
	assets string
	signer ed25519.PrivateKey
	public string
	env    map[string]string
}

// findOpenSSL3 returns an OpenSSL 3 binary. macOS ships LibreSSL, which lacks Ed25519 -rawin
func findOpenSSL3() string {
	candidates := []string{"/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"}
	if path, err := exec.LookPath("openssl"); err == nil {
		candidates = append([]string{path}, candidates...)
	}
	for _, candidate := range candidates {
		output, err := exec.Command(candidate, "version").Output()
		if err == nil && regexp.MustCompile(`^OpenSSL ([3-9]|[1-9][0-9])\.`).Match(output) {
			return candidate
		}
	}
	return ""
}

func newInstallEnv(t *testing.T) *installEnv {
	t.Helper()
	openssl := findOpenSSL3()
	if openssl == "" {
		t.Skip("installer tests need OpenSSL 3 for Ed25519 signature checks. macOS LibreSSL lacks it, so install openssl@3")
	}
	for _, tool := range []string{"bash", "sha256sum", "tar", "cmp"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("installer tests need %s", tool)
		}
	}
	if os.Geteuid() == 0 {
		t.Skip("install.sh refuses its test root when run as root")
	}
	signer, public := testSigner(t)
	base := t.TempDir()
	e := &installEnv{
		t: t, base: base, root: filepath.Join(base, "root"), stubs: filepath.Join(base, "stubs"), log: filepath.Join(base, "log"),
		assets: filepath.Join(base, "assets"), signer: signer, public: public,
	}
	for _, dir := range []string{"run/systemd/system", "run/systemd/resolve", "sys/module/wireguard", "etc/systemd/system", "usr/local/bin", "usr/sbin"} {
		mkdirAll(t, filepath.Join(e.root, dir))
	}
	mkdirAll(t, e.stubs)
	writeFile(t, filepath.Join(e.root, "etc/os-release"), "NAME=\"Ubuntu\"\nID=ubuntu\nVERSION_ID=\"24.04\"\n"+
		"PRETTY_NAME=\"Ubuntu $(touch "+filepath.Join(base, "expanded")+")\"\ntouch "+filepath.Join(base, "sourced")+"\n", 0o644)
	if err := os.Symlink("../run/systemd/resolve/stub-resolv.conf", filepath.Join(e.root, "etc/resolv.conf")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(openssl, filepath.Join(e.stubs, "openssl")); err != nil {
		t.Fatal(err)
	}
	// The daemon finds these in fixed system dirs, so the installer checks there too
	for _, tool := range []string{"ip", "wg", "nft"} {
		writeFile(t, filepath.Join(e.root, "usr/sbin", tool), "#!/bin/sh\n", 0o755)
	}
	logged := `echo "$(basename "$0") $*" >>"$CLOUDGATEWAY_TEST_LOG"`
	stubs := map[string]string{
		"id":         `if [ $# -eq 1 ]; then echo "${CLOUDGATEWAY_TEST_UID:-0}"; elif [ "$3" = alice ]; then echo 1000; elif [ "$3" = root ]; then echo 0; else exit 1; fi`,
		"uname":      `echo "${CLOUDGATEWAY_TEST_MACHINE:-x86_64}"`,
		"chown":      logged,
		"flock":      logged,
		"systemctl":  logged + `; [ "$1" != "$CLOUDGATEWAY_TEST_FAIL" ]`,
		"resolvectl": "echo Global:; echo 'Link 2 (eth0): 10.0.0.2'",
	}
	// GNU mv has -T. Elsewhere rename(2) through perl replaces the link the same way
	if runtime.GOOS != "linux" {
		realMv, err := exec.LookPath("mv")
		if err != nil {
			t.Fatal(err)
		}
		stubs["mv"] = `if [ "$1" = -T ]; then exec perl -e 'rename($ARGV[0], $ARGV[1]) or die "mv: $!\n"' "$2" "$3"; fi; exec ` + realMv + ` "$@"`
	}
	for name, body := range stubs {
		e.stub(name, body)
	}
	e.env = map[string]string{
		"PATH":                           e.stubs + ":/usr/bin:/bin:/usr/sbin:/sbin",
		"HOME":                           base,
		"SUDO_USER":                      "alice",
		"CLOUDGATEWAY_INSTALL_TEST_ROOT": e.root,
		"CLOUDGATEWAY_TEST_LOG":          e.log,
	}
	t.Cleanup(func() {
		for _, marker := range []string{"expanded", "sourced"} {
			if _, err := os.Stat(filepath.Join(base, marker)); err == nil {
				t.Errorf("install.sh executed /etc/os-release contents (%s)", marker)
			}
		}
	})
	return e
}

func (e *installEnv) stub(name, body string) {
	writeFile(e.t, filepath.Join(e.stubs, name), "#!/bin/sh\n"+body+"\n", 0o755)
}

// release packages a fixture release and returns its asset directory
func (e *installEnv) release(version string, storageVersion int) string {
	e.t.Helper()
	if _, err := packageRelease(fixtureParams(e.assets, version, storageVersion, e.signer, e.public)); err != nil {
		e.t.Fatal(err)
	}
	return filepath.Join(e.assets, "linux-v"+version)
}

// signedAssets signs manifest with the test key and writes it, the stamped
// installer, and extra files to a new asset directory
func (e *installEnv) signedAssets(manifest []byte, extra map[string][]byte) string {
	e.t.Helper()
	dir := e.t.TempDir()
	script, err := stampInstaller(install.Script, "1.0.0", e.public)
	if err != nil {
		e.t.Fatal(err)
	}
	files := map[string][]byte{release.ManifestName: manifest, release.SignatureName: ed25519.Sign(e.signer, manifest), "install.sh": script}
	for name, contents := range extra {
		files[name] = contents
	}
	for name, contents := range files {
		writeFile(e.t, filepath.Join(dir, name), string(contents), 0o644)
	}
	return dir
}

func (e *installEnv) run(script string, args ...string) (string, error) {
	e.t.Helper()
	command := exec.Command("bash", append([]string{script}, args...)...)
	for key, value := range e.env {
		command.Env = append(command.Env, key+"="+value)
	}
	// No controlling terminal, so prompts read as no
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	command.Stdin = strings.NewReader("")
	output, err := command.CombinedOutput()
	return string(output), err
}

func (e *installEnv) install(dir string, args ...string) string {
	e.t.Helper()
	output, err := e.run(filepath.Join(dir, "install.sh"), append([]string{"--from", dir}, args...)...)
	if err != nil {
		e.t.Fatalf("install from %s failed: %v\n%s", dir, err, output)
	}
	return output
}

func (e *installEnv) refuse(want, script string, args ...string) {
	e.t.Helper()
	output, err := e.run(script, args...)
	if err == nil || !strings.Contains(output, want) {
		e.t.Fatalf("want failure containing %q, got %v:\n%s", want, err, output)
	}
}

func (e *installEnv) takeLog() string {
	data, _ := os.ReadFile(e.log)
	_ = os.Truncate(e.log, 0)
	return string(data)
}

func (e *installEnv) path(rel string) string { return filepath.Join(e.root, rel) }

func (e *installEnv) current() string {
	target, _ := os.Readlink(e.path("opt/cloudgateway/current"))
	return target
}

func (e *installEnv) exists(rel string) bool {
	_, err := os.Lstat(e.path(rel))
	return err == nil
}

func TestInstallFreshLayout(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	output := e.install(dir)
	if !strings.Contains(output, "Installed CloudGateway 1.0.0") || strings.Contains(output, "warning:") {
		t.Errorf("output:\n%s", output)
	}

	if e.current() != "releases/1.0.0" {
		t.Fatalf("current -> %q", e.current())
	}
	installed := e.path("opt/cloudgateway/releases/1.0.0")
	for _, name := range []string{"bin/cloudgateway", "bin/cloudgatewayd", release.UnitName, release.ManifestName, release.SignatureName} {
		if !e.exists("opt/cloudgateway/releases/1.0.0/" + name) {
			t.Errorf("missing %s", name)
		}
	}
	info, _ := os.Stat(filepath.Join(installed, "bin/cloudgatewayd"))
	if info.Mode().Perm() != 0o755 {
		t.Errorf("cloudgatewayd mode %v", info.Mode())
	}
	data, _ := os.ReadFile(filepath.Join(installed, release.ManifestName))
	signature, _ := os.ReadFile(filepath.Join(installed, release.SignatureName))
	if manifest, err := release.Verify(data, signature, e.public); err != nil || manifest.Version != "1.0.0" {
		t.Errorf("installed manifest %+v, %v", manifest, err)
	}
	if link, _ := os.Readlink(e.path("usr/local/bin/cloudgateway")); link != e.path("opt/cloudgateway/current/bin/cloudgateway") {
		t.Errorf("cloudgateway link -> %q", link)
	}
	if unit, _ := os.ReadFile(e.path("etc/systemd/system/cloudgatewayd.service")); !bytes.Equal(unit, install.Unit) {
		t.Error("installed unit differs from install/cloudgatewayd.service")
	}
	config, _ := os.ReadFile(e.path("etc/cloudgateway/daemon.json"))
	info, _ = os.Stat(e.path("etc/cloudgateway/daemon.json"))
	if string(config) != "{\"operatorUid\": 1000}\n" || info.Mode().Perm() != 0o644 {
		t.Errorf("daemon.json %q %v", config, info.Mode())
	}
	log := e.takeLog()
	for _, want := range []string{
		"flock -n 9",
		"chown root:root " + e.path("etc/cloudgateway/daemon.json.tmp"),
		"systemctl daemon-reload\nsystemctl enable cloudgatewayd.service\nsystemctl reset-failed cloudgatewayd.service\nsystemctl restart cloudgatewayd.service\n",
	} {
		if !strings.Contains(log, want) {
			t.Errorf("log lacks %q:\n%s", want, log)
		}
	}
	entries, _ := os.ReadDir(e.path("opt/cloudgateway"))
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if strings.Join(names, " ") != ".lock current releases" {
		t.Errorf("leftovers in /opt/cloudgateway: %v", names)
	}
	if entries, _ := os.ReadDir(e.path("opt/cloudgateway/releases")); len(entries) != 1 {
		t.Errorf("leftover staging dirs: %v", entries)
	}
}

func TestInstallUpdateKeepsPreviousRelease(t *testing.T) {
	e := newInstallEnv(t)
	e.install(e.release("1.0.0", 1))
	e.takeLog()

	// An update by another admin keeps the enrolled operator
	e.env["SUDO_USER"] = "root"
	output := e.install(e.release("1.0.1", 1))
	if e.current() != "releases/1.0.1" || !e.exists("opt/cloudgateway/releases/1.0.0") || !strings.Contains(output, "replacing 1.0.0") {
		t.Fatalf("current -> %q, output:\n%s", e.current(), output)
	}
	if log := e.takeLog(); !strings.Contains(log, "systemctl restart cloudgatewayd.service") {
		t.Errorf("update log:\n%s", log)
	}
	if config, _ := os.ReadFile(e.path("etc/cloudgateway/daemon.json")); string(config) != "{\"operatorUid\": 1000}\n" {
		t.Errorf("daemon.json %q", config)
	}

	e.install(e.release("1.0.2", 1), "--operator", "root")
	if e.current() != "releases/1.0.2" || !e.exists("opt/cloudgateway/releases/1.0.1") || e.exists("opt/cloudgateway/releases/1.0.0") {
		t.Fatalf("after second update current -> %q", e.current())
	}
	if config, _ := os.ReadFile(e.path("etc/cloudgateway/daemon.json")); string(config) != "{\"operatorUid\": 0}\n" {
		t.Errorf("re-enrolled daemon.json %q", config)
	}
}

func TestReinstallReusesOrRepairsRelease(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.install(dir)
	marker := e.path("opt/cloudgateway/releases/1.0.0/marker")
	writeFile(t, marker, "", 0o644)

	// A matching release stays in place, so current never dangles, and gets its modes back
	daemon := e.path("opt/cloudgateway/releases/1.0.0/bin/cloudgatewayd")
	if err := os.Chmod(daemon, 0o644); err != nil {
		t.Fatal(err)
	}
	e.takeLog()
	e.install(dir)
	if _, err := os.Stat(marker); err != nil || e.current() != "releases/1.0.0" {
		t.Fatalf("reinstall replaced a matching release: %v, current -> %q", err, e.current())
	}
	if info, _ := os.Stat(daemon); info.Mode().Perm() != 0o755 {
		t.Errorf("reinstall left cloudgatewayd mode %v", info.Mode())
	}
	if log := e.takeLog(); !strings.Contains(log, "chown -R root:root "+e.path("opt/cloudgateway/releases/1.0.0")+"\n") {
		t.Errorf("reinstall did not reset ownership:\n%s", log)
	}

	// A damaged signature means the release is replaced
	signature := e.path("opt/cloudgateway/releases/1.0.0/" + release.SignatureName)
	goodSignature, _ := os.ReadFile(signature)
	writeFile(t, signature, "damaged", 0o644)
	e.install(dir)
	if repaired, _ := os.ReadFile(signature); !bytes.Equal(repaired, goodSignature) || e.exists("opt/cloudgateway/releases/1.0.0/marker") {
		t.Fatal("reinstall kept a damaged signature")
	}
	writeFile(t, marker, "", 0o644)

	good, _ := os.ReadFile(daemon)
	writeFile(t, daemon, "damaged", 0o755)
	e.install(dir)
	if repaired, _ := os.ReadFile(daemon); !bytes.Equal(repaired, good) || e.exists("opt/cloudgateway/releases/1.0.0/marker") {
		t.Fatal("reinstall kept a damaged release")
	}
}

func TestInstallCleansUpAfterKilledRun(t *testing.T) {
	e := newInstallEnv(t)
	e.install(e.release("1.0.0", 1))
	// A killed same-version reinstall moved 1.0.0 aside and left temp dirs behind
	releases := e.path("opt/cloudgateway/releases")
	mkdirAll(t, filepath.Join(releases, ".replaced.abc"))
	if err := os.Rename(filepath.Join(releases, "1.0.0"), filepath.Join(releases, ".replaced.abc", "1.0.0")); err != nil {
		t.Fatal(err)
	}
	mkdirAll(t, filepath.Join(releases, ".staging.def"))
	mkdirAll(t, e.path("opt/cloudgateway/.work.ghi"))

	e.install(e.release("1.0.1", 1))
	if !e.exists("opt/cloudgateway/releases/1.0.0/bin/cloudgatewayd") || e.current() != "releases/1.0.1" {
		t.Fatalf("1.0.0 not restored, current -> %q", e.current())
	}
	for _, leftover := range []string{"opt/cloudgateway/releases/.replaced.abc", "opt/cloudgateway/releases/.staging.def", "opt/cloudgateway/.work.ghi"} {
		if e.exists(leftover) {
			t.Errorf("kept %s", leftover)
		}
	}
}

func TestRerunFinishesInterruptedFirstInstall(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.env["CLOUDGATEWAY_TEST_FAIL"] = "enable"
	e.refuse("", filepath.Join(dir, "install.sh"), "--from", dir)
	if e.current() != "releases/1.0.0" {
		t.Fatalf("interrupted install current -> %q", e.current())
	}
	e.takeLog()
	delete(e.env, "CLOUDGATEWAY_TEST_FAIL")
	e.install(dir)
	if log := e.takeLog(); !strings.Contains(log, "systemctl enable cloudgatewayd.service\nsystemctl reset-failed cloudgatewayd.service\nsystemctl restart cloudgatewayd.service\n") {
		t.Fatalf("rerun log:\n%s", log)
	}
}

func TestInstallRefusesTamperedAssets(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	archive := filepath.Join(dir, release.ArchiveName("1.0.0", "amd64"))
	original, _ := os.ReadFile(archive)
	tampered := bytes.Clone(original)
	tampered[len(tampered)/2] ^= 1
	writeFile(t, archive, string(tampered), 0o644)
	e.refuse("does not match the signed manifest", filepath.Join(dir, "install.sh"), "--from", dir)
	writeFile(t, archive, string(original), 0o644)

	manifestPath := filepath.Join(dir, release.ManifestName)
	manifest, _ := os.ReadFile(manifestPath)
	writeFile(t, manifestPath, strings.Replace(string(manifest), `"storageVersion": 1`, `"storageVersion": 9`, 1), 0o644)
	e.refuse("signature does not verify", filepath.Join(dir, "install.sh"), "--from", dir)
	writeFile(t, manifestPath, string(manifest), 0o644)

	_, otherKey := testSigner(t)
	otherInstaller, err := stampInstaller(install.Script, "1.0.0", otherKey)
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(t.TempDir(), "install.sh")
	writeFile(t, script, string(otherInstaller), 0o755)
	e.refuse("signature does not verify", script, "--from", dir)

	e.refuse("has no pinned release key", filepath.Join("..", "..", "install", "install.sh"), "--from", dir)
	if e.exists("opt/cloudgateway/current") || e.exists("etc/cloudgateway/daemon.json") {
		t.Fatal("a refused install changed the system")
	}
}

// archiveEntry is a raw tar entry, so tests can build archives the release tool never would
type archiveEntry struct {
	name     string
	typeflag byte
	contents string
	link     string
}

func rawArchive(t *testing.T, entries []archiveEntry) []byte {
	t.Helper()
	var out bytes.Buffer
	compressor := gzip.NewWriter(&out)
	writer := tar.NewWriter(compressor)
	for _, entry := range entries {
		header := &tar.Header{Name: entry.name, Typeflag: entry.typeflag, Linkname: entry.link, Mode: 0o755, ModTime: time.Unix(0, 0), Size: int64(len(entry.contents))}
		if entry.typeflag != tar.TypeReg {
			header.Size = 0
		}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(entry.contents)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressor.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestInstallRefusesUnsafeArchiveContents(t *testing.T) {
	e := newInstallEnv(t)
	escape := filepath.Join(e.base, "escaped")
	legit := []archiveEntry{
		{name: "bin/", typeflag: tar.TypeDir},
		{name: "bin/cloudgateway", typeflag: tar.TypeReg, contents: "cli"},
		{name: "bin/cloudgatewayd", typeflag: tar.TypeReg, contents: "daemon"},
		{name: release.UnitName, typeflag: tar.TypeReg, contents: "unit"},
	}
	replace := func(i int, entry archiveEntry) []archiveEntry {
		entries := append([]archiveEntry(nil), legit...)
		entries[i] = entry
		return entries
	}
	cases := map[string]struct {
		entries []archiveEntry
		want    string
	}{
		"extra file":     {append(append([]archiveEntry(nil), legit...), archiveEntry{name: "bin/extra", typeflag: tar.TypeReg, contents: "x"}), "does not hold exactly the files"},
		"traversal":      {append(append([]archiveEntry(nil), legit...), archiveEntry{name: "../../escaped", typeflag: tar.TypeReg, contents: "x"}), "does not hold exactly the files"},
		"absolute path":  {append(append([]archiveEntry(nil), legit...), archiveEntry{name: escape, typeflag: tar.TypeReg, contents: "x"}), "does not hold exactly the files"},
		"duplicate":      {append(append([]archiveEntry(nil), legit...), legit[1]), "does not hold exactly the files"},
		"no dir entry":   {legit[1:], "does not hold exactly the files"},
		"symlink":        {replace(1, archiveEntry{name: "bin/cloudgateway", typeflag: tar.TypeSymlink, link: escape}), "entries other than files and directories"},
		"dir symlink":    {replace(0, archiveEntry{name: "bin", typeflag: tar.TypeSymlink, link: e.base}), "does not hold exactly the files"},
		"hardlink":       {replace(2, archiveEntry{name: "bin/cloudgatewayd", typeflag: tar.TypeLink, link: escape}), ""},
		"fifo":           {replace(3, archiveEntry{name: release.UnitName, typeflag: tar.TypeFifo}), ""},
		"char device":    {replace(3, archiveEntry{name: release.UnitName, typeflag: tar.TypeChar}), ""},
		"wrong contents": {replace(1, archiveEntry{name: "bin/cloudgateway", typeflag: tar.TypeReg, contents: "evil"}), "bin/cloudgateway does not match the signed manifest"},
	}
	writeFile(t, escape, "outside", 0o644)
	for name, c := range cases {
		archive := rawArchive(t, c.entries)
		manifest := release.Manifest{SchemaVersion: 1, Version: "1.0.0", IPCVersion: 1, StorageVersion: 1, Entries: []release.Entry{
			entry("amd64", release.KindArchive, release.ArchiveName("1.0.0", "amd64"), archive),
			entry("amd64", release.KindFile, "bin/cloudgateway", []byte("cli")),
			entry("amd64", release.KindFile, "bin/cloudgatewayd", []byte("daemon")),
			entry("amd64", release.KindFile, release.UnitName, []byte("unit")),
		}}
		data, err := manifest.Encode()
		if err != nil {
			t.Fatal(err)
		}
		dir := e.signedAssets(data, map[string][]byte{release.ArchiveName("1.0.0", "amd64"): archive})
		output, err := e.run(filepath.Join(dir, "install.sh"), "--from", dir)
		if err == nil || !strings.Contains(output, c.want) {
			t.Errorf("%s: want failure containing %q, got %v:\n%s", name, c.want, err, output)
		}
		if contents, _ := os.ReadFile(escape); string(contents) != "outside" || e.exists("opt/cloudgateway/current") || e.exists("escaped") {
			t.Fatalf("%s: archive escaped the staging dir or installed", name)
		}
	}
}

// TestManifestParsersAgree signs valid and malicious manifests and checks that
// install.sh accepts exactly what release.Parse accepts
func TestManifestParsersAgree(t *testing.T) {
	e := newInstallEnv(t)
	baseData, _ := os.ReadFile(filepath.Join(e.release("1.0.0", 1), release.ManifestName))
	base := string(baseData)
	lines := strings.Split(strings.TrimSuffix(base, "\n"), "\n")
	withLines := func(edit func([]string) []string) string {
		return strings.Join(edit(append([]string(nil), lines...)), "\n") + "\n"
	}
	parsed, err := release.Parse(baseData)
	if err != nil {
		t.Fatal(err)
	}
	onlyARM := parsed
	onlyARM.Entries = nil
	for _, entry := range parsed.Entries {
		if entry.Arch == "arm64" {
			onlyARM.Entries = append(onlyARM.Entries, entry)
		}
	}
	armData, err := onlyARM.Encode()
	if err != nil {
		t.Fatal(err)
	}
	// lines[6] is the amd64 archive, then its three files, then arm64
	cases := map[string]string{
		"valid":               base,
		"arm64 only":          string(armData),
		"18 digit size":       regexp.MustCompile(`("bin/cloudgateway","size":)\d+`).ReplaceAllString(base, "${1}999999999999999999"),
		"19 digit size":       regexp.MustCompile(`"size":\d+`).ReplaceAllLiteralString(base, `"size":1000000000000000000`),
		"18 digit version":    strings.ReplaceAll(base, "1.0.0", "999999999999999999.0.0"),
		"19 digit version":    strings.ReplaceAll(base, "1.0.0", "1000000000000000000.0.0"),
		"18 digit storage":    strings.Replace(base, `"storageVersion": 1,`, `"storageVersion": 999999999999999999,`, 1),
		"leading slash":       strings.Replace(base, `"path":"bin/cloudgateway"`, `"path":"/bin/cloudgateway"`, 1),
		"double slash":        strings.Replace(base, `"path":"bin/cloudgateway"`, `"path":"bin//cloudgateway"`, 1),
		"dot component":       strings.Replace(base, `"path":"bin/cloudgateway"`, `"path":"bin/.cloudgateway"`, 1),
		"dot first component": strings.Replace(base, `"path":"bin/cloudgateway"`, `"path":".bin/cloudgateway"`, 1),
		"traversal":           strings.Replace(base, `"path":"bin/cloudgateway"`, `"path":"bin/../cloudgateway"`, 1),
		"duplicate entry":     withLines(func(l []string) []string { return slices.Insert(l, 8, l[7]) }),
		"second archive": withLines(func(l []string) []string {
			return slices.Insert(l, 7, strings.Replace(l[6], "amd64.tar.gz", "amd64.tar.gz.x", 1))
		}),
		"unsorted":             withLines(func(l []string) []string { l[7], l[8] = l[8], l[7]; return l }),
		"unknown header":       withLines(func(l []string) []string { return slices.Insert(l, 2, `  "extra": 1,`) }),
		"unknown entry field":  strings.Replace(base, `"kind":"file","path":"bin/cloudgateway",`, `"kind":"file","mode":"x","path":"bin/cloudgateway",`, 1),
		"field order":          regexp.MustCompile(`"size":(\d+),"sha256":"([0-9a-f]+)"`).ReplaceAllString(base, `"sha256":"$2","size":$1`),
		"no trailing newline":  strings.TrimSuffix(base, "\n"),
		"trailing blank line":  base + "\n",
		"trailing comma":       withLines(func(l []string) []string { l[len(l)-3] += ","; return l }),
		"missing comma":        withLines(func(l []string) []string { l[6] = strings.TrimSuffix(l[6], ","); return l }),
		"uppercase hex":        regexp.MustCompile(`"sha256":"[0-9a-f]+"`).ReplaceAllStringFunc(base, strings.ToUpper),
		"size leading zero":    strings.Replace(base, `"bin/cloudgateway","size":`, `"bin/cloudgateway","size":0`, 1),
		"size space":           strings.Replace(base, `"size":`, `"size": `, 1),
		"version leading zero": strings.ReplaceAll(base, "1.0.0", "01.0.0"),
		"archive name":         strings.Replace(base, `"version": "1.0.0"`, `"version": "1.0.1"`, 1),
		"schema 2":             strings.Replace(base, `"schemaVersion": 1`, `"schemaVersion": 2`, 1),
		"storage 0":            strings.Replace(base, `"storageVersion": 1`, `"storageVersion": 0`, 1),
		"ipc 0":                strings.Replace(base, `"ipcVersion": 1`, `"ipcVersion": 0`, 1),
		"unknown arch":         strings.ReplaceAll(base, "arm64", "riscv64"),
		"missing unit":         withLines(func(l []string) []string { return slices.Delete(l, 9, 10) }),
		"crlf":                 strings.ReplaceAll(base, "\n", "\r\n"),
		"nul byte":             strings.Replace(base, `"bin/cloudgateway"`, "\"bin/cloud\x00gateway\"", 1),
		"tab indent":           withLines(func(l []string) []string { l[6] = "\t" + strings.TrimLeft(l[6], " "); return l }),
		"archive size zero":    regexp.MustCompile(`(amd64\.tar\.gz","size":)\d+`).ReplaceAllString(base, "${1}0"),
		"empty entries":        strings.Join(lines[:6], "\n") + "\n  ]\n}\n",
		"trailing data":        base + "x",
	}
	rejected := regexp.MustCompile(`release manifest is malformed|unsupported release manifest schema|larger than expected`)
	for name, manifest := range cases {
		_, goErr := release.Parse([]byte(manifest))
		dir := e.signedAssets([]byte(manifest), nil)
		output, err := e.run(filepath.Join(dir, "install.sh"), "--from", dir)
		if err == nil {
			t.Fatalf("%s: install.sh succeeded without an archive:\n%s", name, output)
		}
		if shellOK := !rejected.MatchString(output); shellOK != (goErr == nil) {
			t.Errorf("%s: release.Parse error %v, install.sh output:\n%s", name, goErr, output)
		}
	}
	armDir := e.signedAssets(armData, nil)
	if output, _ := e.run(filepath.Join(armDir, "install.sh"), "--from", armDir); !strings.Contains(output, "release 1.0.0 has no amd64 build") {
		t.Errorf("missing arch output:\n%s", output)
	}
}

func TestInstallRefusesStorageDowngrade(t *testing.T) {
	e := newInstallEnv(t)
	older := e.release("1.0.0", 1)
	e.install(e.release("1.0.1", 2))
	e.refuse("Refusing a downgrade across a storage format change", filepath.Join(older, "install.sh"), "--from", older)
	if e.current() != "releases/1.0.1" {
		t.Fatalf("current -> %q", e.current())
	}

	// State left by an uninstalled newer release also counts
	state := newInstallEnv(t)
	olderState := state.release("1.0.0", 1)
	mkdirAll(t, state.path("var/lib/cloudgateway"))
	writeFile(t, state.path("var/lib/cloudgateway/storage.json"), `{"storageVersion":2}`, 0o600)
	state.refuse("this machine already uses format 2", filepath.Join(olderState, "install.sh"), "--from", olderState)
}

func TestUninstallKeepsStateUnlessPurged(t *testing.T) {
	for _, purge := range []bool{false, true} {
		e := newInstallEnv(t)
		dir := e.release("1.0.0", 1)
		e.install(dir)
		mkdirAll(t, e.path("var/lib/cloudgateway"))
		writeFile(t, e.path("var/lib/cloudgateway/storage.json"), `{"storageVersion":1}`, 0o600)
		e.takeLog()

		args := []string{"--uninstall"}
		if purge {
			args = append(args, "--purge")
		}
		output, err := e.run(filepath.Join(dir, "install.sh"), args...)
		if err != nil {
			t.Fatalf("uninstall: %v\n%s", err, output)
		}
		log := e.takeLog()
		stop, cleanup, disable := strings.Index(log, "systemctl stop cloudgatewayd.service"), strings.Index(log, "cloudgatewayd 1.0.0 cleanup"), strings.Index(log, "systemctl disable cloudgatewayd.service")
		if stop < 0 || cleanup < stop || disable < cleanup {
			t.Errorf("uninstall order:\n%s", log)
		}
		for _, gone := range []string{"opt/cloudgateway", "etc/systemd/system/cloudgatewayd.service", "usr/local/bin/cloudgateway", "etc/cloudgateway"} {
			if e.exists(gone) {
				t.Errorf("uninstall kept %s", gone)
			}
		}
		if e.exists("var/lib/cloudgateway/storage.json") == purge {
			t.Errorf("purge %v, state exists %v", purge, !purge)
		}
	}
}

func TestUninstallStopsWhenCleanupFails(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.install(dir)
	writeFile(t, e.path("opt/cloudgateway/releases/1.0.0/bin/cloudgatewayd"), "#!/bin/sh\nexit 1\n", 0o755)
	e.refuse("cloudgatewayd cleanup failed", filepath.Join(dir, "install.sh"), "--uninstall")
	if !e.exists("opt/cloudgateway/current") || !e.exists("etc/systemd/system/cloudgatewayd.service") {
		t.Fatal("failed cleanup removed files")
	}
}

func TestForeignCommandLinkIsLeftAlone(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	foreign := e.path("usr/local/bin/cloudgateway")
	writeFile(t, foreign, "someone else's", 0o755)
	e.refuse("is not CloudGateway's link", filepath.Join(dir, "install.sh"), "--from", dir)
	if e.exists("opt/cloudgateway/current") {
		t.Fatal("install continued past a foreign command")
	}

	if err := os.Remove(foreign); err != nil {
		t.Fatal(err)
	}
	e.install(dir)
	if err := os.Remove(foreign); err != nil {
		t.Fatal(err)
	}
	writeFile(t, foreign, "someone else's", 0o755)
	if output, err := e.run(filepath.Join(dir, "install.sh"), "--uninstall"); err != nil {
		t.Fatalf("uninstall: %v\n%s", err, output)
	}
	if contents, _ := os.ReadFile(foreign); string(contents) != "someone else's" {
		t.Fatal("uninstall removed a foreign command")
	}
}

func TestInstallChecksHostAndOperator(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	script := filepath.Join(dir, "install.sh")

	e.env["CLOUDGATEWAY_TEST_UID"] = "1000"
	e.refuse("run as root", script, "--from", dir)
	delete(e.env, "CLOUDGATEWAY_TEST_UID")

	e.env["SUDO_USER"] = ""
	e.refuse("pass --operator <user>", script, "--from", dir)
	e.refuse("no local user named mallory", script, "--from", dir, "--operator", "mallory")
	e.refuse("invalid operator name -u", script, "--from", dir, "--operator", "-u")
	e.env["SUDO_USER"] = "alice"

	e.env["CLOUDGATEWAY_TEST_MACHINE"] = "mips"
	e.refuse("unsupported architecture mips", script, "--from", dir)
	if e.exists("opt/cloudgateway") {
		t.Fatal("a refused preflight created /opt/cloudgateway")
	}
	e.env["CLOUDGATEWAY_TEST_MACHINE"] = "x86_64"
	e.refuse("the manifest is for release 1.0.0, not 1.0.1", script, "--from", dir, "--version", "1.0.1")
	e.refuse("--purge needs --uninstall", script, "--purge")
	e.refuse("--version must look like 1.0.0", script, "--version", "latest")

	for _, version := range []string{"LibreSSL 3.3.6", "OpenSSL 1.1.1w  11 Sep 2023"} {
		e.env["CLOUDGATEWAY_TEST_MACHINE"] = "x86_64"
		openssl := filepath.Join(e.stubs, "openssl")
		real, _ := os.Readlink(openssl)
		_ = os.Remove(openssl)
		e.stub("openssl", "echo '"+version+"'")
		e.refuse("needs OpenSSL 3 or later, found: "+version, script, "--from", dir)
		_ = os.Remove(openssl)
		if err := os.Symlink(real, openssl); err != nil {
			t.Fatal(err)
		}
	}

	e.env["CLOUDGATEWAY_TEST_MACHINE"] = "aarch64"
	e.install(dir)
	if e.current() != "releases/1.0.0" {
		t.Fatalf("arm64 install current -> %q", e.current())
	}
}

func TestInstallNeedsFlock(t *testing.T) {
	for _, dir := range []string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"} {
		if _, err := os.Stat(filepath.Join(dir, "flock")); err == nil {
			t.Skip("this host has flock outside the stub dir")
		}
	}
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	if err := os.Remove(filepath.Join(e.stubs, "flock")); err != nil {
		t.Fatal(err)
	}
	e.refuse("flock is missing. Install util-linux and rerun", filepath.Join(dir, "install.sh"), "--from", dir)
}

func TestInstallMissingPackagesNeedConsent(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	if err := os.Remove(e.path("usr/sbin/nft")); err != nil {
		t.Fatal(err)
	}
	e.stub("apt-get", `echo "apt-get $*" >>"$CLOUDGATEWAY_TEST_LOG"; [ "$1" != "$CLOUDGATEWAY_TEST_FAIL" ] || exit 1; if [ "$1" = install ]; then printf '#!/bin/sh\n' >"$CLOUDGATEWAY_INSTALL_TEST_ROOT/usr/sbin/nft"; chmod +x "$CLOUDGATEWAY_INSTALL_TEST_ROOT/usr/sbin/nft"; fi`)
	e.refuse("Install them with: apt-get update && apt-get install -y nftables", filepath.Join(dir, "install.sh"), "--from", dir)
	if log := e.takeLog(); strings.Contains(log, "apt-get") {
		t.Fatalf("installed packages without consent:\n%s", log)
	}

	e.env["CLOUDGATEWAY_TEST_FAIL"] = "update"
	e.refuse("apt-get update failed", filepath.Join(dir, "install.sh"), "--from", dir, "--yes")
	if log := e.takeLog(); strings.Contains(log, "apt-get install") {
		t.Fatalf("installed after a failed update:\n%s", log)
	}
	delete(e.env, "CLOUDGATEWAY_TEST_FAIL")

	e.install(dir, "--yes")
	if log := e.takeLog(); !strings.Contains(log, "apt-get update\napt-get install -y nftables\n") {
		t.Fatalf("package install log:\n%s", log)
	}
}

func TestInstallWarnsWithoutResolved(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.stub("resolvectl", "echo Global:")
	output := e.install(dir)
	if !strings.Contains(output, "warning: no network link has upstream DNS servers in systemd-resolved") {
		t.Fatalf("output:\n%s", output)
	}
}

func TestInstallDownloadsOverHTTPS(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	// The stub serves files from the release dir by URL basename
	e.stub("curl", `echo "curl $*" >>"$CLOUDGATEWAY_TEST_LOG"; while [ $# -gt 1 ]; do if [ "$1" = -o ]; then out="$2"; fi; shift; done; cp "`+dir+`/$(basename "$1")" "$out"`)
	output, err := e.run(filepath.Join(dir, "install.sh"))
	if err != nil {
		t.Fatalf("download install: %v\n%s", err, output)
	}
	log := e.takeLog()
	data, _ := os.ReadFile(filepath.Join(dir, release.ManifestName))
	manifest, _ := release.Parse(data)
	archive, _ := manifest.Archive("amd64")
	base := "https://github.com/Albro3459/CloudGateway/releases/download/linux-v1.0.0/"
	for asset, limit := range map[string]string{release.ManifestName: "65536", release.SignatureName: "64", archive.Path: strconv.FormatInt(archive.Size, 10)} {
		if !strings.Contains(log, "--proto =https --proto-redir =https --tlsv1.2 -fsSL --connect-timeout 30 --max-time 900 --max-filesize "+limit+" -o ") ||
			!strings.Contains(log, base+asset+"\n") {
			t.Errorf("no bounded HTTPS download of %s:\n%s", asset, log)
		}
	}
	if e.current() != "releases/1.0.0" {
		t.Fatalf("current -> %q", e.current())
	}
}

func mkdirAll(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, contents string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func TestUninstallRestoresAnInterruptedRepair(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.install(dir)
	// A same-version repair killed after moving the old release aside
	releases := e.path("opt/cloudgateway/releases")
	replaced := filepath.Join(releases, ".replaced.abc123")
	mkdirAll(t, replaced)
	if err := os.Rename(filepath.Join(releases, "1.0.0"), filepath.Join(replaced, "1.0.0")); err != nil {
		t.Fatal(err)
	}
	e.takeLog()

	if output, err := e.run(filepath.Join(dir, "install.sh"), "--uninstall"); err != nil {
		t.Fatalf("uninstall: %v\n%s", err, output)
	}

	if !strings.Contains(e.takeLog(), "cloudgatewayd 1.0.0 cleanup") {
		t.Fatal("uninstall skipped network cleanup")
	}
}

func TestUninstallRefusesWithoutADaemonWhileTheTunnelIsUp(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.install(dir)
	if err := os.RemoveAll(e.path("opt/cloudgateway/releases/1.0.0/bin")); err != nil {
		t.Fatal(err)
	}
	for name, leftover := range map[string]func(){
		"aliased link": func() {
			mkdirAll(t, e.path("sys/class/net/cloudgateway"))
			writeFile(t, e.path("sys/class/net/cloudgateway/ifalias"), "cloudgatewayd\n", 0o644)
		},
		"pending link": func() { mkdirAll(t, e.path("sys/class/net/cloudgw-pending")) },
		"nftables table": func() {
			writeFile(t, e.path("usr/sbin/nft"), "#!/bin/sh\n[ \"$4\" = cloudgateway_client ] && echo 'table inet cloudgateway_client {'\n", 0o755)
		},
	} {
		leftover()

		e.refuse("no cloudgatewayd is left", filepath.Join(dir, "install.sh"), "--uninstall")

		if !e.exists("etc/systemd/system/cloudgatewayd.service") {
			t.Fatalf("%s: uninstall removed files without cleaning up the network", name)
		}
		_ = os.RemoveAll(e.path("sys/class/net"))
		writeFile(t, e.path("usr/sbin/nft"), "#!/bin/sh\n", 0o755)
	}
}

func TestUninstallIgnoresAForeignLinkWithOurName(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	e.install(dir)
	if err := os.RemoveAll(e.path("opt/cloudgateway/releases/1.0.0/bin")); err != nil {
		t.Fatal(err)
	}
	// A wg-quick link the admin named cloudgateway, without the daemon's alias
	mkdirAll(t, e.path("sys/class/net/cloudgateway"))
	writeFile(t, e.path("sys/class/net/cloudgateway/ifalias"), "\n", 0o644)

	if output, err := e.run(filepath.Join(dir, "install.sh"), "--uninstall"); err != nil {
		t.Fatalf("uninstall: %v\n%s", err, output)
	}
	if e.exists("opt/cloudgateway") {
		t.Fatal("uninstall kept files")
	}
}

func TestUninstallFallsBackToTheHighestInstalledDaemon(t *testing.T) {
	e := newInstallEnv(t)
	e.install(e.release("1.9.0", 1))
	dir := e.release("1.10.0", 1)
	e.install(dir)
	// current points at a release that is gone
	if err := os.RemoveAll(e.path("opt/cloudgateway/releases/1.10.0")); err != nil {
		t.Fatal(err)
	}
	mkdirAll(t, e.path("opt/cloudgateway/releases/1.11.0/bin"))
	writeFile(t, e.path("opt/cloudgateway/releases/1.11.0/bin/cloudgatewayd"), "#!/bin/sh\n"+`echo "cloudgatewayd 1.11.0 $*" >>"$CLOUDGATEWAY_TEST_LOG"`+"\n", 0o755)
	e.takeLog()

	if output, err := e.run(filepath.Join(dir, "install.sh"), "--uninstall"); err != nil {
		t.Fatalf("uninstall: %v\n%s", err, output)
	}

	if log := e.takeLog(); !strings.Contains(log, "cloudgatewayd 1.11.0 cleanup") {
		t.Fatalf("log:\n%s", log)
	}
}

func TestStampedInstallerOnlyInstallsItsReleaseFromAFolder(t *testing.T) {
	e := newInstallEnv(t)
	newer := e.release("2.0.0", 1)
	older := e.release("1.0.0", 1)

	e.refuse("the manifest is for release 1.0.0, not 2.0.0", filepath.Join(newer, "install.sh"), "--from", older)
}

func TestResolverCheckReadsLongOutput(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	// Hosts with many veths print more than a pipe holds, and grep -q stops at the first match
	e.stub("resolvectl", `echo 'Link 2 (eth0): 10.0.0.2'; i=0; while [ $i -lt 20000 ]; do echo "Link $i (veth$i): fe80::1"; i=$((i+1)); done`)

	output := e.install(dir)

	if strings.Contains(output, "no network link has upstream DNS servers") {
		t.Fatalf("false resolver warning:\n%s", output)
	}
}
