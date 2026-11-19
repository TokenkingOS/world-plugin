package main

// JSON 值，按 0.1.6 的 capture.sh 用的 jq 1.7.1（macOS 自带的 jq-1.7.1-apple）的语义：对象保留键的插入顺序，重复的键后者覆盖、
// 位置留在第一次出现处；读进来的数字记下原文，原样写出时按 decNumber 的规则规范化（1e2 写成 1E+2，1.50 不变）；算出来的数字按 jq 的
// 最短往返写法（1e+17、0.1）。写出用 jq -c 的转义（0x7F 写成 \u007f，非 ASCII 原样）。会话文件的一行另有严格的读法（JSON.parse），
// 版本串另有 JSON.stringify 的写法：见 parseJS 与 jsString。

import (
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

type kind byte

const (
	kNull kind = iota
	kFalse
	kTrue
	kNumber
	kString
	kArray
	kObject
)

type Value struct {
	k   kind
	s   string // 字符串；数字的原文（已规范化），算出来的数字为空
	f   float64
	arr []Value
	obj *object
}

type object struct {
	keys []string
	m    map[string]Value
}

var (
	Null  = Value{k: kNull}
	False = Value{k: kFalse}
	True  = Value{k: kTrue}
)

func Bool(b bool) Value {
	if b {
		return True
	}
	return False
}
func Str(s string) Value       { return Value{k: kString, s: s} }
func Num(f float64) Value      { return Value{k: kNumber, f: f} }
func Int(n int64) Value        { return Value{k: kNumber, f: float64(n)} }
func Arr(items ...Value) Value { return Value{k: kArray, arr: append([]Value{}, items...)} }
func ArrOf(items []Value) Value {
	if items == nil {
		items = []Value{}
	}
	return Value{k: kArray, arr: items}
}

// Obj 按给出的顺序建对象：Obj("a", x, "b", y)。
func Obj(pairs ...any) Value {
	o := &object{m: make(map[string]Value, len(pairs)/2)}
	for i := 0; i+1 < len(pairs); i += 2 {
		o.put(pairs[i].(string), pairs[i+1].(Value))
	}
	return Value{k: kObject, obj: o}
}

func (o *object) put(key string, v Value) {
	if _, ok := o.m[key]; !ok {
		o.keys = append(o.keys, key)
	}
	o.m[key] = v
}

func (v Value) IsNull() bool   { return v.k == kNull }
func (v Value) IsString() bool { return v.k == kString }
func (v Value) IsNumber() bool { return v.k == kNumber }
func (v Value) IsArray() bool  { return v.k == kArray }
func (v Value) IsObject() bool { return v.k == kObject }
func (v Value) IsBool() bool   { return v.k == kTrue || v.k == kFalse }

// Truthy 是 jq 的真假：只有 null 和 false 为假。
func (v Value) Truthy() bool { return v.k != kNull && v.k != kFalse }

func (v Value) Keys() []string {
	if v.k != kObject {
		return nil
	}
	return v.obj.keys
}

// Lookup 只看对象里有没有这个键。
func (v Value) Lookup(key string) (Value, bool) {
	if v.k != kObject {
		return Null, false
	}
	x, ok := v.obj.m[key]
	return x, ok
}

// With 返回加上（或改掉）一个键的新对象；已有的键留在原位。v 不是对象时当作空对象。
func (v Value) With(key string, x Value) Value {
	o := &object{m: make(map[string]Value)}
	if v.k == kObject {
		o.keys = append([]string{}, v.obj.keys...)
		for k, val := range v.obj.m {
			o.m[k] = val
		}
	}
	o.put(key, x)
	return Value{k: kObject, obj: o}
}

// Without 返回删掉这些键的新对象（jq 的 del）。
func (v Value) Without(keys ...string) Value {
	if v.k != kObject {
		return v
	}
	drop := map[string]bool{}
	for _, k := range keys {
		drop[k] = true
	}
	o := &object{m: make(map[string]Value)}
	for _, k := range v.obj.keys {
		if !drop[k] {
			o.put(k, v.obj.m[k])
		}
	}
	return Value{k: kObject, obj: o}
}

// Merge 是 jq 的对象加法：右边的键覆盖左边的，左边已有的键留在原位。
func (v Value) Merge(x Value) Value {
	out := v
	for _, k := range x.Keys() {
		out = out.With(k, x.obj.m[k])
	}
	if out.k != kObject {
		return Obj()
	}
	return out
}

// ---------- 写出：jq -c ----------

func (v Value) JSON() string {
	var b strings.Builder
	v.dump(&b)
	return b.String()
}

func (v Value) dump(b *strings.Builder) {
	switch v.k {
	case kNull:
		b.WriteString("null")
	case kFalse:
		b.WriteString("false")
	case kTrue:
		b.WriteString("true")
	case kNumber:
		b.WriteString(v.numberText())
	case kString:
		jqQuote(b, v.s)
	case kArray:
		b.WriteByte('[')
		for i, x := range v.arr {
			if i > 0 {
				b.WriteByte(',')
			}
			x.dump(b)
		}
		b.WriteByte(']')
	case kObject:
		b.WriteByte('{')
		for i, k := range v.obj.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			jqQuote(b, k)
			b.WriteByte(':')
			v.obj.m[k].dump(b)
		}
		b.WriteByte('}')
	}
}

