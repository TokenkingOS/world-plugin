package main

// 后台轮的纯规则：0.1.6 的 round.jq，加上准备一步和按会话分组的判断。排批、拼提示词、解析两种 CLI 的输出、核对判断、拼送出骨架和运行回执。
// 文件读写、加锁、起 CLI 在 round.go。jq 在哪里会报错，这里就在哪里 raise（见 jq.go），调用方按 capture.sh 的那条路走。

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const claudePrefix = "mcp__plugin_world_world__"

// 每种调用放行的 world 工具。判断和每周复核一个都没有，也不连 world。
var roundTools = map[string][]string{
	"prepare": {"world_app_sources_read", "world_app_sources_targets"},
	"judge":   {},
	"audit":   {},
	"send":    {"world_app_sources_ingest", "world_app_sources_imports"},
	"report":  {"world_app_sources_report_run"},
}

// 一轮最多 5 批、每批 30 条候选；候选原文最多交 8000 字（头 6000、尾 2000），一批候选原文合计最多 60000 字。
// 每个会话组带第一条候选之前、最后一条候选之后各 3 条前后文，前后文最多交 1500 字（头 1000、尾 500）。
// 读回导入每页 10 条、最多 20 页。回执的积压清单列最早的 20 条。
const (
	limitBatches     = 5
	limitBatch       = 30
	limitItemChars   = 8000
	limitBatchChars  = 60000
	limitContext     = 3
	limitContextText = 1500
	limitShort       = 300  // 规则开着时，不到这么多 UTF-16 码元的答复只当前后文
	limitQuiet       = 1800 // 会话静默这么多秒，它的候选都可判；最早一条可判候选等了这么多秒，就起轮
	limitIncrement   = 50
	limitIncrements  = 5
	limitReadPages   = 20
	limitReadPage    = 10
	limitPendingList = 20
	limitJudgeAlone  = 3 // 失败过的候选单独判，单独判失败满这么多次就按 null 落盘（judge_failed）
)

var itemFields = []string{"classification", "target_ref", "field_key", "value", "quote", "occurred_at", "links", "source_event_ref", "constraint"}

// deliveredSet：delivered/<格式>.jsonl 里每一行读得出的对象的名字。
func deliveredSet(raw string) set {
	out := set{}
	for _, line := range jqSplit(raw, "\n") {
		v, ok := fromJSON(line)
		if ok && v.k == kObject {
			out[nameOf(v)] = true
		}
	}
	return out
}

// clip：原文超过 limit 字时留头 head 字、尾 tail 字，中间换成 round-prompt.md 里 omitted 那一句；截了的交出原长。
func clip(t Value, omitted string, limit, head, tail int) (Value, Value) {
	n := length(t)
	if n <= limit {
		return t, Null
	}
	s := str(t)
	return Str(runeSlice(s, 0, intp(head)) + "\n" + fill(omitted, "n", strconv.Itoa(n-head-tail)) + "\n" + runeSlice(s, -tail, nil)), Int(int64(n))
}

// judgeBatch：一次判断调用。items 是候选（队列里的条目加 name，等重判的带 rejected、attempt），顺序就是 key 的顺序（"1" 起）；
// body 是提示词里的「这一批」：{"sessions":[{"session":"s1","entries":[…]}]}。
type judgeBatch struct {
	items []Value
	body  Value
}

type plan struct {
	backlog   int
	pending   []Value
	settle    []Value
	screen    []Value // 规则挡下、这一次可以落地的：队列里的条目加 name、by
	judge     []judgeBatch
	judgeable int                // 可判的候选有几条（不只是装进这一轮各批的）
	due       []Value            // 算起轮的条目的入队时刻：可判的候选，可以落地的挡下条目，和已判完、待送出、待读回的
	held      map[string][]Value // 会话 → 还没判完的队列条目：要判的、判失败过的、挡下等落地的、判了非 null 等送出或读回的（送出被拒还要重判）
	send      [][]Value
	readback  []Value
	stale     []string
}

// planInput：排这一轮要读的本机状态。results 是 results/ 里各文件，contexts 是前文存放（会话 → 条目），
// ended 是位置文件记了 ended_at 的会话，now 是现在（Unix 秒）。
type planInput struct {
	format    string
	queue     []Value
	results   []namedValue
	delivered string
	omitted   string
	screen    bool
	ended     set
	contexts  map[string][]Value
	now       int64
}

type namedValue struct {
	name  string
	value Value
}

// utf16Len：字符串的 UTF-16 码元数，和库里的 text.length 一样（jq 的 length 数码点）。
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		n++
		if r > 0xFFFF {
			n++
		}
	}
	return n
}

// screenedBy：规则开着时这一条挡不挡（决定一）。用户消息挡，记 rule:user；不到 300 个 UTF-16 码元的答复挡，记 rule:short。
func screenedBy(e Value) string {
	switch role := get(e, "role"); {
	case is(role, "user"):
		return "rule:user"
	case is(role, "assistant") && utf16Len(str(get(e, "text"))) < limitShort:
		return "rule:short"
	}
	return ""
}

// mergeContext：前文存放里原有的加上这一次判完或挡下的，按名字去重，留两部分的并集：按先后的最后 3 条，
// 和 held（同一会话里还留在队列、还没判完的条目）每一条前面紧挨着的 3 条。判断次序乱了时（某批答坏、漏判、被 world 拒后重判），
// 后面先判完的就挤不掉前面那条还要用的前文；它判完以后，多留的在下一次并进来时清掉。
func mergeContext(old Value, rows, held []Value) Value {
	var all []Value
	seen := set{}
	for _, e := range append(eachOpt(alt(old, Arr())), rows...) {
		if e.k != kObject || get(e, "item_id").k != kString || seen[nameOf(e)] {
			continue
		}
		seen[nameOf(e)] = true
		all = append(all, Obj("item_id", get(e, "item_id"), "item_version", get(e, "item_version"), "role", get(e, "role"),
			"reported_at", get(e, "reported_at"), "text", get(e, "text"), "line", get(e, "line")))
	}
	all = sortBy(all, byLine)
	keep := make([]bool, len(all))
	before := func(end int) { // all[end-3:end]
		for i := max(0, end-limitContext); i < end; i++ {
			keep[i] = true
		}
	}
	before(len(all))
	for _, h := range held {
		before(sort.Search(len(all), func(i int) bool { return compare(byLine(all[i]), byLine(h)) >= 0 }))
	}
	var kept []Value
	for i, e := range all {
		if keep[i] {
			kept = append(kept, e)
		}
	}
	return ArrOf(kept)
}

// sessionOf：条目所在会话（位置文件的 key）。没有 session 的旧条目各自算一个会话。
func sessionOf(e Value) string {
	if k := get(e, "session"); k.k == kString && hex64.MatchString(k.s) {
		return k.s
	}
	return "item:" + nameOf(e)
}

// byLine：会话里的先后，按行号（旧条目没有，算 0），再按名字。
func byLine(e Value) Value {
	line := get(e, "line")
	if line.k != kNumber {
		line = Int(0)
	}
	return Arr(line, Str(nameOf(e)))
}

