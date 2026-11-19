package main

// 每周复核：看判断漏没漏。挂在一次后台轮的末尾、同一把锁里：这一轮准备成功过、没有失败、剩下的时间够，并且准备时离上一次复核完成
// 满 7 天才跑（没有过复核也算满），否则留给下一轮。要复核的轮，准备读已记的事实从窗口起点往前 24 小时读起，判断那一步只用
// 原 since 以来的（见 prepare）。从 delivered/ 最近 7 天（按 at）的行里取两类：规则挡下的（status 为 screened）和判成 null 的
// （status 为 null；dropped 的不算），每类随机抽最多 30 条，按会话文件重读原文、带上前后各 3 条，照判断那一步的提示词和批的形状
// 重判一次：不带工具、不连 world，选择、目标和时区用这一轮准备读到的，也带上这一轮判断已交出的结论。交回的照判断那一步的规则核，
// 合规、带时刻的非 null 是分歧，记进 audits/<格式>/<UTC 日期>.json 给本人看。
// 不写 world，不改 delivered/、队列和 results/；原文只在内存里用，不另存。

import (
	"bytes"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	auditEvery  = 7 * 86400 // 离上一次复核完成满这么多秒才跑；也只抽这么久以内落进 delivered/ 的
	auditSample = 30        // 每类最多抽这么多条
	auditKeep   = 26        // 每种格式最多留这么多份（半年）
)

// 两类，按这个顺序抽、装批、调用。
var auditKinds = []string{"screened", "null"}

func (c *capturer) auditDir() string {
	return filepath.Join(c.home, "audits", filepath.FromSlash(c.format))
}

// auditDue：audits/ 里最新的那份（文件名是 UTC 日期）完成满 7 天；没有过复核、那份读不出的也算满。
func auditDue(dir string, now int64) bool {
	latest := ""
	for _, name := range sortedNames(dir) {
		if strings.HasSuffix(name, ".json") {
			latest = name
		}
	}
	if latest == "" {
		return true
	}
	v, _ := readJSONFile(filepath.Join(dir, latest))
	finished := field(v, "finished_at")
	t, ok := fromDate(finished.s)
	return finished.k != kString || !ok || now-t >= auditEvery
}

// recordedSince：各目标的 recorded 只留 occurred_at 不早于 from 的，同服务端按 since 筛；没有 recorded 的目标照旧。
func recordedSince(targets Value, from string) Value {
	floor, ok := fromDate(from)
	if !ok || targets.k != kArray {
		return targets
	}
	var out []Value
	for _, target := range targets.arr {
		if recorded := get(target, "recorded"); recorded.k == kArray {
			var kept []Value
			for _, fact := range recorded.arr {
				at := get(fact, "occurred_at")
				if t, err := time.Parse(time.RFC3339, at.s); at.k == kString && err == nil && !t.Before(time.Unix(floor, 0)) {
					kept = append(kept, fact)
				}
			}
			target = target.With("recorded", ArrOf(kept))
		}
		out = append(out, target)
	}
	return ArrOf(out)
}

// auditPool：delivered/ 里 at 不早于 from 的两类，同一条只算一次。
func auditPool(raw string, from int64) map[string][]Value {
	pool := map[string][]Value{}
	for _, line := range jqSplit(raw, "\n") {
		v, ok := fromJSON(line)
		if !ok || v.k != kObject || get(v, "item_id").k != kString || get(v, "item_version").k != kString {
			continue
		}
		at := get(v, "at")
		if t, ok := fromDate(at.s); at.k != kString || !ok || t < from {
			continue
		}
		if status := get(v, "status"); is(status, "screened") || is(status, "null") {
			pool[status.s] = append(pool[status.s], v)
		}
	}
	for kind, rows := range pool {
		pool[kind] = uniqueBy(rows, func(v Value) Value { return Str(nameOf(v)) })
	}
	return pool
}

// auditSessionOf：delivered/ 这一行的会话（位置文件的 key）；没有 session、line 的旧行交 false。
func auditSessionOf(row Value) (string, bool) {
	session, line := get(row, "session"), get(row, "line")
	return session.s, session.k == kString && hex64.MatchString(session.s) && line.k == kNumber && line.f >= 1 && line.f == floorF(line.f)
}

