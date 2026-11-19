package main

// 时间：contract.mjs 的 utc 与 before（capture.jq 照它写的那一份），加上 jq 的 fromdateiso8601、todate 和 sh 的 date -u。

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

func nowISO() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

var utcPattern = regexp.MustCompile(`\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(Z|([+-])([0-9]{2}):([0-9]{2}))\z`)

func floorDiv(a, b int64) int64 {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

func daysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := floorDiv(y, 400)
	yoe := y - era*400
	mp := m + 9
	if m > 2 {
		mp = m - 3
	}
	doe := yoe*365 + yoe/4 - yoe/100 + (153*mp+2)/5 + d - 1
	return era*146097 + doe - 719468
}

func civilFromDays(z int64) (int64, int64, int64) {
	z += 719468
	era := floorDiv(z, 146097)
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	m := mp + 3
	if mp >= 10 {
		m = mp - 9
	}
	y := yoe + era*400
	if m <= 2 {
		y++
	}
	return y, m, doy - (153*mp+2)/5 + 1
}

func pad(n int64, width int) string {
	s := strconv.FormatInt(n, 10)
	if len(s) < width {
		s = strings.Repeat("0", width-len(s)) + s
	}
	return s
}

// Date#toISOString 到秒为止的那一段：0–9999 年写四位，之外写正负号加六位。
func isoSeconds(t int64) string {
	days := floorDiv(t, 86400)
	s := t - days*86400
	y, m, d := civilFromDays(days)
	var year string
	switch {
	case y >= 0 && y <= 9999:
		year = pad(y, 4)
	case y < 0:
		year = "-" + pad(-y, 6)
	default:
		year = "+" + pad(y, 6)
	}
	return year + "-" + pad(m, 2) + "-" + pad(d, 2) + "T" + pad(s/3600, 2) + ":" + pad(s%3600/60, 2) + ":" + pad(s%60, 2)
}

// utc：带时区的显式时刻换成 UTC；秒以下照原样保留全部位数，没有就补 .000。不合法返回 false。
func utc(v Value) (string, bool) {
	if v.k != kString {
		return "", false
	}
	c := utcPattern.FindStringSubmatch(v.s)
	if c == nil {
		return "", false
	}
	n := func(i int) int64 { x, _ := strconv.ParseInt(c[i], 10, 64); return x }
	y, mo, d, h, mi, s := n(1), n(2), n(3), n(4), n(5), n(6)
	var oh, om int64
	if c[8] != "Z" {
		oh, om = n(10), n(11)
	}
	leap := y%4 == 0 && (y%100 != 0 || y%400 == 0)
	month := [12]int64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if leap {
		month[1] = 29
	}
	if y < 1 || mo < 1 || mo > 12 || d < 1 || d > month[mo-1] || h > 23 || mi > 59 || s > 59 || oh > 23 || om > 59 {
		return "", false
	}
	sign := int64(1)
	if c[9] == "-" {
		sign = -1
	}
	frac := c[7]
	if frac == "" {
		frac = "000"
	}
	t := daysFromCivil(y, mo, d)*86400 + h*3600 + mi*60 + s - sign*(oh*3600+om*60)
	return first19(isoSeconds(t)) + "." + frac + "Z", true
}

func padRight(s string, w int) string {
	if len(s) < w {
		return s + strings.Repeat("0", w-len(s))
	}
	return s
}

// before：先比到秒为止的那一段，再比秒以下（短的补零）。两边都是 utc 的结果。
func before(a, b string) bool {
	if first19(a) != first19(b) {
		return first19(a) < first19(b)
	}
	x, y := runeSlice(a, 20, intp(-1)), runeSlice(b, 20, intp(-1))
	w := max(len(x), len(y))
	return padRight(x, w) < padRight(y, w)
}

// fromDate 是 jq 的 fromdateiso8601：只收 %Y-%m-%dT%H:%M:%SZ。
func fromDate(s string) (int64, bool) {
	t, err := time.Parse("2006-01-02T15:04:05Z", s)
	if err != nil {
		return 0, false
	}
	return t.Unix(), true
}

// toDate 是 jq 的 todate。
func toDate(t float64) string {
	return time.Unix(int64(floorF(t)), 0).UTC().Format("2006-01-02T15:04:05Z")
}

func floorF(f float64) float64 {
	i := float64(int64(f))
	if i > f {
		i--
	}
	return i
}