// batchBody：一批候选按会话分组，每组带上第一条候选之前、最后一条候选之后各 3 条前后文，以及候选之间的非候选条目。
// rows 里同一会话的候选挨在一起、按先后排；entries 是各会话的全部条目（按先后排）。
func batchBody(rows []Value, entries map[string][]Value, omitted string) Value {
	var groups []Value
	key := 0
	for i := 0; i < len(rows); {
		session := sessionOf(rows[i])
		j := i
		candidate := map[string]Value{}
		for ; j < len(rows) && sessionOf(rows[j]) == session; j++ {
			candidate[nameOf(rows[j])] = rows[j]
		}
		all := entries[session]
		first, last := -1, -1
		for n, e := range all {
			if _, ok := candidate[nameOf(e)]; ok {
				if first < 0 {
					first = n
				}
				last = n
			}
		}
		var group []Value
		for _, e := range all[max(0, first-limitContext):min(len(all), last+1+limitContext)] {
			if row, ok := candidate[nameOf(e)]; ok {
				key++
				text, truncated := clip(get(row, "text"), omitted, limitItemChars, 6000, 2000)
				x := Obj("key", Str(strconv.Itoa(key)), "role", get(row, "role"), "reported_at", get(row, "reported_at"), "text", text)
				if !truncated.IsNull() {
					x = x.With("truncated", truncated)
				}
				if r := get(row, "rejected"); !r.IsNull() {
					x = x.With("rejected", r)
				}
				group = append(group, x)
				continue
			}
			text, truncated := clip(get(e, "text"), omitted, limitContextText, 1000, 500)
			x := Obj("role", get(e, "role"), "reported_at", get(e, "reported_at"), "text", text)
			if !truncated.IsNull() {
				x = x.With("truncated", truncated)
			}
			group = append(group, x)
		}
		groups = append(groups, Obj("session", Str("s"+strconv.Itoa(len(groups)+1)), "entries", ArrOf(group)))
		i = j
	}
	return Obj("sessions", ArrOf(groups))
}

// judgeAlone：判断失败过的候选（results/ 里有 judge_failures）单独成一批，前后文照常带，坏的那条不再连累同批的别的候选。
// 只失败过一次、是和别的候选一起整批答坏的，还认不出是哪一条，先照常装批再判一次：偶尔答坏一次多半不是哪一条的问题，
// 不值得把一批拆成一条一次调用。
func judgeAlone(row Value) bool {
	failures := eachOpt(path(row, "stored", "judge_failures"))
	if len(failures) == 1 && !field(failures[0], "alone").Truthy() && is(field(failures[0], "reason"), "answer_unreadable") {
		return false
	}
	return len(failures) > 0
}

// planRound：这一轮要做的事。
func planRound(in planInput) plan {
	queue, omitted := in.queue, in.omitted
	done := deliveredSet(in.delivered)
	stored := map[string]Value{}
	var storedNames []string
	for _, r := range in.results {
		if !is(get(r.value, "format"), in.format) {
			continue
		}
		if _, ok := stored[r.name]; !ok {
			storedNames = append(storedNames, r.name)
		}
		stored[r.name] = r.value
	}
	isItem := func(v Value) bool { return v.k == kObject && get(v, "item_id").k == kString }
	var open []Value
	for _, q := range queue {
		if !isItem(q) {
			continue
		}
		name := nameOf(q)
		if done[name] {
			continue
		}
		open = append(open, q.With("name", Str(name)))
	}
	open = uniqueBy(open, func(v Value) Value { return get(v, "name") })
	open = sortBy(open, func(v Value) Value { return Arr(get(v, "first_seen_at"), get(v, "reported_at"), get(v, "item_id")) })
	isOpen := set{}
	for _, e := range open {
		isOpen[get(e, "name").s] = true
	}
	p := plan{backlog: len(open), held: map[string][]Value{}}
	for _, e := range open {
		p.pending = append(p.pending, Obj("item_id", get(e, "item_id"), "item_version", get(e, "item_version")))
	}
	// 落进 delivered/ 的行要带的会话和行号，队列条目有才带（旧条目没有）。
	pick := func(e Value, keys ...string) Value {
		out := Obj()
		for _, k := range keys {
			out = out.With(k, get(e, k))
		}
		for _, k := range []string{"session", "line"} {
			if v, ok := e.Lookup(k); ok {
				out = out.With(k, v)
			}
		}
		return out
	}
	// 要判的条目：规则开着时挡下的不算候选。
	var send []Value
	needs := map[string]Value{} // 名字 → 要判的那一行（等重判的带 rejected、attempt）
	for _, e := range open {
		s, has := stored[get(e, "name").s]
		if !has {
			s = Null
		}
		_, hasResult := s.Lookup("result")
		if s.k != kNull && s.k != kObject {
			raise("has on non-object")
		}
		settled := !s.IsNull() && hasResult && get(s, "result").IsNull()
		if !settled {
			p.held[sessionOf(e)] = append(p.held[sessionOf(e)], e)
		}
		switch {
		case settled:
			p.settle = append(p.settle, pick(e, "name", "item_id", "item_version").With("dropped", get(s, "dropped")))
		case s.IsNull() || !hasResult:
			row := e
			if !s.IsNull() {
				row = row.With("stored", s)
			}
			if get(s, "rejected").Truthy() {
				row = row.Merge(Obj("rejected", get(at(get(s, "rejected"), -1), "code"), "attempt", alt(get(s, "attempt"), Int(1))))
			}
			needs[get(e, "name").s] = row
		}
		if t := get(e, "first_seen_at"); !s.IsNull() && hasResult && t.k == kString {
			p.due = append(p.due, t)
		}
		if !s.IsNull() && hasResult && !get(s, "result").IsNull() && !get(s, "conflict").Truthy() {
			send = append(send, pick(e, "name", "item_id", "item_version", "locator", "reported_at").With("result", get(s, "result")).With("stored", s))
		}
		if get(s, "conflict").Truthy() {
			p.readback = append(p.readback, pick(e, "name", "item_id", "item_version").With("stored", s))
		}
	}
	// 每个会话里，候选按先后看：后面队列里已有 3 条、会话已结束、或会话静默满 30 分钟（最新一条入队已满 30 分钟），就可判；
	// 没有 session 的旧条目立即可判。可判的总是一个会话里前面那几条：第一条不可判的候选及其后的条目都留在队列等后文，
	// 后面的留在队列里照样算数。规则挡下的条目要两件事都满足才落地：同一会话里排在它前面的候选都已判完落盘（results/ 里有了 result）；
	// 它后面那条候选也已判完落盘，或它后面已没有候选、会话可判了（结束或静默满 30 分钟）。判断中途停下、某批答坏、超出批数或时间时，
	// 没判到的候选前后挡下的都还在队列里当前后文。
	queued := map[string][]Value{}
	var keys []string
	for _, e := range open {
		if _, ok := queued[sessionOf(e)]; !ok {
			keys = append(keys, sessionOf(e))
		}
		queued[sessionOf(e)] = append(queued[sessionOf(e)], e)
	}
	sort.Strings(keys)
	ready := set{}
	for _, k := range keys {
		list := sortBy(queued[k], byLine)
		newest := maxOf(func() []Value {
			var t []Value
			for _, e := range list {
				t = append(t, get(e, "first_seen_at"))
			}
			return t
		}())
		quiet := false
		if newest.k == kString {
			if t, ok := fromDate(newest.s); ok && in.now-t >= limitQuiet {
				quiet = true
			}
		}
		allReady := strings.HasPrefix(k, "item:") || in.ended[k] || quiet
		var waiting []Value // 挡下的，等它后面那条候选判完
		blocked := false    // 前面有还没判完的候选：之后挡下的都不落地
		for n, e := range list {
			_, need := needs[nameOf(e)]
			by := ""
			if need && in.screen {
				by = screenedBy(e)
			}
			switch {
			case by != "":
				if !blocked {
					waiting = append(waiting, e.With("by", Str(by)))
				}
				continue
			case !need: // 已判完落盘的候选
				p.screen = append(p.screen, waiting...)
				waiting = nil
				continue
			}
			blocked, waiting = true, nil
			if !allReady && len(list)-n-1 < limitContext {
				break
			}
			ready[nameOf(e)] = true
			if t := get(e, "first_seen_at"); t.k == kString {
				p.due = append(p.due, t)
			}
		}
		if allReady {
			p.screen = append(p.screen, waiting...)
		}
	}
	for _, e := range p.screen {
		if t := get(e, "first_seen_at"); t.k == kString {
			p.due = append(p.due, t)
		}
	}
	var judge []Value
	for _, e := range open {
		if ready[nameOf(e)] {
			judge = append(judge, needs[nameOf(e)])
		}
	}
	p.judgeable = len(judge)
	// 判断按会话：会话按其中最早入队的候选排，会话里的候选按先后排，依次装批；判断失败过的候选单独成一批（见 judgeAlone）。
	// 前后文取自队列和前文存放。
	entries := map[string][]Value{}
	for k, list := range queued {
		inQueue := set{}
		for _, e := range list {
			inQueue[nameOf(e)] = true
		}
		for _, e := range in.contexts[k] {
			if e.k == kObject && get(e, "item_id").k == kString && !inQueue[nameOf(e)] {
				list = append(list, e)
			}
		}
		entries[k] = sortBy(list, byLine)
	}
	bySession := map[string][]Value{}
	var sessions []string
	for _, e := range judge {
		k := sessionOf(e)
		if _, seen := bySession[k]; !seen {
			sessions = append(sessions, k)
		}
		bySession[k] = append(bySession[k], e)
	}
	var batches [][]Value
	var current []Value
	chars, sealed := 0, false // sealed：current 是一条失败过的候选单独成的一批
	for _, k := range sessions {
		for _, e := range sortBy(bySession[k], byLine) {
			text, _ := clip(get(e, "text"), omitted, limitItemChars, 6000, 2000)
			n := length(text)
			alone := judgeAlone(e)
			switch {
			case len(batches) >= limitBatches:
			case len(current) > 0 && (alone || sealed || len(current) >= limitBatch || chars+n > limitBatchChars):
				batches = append(batches, current)
				current, chars = []Value{e}, n
			default:
				current = append(current, e)
				chars += n
			}
			sealed = alone
		}
	}
	if len(current) > 0 {
		batches = append(batches, current)
	}
	if len(batches) > limitBatches {
		batches = batches[:limitBatches]
	}
	for _, rows := range batches {
		p.judge = append(p.judge, judgeBatch{items: rows, body: batchBody(rows, entries, omitted)})
	}
	if len(send) > limitIncrement*limitIncrements {
		send = send[:limitIncrement*limitIncrements]
	}
	for i := 0; i < len(send); i += limitIncrement {
		p.send = append(p.send, send[i:min(i+limitIncrement, len(send))])
	}
	var stale []string
	for _, name := range uniqueStrings(storedNames) {
		if !isOpen[name] {
			stale = append(stale, name)
		}
	}
	for _, q := range queue {
		if isItem(q) && done[nameOf(q)] {
			stale = append(stale, nameOf(q))
		}
	}
	p.stale = uniqueStrings(stale)
	return p
}

