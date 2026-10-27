// Package jsonout writes compact JSON with the bytes Swift's JSONEncoder
// produces using sortedKeys, withoutEscapingSlashes, and iso8601 dates
//
// Go's encoding/json differs: it escapes <>& and U+2028/U+2029 and keeps
// struct field order, so public CLI records are built as explicit trees
package jsonout

import (
	"fmt"
	"slices"
	"strconv"
	"time"
	"unicode/utf8"
)

// Object is a JSON object. Absent keys are omitted, nil values encode as null
type Object map[string]any

// DateFormat matches Swift's .iso8601 date strategy: UTC, whole seconds
const DateFormat = "2006-01-02T15:04:05Z"

// Marshal accepts nil, bool, int, string, time.Time, Object, []any, []string, and []Object
func Marshal(value any) ([]byte, error) {
	return appendValue(nil, value)
}

func appendValue(b []byte, value any) ([]byte, error) {
	var err error
	switch value := value.(type) {
	case nil:
		return append(b, "null"...), nil
	case bool:
		return strconv.AppendBool(b, value), nil
	case int:
		return strconv.AppendInt(b, int64(value), 10), nil
	case string:
		return appendString(b, value), nil
	case time.Time:
		return appendString(b, value.UTC().Format(DateFormat)), nil
	case Object:
		// Swift's sortedKeys compares keys byte-wise, so B sorts before a
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		slices.Sort(keys)
		b = append(b, '{')
		for i, key := range keys {
			if i > 0 {
				b = append(b, ',')
			}
			b = appendString(b, key)
			b = append(b, ':')
			if b, err = appendValue(b, value[key]); err != nil {
				return nil, err
			}
		}
		return append(b, '}'), nil
	case []any:
		return appendArray(b, value)
	case []string:
		return appendArray(b, value)
	case []Object:
		return appendArray(b, value)
	}
	return nil, fmt.Errorf("jsonout: unsupported value %T", value)
}

func appendArray[T any](b []byte, values []T) ([]byte, error) {
	var err error
	b = append(b, '[')
	for i, value := range values {
		if i > 0 {
			b = append(b, ',')
		}
		if b, err = appendValue(b, value); err != nil {
			return nil, err
		}
	}
	return append(b, ']'), nil
}

const hex = "0123456789abcdef"

// Swift writes short escapes for quote, backslash, and \b\f\n\r\t, lowercase
// \u00XX for other C0 controls, and every other scalar raw
func appendString(b []byte, s string) []byte {
	b = append(b, '"')
	for _, r := range s {
		switch r {
		case '"':
			b = append(b, `\"`...)
		case '\\':
			b = append(b, `\\`...)
		case '\b':
			b = append(b, `\b`...)
		case '\f':
			b = append(b, `\f`...)
		case '\n':
			b = append(b, `\n`...)
		case '\r':
			b = append(b, `\r`...)
		case '\t':
			b = append(b, `\t`...)
		default:
			if r < 0x20 {
				b = append(b, '\\', 'u', '0', '0', hex[r>>4], hex[r&0xf])
			} else {
				// Invalid UTF-8 decodes to U+FFFD, as Swift repairs it when decoding text
				b = utf8.AppendRune(b, r)
			}
		}
	}
	return append(b, '"')
}
