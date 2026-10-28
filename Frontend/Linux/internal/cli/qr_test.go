package cli

import (
	"bytes"
	"slices"
	"strings"
	"testing"
)

func TestQRReedSolomonMatchesTheHelloWorldReference(t *testing.T) {
	// "HELLO WORLD" at 1-M from the ISO 18004 walkthrough
	data := []byte{32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17}
	want := []byte{196, 35, 39, 119, 235, 215, 231, 226, 93, 23}
	if got := qrRemainder(data, qrDivisor(10)); !bytes.Equal(got, want) {
		t.Fatalf("ecc %v, want %v", got, want)
	}
}

func TestQRFormatBitsMatchTheLevelMTable(t *testing.T) {
	want := []int{0b101010000010010, 0b101000100100101, 0b101111001111100, 0b101101101001011,
		0b100010111111001, 0b100000011001110, 0b100111110010111, 0b100101010100000}
	for mask, bits := range want {
		expectEqual(t, "mask", qrFormatBits(mask), bits)
	}
}

func TestQRPicksTheSmallestLevelMVersion(t *testing.T) {
	for _, tc := range []struct{ length, size int }{{14, 21}, {15, 25}, {84, 37}, {85, 41}, {213, 57}, {214, 61}} {
		matrix, err := encodeQR(strings.Repeat("a", tc.length))
		if err != nil {
			t.Fatal(err)
		}
		expectEqual(t, "size", len(matrix), tc.size)
	}
	if _, err := encodeQR(strings.Repeat("a", 2332)); err == nil {
		t.Fatal("oversized text encoded")
	}
}

// TestQRRoundTrip reads a symbol back with an independent reader: format bits, unmasking,
// codeword order, block deinterleaving, Reed-Solomon syndromes, and the byte-mode payload
func TestQRRoundTrip(t *testing.T) {
	for _, text := range []string{loginURL, "https://example.com/" + strings.Repeat("x", 300), "a"} {
		matrix, err := encodeQR(text)
		if err != nil {
			t.Fatal(err)
		}
		size := len(matrix)
		version := (size - 17) / 4
		reference := newQRSymbol(version)
		formatBits := 0
		for i := range 15 {
			// Second copy: bits 0-7 along row 8 from the right, 8-14 down column 8 at the bottom
			var dark bool
			if i < 8 {
				dark = matrix[8][size-1-i]
			} else {
				dark = matrix[size-15+i][8]
			}
			if dark {
				formatBits |= 1 << i
			}
		}
		mask := -1
		for candidate := range 8 {
			if qrFormatBits(candidate) == formatBits {
				mask = candidate
			}
		}
		if mask < 0 {
			t.Fatalf("format bits %015b match no level M mask", formatBits)
		}
		for _, center := range [][2]int{{3, 3}, {size - 4, 3}, {3, size - 4}} {
			if !matrix[center[1]][center[0]] || matrix[center[1]-2][center[0]] {
				t.Fatalf("finder pattern at %v", center)
			}
		}
		var stream []byte
		var current byte
		count := 0
		upward := true
		for right := size - 1; right >= 1; right, upward = right-2, !upward {
			if right == 6 {
				right--
			}
			for step := range size {
				y := step
				if upward {
					y = size - 1 - step
				}
				for _, x := range []int{right, right - 1} {
					if reference.isFunction[y][x] {
						continue
					}
					bit := matrix[y][x]
					if maskBit(mask, x, y) {
						bit = !bit
					}
					current <<= 1
					if bit {
						current |= 1
					}
					if count++; count%8 == 0 {
						stream = append(stream, current)
						current = 0
					}
				}
			}
		}
		raw := qrRawModules(version) / 8
		stream = stream[:raw]
		blocks, ecc := qrBlocks[version], qrECCodewordsPerBlock[version]
		shortBlocks := blocks - raw%blocks
		shortData := raw/blocks - ecc
		split := make([][]byte, blocks)
		k := 0
		for i := range shortData + 1 {
			for j := range blocks {
				if i < shortData || j >= shortBlocks {
					split[j] = append(split[j], stream[k])
					k++
				}
			}
		}
		for range ecc {
			for j := range blocks {
				split[j] = append(split[j], stream[k])
				k++
			}
		}
		var data []byte
		for j, block := range split {
			for power := range ecc {
				if syndrome(block, power) != 0 {
					t.Fatalf("block %d syndrome %d is nonzero", j, power)
				}
			}
			data = append(data, block[:len(block)-ecc]...)
		}
		if data[0]>>4 != 0b0100 {
			t.Fatalf("mode %04b", data[0]>>4)
		}
		var length int
		var payload []byte
		if version < 10 {
			length = int(data[0]&0xf)<<4 | int(data[1]>>4)
			for i := range length {
				payload = append(payload, data[1+i]<<4|data[2+i]>>4)
			}
		} else {
			length = int(data[0]&0xf)<<12 | int(data[1])<<4 | int(data[2]>>4)
			for i := range length {
				payload = append(payload, data[2+i]<<4|data[3+i]>>4)
			}
		}
		expectEqual(t, "payload", string(payload), text)
	}
}

func maskBit(mask, x, y int) bool {
	return []bool{(x+y)%2 == 0, y%2 == 0, x%3 == 0, (x+y)%3 == 0, (x/3+y/2)%2 == 0, x*y%2+x*y%3 == 0,
		(x*y%2+x*y%3)%2 == 0, ((x+y)%2+x*y%3)%2 == 0}[mask]
}

// syndrome evaluates the codeword polynomial at alpha^power with Horner's rule
func syndrome(block []byte, power int) byte {
	alpha := byte(1)
	for range power {
		alpha = qrMultiply(alpha, 2)
	}
	var result byte
	for _, b := range block {
		result = qrMultiply(result, alpha) ^ b
	}
	return result
}

func TestQRVersionInformationAppearsFromVersionSeven(t *testing.T) {
	matrix, err := encodeQR(strings.Repeat("a", 122))
	if err != nil {
		t.Fatal(err)
	}
	expectEqual(t, "size", len(matrix), 45)
	// Version 7 information is 000111110010010100, least significant bit first down the columns
	var bits []bool
	for i := range 18 {
		bits = append(bits, matrix[i/3][len(matrix)-11+i%3])
	}
	want := []bool{false, false, true, false, true, false, false, true, false, false, true, true, true, true, true, false, false, false}
	if !slices.Equal(bits, want) {
		t.Fatalf("version bits %v", bits)
	}
}