// ---------- 落盘 ----------

type write struct {
	name    string
	replace bool
	value   Value
}

type effects struct {
	deliver []string
	remove  []string
	write   []write
	context []Value // 判完或挡下的条目，并进各自会话的前文存放
}

// deliveredLine：delivered/ 的一行。条目有 session、line 就原样带上（每周复核按它们从会话文件找回原文），旧条目没有就不带。
func deliveredLine(row Value, status, round, at string, extra Value) string {
	out := Obj("item_id", get(row, "item_id"), "item_version", get(row, "item_version"), "import_id", alt(get(extra, "import_id"), Null),
		"status", Str(status), "round_id", Str(round), "at", Str(at)).Merge(extra.Without("import_id"))
	for _, k := range []string{"session", "line"} {
		if v, ok := row.Lookup(k); ok {
			out = out.With(k, v)
		}
	}
	return out.JSON()
}

// settleEffects：规则挡下、可以落地的记进 delivered/（status 为 screened，带 by），放进前文存放；已判为 null 的记进 delivered/；
// 再删掉这些条目的队列文件和 results/，以及已不在待提炼里的。
func settleEffects(p plan, round, at string) effects {
	var e effects
	for _, row := range p.screen {
		e.deliver = append(e.deliver, deliveredLine(row, "screened", round, at, Obj("by", get(row, "by"))))
		e.remove = append(e.remove, nameOf(row))
		e.context = append(e.context, row)
	}
	for _, s := range p.settle {
		status, extra := "null", Obj()
		if get(s, "dropped").Truthy() {
			status, extra = "dropped", Obj("code", get(s, "dropped"))
		}
		e.deliver = append(e.deliver, deliveredLine(s, status, round, at, extra))
		e.remove = append(e.remove, get(s, "name").s)
	}
	e.remove = append(e.remove, p.stale...)
	return e
}

// judgeOutcome：一次判断调用的结果。missed 是这一次没判成的候选（带 reason：answer_unreadable 整批答坏，unanswered 漏了它的 key，
// no_result 有 key 没 result），alone 是这一批只有一条候选。
type judgeOutcome struct {
	failure    Value
	accepted   []Value
	invalid    []Value
	missed     []Value
	alone      bool
	mismatches []Value
}

// judgeEffects：合规的判断写进 results/（已有 results/ 文件的是等重判或判失败过的，改写），不合规的算被拒一次；
// 没判成的在 results/ 的 judge_failures 里记一笔（reason、round_id、alone），已有的 rejected、attempt 照留；
// 单独判失败满 3 次的按 null 落盘，dropped 记 judge_failed，不再判，也不再拖着它所在的批。
func judgeEffects(o judgeOutcome, format, round, at string) effects {
	var e effects
	stored := func(x Value) bool { return get(x, "stored").k == kObject }
	for _, a := range o.accepted {
		value := Obj("format", Str(format), "item_id", get(a, "item_id"), "item_version", get(a, "item_version"), "result", get(a, "result"))
		if d := get(a, "dropped"); !d.IsNull() {
			value = value.With("dropped", d)
		}
		e.write = append(e.write, write{name: get(a, "name").s, replace: stored(a), value: value.Merge(Obj(
			"attempt", add(alt(get(a, "attempt"), Int(0)), Int(1)), "round_id", Str(round), "judged_at", Str(at)))})
		e.context = append(e.context, a)
	}
	for _, x := range o.missed {
		base := get(x, "stored")
		if !stored(x) {
			base = Obj("format", Str(format), "item_id", get(x, "item_id"), "item_version", get(x, "item_version"))
		}
		failures := append(append([]Value{}, eachOpt(get(base, "judge_failures"))...),
			Obj("reason", get(x, "reason"), "round_id", Str(round), "alone", Bool(o.alone)))
		value := base.With("judge_failures", ArrOf(failures))
		alone := 0
		for _, f := range failures {
			if field(f, "alone").Truthy() {
				alone++
			}
		}
		if alone >= limitJudgeAlone {
			value = value.Merge(Obj("result", Null, "dropped", Str("judge_failed"), "round_id", Str(round), "judged_at", Str(at)))
		}
		e.write = append(e.write, write{name: get(x, "name").s, replace: true, value: value})
	}
	for _, x := range o.invalid {
		n := add(alt(get(x, "attempt"), Int(0)), Int(1))
		var value Value
		if compare(n, Int(2)) >= 0 {
			value = Obj("format", Str(format), "item_id", get(x, "item_id"), "item_version", get(x, "item_version"), "result", Null,
				"dropped", Str("invalid_increment"), "attempt", n, "round_id", Str(round), "judged_at", Str(at))
		} else {
			value = Obj("format", Str(format), "item_id", get(x, "item_id"), "item_version", get(x, "item_version"),
				"rejected", Arr(Obj("code", Str("invalid_increment"), "round_id", Str(round))), "attempt", n)
		}
		e.write = append(e.write, write{name: get(x, "name").s, replace: stored(x), value: value})
	}
	return e
}

