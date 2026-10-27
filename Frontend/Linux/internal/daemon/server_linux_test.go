package daemon

import (
	"net"
	"os"
	"syscall"
	"testing"
)

func TestPeerCredentialsReadsSocketPeer(t *testing.T) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	conns := make([]*net.UnixConn, 2)
	for i, fd := range fds {
		file := os.NewFile(uintptr(fd), "socketpair")
		conn, err := net.FileConn(file)
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		conns[i] = conn.(*net.UnixConn)
	}
	peer, err := peerCredentials(conns[0])
	if err != nil {
		t.Fatal(err)
	}
	if peer != (Peer{UID: uint32(os.Getuid()), PID: int32(os.Getpid())}) {
		t.Fatalf("peer = %+v", peer)
	}
}