// auditEntries：一段增量照钩子读增量的同一套规则（解析、条目身份、历史过滤）读出的条目，按行号排。认不出格式的没有条目。
func (c *capturer) auditEntries(inc increment) []Value {
	if !inc.recognized {
		return nil
	}
	var out []Value
	for _, e := range inc.entries {
		item, version := itemIdentity(c.format, e)
		out = append(out, Obj("item_id", Str(item), "item_version", Str(version), "role", Str(e.role), "reported_at", Str(e.reportedAt),
			"text", Str(e.text), "line", Int(int64(e.line))))
	}
	return sortBy(out, byLine)
}

func findItem(entries []Value, id Value) (Value, bool) {
	for _, e := range entries {
		if equal(get(e, "item_id"), id) {
			return e, true
		}
	}
	return Null, false
}

// lineEnd：前 n 行之后的字节位置；不到 n 行交 0。
func lineEnd(data []byte, n int) int {
	end := 0
	for ; n > 0; n-- {
		i := bytes.IndexByte(data[end:], '\n')
		if i < 0 {
			return 0
		}
		end += i + 1
	}
	return end
}

// auditFound：从会话文件找回的一条：candidate 是 delivered/ 的那一行加上 role、reported_at、text，context 是它前后各 3 条。
type auditFound struct {
	candidate Value
	context   []Value
}

// auditSession：一个会话在池子里的各行，从它的会话文件一起找回原文，按 nameOf 交出找到、版本也对得上的。
// 位置文件 transcripts/<session>.json 里记的会话文件读一遍，照钩子读增量的规则读出整份的条目，按 item_id 找；整份里找不到的
// （一轮中间被读进来、后来被同一轮更晚的答复顶掉的答复）按行号排，接着上一段的状态往后读，每读到其中一条那一行为止，
// 在这一段读出的条目里找，同钩子当时读到它那一段。位置文件没了或读不出、格式不对、会话文件不在确认过的文件夹下或不是普通文件
// （删了、Codex 压缩了、换成了符号链接）、读不了，都交空。会话文件和它整份的条目在这里读完就放掉。
func (c *capturer) auditSession(session string, rows []Value) map[string]auditFound {
	found := map[string]auditFound{}
	position, ok := readJSONFile(filepath.Join(c.home, "transcripts", session+".json"))
	path := field(position, "path")
	if !ok || !is(field(position, "format"), c.format) || path.k != kString || !transcriptOK(path.s, c.folder) {
		return found
	}
	data, err := os.ReadFile(path.s)
	if err != nil {
		return found
	}
	data = data[:bytes.LastIndexByte(data, '\n')+1]
	entries := c.auditEntries(parseIncrement(c.format, c.from, 0, Null, data))
	match := map[string]Value{}
	var missing []Value
	for _, row := range rows {
		if e, ok := findItem(entries, get(row, "item_id")); ok {
			match[nameOf(row)] = e
		} else {
			missing = append(missing, row)
		}
	}
	var chunk []Value
	end, read, state := 0, 0, Null
	for _, row := range sortBy(missing, byLine) {
		if line := int(get(row, "line").f); line > read {
			n := lineEnd(data[end:], line-read)
			if n == 0 {
				break
			}
			inc := parseIncrement(c.format, c.from, read, state, data[end:end+n])
			chunk, end, read, state = c.auditEntries(inc), end+n, line, Obj("state", inc.state)
		}
		if e, ok := findItem(chunk, get(row, "item_id")); ok {
			match[nameOf(row)] = e
		}
	}
	for _, row := range rows {
		e, ok := match[nameOf(row)]
		if !ok || !equal(get(e, "item_version"), get(row, "item_version")) {
			continue
		}
		var before, after []Value
		for _, x := range entries {
			switch order := compare(byLine(x), byLine(e)); {
			case order < 0:
				before = append(before, x)
			case order > 0 && len(after) < limitContext:
				after = append(after, x)
			}
		}
		found[nameOf(row)] = auditFound{
			candidate: row.Merge(Obj("role", get(e, "role"), "reported_at", get(e, "reported_at"), "text", get(e, "text"))),
			context:   append(before[max(0, len(before)-limitContext):], after...),
		}
	}
	return found
}

