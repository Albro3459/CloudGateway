package cli

import (
	"errors"
	"strings"
)

// A minimal QR Code encoder: byte mode at error correction level M, matching
// the macOS CIQRCodeGenerator setting, with the smallest version that fits

var qrECCodewordsPerBlock = [41]int{0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
	26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28}

var qrBlocks = [41]int{0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25,
	26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49}

// Level M format bits are 00
const qrFormatLevel = 0

func qrRawModules(version int) int {
	result := (16*version+128)*version + 64
	if version >= 2 {
		aligns := version/7 + 2
		result -= (25*aligns-10)*aligns - 55
		if version >= 7 {
			result -= 36
		}
	}
	return result
}

func qrDataCodewords(version int) int {
	return qrRawModules(version)/8 - qrECCodewordsPerBlock[version]*qrBlocks[version]
}

func encodeQR(text string) ([][]bool, error) {
	data := []byte(text)
	version := 1
	for ; version <= 40; version++ {
		countBits := 8
		if version >= 10 {
			countBits = 16
		}
		if len(data) < 1<<countBits && 4+countBits+8*len(data) <= qrDataCodewords(version)*8 {
			break
		}
	}
	if version > 40 {
		return nil, errors.New("qr: text too long")
	}
	var bits qrBits
	bits.append(0b0100, 4)
	if version >= 10 {
		bits.append(len(data), 16)
	} else {
		bits.append(len(data), 8)
	}
	for _, b := range data {
		bits.append(int(b), 8)
	}
	capacity := qrDataCodewords(version) * 8
	bits.append(0, min(4, capacity-len(bits)))
	bits.append(0, (8-len(bits)%8)%8)
	codewords := make([]byte, 0, capacity/8)
	for i := 0; i < len(bits); i += 8 {
		var b byte
		for _, bit := range bits[i : i+8] {
			b = b<<1 | bit
		}
		codewords = append(codewords, b)
	}
	for pad := byte(0xEC); len(codewords) < capacity/8; pad ^= 0xEC ^ 0x11 {
		codewords = append(codewords, pad)
	}
	q := newQRSymbol(version)
	q.drawCodewords(qrInterleave(version, codewords))
	best, bestPenalty := 0, -1
	for mask := range 8 {
		q.applyMask(mask)
		q.drawFormat(mask)
		if penalty := q.penalty(); bestPenalty < 0 || penalty < bestPenalty {
			best, bestPenalty = mask, penalty
		}
		q.applyMask(mask)
	}
	q.applyMask(best)
	q.drawFormat(best)
	return q.modules, nil
}

type qrBits []byte

func (b *qrBits) append(value, count int) {
	for i := count - 1; i >= 0; i-- {
		*b = append(*b, byte(value>>i&1))
	}
}

func qrMultiply(x, y byte) byte {
	var z int
	for i := 7; i >= 0; i-- {
		z = z<<1 ^ (z>>7)*0x11D
		z ^= int(y>>i&1) * int(x)
	}
	return byte(z)
}

func qrDivisor(degree int) []byte {
	result := make([]byte, degree)
	result[degree-1] = 1
	root := byte(1)
	for range degree {
		for j := range result {
			result[j] = qrMultiply(result[j], root)
			if j+1 < len(result) {
				result[j] ^= result[j+1]
			}
		}
		root = qrMultiply(root, 2)
	}
	return result
}

func qrRemainder(data, divisor []byte) []byte {
	result := make([]byte, len(divisor))
	for _, b := range data {
		factor := b ^ result[0]
		copy(result, result[1:])
		result[len(result)-1] = 0
		for i, coefficient := range divisor {
			result[i] ^= qrMultiply(coefficient, factor)
		}
	}
	return result
}

