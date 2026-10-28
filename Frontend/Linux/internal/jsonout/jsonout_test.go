package jsonout

import (
	"strings"
	"testing"
	"time"
)

func TestMarshalMatchesSwiftEncoderBytes(t *testing.T) {
	observed := time.Date(2027, 1, 15, 8, 0, 0, 999_000_000, time.UTC)
	cases := []struct {
		name  string
		value any
		want  string
	}{
		{"sorted keys and nulls", Object{"type": "result", "data": nil, "command": "list", "schemaVersion": 1},
			`{"command":"list","data":null,"schemaVersion":1,"type":"result"}`},
		{"nested arrays stay arrays", Object{"regions": []any{}, "flags": []string{"-h", "--help"}, "checks": []Object{}},
			`{"checks":[],"flags":["-h","--help"],"regions":[]}`},
		{"nil slices encode as empty arrays", Object{"notes": []string(nil), "configs": []any(nil)},
			`{"configs":[],"notes":[]}`},
		{"slashes and html stay raw", "https://example.com/a?b=<c>&d",
			`"https://example.com/a?b=<c>&d"`},
		{"line and paragraph separators stay raw", "a\u2028b\u2029c", "\"a\u2028b\u2029c\""},
		{"short escapes", "q\"b\\s\bf\fn\nr\rt\t", `"q\"b\\s\bf\fn\nr\rt\t"`},
		{"other controls use lowercase hex", "\x00\x01\x1b\x1f\x7f", "\"\\u0000\\u0001\\u001b\\u001f\x7f\""},
		{"C1 and format characters stay raw", "\u009b\u202e\u200b", "\"\u009b\u202e\u200b\""},
		{"invalid UTF-8 becomes replacement", "a\xffb", "\"a\ufffdb\""},
		{"dates use UTC whole seconds", observed, `"2027-01-15T08:00:00Z"`},
		{"dates convert to UTC", time.Date(2027, 1, 15, 3, 0, 0, 0, time.FixedZone("EST", -5*3600)), `"2027-01-15T08:00:00Z"`},
		{"dates before 1970 floor", time.Unix(-1, 500_000_000).UTC(), `"1969-12-31T23:59:59Z"`},
		{"booleans and ints", []any{true, false, 0, -1, 1 << 40}, `[true,false,0,-1,1099511627776]`},
	}
	for _, tc := range cases {
		got, err := Marshal(tc.value)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if string(got) != tc.want {
			t.Errorf("%s:\n got %s\nwant %s", tc.name, got, tc.want)
		}
	}
}

func TestMarshalRejectsUnsupportedValues(t *testing.T) {
	if _, err := Marshal(Object{"value": 1.5}); err == nil {
		t.Fatal("float accepted")
	}
}

// Captured from swift-foundation JSONEncoder with [.sortedKeys, .withoutEscapingSlashes] and .iso8601
func TestMarshalMatchesCapturedSwiftBytes(t *testing.T) {
	var value strings.Builder
	for r := rune(0); r < 0x20; r++ {
		value.WriteRune(r)
	}
	value.WriteString("\u007f\u0080\u009f\u2028\u2029/<>&\"\\\u00e9\U0001f600\u200b\ufeff")
	got, err := Marshal(Object{"a": value.String(), "B": "x", "configs": 1, "configId": 2, "date": time.Unix(1700000000, 987000000)})
	if err != nil {
		t.Fatal(err)
	}
	want := "{\"B\":\"x\",\"a\":\"\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001f\u007f\u0080\u009f\u2028\u2029/<>&\\\"\\\\\u00e9\U0001f600\u200b\ufeff\",\"configId\":2,\"configs\":1,\"date\":\"2023-11-14T22:13:20Z\"}"
	if string(got) != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}