// auditPick：每类打乱后按顺序取，找得回原文的取满 30 条为止，找不回的记进 unreadable。取到某一行时它的会话还没读过，
// 就把池子里这个会话的行（两类）一起找完，一个会话文件只读一遍。每读一个会话文件前看剩下的时间，不够交 false。
func (r *roundRun) auditPick(pool map[string][]Value, counts map[string]*auditCounts) (picked, around map[string][]Value, ok bool) {
	bySession := map[string][]Value{}
	for _, kind := range auditKinds {
		for _, row := range pool[kind] {
			if session, ok := auditSessionOf(row); ok {
				bySession[session] = append(bySession[session], row)
			}
		}
	}
	found, read := map[string]auditFound{}, set{}
	picked, around = map[string][]Value{}, map[string][]Value{}
	for _, kind := range auditKinds {
		rows := append([]Value{}, pool[kind]...)
		rand.Shuffle(len(rows), func(i, j int) { rows[i], rows[j] = rows[j], rows[i] })
		for _, row := range rows {
			if len(picked[kind]) == auditSample {
				break
			}
			if session, ok := auditSessionOf(row); ok && !read[session] {
				if _, ok := r.auditBudget(); !ok {
					return nil, nil, false
				}
				read[session] = true
				for name, f := range r.c.auditSession(session, bySession[session]) {
					found[name] = f
				}
			}
			f, ok := found[nameOf(row)]
			if !ok {
				counts[kind].unreadable++
				continue
			}
			picked[kind] = append(picked[kind], f.candidate)
			around[nameOf(f.candidate)] = f.context
		}
	}
	return picked, around, true
}

// auditBatches：一类抽中的候选按会话、行号排，照判断那一步装批：每批最多 30 条候选，候选原文合计最多 60000 字（超长的按截过的算）。
// 一个会话里抽中几条时，各自的前后文按行号接成这个会话的条目，同一个会话的候选在一组里。
func auditBatches(rows []Value, around map[string][]Value, omitted string) []judgeBatch {
	rows = sortBy(rows, func(v Value) Value { return Arr(Str(sessionOf(v)), byLine(v)) })
	entries := map[string][]Value{}
	for _, r := range rows {
		k := sessionOf(r)
		entries[k] = append(append(entries[k], r), around[nameOf(r)]...)
	}
	for k, list := range entries {
		entries[k] = sortBy(uniqueBy(list, func(v Value) Value { return Str(nameOf(v)) }), byLine)
	}
	var batches []judgeBatch
	var current []Value
	chars := 0
	seal := func() {
		if len(current) > 0 {
			batches = append(batches, judgeBatch{items: current, body: batchBody(current, entries, omitted)})
		}
		current, chars = nil, 0
	}
	for _, r := range rows {
		text, _ := clip(get(r, "text"), omitted, limitItemChars, 6000, 2000)
		n := length(text)
		if len(current) >= limitBatch || chars+n > limitBatchChars {
			seal()
		}
		current = append(current, r)
		chars += n
	}
	seal()
	return batches
}

// auditAnswer：一批复核的结果。disagree 是合规、带 occurred_at 的非 null（候选带着去掉了 null 字段的 result）；
// invalid 是交回不合规的候选，不带交回的内容；unanswered 是漏判的条数（没交，或交了没带 result）。
type auditAnswer struct {
	disagree, invalid []Value
	unanswered        int
}

// auditAnswers：复核那次的回复照判断那一步的规则（judgeOutcomeOf）对回这一批的候选：合规却没带 occurred_at 的同判断改成 null，
// 不算分歧。调用失败、读不出 results 数组交 false。
func auditAnswers(r cliResult, batch []Value) (auditAnswer, bool) {
	o, ok := try(func() judgeOutcome { return judgeOutcomeOf(r, batch) })
	if r.failure.Truthy() || !ok || !o.failure.IsNull() {
		return auditAnswer{}, false
	}
	a := auditAnswer{invalid: o.invalid, unanswered: len(o.missed)}
	for _, x := range o.accepted {
		if !get(x, "result").IsNull() {
			a.disagree = append(a.disagree, x)
		}
	}
	return a, true
}

// auditRef：audits/ 里记的是哪一条：类别、身份、会话和行号，挡下的另带挡下它的规则。
func auditRef(kind string, e Value) Value {
	x := Obj("kind", Str(kind), "item_id", get(e, "item_id"), "item_version", get(e, "item_version"), "session", get(e, "session"),
		"line", get(e, "line"))
	if kind == "screened" {
		x = x.With("by", get(e, "by"))
	}
	return x
}

type auditCounts struct{ pool, sampled, unreadable, unanswered, invalid, failed int }

func (n auditCounts) value() Value {
	return Obj("pool", Int(int64(n.pool)), "sampled", Int(int64(n.sampled)), "unreadable", Int(int64(n.unreadable)),
		"unanswered", Int(int64(n.unanswered)), "invalid", Int(int64(n.invalid)), "failed", Int(int64(n.failed)))
}