// qrInterleave splits data into blocks, appends each block's error correction, and interleaves them
func qrInterleave(version int, data []byte) []byte {
	blocks, eccLength := qrBlocks[version], qrECCodewordsPerBlock[version]
	raw := qrRawModules(version) / 8
	shortBlocks := blocks - raw%blocks
	shortLength := raw / blocks
	divisor := qrDivisor(eccLength)
	var all [][]byte
	for i, k := 0, 0; i < blocks; i++ {
		length := shortLength - eccLength
		if i >= shortBlocks {
			length++
		}
		block := append([]byte(nil), data[k:k+length]...)
		k += length
		ecc := qrRemainder(block, divisor)
		if i < shortBlocks {
			block = append(block, 0)
		}
		all = append(all, append(block, ecc...))
	}
	result := make([]byte, 0, raw)
	for i := range all[0] {
		for j, block := range all {
			if i != shortLength-eccLength || j >= shortBlocks {
				result = append(result, block[i])
			}
		}
	}
	return result
}

type qrSymbol struct {
	size       int
	modules    [][]bool
	isFunction [][]bool
}

func newQRSymbol(version int) *qrSymbol {
	size := version*4 + 17
	q := &qrSymbol{size: size, modules: make([][]bool, size), isFunction: make([][]bool, size)}
	for i := range size {
		q.modules[i], q.isFunction[i] = make([]bool, size), make([]bool, size)
	}
	for i := range size {
		q.setFunction(6, i, i%2 == 0)
		q.setFunction(i, 6, i%2 == 0)
	}
	for _, center := range [][2]int{{3, 3}, {size - 4, 3}, {3, size - 4}} {
		for dy := -4; dy <= 4; dy++ {
			for dx := -4; dx <= 4; dx++ {
				x, y := center[0]+dx, center[1]+dy
				if x >= 0 && x < size && y >= 0 && y < size {
					distance := max(abs(dx), abs(dy))
					q.setFunction(x, y, distance != 2 && distance != 4)
				}
			}
		}
	}
	positions := qrAlignmentPositions(version)
	for i, x := range positions {
		for j, y := range positions {
			if (i == 0 && j == 0) || (i == 0 && j == len(positions)-1) || (i == len(positions)-1 && j == 0) {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					q.setFunction(x+dx, y+dy, max(abs(dx), abs(dy)) != 1)
				}
			}
		}
	}
	// Reserve the format area before data placement. The final mask redraws it
	q.drawFormat(0)
	if version >= 7 {
		remainder := version
		for range 12 {
			remainder = remainder<<1 ^ (remainder>>11)*0x1F25
		}
		bits := version<<12 | remainder
		for i := range 18 {
			dark := bits>>i&1 != 0
			a, b := size-11+i%3, i/3
			q.setFunction(a, b, dark)
			q.setFunction(b, a, dark)
		}
	}
	return q
}

func abs(value int) int { return max(value, -value) }

func qrAlignmentPositions(version int) []int {
	if version == 1 {
		return nil
	}
	count := version/7 + 2
	step := (version*8 + count*3 + 5) / (count*4 - 4) * 2
	result := make([]int, count)
	result[0] = 6
	for i, position := count-1, version*4+17-7; i >= 1; i, position = i-1, position-step {
		result[i] = position
	}
	return result
}

func (q *qrSymbol) setFunction(x, y int, dark bool) {
	q.modules[y][x] = dark
	q.isFunction[y][x] = true
}

func qrFormatBits(mask int) int {
	value := qrFormatLevel<<3 | mask
	remainder := value
	for range 10 {
		remainder = remainder<<1 ^ (remainder>>9)*0x537
	}
	return (value<<10 | remainder) ^ 0x5412
}

func (q *qrSymbol) drawFormat(mask int) {
	bits := qrFormatBits(mask)
	bit := func(i int) bool { return bits>>i&1 != 0 }
	for i := range 6 {
		q.setFunction(8, i, bit(i))
	}
	q.setFunction(8, 7, bit(6))
	q.setFunction(8, 8, bit(7))
	q.setFunction(7, 8, bit(8))
	for i := 9; i < 15; i++ {
		q.setFunction(14-i, 8, bit(i))
	}
	for i := range 8 {
		q.setFunction(q.size-1-i, 8, bit(i))
	}
	for i := 8; i < 15; i++ {
		q.setFunction(8, q.size-15+i, bit(i))
	}
	q.setFunction(8, q.size-8, true)
}

