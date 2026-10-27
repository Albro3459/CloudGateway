package network

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strings"
	"time"
)

const (
	typeA    uint16 = 1
	typeNS   uint16 = 2
	typeAAAA uint16 = 28
	classIN  uint16 = 1
)

var errMalformedReply = errors.New("network: malformed DNS reply")

// buildQuery encodes one recursive question without EDNS
func buildQuery(id uint16, name string, qtype uint16) ([]byte, error) {
	msg := binary.BigEndian.AppendUint16(nil, id)
	// Recursion desired, one question
	msg = append(msg, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0)
	name = strings.TrimSuffix(name, ".")
	if len(name) > 253 {
		return nil, errors.New("network: DNS name too long")
	}
	if name != "" {
		for label := range strings.SplitSeq(name, ".") {
			if label == "" || len(label) > 63 {
				return nil, errors.New("network: invalid DNS name")
			}
			msg = append(msg, byte(len(label)))
			msg = append(msg, label...)
		}
	}
	msg = append(msg, 0)
	msg = binary.BigEndian.AppendUint16(msg, qtype)
	return binary.BigEndian.AppendUint16(msg, classIN), nil
}

// parseReply returns the answer records of qtype. CNAME records in the chain are skipped
func parseReply(msg []byte, id, qtype uint16) ([]netip.Addr, error) {
	if len(msg) < 12 {
		return nil, errMalformedReply
	}
	if binary.BigEndian.Uint16(msg) != id {
		return nil, errors.New("network: DNS reply ID mismatch")
	}
	flags := binary.BigEndian.Uint16(msg[2:])
	if flags&0x8000 == 0 {
		return nil, errMalformedReply
	}
	if code := flags & 0x000f; code != 0 {
		return nil, fmt.Errorf("network: DNS reply code %d", code)
	}
	questions := int(binary.BigEndian.Uint16(msg[4:]))
	answers := int(binary.BigEndian.Uint16(msg[6:]))
	offset := 12
	var err error
	for range questions {
		if offset, err = skipName(msg, offset); err != nil {
			return nil, err
		}
		offset += 4
	}
	var addrs []netip.Addr
	for range answers {
		if offset, err = skipName(msg, offset); err != nil {
			return nil, err
		}
		if offset+10 > len(msg) {
			return nil, errMalformedReply
		}
		recordType := binary.BigEndian.Uint16(msg[offset:])
		recordClass := binary.BigEndian.Uint16(msg[offset+2:])
		length := int(binary.BigEndian.Uint16(msg[offset+8:]))
		offset += 10
		if offset+length > len(msg) {
			return nil, errMalformedReply
		}
		if recordClass == classIN && recordType == qtype {
			addr, ok := netip.AddrFromSlice(msg[offset : offset+length])
			if ok && addr.Is4() == (qtype == typeA) {
				addrs = append(addrs, addr)
			}
		}
		offset += length
	}
	return addrs, nil
}

func skipName(msg []byte, offset int) (int, error) {
	for {
		if offset >= len(msg) {
			return 0, errMalformedReply
		}
		length := int(msg[offset])
		switch {
		case length == 0:
			return offset + 1, nil
		case length&0xc0 == 0xc0:
			if offset+2 > len(msg) {
				return 0, errMalformedReply
			}
			return offset + 2, nil
		case length&0xc0 != 0:
			return 0, errMalformedReply
		}
		offset += 1 + length
	}
}

// exchangeUDP sends one query on a connected socket and returns the first datagram back
func exchangeUDP(ctx context.Context, server netip.AddrPort, mark uint32, query []byte) ([]byte, error) {
	var dialer net.Dialer
	if mark != 0 {
		dialer.Control = markControl(mark)
	}
	conn, err := dialer.DialContext(ctx, "udp", server.String())
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.SetDeadline(time.Unix(1, 0)) })
	defer stop()
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}
	reply := make([]byte, 4096)
	n, err := conn.Read(reply)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	// The socket deadline can pass just before the context notices
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return nil, context.DeadlineExceeded
	}
	if err != nil {
		return nil, err
	}
	return reply[:n], nil
}