type incrementOutcome struct {
	index    int
	items    []string
	sent     bool
	exact    bool
	imports  []Value // {name, import_id, status}
	err      Value
	rejected []Value // {name, code}
}

type sendOutcome struct {
	increments []incrementOutcome
	complete   bool
	found      Value // 对象：名字 → import_id
	unknown    [][]string
}

func sendEffects(p plan, o *sendOutcome, round, at string) effects {
	rows := map[string]Value{}
	for _, group := range p.send {
		for _, r := range group {
			rows[get(r, "name").s] = r
		}
	}
	type outcome struct {
		kind     string
		row      Value
		importID Value
		mismatch bool
		code     Value
	}
	var all []outcome
	if o != nil {
		for _, inc := range o.increments {
			got := map[string]Value{}
			for _, imp := range inc.imports {
				got[get(imp, "name").s] = get(imp, "import_id")
			}
			why := map[string]Value{}
			for _, r := range inc.rejected {
				why[get(r, "name").s] = get(r, "code")
			}
			for _, name := range inc.items {
				row, ok := rows[name]
				if !ok {
					continue
				}
				switch {
				case got[name].Truthy():
					all = append(all, outcome{kind: "imported", row: row, importID: got[name], mismatch: !inc.exact})
				case why[name].Truthy():
					all = append(all, outcome{kind: "rejected", row: row, code: why[name]})
				case equal(inc.err, Str("IDEMPOTENCY_CONFLICT")):
					all = append(all, outcome{kind: "conflict", row: row})
				}
			}
		}
	}
	found, complete := Obj(), false
	if o != nil {
		found, complete = o.found, o.complete
	}
	for _, row := range p.readback {
		id := get(found, get(row, "name").s)
		if id.Truthy() {
			all = append(all, outcome{kind: "read_back", row: row, importID: id})
		} else if complete {
			all = append(all, outcome{kind: "unflag", row: row})
		}
	}
	attempt := func(row Value) Value { return alt(path(row, "stored", "attempt"), Int(1)) }
	var e effects
	status := map[string]string{"imported": "imported", "read_back": "conflict", "rejected": "dropped"}
	for _, x := range all {
		if x.kind == "imported" || x.kind == "read_back" || (x.kind == "rejected" && compare(attempt(x.row), Int(2)) >= 0) {
			extra := Obj("import_id", x.importID)
			if x.mismatch {
				extra = extra.With("copy_mismatch", True)
			}
			if x.code.Truthy() {
				extra = extra.With("code", x.code)
			}
			e.deliver = append(e.deliver, deliveredLine(x.row, status[x.kind], round, at, extra))
			e.remove = append(e.remove, get(x.row, "name").s)
		}
	}
	for _, x := range all {
		stored := get(x.row, "stored")
		var value Value
		switch {
		case x.kind == "rejected" && compare(attempt(x.row), Int(2)) < 0:
			value = Obj("format", get(stored, "format"), "item_id", get(x.row, "item_id"), "item_version", get(x.row, "item_version"),
				"rejected", add(alt(get(stored, "rejected"), Arr()), Arr(Obj("code", x.code, "round_id", Str(round)))), "attempt", attempt(x.row))
		case x.kind == "conflict":
			value = stored.Merge(Obj("conflict", Str(round)))
		case x.kind == "unflag":
			value = stored.Without("conflict")
		default:
			continue
		}
		e.write = append(e.write, write{name: get(x.row, "name").s, replace: true, value: value})
	}
	return e
}

// ---------- 提示词 ----------

// promptSection：round-prompt.md 里 <!-- kind --> 之后、下一个标记之前的一段，去掉两头的空白。
func promptSection(text, kind string) string {
	parts := jqSplit(text, "<!-- "+kind+" -->")
	section := ""
	if len(parts) > 1 {
		section = parts[1]
	}
	pieces := jqSplit(section, "\n<!-- ")
	if len(pieces) == 0 {
		raise("section missing")
	}
	return trimRightJQ(trimLeftJQ(pieces[0]))
}

// skillRules：world-source-extract 技能里 rules-from 那一段列出的各节，按技能里的顺序原样交给判断轮；少一节或多一节交 false。
func skillRules(skill, names string) (string, bool) {
	var wanted []string
	for _, n := range jqSplit(names, "\n") {
		if n != "" {
			wanted = append(wanted, n)
		}
	}
	var kept []string
	for _, part := range jqSplit(skill, "\n## ") {
		for _, n := range wanted {
			if strings.HasPrefix(part, n+"\n") {
				kept = append(kept, "## "+part)
				break
			}
		}
	}
	if len(kept) != len(wanted) {
		return "", false
	}
	return trimRightJQ(strings.Join(kept, "\n")), true
}

func codeBlock(v Value) string { return "```json\n" + v.JSON() + "\n```" }

func since(batch []Value) string {
	var times []Value
	for _, e := range batch {
		t, ok := fromDate(first19(str(get(e, "reported_at"))) + "Z")
		if !ok {
			raise("date")
		}
		times = append(times, Int(t))
	}
	return toDate(minOf(times).f - 86400)
}

// preparePrompt：准备那次两个读工具的参数，since 是 from（见 prepare）。
func preparePrompt(template string, cfg Value, from string) string {
	return fill(template, "read", codeBlock(Obj("selection_id", get(cfg, "selection_id"))),
		"targets", codeBlock(Obj("selection_id", get(cfg, "selection_id"), "since", Str(from)))) + "\n"
}

// judgePrompt：判断规则、时区、目标（含验收条目和已记事实）、本轮前几批已交出的结论，以及这一批。
func judgePrompt(template, rules string, p prepared, submitted []Value, b judgeBatch) string {
	return fill(template, "rules", rules, "time_zone", tostring(p.timeZone), "targets", codeBlock(p.targets),
		"submitted", codeBlock(ArrOf(submitted)), "batch", codeBlock(b.body)) + "\n"
}

