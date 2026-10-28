package ipc

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

var ErrMessageTooLarge = errors.New("ipc message too large")

// WriteMessage writes one length-prefixed JSON message
func WriteMessage(w io.Writer, value any, limit int) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(body) > limit {
		return ErrMessageTooLarge
	}
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame, uint32(len(body)))
	copy(frame[4:], body)
	_, err = w.Write(frame)
	return err
}

// ReadMessage reads one length-prefixed JSON message, rejecting frames over limit
func ReadMessage(r io.Reader, value any, limit int) error {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size > uint32(limit) {
		return ErrMessageTooLarge
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(r, body); err != nil {
		return err
	}
	return json.Unmarshal(body, value)
}

// Conn is one CLI connection to the daemon. Calls are sequential
type Conn struct {
	conn net.Conn
}

func Dial(ctx context.Context, path string) (*Conn, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, err
	}
	return &Conn{conn: conn}, nil
}

// Call sends one request and waits for its reply, bounded by ctx
func (c *Conn) Call(ctx context.Context, request Request) (Reply, error) {
	request.Version = Version
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Time{}
	}
	if err := c.conn.SetDeadline(deadline); err != nil {
		return Reply{}, err
	}
	stop := context.AfterFunc(ctx, func() { _ = c.conn.SetDeadline(time.Unix(1, 0)) })
	defer stop()
	if err := WriteMessage(c.conn, request, MaxRequestBytes); err != nil {
		return Reply{}, c.contextError(ctx, err)
	}
	var reply Reply
	if err := ReadMessage(c.conn, &reply, MaxReplyBytes); err != nil {
		return Reply{}, c.contextError(ctx, err)
	}
	return reply, nil
}

func (c *Conn) contextError(ctx context.Context, err error) error {
	if ctxErr := ctx.Err(); ctxErr != nil {
		return ctxErr
	}
	// The socket deadline can fire just before the context records it
	if _, ok := ctx.Deadline(); ok && errors.Is(err, os.ErrDeadlineExceeded) {
		return context.DeadlineExceeded
	}
	return fmt.Errorf("ipc call: %w", err)
}

func (c *Conn) Close() error { return c.conn.Close() }
