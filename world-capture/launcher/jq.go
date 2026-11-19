package main

// capture.sh 的规则写在 jq 里，jq 碰到类型不对（对字符串取键、对数字迭代……）就整段报错，sh 那边再按退出码走另一条路。
// 这里照搬：这些小件在 jq 会报错的地方 panic(jqError)，每段 jq 程序对应的 Go 函数由 try 接住，对应 sh 里 `|| …` 的那条路。

import (
	"math"
	"sort"
	"strings"
	"unicode/utf8"
)

type jqError struct{ msg string }

func raise(msg string) { panic(jqError{msg}) }

// try 跑一段对应一次 jq 调用的逻辑：jq 报错时 ok 为假。
func try[T any](f func() T) (out T, ok bool) {
	defer func() {
		if r := recover(); r != nil {
			if _, is := r.(jqError); !is {
				panic(r)
			}
			ok = false
		}
	}()
	return f(), true
}

// get 是 jq 的 .key：null 上是 null，对象上是值或 null，别的报错。
func get(v Value, key string) Value {
	switch v.k {
	case kNull:
		return Null
	case kObject:
		if x, ok := v.obj.m[key]; ok {
			return x
		}
		return Null
	}
	raise("Cannot index with string")
	return Null
}

// path 是 .a.b.c。
func path(v Value, keys ...string) Value {
	for _, k := range keys {
		v = get(v, k)
	}
	return v
}

// field 是 capture.jq 的 field($k)：不是对象就是 null，不报错。
func field(v Value, key string) Value {
	if v.k != kObject {
		return Null
	}
	return get(v, key)
}

// at 是 .[n]：null 上是 null，数组上越界是 null，负数从末尾数，别的报错。
func at(v Value, n int) Value {
	switch v.k {
	case kNull:
		return Null
	case kArray:
		if n < 0 {
			n += len(v.arr)
		}
		if n < 0 || n >= len(v.arr) {
			return Null
		}
		return v.arr[n]
	}
	raise("Cannot index with number")
	return Null
}

// each 是 .[]：数组的元素、对象的值，别的报错。
func each(v Value) []Value {
	switch v.k {
	case kArray:
		return v.arr
	case kObject:
		out := make([]Value, len(v.obj.keys))
		for i, k := range v.obj.keys {
			out[i] = v.obj.m[k]
		}
		return out
	}
	raise("Cannot iterate")
	return nil
}

// eachOpt 是 .[]?。
func eachOpt(v Value) []Value {
	if v.k == kArray || v.k == kObject {
		return each(v)
	}
	return nil
}

// alt 是 a // b。
func alt(a, b Value) Value {
	if a.Truthy() {
		return a
	}
	return b
}

func str(v Value) string {
	if v.k != kString {
		raise("string required")
	}
	return v.s
}

// tostring：字符串原样，别的写成 JSON。
func tostring(v Value) string {
	if v.k == kString {
		return v.s
	}
	return v.JSON()
}

// length：null 是 0，布尔报错，数字是绝对值，字符串数码点，数组和对象数个数。
func length(v Value) int {
	switch v.k {
	case kNull:
		return 0
	case kNumber:
		return int(math.Abs(v.f))
	case kString:
		return utf8.RuneCountInString(v.s)
	case kArray:
		return len(v.arr)
	case kObject:
		return len(v.obj.keys)
	}
	raise("boolean has no length")
	return 0
}

// add 是 jq 的 +。
func add(a, b Value) Value {
	switch {
	case a.k == kNull:
		return b
	case b.k == kNull:
		return a
	case a.k == kNumber && b.k == kNumber:
		return Num(a.f + b.f)
	case a.k == kString && b.k == kString:
		return Str(a.s + b.s)
	case a.k == kArray && b.k == kArray:
		return ArrOf(append(append([]Value{}, a.arr...), b.arr...))
	case a.k == kObject && b.k == kObject:
		return a.Merge(b)
	}
	raise("cannot be added")
	return Null
}

// sum 是 jq 的 add：从 null 起逐个加。
func sum(items []Value) Value {
	out := Null
	for _, x := range items {
		out = add(out, x)
	}
	return out
}

// ---------- 比较与排序：jq 的全序 null < false < true < 数字 < 字符串 < 数组 < 对象 ----------

func order(k kind) int { return int(k) }

func compare(a, b Value) int {
	if a.k != b.k {
		return order(a.k) - order(b.k)
	}
	switch a.k {
	case kNumber:
		switch {
		case a.f < b.f:
			return -1
		case a.f > b.f:
			return 1
		}
		return 0
	case kString:
		return strings.Compare(a.s, b.s)
	case kArray:
		for i := 0; i < len(a.arr) && i < len(b.arr); i++ {
			if c := compare(a.arr[i], b.arr[i]); c != 0 {
				return c
			}
		}
		return len(a.arr) - len(b.arr)
	case kObject:
		ka, kb := sortedKeys(a), sortedKeys(b)
		if c := compare(strs(ka), strs(kb)); c != 0 {
			return c
		}
		for _, k := range ka {
			if c := compare(a.obj.m[k], b.obj.m[k]); c != 0 {
				return c
			}
		}
		return 0
	}
	return 0
}

func equal(a, b Value) bool { return compare(a, b) == 0 }

func strs(list []string) Value {
	out := make([]Value, len(list))
	for i, s := range list {
		out[i] = Str(s)
	}
	return ArrOf(out)
}

func sortedKeys(v Value) []string {
	keys := append([]string{}, v.Keys()...)
	sort.Strings(keys)
	return keys
}