func sendPrompt(template, readbackStep, ingestStep string, cfg Value, increments []Value, readback []Value) string {
	var steps []string
	if len(readback) > 0 {
		steps = append(steps, fill(readbackStep, "pages", strconv.Itoa(limitReadPages),
			"args", codeBlock(Obj("selection_id", get(cfg, "selection_id"), "limit", Int(limitReadPage)))))
	}
	for _, inc := range increments {
		steps = append(steps, fill(ingestStep, "args", codeBlock(inc)))
	}
	numbered := make([]string, len(steps))
	for i, s := range steps {
		numbered[i] = strconv.Itoa(i+1) + ". " + s
	}
	return fill(template, "steps", strings.Join(numbered, "\n\n")) + "\n"
}

func reportPrompt(template string, args Value) string {
	return fill(template, "args", codeBlock(args)) + "\n"
}

// ---------- 两种 CLI 的输出 ----------

type toolCall struct {
	tool   Value
	args   Value
	text   Value
	failed bool
}

type cliResult struct {
	events     int
	mcp        Value
	calls      []toolCall
	denied     []Value
	final      Value
	errors     []string
	apiStatus  Value
	worldTools Value // 数组或 null
	requests   Value
	usage      Value
	failure    Value
}

func body(v Value) Value {
	if v.k != kString {
		return Null
	}
	if x, ok := fromJSON(v.s); ok {
		return x
	}
	return Null
}

func firstText(v Value) Value {
	switch v.k {
	case kString:
		return v
	case kArray:
		for _, x := range v.arr {
			if x.k == kObject && equal(get(x, "type"), Str("text")) {
				return get(x, "text")
			}
		}
	}
	return Null
}

func fullContent(v Value) Value {
	if v.k != kObject {
		return v
	}
	if sc := get(v, "structuredContent"); sc.k == kObject {
		return Str(sc.JSON())
	}
	return get(v, "content")
}

func is(v Value, s string) bool { return equal(v, Str(s)) }

func ltrimstr(v Value, prefix string) Value {
	if v.k == kString && strings.HasPrefix(v.s, prefix) {
		return Str(v.s[len(prefix):])
	}
	return v
}

// parseClaude：claude -p --output-format stream-json --verbose 的每一行。
func parseClaude(rows []Value) cliResult {
	for _, r := range rows {
		if r.k != kObject {
			raise("row")
		}
	}
	init, result := Null, Null
	initSeen := false
	for _, r := range rows {
		if !initSeen && is(get(r, "type"), "system") && is(get(r, "subtype"), "init") {
			init, initSeen = r, true
		}
		if is(get(r, "type"), "result") {
			result = r
		}
	}
	outs := Obj()
	for _, r := range rows {
		if !is(get(r, "type"), "user") {
			continue
		}
		full := get(r, "tool_use_result")
		var blocks []Value
		for _, b := range eachOpt(path(r, "message", "content")) {
			if b.k == kObject && is(get(b, "type"), "tool_result") {
				blocks = append(blocks, b)
			}
		}
		if len(blocks) == 1 && !fullContent(full).IsNull() {
			blocks = []Value{blocks[0].Merge(Obj("content", fullContent(full)))}
		}
		for _, b := range blocks {
			outs = outs.Merge(Obj(tostring(get(b, "tool_use_id")), b))
		}
	}
	out := cliResult{events: len(rows), mcp: Null, apiStatus: get(result, "api_error_status"), worldTools: Null, requests: Null, usage: Null}
	if initSeen {
		servers := alt(get(init, "mcp_servers"), Arr())
		world, found := Null, false
		for _, s := range each(servers) {
			if is(get(s, "name"), "plugin:world:world") && !found {
				world, found = s, true
			}
		}
		out.mcp = alt(get(world, "status"), Str("missing"))
	}
	var ids []string
	for _, r := range rows {
		if !is(get(r, "type"), "assistant") {
			continue
		}
		if id := path(r, "message", "id"); id.k == kString {
			ids = append(ids, id.s)
		}
		for _, b := range eachOpt(path(r, "message", "content")) {
			if b.k != kObject || !is(get(b, "type"), "tool_use") {
				continue
			}
			if !startsWith(get(b, "name"), claudePrefix) {
				continue
			}
			o := get(outs, tostring(get(b, "id")))
			out.calls = append(out.calls, toolCall{tool: ltrimstr(get(b, "name"), claudePrefix), args: get(b, "input"),
				text: firstText(get(o, "content")), failed: o.IsNull() || equal(get(o, "is_error"), True)})
		}
	}
	for _, d := range each(alt(get(result, "permission_denials"), Arr())) {
		out.denied = append(out.denied, get(d, "tool_name"))
	}
	if r := get(result, "result"); r.k == kString {
		out.final = r
	} else {
		out.final = Null
	}
	if equal(get(result, "is_error"), True) {
		out.errors = append(out.errors, tostring(alt(get(result, "result"), Str("error"))))
	}
	if initSeen {
		var tools []Value
		for _, t := range each(alt(get(init, "tools"), Arr())) {
			if t.k == kString && strings.HasPrefix(t.s, claudePrefix) {
				tools = append(tools, ltrimstr(t, claudePrefix))
			}
		}
		out.worldTools = ArrOf(tools)
	}
	if n := len(uniqueStrings(ids)); n > 0 {
		out.requests = Int(int64(n))
	}
	if u := get(result, "usage"); u.k == kObject {
		out.usage = Obj("input_tokens", add(add(alt(get(u, "input_tokens"), Int(0)), alt(get(u, "cache_creation_input_tokens"), Int(0))),
			alt(get(u, "cache_read_input_tokens"), Int(0))),
			"cached_input_tokens", alt(get(u, "cache_read_input_tokens"), Int(0)), "output_tokens", alt(get(u, "output_tokens"), Int(0)))
	}
	return out
}

// parseCodex：codex exec --json 的每一行。
func parseCodex(rows []Value) cliResult {
	for _, r := range rows {
		if r.k != kObject {
			raise("row")
		}
	}
	out := cliResult{events: len(rows), mcp: Null, final: Null, apiStatus: Null, worldTools: Null, requests: Null, usage: Null}
	completed := func(r Value, itemType string) bool {
		return is(get(r, "type"), "item.completed") && is(path(r, "item", "type"), itemType)
	}
	var errs []Value
	for _, r := range rows {
		if completed(r, "mcp_tool_call") && is(path(r, "item", "server"), "world") {
			item := get(r, "item")
			out.calls = append(out.calls, toolCall{tool: get(item, "tool"), args: get(item, "arguments"), text: firstText(path(item, "result", "content")),
				failed: !is(get(item, "status"), "completed") || !get(item, "error").IsNull()})
		}
		if completed(r, "agent_message") {
			out.final = path(r, "item", "text")
		}
	}
	for _, r := range rows {
		if is(get(r, "type"), "error") {
			errs = append(errs, get(r, "message"))
		}
	}
	for _, r := range rows {
		if is(get(r, "type"), "turn.failed") {
			errs = append(errs, path(r, "error", "message"))
		}
	}
	for _, r := range rows {
		if completed(r, "error") {
			errs = append(errs, path(r, "item", "message"))
		}
	}
	for _, e := range errs {
		out.errors = append(out.errors, tostring(e))
	}
	var usages []Value
	for _, r := range rows {
		if is(get(r, "type"), "turn.completed") {
			usages = append(usages, get(r, "usage"))
		}
	}
	if len(usages) > 0 {
		column := func(key string) Value {
			values := make([]Value, len(usages))
			for i, u := range usages {
				values[i] = alt(get(u, key), Int(0))
			}
			return sum(values)
		}
		out.usage = Obj("input_tokens", column("input_tokens"), "cached_input_tokens", column("cached_input_tokens"), "output_tokens", column("output_tokens"))
	}
	return out
}

