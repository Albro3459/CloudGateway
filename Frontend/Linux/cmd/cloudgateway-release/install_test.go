package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
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
	env    map[string]string
}

func newInstallEnv(t *testing.T) *installEnv {
	t.Helper()
	for _, tool := range []string{"bash", "sha256sum", "tar", "cmp"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("installer tests need %s", tool)
		}
	}
	if os.Geteuid() == 0 {
		t.Skip("install.sh refuses its test root when run as root")
	}
	base := t.TempDir()
	e := &installEnv{
		t: t, base: base, root: filepath.Join(base, "root"), stubs: filepath.Join(base, "stubs"), log: filepath.Join(base, "log"),
		assets: filepath.Join(base, "assets"),
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
		"sleep":      logged,
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
	if err := packageRelease(fixtureParams(e.assets, version, storageVersion)); err != nil {
		e.t.Fatal(err)
	}
	return filepath.Join(e.assets, "linux-v"+version)
}

// rawAssets writes archive as release 1.0.0's amd64 build with an installer
// stamped for it, so tests can install archives the release tool never writes
func (e *installEnv) rawAssets(archive []byte) string {
	e.t.Helper()
	dir := e.t.TempDir()
	script, err := stampInstaller(install.Script, "1.0.0", 1, map[string][]byte{"amd64": archive, "arm64": archive})
	if err != nil {
		e.t.Fatal(err)
	}
	writeFile(e.t, filepath.Join(dir, "install.sh"), string(script), 0o644)
	writeFile(e.t, filepath.Join(dir, release.ArchiveName("1.0.0", "amd64")), string(archive), 0o644)
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
	for _, name := range []string{"bin/cloudgateway", "bin/cloudgatewayd", release.UnitName} {
		if !e.exists("opt/cloudgateway/releases/1.0.0/" + name) {
			t.Errorf("missing %s", name)
		}
	}
	if entries, _ := os.ReadDir(installed); len(entries) != 2 {
		t.Errorf("release holds %v", entries)
	}
	info, _ := os.Stat(filepath.Join(installed, "bin/cloudgatewayd"))
	if info.Mode().Perm() != 0o755 {
		t.Errorf("cloudgatewayd mode %v", info.Mode())
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

	// A damaged or missing file means the release is replaced
	unit := e.path("opt/cloudgateway/releases/1.0.0/" + release.UnitName)
	if err := os.Remove(unit); err != nil {
		t.Fatal(err)
	}
	e.install(dir)
	if repaired, _ := os.ReadFile(unit); !bytes.Equal(repaired, install.Unit) || e.exists("opt/cloudgateway/releases/1.0.0/marker") {
		t.Fatal("reinstall kept a release without its unit")
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
	e.refuse("does not match this installer's release", filepath.Join(dir, "install.sh"), "--from", dir)
	writeFile(t, archive, string(original)+"x", 0o644)
	e.refuse("is larger than expected", filepath.Join(dir, "install.sh"), "--from", dir)
	writeFile(t, archive, string(original), 0o644)

	// An installer from another build of the same version refuses this archive
	params := fixtureParams(t.TempDir(), "1.0.0", 1)
	params.binaries["amd64"]["bin/cloudgatewayd"] = []byte("rebuilt")
	if err := packageRelease(params); err != nil {
		t.Fatal(err)
	}
	e.refuse("does not match this installer's release", filepath.Join(params.outDir, "linux-v1.0.0", "install.sh"), "--from", dir)

	e.refuse("has no stamped release", filepath.Join("..", "..", "install", "install.sh"), "--from", dir)
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
		"extra file":    {append(append([]archiveEntry(nil), legit...), archiveEntry{name: "bin/extra", typeflag: tar.TypeReg, contents: "x"}), "does not hold exactly the release files"},
		"traversal":     {append(append([]archiveEntry(nil), legit...), archiveEntry{name: "../../escaped", typeflag: tar.TypeReg, contents: "x"}), "does not hold exactly the release files"},
		"absolute path": {append(append([]archiveEntry(nil), legit...), archiveEntry{name: escape, typeflag: tar.TypeReg, contents: "x"}), "does not hold exactly the release files"},
		"duplicate":     {append(append([]archiveEntry(nil), legit...), legit[1]), "does not hold exactly the release files"},
		"no dir entry":  {legit[1:], "does not hold exactly the release files"},
		"symlink":       {replace(1, archiveEntry{name: "bin/cloudgateway", typeflag: tar.TypeSymlink, link: escape}), "entries other than files and directories"},
		"dir symlink":   {replace(0, archiveEntry{name: "bin", typeflag: tar.TypeSymlink, link: e.base}), "does not hold exactly the release files"},
		// tar strips the leading / from link targets, so the link has nothing to point at
		"hardlink": {replace(2, archiveEntry{name: "bin/cloudgatewayd", typeflag: tar.TypeLink, link: escape}), "cannot extract"},
		"fifo":     {replace(3, archiveEntry{name: release.UnitName, typeflag: tar.TypeFifo}), "entries other than files and directories"},
		// mknod needs root, so tar fails here first. As root the find check refuses it
		"char device": {replace(3, archiveEntry{name: release.UnitName, typeflag: tar.TypeChar}), "cannot extract"},
	}
	writeFile(t, escape, "outside", 0o644)
	if dir := e.rawAssets(rawArchive(t, legit)); !strings.Contains(e.install(dir), "Installed CloudGateway 1.0.0") {
		t.Fatal("the legitimate raw archive did not install")
	}
	if err := os.RemoveAll(e.path("opt/cloudgateway")); err != nil {
		t.Fatal(err)
	}
	for name, c := range cases {
		dir := e.rawAssets(rawArchive(t, c.entries))
		output, err := e.run(filepath.Join(dir, "install.sh"), "--from", dir)
		if err == nil || !strings.Contains(output, c.want) {
			t.Errorf("%s: want failure containing %q, got %v:\n%s", name, c.want, err, output)
		}
		if contents, _ := os.ReadFile(escape); string(contents) != "outside" || e.exists("opt/cloudgateway/current") || e.exists("escaped") {
			t.Fatalf("%s: archive escaped the staging dir or installed", name)
		}
	}
}

func TestInstallFailsWhenTheDaemonDoesNotStayRunning(t *testing.T) {
	e := newInstallEnv(t)
	e.install(e.release("1.0.0", 1))
	e.install(e.release("1.0.1", 1))
	dir := e.release("1.0.2", 1)
	for name, systemctl := range map[string]string{
		// Each show reads a new invocation, as after an automatic restart
		"restarted": `if [ "$1" = show ]; then echo >>"$CLOUDGATEWAY_TEST_LOG.starts"; wc -l <"$CLOUDGATEWAY_TEST_LOG.starts"; fi`,
		"stopped":   `[ "$1" != is-active ]`,
	} {
		e.stub("systemctl", `echo "systemctl $*" >>"$CLOUDGATEWAY_TEST_LOG"; `+systemctl)
		output, err := e.run(filepath.Join(dir, "install.sh"), "--from", dir)
		if err == nil || !strings.Contains(output, "cloudgatewayd.service did not stay running") || strings.Contains(output, "Installed CloudGateway") {
			t.Fatalf("%s: %v\n%s", name, err, output)
		}
		if !e.exists("opt/cloudgateway/releases/1.0.0") || !e.exists("opt/cloudgateway/releases/1.0.1") {
			t.Fatalf("%s: a failed start pruned releases", name)
		}
	}
}

func TestInstallRefusesAnInstallDirOthersCanWrite(t *testing.T) {
	e := newInstallEnv(t)
	dir := e.release("1.0.0", 1)
	mkdirAll(t, e.path("opt/cloudgateway"))
	if err := os.Chmod(e.path("opt/cloudgateway"), 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(e.base, "target"), e.path("opt/cloudgateway/.lock")); err != nil {
		t.Fatal(err)
	}
	e.refuse("is writable by a user other than root", filepath.Join(dir, "install.sh"), "--from", dir)
	if e.exists("opt/cloudgateway/current") || e.exists("../target") {
		t.Fatal("install continued in a dir others can write")
	}
}

func TestInstallRefusesStorageDowngrade(t *testing.T) {
	e := newInstallEnv(t)
	older := e.release("1.0.0", 1)
	newer := e.release("1.0.1", 2)
	// Without state in the newer format, going back is safe
	e.install(newer)
	e.install(older)
	e.install(newer)
	mkdirAll(t, e.path("var/lib/cloudgateway"))
	writeFile(t, e.path("var/lib/cloudgateway/storage.json"), `{"storageVersion": 2}`, 0o600)
	e.refuse("release 1.0.0 reads storage format 1, but this machine already uses format 2", filepath.Join(older, "install.sh"), "--from", older)
	if e.current() != "releases/1.0.1" {
		t.Fatalf("current -> %q", e.current())
	}
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
	e.refuse("--purge needs --uninstall", script, "--purge")
	e.refuse("Usage:", script, "--version", "1.0.0")

	// An installer stamped without an amd64 build
	stamped, _ := os.ReadFile(script)
	armOnly := regexp.MustCompile(`\nAMD64_ARCHIVE_(SIZE|SHA256)="[^"]*"`).ReplaceAll(stamped, []byte("\nAMD64_ARCHIVE_$1=\"\""))
	armScript := filepath.Join(t.TempDir(), "install.sh")
	writeFile(t, armScript, string(armOnly), 0o644)
	e.refuse("release 1.0.0 has no amd64 build", armScript, "--from", dir)

	e.env["CLOUDGATEWAY_TEST_MACHINE"] = "aarch64"
	e.install(dir)
	if e.current() != "releases/1.0.0" {
		t.Fatalf("arm64 install current -> %q", e.current())
	}
	if daemon, _ := os.ReadFile(e.path("opt/cloudgateway/current/bin/cloudgatewayd")); !strings.Contains(string(daemon), "# arm64\n") {
		t.Fatalf("arm64 install holds %q", daemon)
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
	archive := release.ArchiveName("1.0.0", "amd64")
	info, _ := os.Stat(filepath.Join(dir, archive))
	if strings.Count(log, "curl ") != 1 ||
		!strings.Contains(log, "--proto =https --proto-redir =https --tlsv1.2 -fsSL --connect-timeout 30 --max-time 900 --max-filesize "+strconv.FormatInt(info.Size(), 10)+" -o ") ||
		!strings.Contains(log, "https://github.com/Albro3459/CloudGateway/releases/download/linux-v1.0.0/"+archive+"\n") {
		t.Errorf("no bounded HTTPS download of %s:\n%s", archive, log)
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

	e.refuse("cannot read "+older+"/cloudgateway-linux-2.0.0-amd64.tar.gz", filepath.Join(newer, "install.sh"), "--from", older)
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