// sortBy 是 sort_by(f)（稳定）。
func sortBy(items []Value, key func(Value) Value) []Value {
	type pair struct {
		k Value
		v Value
	}
	ps := make([]pair, len(items))
	for i, x := range items {
		ps[i] = pair{key(x), x}
	}
	sort.SliceStable(ps, func(i, j int) bool { return compare(ps[i].k, ps[j].k) < 0 })
	out := make([]Value, len(ps))
	for i, p := range ps {
		out[i] = p.v
	}
	return out
}

// uniqueBy 是 unique_by(f)：按 f 排好，每组留第一个。
func uniqueBy(items []Value, key func(Value) Value) []Value {
	sorted := sortBy(items, key)
	var out []Value
	var last Value
	for i, x := range sorted {
		k := key(x)
		if i > 0 && equal(k, last) {
			continue
		}
		out, last = append(out, x), k
	}
	return out
}

// groupBy 是 group_by(f)。
func groupBy(items []Value, key func(Value) Value) [][]Value {
	sorted := sortBy(items, key)
	var out [][]Value
	var last Value
	for i, x := range sorted {
		k := key(x)
		if i > 0 && equal(k, last) {
			out[len(out)-1] = append(out[len(out)-1], x)
			continue
		}
		out, last = append(out, []Value{x}), k
	}
	return out
}

// maxBy 是 max_by(f)：一样大时取后面的。
func maxBy(items []Value, key func(Value) Value) Value {
	if len(items) == 0 {
		return Null
	}
	sorted := sortBy(items, key)
	return sorted[len(sorted)-1]
}

func minOf(items []Value) Value {
	if len(items) == 0 {
		return Null
	}
	best := items[0]
	for _, x := range items[1:] {
		if compare(x, best) < 0 {
			best = x
		}
	}
	return best
}

func maxOf(items []Value) Value {
	if len(items) == 0 {
		return Null
	}
	best := items[0]
	for _, x := range items[1:] {
		if compare(x, best) >= 0 {
			best = x
		}
	}
	return best
}

// uniqueStrings 是字符串数组的 unique（排好、去重）。
func uniqueStrings(list []string) []string {
	cp := append([]string{}, list...)
	sort.Strings(cp)
	var out []string
	for i, s := range cp {
		if i == 0 || s != cp[i-1] {
			out = append(out, s)
		}
	}
	return out
}

// ---------- 字符串 ----------

// runeSlice 是 jq 的 .[from:to]（按码点；to 为 nil 是到末尾，负数从末尾数）。
func runeSlice(s string, from int, to *int) string {
	rs := []rune(s)
	n := len(rs)
	clamp := func(i int) int {
		if i < 0 {
			i += n
		}
		if i < 0 {
			return 0
		}
		if i > n {
			return n
		}
		return i
	}
	a, b := clamp(from), n
	if to != nil {
		b = clamp(*to)
	}
	if a >= b {
		return ""
	}
	return string(rs[a:b])
}

func intp(n int) *int { return &n }

// first19 是 .[0:19]：前 19 个码点。
func first19(s string) string { return runeSlice(s, 0, intp(19)) }

// jqSplit 是 jq 的 split(sep)：空串分出来是空数组。
func jqSplit(s, sep string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, sep)
}

// join 是 jq 的 join(sep)：null 当空串，数字和布尔写成文字，别的报错。
func join(items []Value, sep string) string {
	var b strings.Builder
	for i, x := range items {
		if i > 0 {
			b.WriteString(sep)
		}
		switch x.k {
		case kNull:
		case kString:
			b.WriteString(x.s)
		case kNumber, kTrue, kFalse:
			b.WriteString(x.JSON())
		default:
			raise("Cannot join")
		}
	}
	return b.String()
}

func startsWith(v Value, prefix string) bool { return strings.HasPrefix(str(v), prefix) }

// jq（Oniguruma）的 \s：Unicode 的空白。
func isJQSpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
		return true
	}
	return r >= 0x2000 && r <= 0x200A
}

// trimJQSpace 是 sub("^\\s+"; "") | sub("\\s+$"; "")：jq 的 $ 也认末尾一个换行之前，去掉的是同一段空白。
func trimLeftJQ(s string) string  { return strings.TrimLeftFunc(s, isJQSpace) }
func trimRightJQ(s string) string { return strings.TrimRightFunc(s, isJQSpace) }

// nameOf 是 "\(.item_id)@\(.item_version)"。
func nameOf(v Value) string {
	return tostring(get(v, "item_id")) + "@" + tostring(get(v, "item_version"))
}

// fill：把模板里的 {{键}} 换成对应的值。只换模板本来的：换进去的值（原文、world 的返回、前几批交出的结论）里
// 再出现 {{…}} 原样留着，不会被后面的键换掉。
func fill(template string, pairs ...string) string {
	values := map[string]string{}
	for i := 0; i+1 < len(pairs); i += 2 {
		values[pairs[i]] = pairs[i+1]
	}
	var b strings.Builder
	for {
		i := strings.Index(template, "{{")
		j := -1
		if i >= 0 {
			j = strings.Index(template[i+2:], "}}")
		}
		if j < 0 {
			b.WriteString(template)
			return b.String()
		}
		if v, ok := values[template[i+2:i+2+j]]; ok {
			b.WriteString(template[:i] + v)
			template = template[i+4+j:]
		} else {
			b.WriteString(template[:i+2])
			template = template[i+2:]
		}
	}
}

// set 是 {(k): true} 拼成的那种集合。
type set map[string]bool