var (
	mcpFailed    = regexp.MustCompile(`required MCP servers failed to initialize`)
	mcpNetwork   = regexp.MustCompile(`error sending request|dns error|[Cc]onnection refused|timed out|[Nn]etwork`)
	loginPattern = regexp.MustCompile(`401 Unauthorized|403 Forbidden|[Ii]nvalid API key|/login|[Nn]ot logged in|log in again|refresh token|suspended|authentication_error`)
	netPattern   = regexp.MustCompile(`error sending request|stream disconnected|[Cc]onnection refused|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|Unable to connect|fetch failed|getaddrinfo`)
)

func failure(class, detail string) Value { return Obj("class", Str(class), "detail", Str(detail)) }

// classify：失败分五类（ADR 决定九）。stderr 是标准错误的末尾一段；world 为假（判断那次不连 world）时不看 world 连没连上。
func classify(r cliResult, agent string, status int, timedOut bool, stderr string, world bool) Value {
	text := strings.Join(r.errors, "\n") + "\n" + stderr
	switch {
	case timedOut:
		return failure("other", "timeout")
	case status == 126 || status == 127:
		return failure("program_missing", "exit "+strconv.Itoa(status))
	case agent == "claude" && (equal(r.apiStatus, Int(401)) || equal(r.apiStatus, Int(403))):
		return failure("login_invalid", "api "+tostring(r.apiStatus))
	case mcpFailed.MatchString(text):
		if mcpNetwork.MatchString(text) {
			return failure("network", "world")
		}
		return failure("world_unavailable", "mcp_not_ready")
	case loginPattern.MatchString(text):
		return failure("login_invalid", "auth")
	case netPattern.MatchString(text):
		return failure("network", "model")
	case r.events == 0:
		return failure("other", "output_unreadable")
	case agent == "claude" && world && !is(r.mcp, "connected"):
		return failure("world_unavailable", "mcp_"+tostring(r.mcp))
	case status != 0:
		return failure("other", "exit "+strconv.Itoa(status))
	}
	return Null
}

// ---------- 判断轮的结果 ----------

func boundedText(v Value, lo, hi int) bool {
	if v.k != kString {
		return false
	}
	n := length(v)
	return n >= lo && n <= hi
}

// jq 的 $ 也匹配末尾一个换行之前，所以这些式子末尾都允许一个 \n。
var (
	targetRefPattern  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@[1-9][0-9]*\n?$`)
	occurredPattern   = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})\n?$`)
	eventRefPattern   = regexp.MustCompile(`^event:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\n?$`)
	toolNamePattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}\n?$`)
	versionDirPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\n?$`)
)

func oneOf(v Value, options ...string) bool {
	for _, o := range options {
		if is(v, o) {
			return true
		}
	}
	return false
}

func validItem(r Value) bool {
	if r.k != kObject {
		return false
	}
	for _, k := range r.Keys() {
		if !contains(itemFields, k) {
			return false
		}
	}
	matches := func(v Value, re *regexp.Regexp) bool { return v.k == kString && re.MatchString(v.s) }
	value := get(r, "value")
	valueOK := value.IsNull() || boundedText(value, 0, 4000)
	if !valueOK && value.k == kArray && len(value.arr) <= 50 {
		valueOK = true
		for _, x := range value.arr {
			if !boundedText(x, 0, 2048) {
				valueOK = false
			}
		}
	}
	links := get(r, "links")
	linksOK := links.IsNull()
	if links.k == kArray && len(links.arr) <= 20 {
		linksOK = true
		for _, x := range links.arr {
			if !boundedText(x, 1, 2048) {
				linksOK = false
			}
		}
	}
	nullOr := func(key string, ok func(Value) bool) bool { v := get(r, key); return v.IsNull() || ok(v) }
	return oneOf(get(r, "classification"), "fact", "decision", "suggestion", "question", "unknown") &&
		nullOr("target_ref", func(v Value) bool { return matches(v, targetRefPattern) }) &&
		nullOr("field_key", func(v Value) bool { return boundedText(v, 1, 300) }) &&
		valueOK &&
		nullOr("quote", func(v Value) bool { return boundedText(v, 1, 2000) }) &&
		nullOr("occurred_at", func(v Value) bool { return matches(v, occurredPattern) }) &&
		linksOK &&
		nullOr("source_event_ref", func(v Value) bool { return matches(v, eventRefPattern) }) &&
		nullOr("constraint", func(v Value) bool { return oneOf(v, "none", "upstream_blocked", "pending_contract_unverified") })
}

func toolBody(r cliResult, tool string) Value {
	last := Null
	for _, c := range r.calls {
		if is(c.tool, tool) && !c.failed {
			last = body(c.text)
		}
	}
	return last
}

func toolError(r cliResult, tool string) Value {
	last := Null
	for _, c := range r.calls {
		if !is(c.tool, tool) {
			continue
		}
		code := alt(path(body(c.text), "error", "code"), Null)
		if code.IsNull() && c.failed {
			code = Str("tool_failed")
		}
		if code.Truthy() {
			last = code
		}
	}
	return last
}

// answer：最终答复里第一个 { 到最后一个 } 那一段的 JSON。
func answer(r cliResult) Value {
	final := alt(r.final, Str(""))
	s := str(final)
	i, j := strings.IndexByte(s, '{'), strings.LastIndexByte(s, '}')
	if i < 0 || j < i {
		return Null
	}
	if v, ok := fromJSON(s[i : j+1]); ok {
		return v
	}
	return Null
}

func answerKey(r Value) Value {
	if r.k != kObject {
		return Null
	}
	switch k := get(r, "key"); k.k {
	case kString:
		return k
	case kNumber:
		return Str(tostring(k))
	}
	return Null
}

// prepared：准备那一步读到的、本轮各批共用的时区和目标。
type prepared struct {
	timeZone Value
	targets  Value
}

// prepareOutcomeOf：只认这一次调用里真的读到了生效的选择和非空的目标（从事件流里 world 的返回取，不认模型自己说的）。
func prepareOutcomeOf(r cliResult, cfg Value) (prepared, Value) {
	selection := get(toolBody(r, "world_app_sources_read"), "selection")
	targets := get(toolBody(r, "world_app_sources_targets"), "targets")
	errCode := alt(toolError(r, "world_app_sources_read"), toolError(r, "world_app_sources_targets"))
	switch {
	case selection.IsNull() || targets.k != kArray:
		class := "world_unavailable"
		if is(errCode, "HTTP_UNAVAILABLE") {
			class = "network"
		}
		return prepared{}, Obj("class", Str(class), "detail", alt(errCode, Str("tools_not_called")))
	case !equal(get(selection, "selection_id"), get(cfg, "selection_id")) || !is(get(selection, "status"), "active") ||
		!equal(get(selection, "version"), get(cfg, "selection_version")):
		return prepared{}, failure("other", "selection_changed")
	case len(targets.arr) == 0:
		return prepared{}, failure("other", "targets_empty")
	}
	return prepared{timeZone: path(field(selection, "choice"), "history", "time_zone"), targets: targets}, Null
}