func (v Value) numberText() string {
	if math.IsNaN(v.f) {
		return "null"
	}
	if v.s != "" {
		return v.s
	}
	return jqNumber(v.f)
}

const hexDigits = "0123456789abcdef"

// jq 的字符串转义：" \ 与 \b \f \n \r \t 用短转义，其余 0x00–0x1F 和 0x7F 写成 \u00xx，别的原样。
// 孤立代理项（只会来自会话文件的 \u 转义）jq 里存不下，写成 U+FFFD。
func jqQuote(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			switch c {
			case '"':
				b.WriteString(`\"`)
			case '\\':
				b.WriteString(`\\`)
			case '\b':
				b.WriteString(`\b`)
			case '\f':
				b.WriteString(`\f`)
			case '\n':
				b.WriteString(`\n`)
			case '\r':
				b.WriteString(`\r`)
			case '\t':
				b.WriteString(`\t`)
			default:
				if c < 0x20 || c == 0x7f {
					b.WriteString(`\u00`)
					b.WriteByte(hexDigits[c>>4])
					b.WriteByte(hexDigits[c&15])
				} else {
					b.WriteByte(c)
				}
			}
			i++
			continue
		}
		if _, n, ok := surrogateAt(s, i); ok {
			b.WriteString("\uFFFD")
			i += n
			continue
		}
		r, n := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && n == 1 {
			b.WriteString("\uFFFD")
		} else {
			b.WriteString(s[i : i+n])
		}
		i += n
	}
	b.WriteByte('"')
}

// jsString 是 JSON.stringify(string)：" \ 与 \b \f \n \r \t 用短转义，其余 0x00–0x1F 写成小写 \u00xx，孤立代理项写成 \udxxx，
// 别的（含 0x7F、U+2028、< > &）原样。版本串 JSON.stringify([role, text, reported_at]) 用它拼。
func jsString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			switch c {
			case '"':
				b.WriteString(`\"`)
			case '\\':
				b.WriteString(`\\`)
			case '\b':
				b.WriteString(`\b`)
			case '\f':
				b.WriteString(`\f`)
			case '\n':
				b.WriteString(`\n`)
			case '\r':
				b.WriteString(`\r`)
			case '\t':
				b.WriteString(`\t`)
			default:
				if c < 0x20 {
					b.WriteString(`\u00`)
					b.WriteByte(hexDigits[c>>4])
					b.WriteByte(hexDigits[c&15])
				} else {
					b.WriteByte(c)
				}
			}
			i++
			continue
		}
		if u, n, ok := surrogateAt(s, i); ok {
			b.WriteString(`\u`)
			for shift := 12; shift >= 0; shift -= 4 {
				b.WriteByte(hexDigits[(u>>shift)&15])
			}
			i += n
			continue
		}
		_, n := utf8.DecodeRuneInString(s[i:])
		b.WriteString(s[i : i+n])
		i += n
	}
	b.WriteByte('"')
}

