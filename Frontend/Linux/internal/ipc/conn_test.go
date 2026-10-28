package ipc

import (
	"bytes"
	"context"
	"errors"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestMessageRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	request := Request{Version: Version, ID: "6f9619ff-8b86-d011-b42d-00cf4fc964ff", Action: ActionConnect, Identifier: "uid/us-sanjose-1/c1"}
	if err := WriteMessage(&buffer, request, MaxRequestBytes); err != nil {
		t.Fatal(err)
	}
	var decoded Request
	if err := ReadMessage(&buffer, &decoded, MaxRequestBytes); err != nil {
		t.Fatal(err)
	}
	if decoded != request {
		t.Fatalf("decoded %+v, want %+v", decoded, request)
	}
}

func TestOversizedFramesAreRejected(t *testing.T) {
	var buffer bytes.Buffer
	if err := WriteMessage(&buffer, Request{ClientName: string(make([]byte, 100))}, 64); !errors.Is(err, ErrMessageTooLarge) {
		t.Fatalf("write err = %v", err)
	}
	buffer.Reset()
	buffer.Write([]byte{0, 1, 0, 0})
	var request Request
	if err := ReadMessage(&buffer, &request, 1024); !errors.Is(err, ErrMessageTooLarge) {
		t.Fatalf("read err = %v", err)
	}
}

func TestCallStopsAtContextDeadline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request Request
		_ = ReadMessage(conn, &request, MaxRequestBytes)
		time.Sleep(time.Second)
	}()
	client, err := Dial(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := client.Call(ctx, Request{Action: ActionSnapshot}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want deadline", err)
	}
}

func TestUpdateOperationMapping(t *testing.T) {
	cases := map[UpdatePhase]Operation{
		UpdatePrepared:          {ID: "u", State: OperationAccepted},
		UpdateActivating:        {ID: "u", State: OperationRunning},
		UpdateCheckingReadiness: {ID: "u", State: OperationRunning},
		UpdateCompleted:         {ID: "u", State: OperationCompleted},
		UpdateFailed:            {ID: "u", State: OperationFailed, Failure: FailureCommandFailed},
		UpdateSuperseded:        {ID: "u", State: OperationUnknown, Failure: FailureOutcomeUnknown},
	}
	for phase, want := range cases {
		if got := (UpdateStatus{ID: "u", Phase: phase}).Operation(); got != want {
			t.Errorf("%s: got %+v, want %+v", phase, got, want)
		}
	}
}