// judgeOutcomeOf：最终答复里那个 JSON 的 results，按 key 对回这一批的候选。读不出 results 是 answer_unreadable，整批不收、都算没判成。
func judgeOutcomeOf(r cliResult, batch []Value) judgeOutcome {
	by := map[string]Value{}
	for i, e := range batch {
		by[strconv.Itoa(i+1)] = e
	}
	missed := func(e Value, reason string) Value { return e.With("reason", Str(reason)) }
	a := answer(r)
	results := get(a, "results")
	if results.k != kArray {
		o := judgeOutcome{failure: failure("other", "answer_unreadable"), alone: len(batch) == 1}
		for _, e := range batch {
			o.missed = append(o.missed, missed(e, "answer_unreadable"))
		}
		return o
	}
	o := judgeOutcome{failure: Null, alone: len(batch) == 1}
	seen := set{}
	for _, x := range results.arr {
		key := tostring(alt(answerKey(x), Str("")))
		e, ok := by[key]
		mismatch := func(reason string) Value {
			return Obj("key", Str(key), "item_id", get(e, "item_id"), "item_version", get(e, "item_version"), "reason", Str(reason))
		}
		_, hasResult := x.Lookup("result")
		switch {
		case !ok:
			k := Null
			if x.k == kObject {
				k = get(x, "key")
			}
			o.mismatches = append(o.mismatches, Obj("key", k, "reason", Str("not_in_batch")))
		case seen[key]:
			o.mismatches = append(o.mismatches, mismatch("duplicate"))
		case !hasResult:
			o.mismatches = append(o.mismatches, mismatch("no_result"))
			o.missed = append(o.missed, missed(e, "no_result"))
			seen[key] = true
		case get(x, "result").IsNull():
			o.accepted = append(o.accepted, e.Merge(Obj("result", Null)))
			seen[key] = true
		case validItem(get(x, "result")):
			kept := Obj()
			res := get(x, "result")
			for _, k := range res.Keys() {
				if v := get(res, k); !v.IsNull() {
					kept = kept.With(k, v)
				}
			}
			// world 按 occurred_at_missing 拒收没有事实时刻的结果，落盘前先改成 null（决定六第 2 条）。
			if get(kept, "occurred_at").IsNull() {
				o.accepted = append(o.accepted, e.Merge(Obj("result", Null, "dropped", Str("occurred_at_missing"))))
				o.mismatches = append(o.mismatches, mismatch("occurred_at_missing"))
			} else {
				o.accepted = append(o.accepted, e.Merge(Obj("result", kept)))
			}
			seen[key] = true
		default:
			o.invalid = append(o.invalid, e)
			seen[key] = true
		}
	}
	for i, e := range batch {
		if !seen[strconv.Itoa(i+1)] {
			o.missed = append(o.missed, missed(e, "unanswered"))
		}
	}
	return o
}

// ---------- 送出 ----------

func incrementsOf(groups [][]Value, cfg Value, round string) []Value {
	out := make([]Value, len(groups))
	for k, group := range groups {
		ready := Null
		var items []Value
		for _, e := range group {
			t := get(e, "reported_at")
			if ready.IsNull() || before(str(ready), str(t)) {
				ready = t
			}
			items = append(items, add(add(Obj("item_id", get(e, "item_id"), "item_version", get(e, "item_version")), get(e, "result")),
				Obj("locator", get(e, "locator"))))
		}
		out[k] = Obj("selection_id", get(cfg, "selection_id"), "selection_version", get(cfg, "selection_version"),
			"increment", Obj("format", Str("world-source-increment/0.1"), "source_id", get(cfg, "source_id"),
				"snapshot_version", Str("queue-"+round), "batch_id", Str("batch-"+round+"-"+strconv.Itoa(k+1)),
				"source_ready_at", ready, "items", ArrOf(items)))
	}
	return out
}

func sentNames(c toolCall) []string {
	var out []string
	for _, x := range eachOpt(alt(path(c.args, "increment", "items"), Arr())) {
		if x.k == kObject {
			out = append(out, nameOf(x))
		}
	}
	return out
}

func sendOutcomeOf(r cliResult, increments []Value) *sendOutcome {
	var ingests []toolCall
	for _, c := range r.calls {
		if is(c.tool, "world_app_sources_ingest") {
			ingests = append(ingests, c)
		}
	}
	all := set{}
	o := &sendOutcome{found: Obj()}
	for k, inc := range increments {
		var mine []string
		for _, it := range each(path(inc, "increment", "items")) {
			mine = append(mine, nameOf(it))
			all[nameOf(it)] = true
		}
		mineSet := set{}
		for _, n := range mine {
			mineSet[n] = true
		}
		var exact, call *toolCall
		for i := range ingests {
			if equal(ingests[i].args, inc) {
				exact = &ingests[i]
				break
			}
		}
		call = exact
		if call == nil {
			for i := range ingests {
				hit := false
				for _, n := range sentNames(ingests[i]) {
					hit = hit || mineSet[n]
				}
				if hit {
					call = &ingests[i]
					break
				}
			}
		}
		b := Null
		if call != nil {
			b = body(call.text)
		}
		res := incrementOutcome{index: k, items: mine, sent: call != nil, exact: exact != nil}
		for _, imp := range each(alt(get(b, "imports"), Arr())) {
			res.imports = append(res.imports, Obj("name", Str(tostring(get(imp, "source_item_id"))+"@"+tostring(get(imp, "source_version"))),
				"import_id", get(imp, "import_id"), "status", get(imp, "status")))
		}
		res.err = alt(path(b, "error", "code"), Null)
		if res.err.IsNull() && call != nil && b.IsNull() {
			res.err = Str("tool_failed")
		}
		for _, rej := range each(alt(path(b, "error", "rejected"), Arr())) {
			res.rejected = append(res.rejected, Obj("name", Str(nameOf(rej)), "code", get(rej, "code")))
		}
		o.increments = append(o.increments, res)
	}
	var pages []Value
	for _, c := range r.calls {
		if is(c.tool, "world_app_sources_imports") && !c.failed {
			if b := body(c.text); !b.IsNull() {
				pages = append(pages, b)
			}
		}
	}
	o.complete = len(pages) > 0 && get(pages[len(pages)-1], "next_cursor").IsNull()
	for _, page := range pages {
		for _, it := range eachOpt(get(page, "items")) {
			o.found = o.found.Merge(Obj(tostring(get(it, "source_item_id"))+"@"+tostring(get(it, "source_version")), get(it, "import_id")))
		}
	}
	for _, c := range ingests {
		names := sentNames(c)
		hit := false
		for _, n := range names {
			hit = hit || all[n]
		}
		if !hit {
			o.unknown = append(o.unknown, names)
		}
	}
	return o
}

// ---------- 运行回执 ----------

