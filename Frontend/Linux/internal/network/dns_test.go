package network

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"runtime"
	"testing"
	"time"
)

func decodeHex(t *testing.T, text string) []byte {
	t.Helper()
	data, err := hex.DecodeString(text)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestBuildQuery(t *testing.T) {
	query, err := buildQuery(0x1234, "vpn.example.com.", typeA)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "A query", hex.EncodeToString(query), "123401000001000000000000"+"0376706e076578616d706c6503636f6d00"+"00010001")

	query, err = buildQuery(0, ".", typeNS)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "root NS query", hex.EncodeToString(query), "000001000001000000000000"+"00"+"00020001")

	for _, name := range []string{"bad..name", string(make([]byte, 64)) + ".example"} {
		if _, err := buildQuery(1, name, typeA); err == nil {
			t.Fatalf("encoded %q", name)
		}
	}
}

func TestParseReply(t *testing.T) {
	// vpn.example.com is a CNAME to edge.example.com, followed by its A record.
	// Both answer names use compression pointers
	data := decodeHex(t, "123481800001000200000000"+
		"0376706e076578616d706c6503636f6d0000010001"+
		"c00c000500010000012c00070465646765c010"+
		"c02d000100010000003c0004cb00710a")

	addrs, err := parseReply(data, 0x1234, typeA)

	if err != nil {
		t.Fatal(err)
	}
	expect(t, "addresses", fmt.Sprint(addrs), "[203.0.113.10]")
	if addrs, err := parseReply(data, 0x1234, typeAAAA); err != nil || len(addrs) != 0 {
		t.Fatalf("AAAA = %v, %v", addrs, err)
	}

	nxdomain := decodeHex(t, "123481830001000000000000"+"0376706e076578616d706c6503636f6d0000010001")
	if _, err := parseReply(nxdomain, 0x1234, typeA); err == nil || err.Error() != "network: DNS reply code 3" {
		t.Fatalf("NXDOMAIN err = %v", err)
	}
	if _, err := parseReply(data, 0x9999, typeA); err == nil {
		t.Fatal("accepted another ID")
	}
	if _, err := parseReply(data[:len(data)-3], 0x1234, typeA); !errors.Is(err, errMalformedReply) {
		t.Fatalf("truncated err = %v", err)
	}
	query := decodeHex(t, "123401000001000000000000"+"0376706e076578616d706c6503636f6d0000010001")
	if _, err := parseReply(query, 0x1234, typeA); !errors.Is(err, errMalformedReply) {
		t.Fatalf("query accepted as reply: %v", err)
	}
	badLabel := decodeHex(t, "123481800001000000000000"+"80")
	if _, err := parseReply(badLabel, 0x1234, typeA); !errors.Is(err, errMalformedReply) {
		t.Fatalf("bad label err = %v", err)
	}
}

func TestExchangeUDP(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	go func() {
		buffer := make([]byte, 512)
		n, from, err := conn.ReadFrom(buffer)
		if err == nil {
			_, _ = conn.WriteTo(answer(buffer[:n], serverAddr), from)
		}
	}()
	server := netip.MustParseAddrPort(conn.LocalAddr().String())
	query, _ := buildQuery(7, "vpn.example.com", typeA)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	data, err := exchangeUDP(ctx, server, 0, query)

	if err != nil {
		t.Fatal(err)
	}
	addrs, err := parseReply(data, 7, typeA)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, "addresses", fmt.Sprint(addrs), "[203.0.113.10]")

	if runtime.GOOS != "linux" {
		if _, err := exchangeUDP(ctx, server, FwMark, query); !errors.Is(err, errors.ErrUnsupported) {
			t.Fatalf("marked exchange err = %v", err)
		}
	}
}

func TestExchangeUDPStopsAtDeadline(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	query, _ := buildQuery(7, ".", typeNS)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	_, err = exchangeUDP(ctx, netip.MustParseAddrPort(conn.LocalAddr().String()), 0, query)

	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v", err)
	}
}

func TestWatchTicks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	signals, err := Watch(ctx, 10*time.Millisecond)

	if runtime.GOOS != "linux" && !errors.Is(err, errors.ErrUnsupported) {
		t.Fatalf("err = %v", err)
	}
	select {
	case <-signals:
	case <-time.After(time.Second):
		t.Fatal("no signal")
	}
}

func TestWatchAcceptsZeroInterval(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if _, err := Watch(ctx, 0); runtime.GOOS != "linux" && !errors.Is(err, errors.ErrUnsupported) {
		t.Fatalf("err = %v", err)
	}
}