// auditBudget：复核的一次调用最多等多久：一轮硬时限的四分之一，不超过剩下的；剩下的不到硬时限的二十分之一就交 false。
func (r *roundRun) auditBudget() (int64, bool) {
	budget := min(r.left(), r.limit/4)
	return budget, budget >= r.limit/20
}

// audit：一轮末尾的每周复核，见文件开头。开始时要剩下一半的时间，audits/ 写不了就不调用、直接作罢。每批一次调用，
// 读会话文件和起每一批之前都看剩下的时间：一批都没判就不够了，这一次什么都不写，留给下一轮；判了几批才不够的，判出的照样写进去，
// 记 partial。某一批调用失败或回复读不出不重试，记进 failed。sampled 是交去复核的条数，没起的批不算。
func (r *roundRun) audit() {
	c := r.c
	at := time.Now().UTC()
	now := at.Unix()
	if !r.auditing || r.audited.targets.k != kArray || get(r.state, "failure").Truthy() || r.left() < r.limit/2 {
		return
	}
	dir := c.auditDir()
	prefix, _, _ := strings.Cut(c.format, "/")
	for _, d := range []string{filepath.Join(c.home, "audits"), filepath.Join(c.home, "audits", prefix), dir} {
		if !privateDir(d, false) {
			r.state = r.state.With("audit", Obj("failure", failure("other", "audits_unwritable")))
			return
		}
	}
	id, name, started := at.Format("20060102T150405Z")+"-"+randomHex(4), at.Format("2006-01-02")+".json", toDate(float64(now))
	raw, _ := readText(r.delivered)
	pool := auditPool(raw, now-auditEvery)
	counts := map[string]*auditCounts{}
	for _, kind := range auditKinds {
		counts[kind] = &auditCounts{pool: len(pool[kind])}
	}
	picked, around, ok := r.auditPick(pool, counts)
	if !ok {
		r.state = r.state.With("audit", Obj("failure", failure("other", "no_time")))
		return
	}
	omitted, _ := try(func() string { return promptSection(r.prompts, "omitted") })
	var disagreements, invalid []Value
	usage := Null
	called, partial := false, false
batches:
	for _, kind := range auditKinds {
		n := counts[kind]
		for _, batch := range auditBatches(picked[kind], around, omitted) {
			budget, ok := r.auditBudget()
			if !ok {
				partial = true
				break batches
			}
			prompt, ok := try(func() string {
				return judgePrompt(promptSection(r.prompts, "judge"), trimRightJQ(r.rules), r.audited, r.submitted, batch) + "\n"
			})
			if !ok {
				prompt = ""
			}
			result := r.call("audit", budget, prompt)
			called = true
			usage = addUsage(usage, result.usage)
			n.sampled += len(batch.items)
			got, ok := auditAnswers(result, batch.items)
			if !ok {
				n.failed++
				continue
			}
			n.unanswered += got.unanswered
			n.invalid += len(got.invalid)
			for _, e := range got.disagree {
				disagreements = append(disagreements, auditRef(kind, e).With("result", get(e, "result")))
			}
			for _, e := range got.invalid {
				invalid = append(invalid, auditRef(kind, e))
			}
		}
	}
	if partial && !called {
		r.state = r.state.With("audit", Obj("failure", failure("other", "no_time")))
		return
	}
	screened, nulls := counts["screened"].value(), counts["null"].value()
	record := Obj("audit_id", Str(id), "round_id", Str(r.id), "agent", Str(c.agent), "format", Str(c.format), "started_at", Str(started),
		"finished_at", Str(nowISO()), "partial", Bool(partial), "window", Obj("from", Str(toDate(float64(now-auditEvery))), "to", Str(started)),
		"screened", screened, "null", nulls, "disagreements", ArrOf(disagreements), "invalid", ArrOf(invalid), "usage", usage)
	if !replaceFile(filepath.Join(dir, name), record.JSON()+"\n", c.work) {
		r.state = r.state.With("audit", Obj("failure", failure("other", "audits_unwritable")))
		return
	}
	var kept []string
	for _, n := range sortedNames(dir) {
		if strings.HasSuffix(n, ".json") {
			kept = append(kept, n)
		}
	}
	for _, n := range kept[:max(0, len(kept)-auditKeep)] {
		os.Remove(filepath.Join(dir, n))
	}
	r.state = r.state.With("audit", Obj("file", Str("audits/"+c.format+"/"+name), "screened", screened, "null", nulls,
		"disagreements", Int(int64(len(disagreements))), "partial", Bool(partial)))
}