func reportArgs(cfg Value, round, started, finished string, p plan, files Value, o *sendOutcome, taken Value) Value {
	backlog := p.backlog
	planned, accepted := 0, 0
	var ids []Value
	blocked := false
	if o != nil {
		planned = len(o.increments)
		for _, inc := range o.increments {
			if inc.sent && inc.err.IsNull() {
				accepted++
			}
			if is(inc.err, "SOURCE_ITEMS_REJECTED") || is(inc.err, "IDEMPOTENCY_CONFLICT") {
				blocked = true
			}
			for _, imp := range inc.imports {
				ids = append(ids, get(imp, "import_id"))
			}
		}
	}
	coverage, code := "ready", "no_new_content"
	switch {
	case backlog > 0:
		coverage, code = "partial", "coverage_incomplete"
	case len(ids) > 0:
		code = "increment_ready"
	case compare(taken, Int(0)) > 0:
		code = "no_business_increment"
	}
	issues := Arr()
	issueCount := 0
	if backlog > 0 {
		issues, issueCount = Arr(Obj("code", Str("extraction_pending"))), 1
	}
	var pending []Value
	for i, e := range p.pending {
		if i >= limitPendingList {
			break
		}
		pending = append(pending, Obj("item_id", get(e, "item_id"), "reason", Str("extraction_pending"), "item_version", get(e, "item_version")))
	}
	delivery := "unknown"
	switch {
	case accepted == planned && backlog > 0:
		delivery = "accepted_with_gaps"
	case accepted == planned:
		delivery = "accepted"
	case blocked:
		delivery = "blocked"
	}
	importIDs := ids
	if len(importIDs) > 1000 {
		importIDs = importIDs[:1000]
	}
	return Obj("selection_id", get(cfg, "selection_id"), "request_key", Str("run-"+round), "selection_version", get(cfg, "selection_version"),
		"trigger", Str("source_change"), "observed_at", Str(started), "started_at", Str(started), "finished_at", Str(finished),
		"coverage_status", Str(coverage), "coverage_code", Str(code), "discovered_files", get(files, "count"), "read_files", get(files, "count"),
		"read_bytes", get(files, "bytes"), "issue_count", Int(int64(issueCount)), "issues", issues, "pending_count", Int(int64(backlog)),
		"pending", ArrOf(pending), "planned_batches", Int(int64(planned)), "accepted_batches", Int(int64(accepted)),
		"delivery_status", Str(delivery), "import_count", Int(int64(len(ids))), "import_ids", ArrOf(importIDs))
}

// ---------- 只给模型看这次要用的 world 工具（Claude Code） ----------

func toolNames(v Value) []string {
	if v.k != kArray {
		return nil
	}
	var out []string
	for _, x := range v.arr {
		if x.k == kString && toolNamePattern.MatchString(x.s) {
			out = append(out, x.s)
		}
	}
	return out
}

func knownTools(old, seen Value) Value {
	return strs(uniqueStrings(append(toolNames(old), toolNames(seen)...)))
}

func hiddenTools(names Value, kind string) string {
	var hidden []string
	for _, n := range toolNames(names) {
		if !contains(roundTools[kind], n) {
			hidden = append(hidden, n)
		}
	}
	hidden = uniqueStrings(hidden)
	for i := range hidden {
		hidden[i] = claudePrefix + hidden[i]
	}
	return strings.Join(hidden, ",")
}

// ---------- 配置与已装的 world 插件 ----------

// roundConfig：config.json 里这种 Agent 合用的那一项，交出后台轮要的三项。
func roundConfig(config Value, agent, format string) (Value, bool) {
	if _, _, _, ok := configEntry(config, agent, format); !ok {
		return Null, false
	}
	e := get(get(config, "agents"), agent)
	return Obj("selection_id", get(e, "selection_id"), "selection_version", get(e, "selection_version"), "source_id", get(e, "source_id")), true
}

// installedWorld：Claude Code 的 installed_plugins.json 里 world@tkos-world 当前装在哪（用户级优先，取第一个绝对路径）。
func installedWorld(data Value) string {
	entries := alt(get(get(data, "plugins"), "world@tkos-world"), Arr())
	if entries.k != kArray {
		entries = Arr()
	}
	var ordered []Value
	for _, e := range entries.arr {
		if is(get(e, "scope"), "user") {
			ordered = append(ordered, e)
		}
	}
	for _, e := range append(ordered, entries.arr...) {
		if p := get(e, "installPath"); p.k == kString && strings.HasPrefix(p.s, "/") {
			return p.s
		}
	}
	return ""
}

// newestVersion：Codex 插件缓存里 world 各版本目录名中版本号最大的（一样大时取后列出的）。
func newestVersion(names []string) string {
	var vs []Value
	for _, n := range names {
		if versionDirPattern.MatchString(n) {
			vs = append(vs, Str(n))
		}
	}
	vs = sortBy(vs, func(v Value) Value {
		var parts []Value
		for _, p := range strings.Split(v.s, ".") {
			f, _ := strconv.ParseFloat(strings.TrimSuffix(p, "\n"), 64)
			parts = append(parts, Num(f))
		}
		return ArrOf(parts)
	})
	if len(vs) == 0 {
		return ""
	}
	return vs[len(vs)-1].s
}

// ---------- 间隔 ----------

type gateResult struct {
	failures int
	next     Value
	tooSoon  bool
}

// gate：上一轮开始后至少隔 30 分钟再起；连续失败几轮，间隔就翻几倍，最长 4 小时（ADR 决定九）。
// 有一批答坏（failed_batches 不空）的轮在这里也按失败算：那一批留在队列，不该每 30 分钟就重判一次。
// 登录类失败（login_invalid、world_unavailable）不翻倍（本人 2026-11-19 定）：最近一轮是登录类的，照旧隔 30 分钟，
// 本人登录好以后最多半小时自动恢复；数连续失败轮数时登录类的轮跳过，既不算数也不打断，别的类照旧翻倍。
// failures 交出的是连续失败的总轮数，登录类的也算在里面。
func gate(rounds []Value, now string) gateResult {
	sorted := sortBy(rounds, func(v Value) Value { return Arr(get(v, "started_at"), get(v, "round_id")) })
	failedRound := func(v Value) bool {
		batches := get(v, "failed_batches")
		return !get(v, "failure").IsNull() || (batches.k == kArray && len(batches.arr) > 0)
	}
	loginRound := func(v Value) bool { return oneOf(path(v, "failure", "class"), "login_invalid", "world_unavailable") }
	failed, doubling := 0, 0
	for i := len(sorted) - 1; i >= 0 && failedRound(sorted[i]); i-- {
		failed++
		if !loginRound(sorted[i]) {
			doubling++
		}
	}
	if failed > 0 && loginRound(sorted[len(sorted)-1]) {
		doubling = 0
	}
	gap := int64(14400)
	if doubling < 4 {
		gap = min(int64(1800)<<doubling, 14400)
	}
	g := gateResult{failures: failed, next: Null}
	if len(sorted) == 0 {
		return g
	}
	started := get(sorted[len(sorted)-1], "started_at")
	if started.k != kString {
		return g
	}
	t, ok := fromDate(first19(started.s) + "Z")
	if !ok {
		return g
	}
	g.next = Str(toDate(float64(t + gap)))
	n, _ := fromDate(now)
	g.tooSoon = n < t+gap
	return g
}

// ---------- results/ 与队列：一个文件一个值，读不出的只跳过它自己 ----------

func byFile(files []namedFile) []namedValue {
	var out []namedValue
	for _, f := range files {
		if v, ok := fromJSON(f.joined); ok {
			out = append(out, namedValue{f.name, v})
		}
	}
	return out
}