// 字符串里的孤立代理项按 WTF-8 存（ED A0–BF xx）。
func surrogateAt(s string, i int) (rune, int, bool) {
	if i+2 < len(s) && s[i] == 0xED && s[i+1] >= 0xA0 && s[i+1] <= 0xBF && s[i+2] >= 0x80 && s[i+2] <= 0xBF {
		return 0xD000 | rune(s[i+1]&0x3F)<<6 | rune(s[i+2]&0x3F), 3, true
	}
	return 0, 0, false
}

func hasSurrogate(s string) bool {
	for i := 0; i+2 < len(s); i++ {
		if _, _, ok := surrogateAt(s, i); ok {
			return true
		}
	}
	return false
}

// wellFormedBytes 是 Node 把字符串编成 UTF-8 时的字节：孤立代理项换成 U+FFFD（sha256 的输入）。
func wellFormedBytes(s string) []byte {
	if !hasSurrogate(s) {
		return []byte(s)
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		if _, n, ok := surrogateAt(s, i); ok {
			b.WriteString("\uFFFD")
			i += n
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return []byte(b.String())
}

// jq 算出来的数字的写法：最短往返的有效数字，小数点位置 decpt <= -4 或 decpt > 位数+15 时写成 1e+17、1e-05 这样的指数形式。
func jqNumber(f float64) string {
	if math.IsInf(f, 1) {
		f = math.MaxFloat64
	} else if math.IsInf(f, -1) {
		f = -math.MaxFloat64
	}
	if f == 0 {
		if math.Signbit(f) {
			return "-0"
		}
		return "0"
	}
	sign := ""
	if f < 0 {
		sign, f = "-", -f
	}
	digits, decpt := shortest(f)
	n := len(digits)
	if decpt <= -4 || decpt > n+15 {
		e := decpt - 1
		es := "+"
		if e < 0 {
			es, e = "-", -e
		}
		exp := strconv.Itoa(e)
		if len(exp) < 2 {
			exp = "0" + exp
		}
		mant := digits[:1]
		if n > 1 {
			mant += "." + digits[1:]
		}
		return sign + mant + "e" + es + exp
	}
	return sign + placeDigits(digits, decpt)
}

// jsNumber 是 JS 的 String(number)，条目 id 里的数字照库的模板字符串写。
func jsNumber(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	case f == 0:
		return "0"
	}
	sign := ""
	if f < 0 {
		sign, f = "-", -f
	}
	digits, n := shortest(f)
	k := len(digits)
	if n >= -5 && n <= 21 {
		return sign + placeDigits(digits, n)
	}
	e := n - 1
	es := "+"
	if e < 0 {
		es, e = "-", -e
	}
	mant := digits[:1]
	if k > 1 {
		mant += "." + digits[1:]
	}
	return sign + mant + "e" + es + strconv.Itoa(e)
}

// 最短往返的有效数字和小数点位置（数值 = 0.digits × 10^decpt）。
func shortest(f float64) (string, int) {
	s := strconv.FormatFloat(f, 'e', -1, 64)
	mant, exp, _ := strings.Cut(s, "e")
	e, _ := strconv.Atoi(exp)
	return strings.Replace(mant, ".", "", 1), e + 1
}

func placeDigits(digits string, decpt int) string {
	n := len(digits)
	switch {
	case decpt <= 0:
		return "0." + strings.Repeat("0", -decpt) + digits
	case decpt >= n:
		return digits + strings.Repeat("0", decpt-n)
	default:
		return digits[:decpt] + "." + digits[decpt:]
	}
}

// decCanonical 是 jq 1.7.1 原样写出读进来的数字时的写法（decNumber 的 to-scientific-string）。tok 已按 jq 的读法核过。
func decCanonical(tok string) string {
	sign := ""
	if tok[0] == '-' || tok[0] == '+' {
		if tok[0] == '-' {
			sign = "-"
		}
		tok = tok[1:]
	}
	mant, exp := tok, 0
	if i := strings.IndexAny(tok, "eE"); i >= 0 {
		mant = tok[:i]
		e, err := strconv.Atoi(tok[i+1:])
		if err != nil {
			return ""
		}
		exp = e
	}
	intPart, frac, _ := strings.Cut(mant, ".")
	coef := strings.TrimLeft(intPart+frac, "0")
	if coef == "" {
		coef = "0"
	}
	exp -= len(frac)
	adjusted := exp + len(coef) - 1
	if exp <= 0 && adjusted >= -6 {
		if exp == 0 {
			return sign + coef
		}
		if len(coef) > -exp {
			return sign + coef[:len(coef)+exp] + "." + coef[len(coef)+exp:]
		}
		return sign + "0." + strings.Repeat("0", -exp-len(coef)) + coef
	}
	out := coef[:1]
	if len(coef) > 1 {
		out += "." + coef[1:]
	}
	if adjusted >= 0 {
		return sign + out + "E+" + strconv.Itoa(adjusted)
	}
	return sign + out + "E" + strconv.Itoa(adjusted)
}

// ---------- 读入 ----------

type parser struct {
	b     []byte
	i     int
	js    bool // JSON.parse 的读法（会话文件的一行）；否则是 jq 的读法
	bad   bool
	depth int // jq 的解析栈：开着的数组占 1 格，开着的对象占 1 格、读它的一个值时再占 1 格
}

// jq 1.7.1 开一个数组或对象时栈里已有 256 格就报 Exceeds depth limit（实测：256 层数组读得出，129 层对象读不出）。
// JSON.parse 没有这个上限，会话文件的一行照它读。
const jqMaxDepth = 256

func (p *parser) open() bool {
	if !p.js && p.depth >= jqMaxDepth {
		p.bad = true
		return false
	}
	p.depth++
	return true
}

// parseJS：一行会话记录，照 JSON.parse：严格的数字和字面量，孤立代理项的 \u 转义原样留下。整段只能有一个值。
func parseJS(b []byte) (Value, bool) {
	p := &parser{b: b, js: true}
	p.ws()
	v := p.value()
	p.ws()
	if p.bad || p.i != len(p.b) {
		return Null, false
	}
	return v, true
}

// parseJQ：jq 读文件、--slurpfile、stdin 的读法：一串值；开头一个 BOM 跳过；UTF-8 不合法的字节换成 U+FFFD；
// 数字收 01、1.、.5、nan、Infinity 这类写法；孤立的低代理项换成 U+FFFD，孤立的高代理项读不出。
func parseJQ(b []byte) ([]Value, bool) {
	p := &parser{b: jqValidUTF8(b)}
	if len(p.b) >= 3 && p.b[0] == 0xEF && p.b[1] == 0xBB && p.b[2] == 0xBF {
		p.i = 3
	}
	var out []Value
	for {
		p.ws()
		if p.i == len(p.b) {
			return out, true
		}
		v := p.value()
		if p.bad {
			return nil, false
		}
		out = append(out, v)
	}
}

// fromJSON 是 jq 的 fromjson：恰好一个值，空串和只有空白的串都读不出。
func fromJSON(s string) (Value, bool) {
	vs, ok := parseJQ([]byte(s))
	if !ok || len(vs) != 1 {
		return Null, false
	}
	return vs[0], true
}

func (p *parser) ws() {
	for p.i < len(p.b) {
		switch p.b[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i++
		default:
			return
		}
	}
}

func (p *parser) fail() Value { p.bad = true; return Null }

func (p *parser) value() Value {
	if p.bad || p.i >= len(p.b) {
		return p.fail()
	}
	switch c := p.b[p.i]; c {
	case '{':
		if !p.open() {
			return Null
		}
		defer func() { p.depth-- }()
		p.i++
		o := &object{m: map[string]Value{}}
		p.ws()
		if p.i < len(p.b) && p.b[p.i] == '}' {
			p.i++
			return Value{k: kObject, obj: o}
		}
		for {
			p.ws()
			if p.i >= len(p.b) || p.b[p.i] != '"' {
				return p.fail()
			}
			key, ok := p.str()
			if !ok {
				return p.fail()
			}
			p.ws()
			if p.i >= len(p.b) || p.b[p.i] != ':' {
				return p.fail()
			}
			p.i++
			p.ws()
			p.depth++
			v := p.value()
			p.depth--
			if p.bad {
				return Null
			}
			o.put(key, v)
			p.ws()
			if p.i >= len(p.b) {
				return p.fail()
			}
			if p.b[p.i] == ',' {
				p.i++
				continue
			}
			if p.b[p.i] == '}' {
				p.i++
				return Value{k: kObject, obj: o}
			}
			return p.fail()
		}
	case '[':
		if !p.open() {
			return Null
		}
		defer func() { p.depth-- }()
		p.i++
		items := []Value{}
		p.ws()
		if p.i < len(p.b) && p.b[p.i] == ']' {
			p.i++
			return ArrOf(items)
		}
		for {
			p.ws()
			v := p.value()
			if p.bad {
				return Null
			}
			items = append(items, v)
			p.ws()
			if p.i >= len(p.b) {
				return p.fail()
			}
			if p.b[p.i] == ',' {
				p.i++
				continue
			}
			if p.b[p.i] == ']' {
				p.i++
				return ArrOf(items)
			}
			return p.fail()
		}
	case '"':
		s, ok := p.str()
		if !ok {
			return p.fail()
		}
		return Str(s)
	default:
		return p.literal()
	}
}

func (p *parser) literal() Value {
	start := p.i
	for p.i < len(p.b) {
		c := p.b[p.i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '[' || c == ']' || c == '{' || c == '}' || c == ',' || c == ':' || c == '"' {
			break
		}
		p.i++
	}
	tok := string(p.b[start:p.i])
	switch tok {
	case "true":
		return True
	case "false":
		return False
	case "null":
		return Null
	}
	if p.js {
		if !strictNumber(tok) {
			return p.fail()
		}
		f, _ := strconv.ParseFloat(tok, 64)
		return Value{k: kNumber, f: f, s: tok}
	}
	if tok == "nan" {
		return Value{k: kNumber, f: math.NaN()}
	}
	return p.jqNumberToken(tok)
}

// jq 1.7.1 的数字：decNumber 收的写法。
func (p *parser) jqNumberToken(tok string) Value {
	body := tok
	neg := false
	if body != "" && (body[0] == '-' || body[0] == '+') {
		neg = body[0] == '-'
		body = body[1:]
	}
	switch strings.ToLower(body) {
	case "inf", "infinity":
		if neg {
			return Num(math.Inf(-1))
		}
		return Num(math.Inf(1))
	case "nan", "snan":
		return Value{k: kNumber, f: math.NaN()}
	}
	digits, dot, i := 0, false, 0
	for ; i < len(body); i++ {
		c := body[i]
		if c >= '0' && c <= '9' {
			digits++
		} else if c == '.' && !dot {
			dot = true
		} else {
			break
		}
	}
	if digits == 0 {
		return p.fail()
	}
	if i < len(body) {
		if body[i] != 'e' && body[i] != 'E' {
			return p.fail()
		}
		j := i + 1
		if j < len(body) && (body[j] == '+' || body[j] == '-') {
			j++
		}
		if j == len(body) {
			return p.fail()
		}
		for ; j < len(body); j++ {
			if body[j] < '0' || body[j] > '9' {
				return p.fail()
			}
		}
	}
	f, err := strconv.ParseFloat(tok, 64)
	if err != nil && !strings.Contains(err.Error(), "range") {
		if strings.HasPrefix(tok, "+") {
			f, _ = strconv.ParseFloat(tok[1:], 64)
		}
	}
	return Value{k: kNumber, f: f, s: decCanonical(tok)}
}

func strictNumber(t string) bool {
	i := 0
	if i < len(t) && t[i] == '-' {
		i++
	}
	if i >= len(t) {
		return false
	}
	if t[i] == '0' {
		i++
	} else if t[i] >= '1' && t[i] <= '9' {
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {
			i++
		}
	} else {
		return false
	}
	if i < len(t) && t[i] == '.' {
		i++
		j := i
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {
			i++
		}
		if i == j {
			return false
		}
	}
	if i < len(t) && (t[i] == 'e' || t[i] == 'E') {
		i++
		if i < len(t) && (t[i] == '+' || t[i] == '-') {
			i++
		}
		j := i
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {
			i++
		}
		if i == j {
			return false
		}
	}
	return i == len(t)
}

func (p *parser) hex4(at int) (rune, bool) {
	if at+4 > len(p.b) {
		return 0, false
	}
	var r rune
	for _, c := range p.b[at : at+4] {
		r <<= 4
		switch {
		case c >= '0' && c <= '9':
			r |= rune(c - '0')
		case c >= 'a' && c <= 'f':
			r |= rune(c-'a') + 10
		case c >= 'A' && c <= 'F':
			r |= rune(c-'A') + 10
		default:
			return 0, false
		}
	}
	return r, true
}

func (p *parser) str() (string, bool) {
	p.i++ // 开头的引号
	var b strings.Builder
	for {
		if p.i >= len(p.b) {
			return "", false
		}
		c := p.b[p.i]
		switch {
		case c == '"':
			p.i++
			return b.String(), true
		case c < 0x20:
			return "", false
		case c != '\\':
			b.WriteByte(c)
			p.i++
			continue
		}
		if p.i+1 >= len(p.b) {
			return "", false
		}
		e := p.b[p.i+1]
		p.i += 2
		switch e {
		case '"', '\\', '/':
			b.WriteByte(e)
		case 'b':
			b.WriteByte('\b')
		case 'f':
			b.WriteByte('\f')
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		case 'u':
			r, ok := p.hex4(p.i)
			if !ok {
				return "", false
			}
			p.i += 4
			if r >= 0xD800 && r <= 0xDBFF {
				if p.i+1 < len(p.b) && p.b[p.i] == '\\' && p.b[p.i+1] == 'u' {
					if lo, ok := p.hex4(p.i + 2); ok && lo >= 0xDC00 && lo <= 0xDFFF {
						p.i += 6
						b.WriteRune(0x10000 + (r-0xD800)<<10 + (lo - 0xDC00))
						continue
					}
				}
				if !p.js {
					return "", false
				}
				writeSurrogate(&b, r)
				continue
			}
			if r >= 0xDC00 && r <= 0xDFFF {
				if !p.js {
					b.WriteString("\uFFFD")
				} else {
					writeSurrogate(&b, r)
				}
				continue
			}
			b.WriteRune(r)
		default:
			return "", false
		}
	}
}

func writeSurrogate(b *strings.Builder, r rune) {
	b.WriteByte(0xED)
	b.WriteByte(byte(0x80 | (r>>6)&0x3F))
	b.WriteByte(byte(0x80 | r&0x3F))
}

// jqValidUTF8 照 jq 的 jvp_utf8_next 把不合法的 UTF-8 换成 U+FFFD：一个不能开头的字节换一个；开头字节后面的续字节不够，
// 已读的那几个字节合起来换一个；过长编码、代理项、超过 U+10FFFF 的整段换一个。
func jqValidUTF8(b []byte) []byte {
	if utf8.Valid(b) {
		return b
	}
	out := make([]byte, 0, len(b)+16)
	for i := 0; i < len(b); {
		c := b[i]
		if c < 0x80 {
			out = append(out, c)
			i++
			continue
		}
		length := 0
		switch {
		case c >= 0xC0 && c <= 0xDF:
			length = 2
		case c >= 0xE0 && c <= 0xEF:
			length = 3
		case c >= 0xF0 && c <= 0xF7:
			length = 4
		}
		if length == 0 {
			out = append(out, "\uFFFD"...)
			i++
			continue
		}
		if i+length > len(b) {
			out = append(out, "\uFFFD"...)
			i = len(b)
			continue
		}
		cp := rune(c) & (0xFF >> (length + 1))
		n := length
		for k := 1; k < length; k++ {
			if b[i+k]&0xC0 != 0x80 {
				cp, n = -1, k
				break
			}
			cp = cp<<6 | rune(b[i+k]&0x3F)
		}
		first := [...]rune{0, 0, 0x80, 0x800, 0x10000}
		if cp >= 0 && (cp < first[n] || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF) {
			cp = -1
		}
		if cp < 0 {
			out = append(out, "\uFFFD"...)
		} else {
			out = append(out, b[i:i+n]...)
		}
		i += n
	}
	return out
}