// drawCodewords places data bits in the two-column zigzag from the bottom right, skipping function modules
func (q *qrSymbol) drawCodewords(data []byte) {
	i := 0
	for right := q.size - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		for vertical := range q.size {
			for j := range 2 {
				x := right - j
				y := vertical
				if (right+1)&2 == 0 {
					y = q.size - 1 - vertical
				}
				if !q.isFunction[y][x] && i < len(data)*8 {
					q.modules[y][x] = data[i>>3]>>(7-i&7)&1 != 0
					i++
				}
			}
		}
	}
}

func (q *qrSymbol) applyMask(mask int) {
	for y := range q.size {
		for x := range q.size {
			var invert bool
			switch mask {
			case 0:
				invert = (x+y)%2 == 0
			case 1:
				invert = y%2 == 0
			case 2:
				invert = x%3 == 0
			case 3:
				invert = (x+y)%3 == 0
			case 4:
				invert = (x/3+y/2)%2 == 0
			case 5:
				invert = x*y%2+x*y%3 == 0
			case 6:
				invert = (x*y%2+x*y%3)%2 == 0
			case 7:
				invert = ((x+y)%2+x*y%3)%2 == 0
			}
			if invert && !q.isFunction[y][x] {
				q.modules[y][x] = !q.modules[y][x]
			}
		}
	}
}

// penalty scores runs, 2x2 blocks, finder-like patterns, and dark balance to pick a readable mask
func (q *qrSymbol) penalty() int {
	result := 0
	at := func(x, y int, transpose bool) bool {
		if transpose {
			return q.modules[x][y]
		}
		return q.modules[y][x]
	}
	finderLike := []bool{true, false, true, true, true, false, true}
	for _, transpose := range []bool{false, true} {
		for y := range q.size {
			run := 1
			for x := 1; x <= q.size; x++ {
				if x < q.size && at(x, y, transpose) == at(x-1, y, transpose) {
					run++
					continue
				}
				if run >= 5 {
					result += run - 2
				}
				run = 1
			}
			for x := 0; x+7 <= q.size; x++ {
				matches := true
				for k, dark := range finderLike {
					if at(x+k, y, transpose) != dark {
						matches = false
						break
					}
				}
				if !matches {
					continue
				}
				light := func(from, to int) bool {
					for k := from; k < to; k++ {
						if k >= 0 && k < q.size && at(k, y, transpose) {
							return false
						}
					}
					return true
				}
				if light(x-4, x) || light(x+7, x+11) {
					result += 40
				}
			}
		}
	}
	dark := 0
	for y := range q.size {
		for x := range q.size {
			if q.modules[y][x] {
				dark++
			}
			if x+1 < q.size && y+1 < q.size {
				color := q.modules[y][x]
				if color == q.modules[y][x+1] && color == q.modules[y+1][x] && color == q.modules[y+1][x+1] {
					result += 3
				}
			}
		}
	}
	total := q.size * q.size
	deviation := abs(dark*20 - total*10)
	result += (deviation + total - 1) / total * 10
	return result
}

// renderQR draws two module rows per text line with half blocks, inside a four-module quiet zone
func renderQR(matrix [][]bool, width int) string {
	count := len(matrix)
	if count < 21 || count > 177 || width < count+8 {
		return ""
	}
	for _, line := range matrix {
		if len(line) != count {
			return ""
		}
	}
	quiet := make([]bool, count+8)
	rows := [][]bool{quiet, quiet, quiet, quiet}
	for _, line := range matrix {
		padded := append(append(make([]bool, 4, count+8), line...), false, false, false, false)
		rows = append(rows, padded)
	}
	rows = append(rows, quiet, quiet, quiet, quiet)
	lines := make([]string, 0, (len(rows)+1)/2)
	for y := 0; y < len(rows); y += 2 {
		lower := quiet
		if y+1 < len(rows) {
			lower = rows[y+1]
		}
		var b strings.Builder
		for x, upper := range rows[y] {
			switch {
			case upper && lower[x]:
				b.WriteString("█")
			case upper:
				b.WriteString("▀")
			case lower[x]:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		lines = append(lines, b.String())
	}
	return "\x1b[30;47m" + strings.Join(lines, "\n") + "\x1b[0m\n"
}
