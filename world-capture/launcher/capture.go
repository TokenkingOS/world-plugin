package main

// 读增量：0.1.6 的 capture.jq 与 capture.sh 的 read_file、read_increment。读取规则逐条照 packages/world-capture 的
// adapters.mjs（claude、codex 两种解析）、index.mjs（逐行读取、条目身份、历史过滤）和 contract.mjs（utc、before）。
// 会话文件的一行按 JSON.parse 读（parseJS）：孤立代理项留在原文里，含它的条目丢掉、记 text_not_well_formed，同库的 isWellFormed。

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

const (
	claudeFormat = "claude-session-jsonl/1"
	codexFormat  = "codex-rollout-jsonl/1"
)

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// ---------- JS 语义的小件 ----------

// JS 的 String.prototype.trim 去掉的字符（WhiteSpace 加 LineTerminator）。
func isJSSpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return r >= 0x2000 && r <= 0x200A
}

// JS 正则里 . 不匹配、多行模式的 ^ $ 认作行边界的字符。
func isEOL(r rune) bool { return r == '\n' || r == '\r' || r == 0x2028 || r == 0x2029 }

func ltrimJS(s string) string { return strings.TrimLeftFunc(s, isJSSpace) }
func blankJS(s string) bool   { return strings.TrimLeftFunc(s, isJSSpace) == "" }

// truthy 是 JS 的真假（capture.jq 的 truthy）。
func truthy(v Value) bool {
	switch v.k {
	case kNull, kFalse:
		return false
	case kNumber:
		return v.f != 0
	case kString:
		return v.s != ""
	}
	return true
}

// jsstr 是 JS 模板字符串里 `${x}` 的结果。
func jsstr(v Value) string {
	switch v.k {
	case kString:
		return v.s
	case kNull:
		return "null"
	case kTrue:
		return "true"
	case kFalse:
		return "false"
	case kNumber:
		return jsNumber(v.f)
	case kArray:
		parts := make([]string, len(v.arr))
		for i, x := range v.arr {
			if !x.IsNull() {
				parts[i] = jsstr(x)
			}
		}
		return strings.Join(parts, ",")
	}
	return "[object Object]"
}

// ---------- adapters.mjs 的判断 ----------

func textBlocks(v Value, kinds ...string) []string {
	switch v.k {
	case kString:
		return []string{v.s}
	case kArray:
		var out []string
		for _, b := range v.arr {
			if b.k != kObject {
				continue
			}
			t, x := get(b, "type"), get(b, "text")
			if t.k == kString && x.k == kString && contains(kinds, t.s) {
				out = append(out, x.s)
			}
		}
		return out
	}
	return nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func knownContent(v Value) bool {
	if v.k == kString {
		return true
	}
	if v.k != kArray {
		return false
	}
	for _, b := range v.arr {
		if b.k != kObject {
			return false
		}
		t := get(b, "type")
		if t.k != kString || (t.s == "text" && get(b, "text").k != kString) {
			return false
		}
	}
	return true
}

func realRequest(s string) bool {
	if blankJS(s) {
		return false
	}
	t := ltrimJS(s)
	for _, p := range []string{"<", "# AGENTS.md", "[Request interrupted", "Caveat:"} {
		if strings.HasPrefix(t, p) {
			return false
		}
	}
	return true
}

// Claude Code 压缩上下文后自己写的续接摘要，不是本人说的话。只用于 Claude 的会话。
func continuationSummary(s string) bool {
	return strings.HasPrefix(ltrimJS(s), "This session is being continued from a previous conversation")
}

// 某一行（按 JS 的行边界切）是「Base directory for this skill: …/<名字>」加上行末的空白。
func skillDirectory(s string, names ...string) bool {
	const prefix = "Base directory for this skill: "
	if !strings.Contains(s, prefix) {
		return false
	}
	for _, line := range strings.FieldsFunc(s, isEOL) {
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		rest := strings.TrimRightFunc(line[len(prefix):], isJSSpace)
		for _, name := range names {
			if strings.HasSuffix(rest, "/"+name) || strings.HasSuffix(rest, `\`+name) {
				return true
			}
		}
	}
	return false
}

// 以 $ 或 / 开头、接一个可选前缀和名字，后面不跟 stop 里的字符。
func slashCommand(s string, prefixes []string, name, stop string) bool {
	t := ltrimJS(s)
	if t == "" || (t[0] != '$' && t[0] != '/') {
		return false
	}
	for _, p := range prefixes {
		rest, ok := strings.CutPrefix(t[1:], p+name)
		if ok && (rest == "" || !strings.ContainsRune(stop, rune(rest[0]))) {
			return true
		}
	}
	return false
}

const wordChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

func dailyRequest(s string) bool {
	return slashCommand(s, []string{"", "tkos-", "world:", "skill:", "skill:tkos-"}, "world-daily", wordChars+"-") ||
		strings.Contains(s, "<command-name>/world-daily</command-name>") || strings.Contains(s, "<command-name>/tkos-world-daily</command-name>") ||
		strings.Contains(s, "<command-name>/world:world-daily</command-name>") ||
		skillDirectory(s, "world-daily", "tkos-world-daily") ||
		strings.HasPrefix(ltrimJS(s), `<skill name="world-daily"`) || strings.HasPrefix(ltrimJS(s), `<skill name="tkos-world-daily"`)
}

func extractRequest(s string) bool {
	return slashCommand(s, []string{"", "world:", "skill:"}, "world-source-extract", wordChars) ||
		strings.Contains(s, "<command-name>/world-source-extract</command-name>") ||
		strings.Contains(s, "<command-name>/world:world-source-extract</command-name>") ||
		skillDirectory(s, "world-source-extract") || strings.HasPrefix(ltrimJS(s), `<skill name="world-source-extract"`)
}

func selfReport(s string) bool { return dailyRequest(s) || extractRequest(s) }

const dailyMark = "【日进展"

func dailyWrite(name, args Value) bool {
	if name.k != kString || !strings.HasSuffix(name.s, "world_record_event") {
		return false
	}
	text := "{}"
	switch args.k {
	case kString:
		text = args.s
	case kNull:
	default:
		text = args.JSON()
	}
	return strings.Contains(text, dailyMark)
}

// ---------- 逐行读取 ----------

type rawEntry struct {
	role, text string
	raw        Value // 会话文件里的原始时刻
	id         string
	line       int   // 在会话文件里的行号（从 1 起）
	priority   int   // Codex：这种表示的优先级
	key        Value // Codex：拼 id 用的那一项
}

type parseRun struct {
	format  string
	state   Value
	pending *rawEntry
	msgs    []rawEntry
	out     []rawEntry
	issues  map[string]int
	n       int
}

func (p *parseRun) bump(code string) { p.issues[code]++ }

func (p *parseRun) setState(key string, v Value) { p.state = p.state.With(key, v) }

func (p *parseRun) claudeStep(r Value) {
	t := get(r, "type")
	isUser, isAssistant := equal(t, Str("user")), equal(t, Str("assistant"))
	if get(r, "sessionId").k == kString && (isUser || isAssistant) {
		p.setState("recognized", True)
	}
	if truthy(get(r, "isSidechain")) || (!isUser && !isAssistant) {
		return
	}
	content := field(get(r, "message"), "content")
	if !knownContent(content) {
		p.bump("parse_failed")
		return
	}
	var texts []string
	for _, x := range textBlocks(content, "text") {
		if !blankJS(x) {
			texts = append(texts, x)
		}
	}
	var ids []Value
	for _, x := range []Value{field(get(r, "message"), "id"), get(r, "uuid"), get(r, "timestamp")} {
		if !x.IsNull() {
			ids = append(ids, x)
		}
	}
	session := "undefined"
	if _, ok := r.Lookup("sessionId"); ok {
		session = jsstr(get(r, "sessionId"))
	}
	key := itoa(p.n)
	if len(ids) > 0 {
		key = jsstr(ids[0])
	}
	makeEntry := func(role, text string) *rawEntry {
		return &rawEntry{role: role, text: text, raw: get(r, "timestamp"), id: session + "/" + role + "/" + key, line: p.n}
	}
	daily := false
	for _, x := range texts {
		if selfReport(x) {
			daily = true
		}
	}
	if content.k == kArray {
		for _, b := range content.arr {
			if equal(get(b, "type"), Str("tool_use")) && dailyWrite(get(b, "name"), get(b, "input")) {
				daily = true
			}
		}
	}
	switch {
	case daily:
		if p.pending != nil && !get(p.state, "daily").Truthy() {
			p.out = append(p.out, *p.pending)
		}
		p.pending = nil
		p.setState("daily", True)
	case isAssistant && len(texts) > 0 && !get(p.state, "daily").Truthy():
		p.pending = makeEntry("assistant", texts[len(texts)-1])
	case isUser && !truthy(get(r, "isMeta")):
		var requests []string
		for _, x := range texts {
			if realRequest(x) && !continuationSummary(x) {
				requests = append(requests, x)
			}
		}
		if len(requests) > 0 {
			if p.pending != nil {
				p.out = append(p.out, *p.pending)
			}
			p.pending = nil
			p.setState("daily", False)
			p.out = append(p.out, *makeEntry("user", strings.Join(requests, "\n")))
		}
	}
}

func (p *parseRun) claudeFinish() bool {
	recognized := get(p.state, "recognized")
	if recognized.Truthy() && p.pending != nil {
		p.out = append(p.out, *p.pending)
	}
	p.pending = nil
	return tostring(recognized) == "true"
}

func (p *parseRun) codexMessages(r Value) {
	pl := get(r, "payload")
	pt := field(pl, "type")
	ts := get(r, "timestamp")
	typ := get(r, "type")
	add := func(role, text string, priority int, id Value) {
		key := id
		if key.IsNull() {
			key = ts
		}
		if key.IsNull() {
			key = Str("line-" + itoa(p.n))
		}
		p.msgs = append(p.msgs, rawEntry{role: role, text: text, priority: priority, raw: ts, key: key, line: p.n})
	}
	is := func(v Value, s string) bool { return equal(v, Str(s)) }
	if is(typ, "event_msg") && is(pt, "user_message") && get(pl, "message").k == kString {
		add("user", get(pl, "message").s, 1, Null)
	}
	if is(typ, "event_msg") && is(pt, "task_complete") && get(pl, "last_agent_message").k == kString {
		add("assistant", get(pl, "last_agent_message").s, 1, get(pl, "turn_id"))
	}
	if is(typ, "event_msg") && is(pt, "item_completed") && truthy(get(pl, "item")) {
		item := get(pl, "item")
		it := field(item, "type")
		if is(it, "UserMessage") {
			for _, x := range textBlocks(field(item, "content"), "text") {
				add("user", x, 2, get(item, "id"))
			}
		}
		if is(it, "AgentMessage") && is(field(item, "phase"), "final_answer") {
			for _, x := range textBlocks(field(item, "content"), "text", "Text") {
				add("assistant", x, 2, get(item, "id"))
			}
		}
		if is(it, "McpToolCall") && dailyWrite(get(item, "tool"), get(item, "arguments")) {
			add("daily", "", 0, Null)
		}
	}
	if is(typ, "response_item") && is(pt, "message") {
		if is(get(pl, "role"), "user") {
			for _, x := range textBlocks(get(pl, "content"), "input_text") {
				add("user", x, 0, Null)
			}
		}
		if is(get(pl, "role"), "assistant") && (is(get(pl, "phase"), "final_answer") || is(get(pl, "channel"), "final")) {
			for _, x := range textBlocks(get(pl, "content"), "output_text") {
				add("assistant", x, 0, Null)
			}
		}
	}
	if is(typ, "response_item") && (is(pt, "function_call") || is(pt, "custom_tool_call")) {
		args := get(pl, "arguments")
		if args.IsNull() {
			args = get(pl, "input")
		}
		if dailyWrite(get(pl, "name"), args) {
			add("daily", "", 0, Null)
		}
	}
}

func (p *parseRun) codexStep(r Value) {
	if equal(get(r, "type"), Str("session_meta")) {
		pl := get(r, "payload")
		p.setState("session", field(pl, "id"))
		p.setState("subagent", Bool(equal(field(pl, "thread_source"), Str("subagent")) || truthy(field(field(pl, "source"), "subagent"))))
	}
	p.codexMessages(r)
}

func (p *parseRun) codexFinish() bool {
	up, ap := []Value{get(p.state, "up")}, []Value{get(p.state, "ap")}
	for _, m := range p.msgs {
		switch m.role {
		case "user":
			up = append(up, Int(int64(m.priority)))
		case "assistant":
			ap = append(ap, Int(int64(m.priority)))
		}
	}
	p.setState("up", maxOf(up))
	p.setState("ap", maxOf(ap))
	session := get(p.state, "session")
	recognized := session.k == kString
	topUser, topAssistant := get(p.state, "up"), get(p.state, "ap")
	for _, m := range p.msgs {
		atTop := func(top Value) bool { return equal(Int(int64(m.priority)), top) }
		switch {
		case m.role == "daily" || (m.role == "user" && atTop(topUser) && selfReport(m.text)):
			p.setState("daily", True)
		case m.role == "user" && atTop(topUser) && realRequest(m.text):
			p.setState("daily", False)
			m.id = tostring(session) + "/user/" + jsstr(m.key)
			p.out = append(p.out, m)
		case m.role == "assistant" && atTop(topAssistant) && !get(p.state, "daily").Truthy() && !blankJS(m.text):
			m.id = tostring(session) + "/assistant/" + jsstr(m.key)
			p.out = append(p.out, m)
		}
	}
	if get(p.state, "subagent").Truthy() {
		p.out = nil
	}
	p.msgs = nil
	return recognized
}

func initialState(format string) Value {
	if format == claudeFormat {
		return Obj("recognized", False, "daily", False)
	}
	return Obj("session", Null, "subagent", False, "up", Int(-1), "ap", Int(-1), "daily", False)
}

type entry struct {
	id, role, text string
	raw            string
	reportedAt     string
	line           int
}

type increment struct {
	recognized bool
	lines      int
	state      Value
	issues     map[string]int
	entries    []entry
}

// lineValid：这一行是合法的 UTF-8，也没有 NUL（capture.sh 先用 grep 挑出来的那些行）。TextDecoder（fatal）读不出前者。
func lineValid(b []byte) bool { return utf8.Valid(b) && bytes.IndexByte(b, 0) < 0 }

// parseIncrement 读一段只含完整行的增量。base 是这段之前已读的行数。
func parseIncrement(format, from string, base int, previous Value, data []byte) increment {
	p := &parseRun{format: format, state: initialState(format), issues: map[string]int{}, n: base}
	if !previous.IsNull() {
		p.state = get(previous, "state")
	}
	lines := bytes.Split(data, []byte("\n"))
	lines = lines[:len(lines)-1]
	for _, line := range lines {
		p.n++
		if len(line) == 0 {
			continue
		}
		if !lineValid(line) {
			p.bump("parse_failed")
			continue
		}
		line = bytes.TrimPrefix(line, []byte("\xef\xbb\xbf"))
		row, ok := parseJS(line)
		if bytes.HasPrefix(line, []byte("\xef\xbb\xbf")) || !ok || row.k != kObject {
			p.bump("parse_failed")
			continue
		}
		if format == claudeFormat {
			p.claudeStep(row)
		} else {
			p.codexStep(row)
		}
	}
	var recognized bool
	if format == claudeFormat {
		recognized = p.claudeFinish()
	} else {
		recognized = p.codexFinish()
	}
	inc := increment{recognized: recognized, lines: p.n, state: p.state, issues: p.issues}
	for _, e := range p.out {
		at, ok := utc(e.raw)
		switch {
		case hasSurrogate(e.text):
			p.bump("text_not_well_formed")
		case !ok:
			p.bump("time_unknown")
		case before(at, from):
		default:
			inc.entries = append(inc.entries, entry{id: e.id, role: e.role, text: e.text, raw: e.raw.s, reportedAt: at, line: e.line})
		}
	}
	return inc
}

// itemIdentity：item_id 是 entry- 加 sha256("<格式>:<条目 id>")，item_version 是 sha256(JSON.stringify([role, text, reported_at]))，
// 这里的 reported_at 是会话文件里的原始时刻串。
func itemIdentity(format string, e entry) (string, string) {
	var b strings.Builder
	b.WriteByte('[')
	jsString(&b, e.role)
	b.WriteByte(',')
	jsString(&b, e.text)
	b.WriteByte(',')
	jsString(&b, e.raw)
	b.WriteByte(']')
	return "entry-" + sha256Hex(wellFormedBytes(format+":"+e.id)), sha256Hex([]byte(b.String()))
}

// ---------- 一个会话文件 ----------

type capturer struct {
	agent, event, format string
	home                 string
	sourceID, from       string
	folder               string
	screen               bool   // config.json 的 screen_short：300 字规则开着
	queue                string // queue/<格式>
	work                 string // 这一次运行的临时目录
}

var hex64 = regexp.MustCompile(`\A[0-9a-f]{64}\z`)
var digitsOnly = regexp.MustCompile(`\A[0-9]+\z`)

// configEntry：config.json 里这种 Agent 的那一项合用时，交出 source_id、历史起点（UTC）和确认过的文件夹。
func configEntry(config Value, agent, format string) (sourceID, from, folder string, ok bool) {
	e := field(field(config, "agents"), agent)
	from, fromOK := utc(field(e, "history_from"))
	sel, ver, src, dir := get(e, "selection_id"), get(e, "selection_version"), get(e, "source_id"), get(e, "folder")
	if e.k != kObject || !equal(get(e, "format"), Str(format)) || !fromOK {
		return "", "", "", false
	}
	if sel.k != kString || !uuidAnyCase.MatchString(sel.s) {
		return "", "", "", false
	}
	if ver.k != kNumber || ver.f < 1 || ver.f != floorF(ver.f) {
		return "", "", "", false
	}
	if src.k != kString || !sourceIDPattern.MatchString(src.s) {
		return "", "", "", false
	}
	if dir.k != kString || !rootedFolder(dir.s) {
		return "", "", "", false
	}
	return src.s, from, dir.s, true
}

var uuidAnyCase = regexp.MustCompile(`\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z`)
var sourceIDPattern = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9._:/@+~-]{0,199}\z`)

// readConfig 读 config.json：读不出、不止一个值时 ok 为假（sh 用 --slurpfile，取第一个值）。
func readJSONFile(path string) (Value, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Null, false
	}
	vs, ok := parseJQ(b)
	if !ok {
		return Null, false
	}
	if len(vs) == 0 {
		return Null, true
	}
	return vs[0], true
}

// positionLine：上次的位置文件合用时交出 offset、head_bytes、head_sha256、lines。
func positionLine(v Value, format, path string) (offset, headBytes int64, headSha string, lines int64, ok bool) {
	if v.k != kObject || !equal(get(v, "format"), Str(format)) || !equal(get(v, "path"), Str(path)) {
		return
	}
	var nums [3]int64
	for i, key := range []string{"offset", "head_bytes", "lines"} {
		n := get(v, key)
		if n.k != kNumber || n.f < 0 || n.f != floorF(n.f) || !digitsOnly.MatchString(tostring(n)) {
			return
		}
		nums[i] = int64(n.f)
	}
	sha := get(v, "head_sha256")
	if sha.k != kString || !hex64.MatchString(sha.s) || get(v, "state").k != kObject {
		return
	}
	return nums[0], nums[1], sha.s, nums[2], true
}

func headDigest(path string, n int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	buf := make([]byte, n)
	got, _ := readFull(f, buf)
	return sha256Hex(buf[:got])
}

func readFull(f *os.File, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := f.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// readFile 读一个会话文件上次读到的位置之后、已经写完整的行，新条目放进队列。
func (c *capturer) readFile(path string) {
	key := sha256Hex([]byte(path))
	position := filepath.Join(c.home, "transcripts", key+".json")
	info, err := os.Stat(path)
	if err != nil {
		return
	}
	size, mtime := info.Size(), info.ModTime().Unix()
	var offset, lines int64
	previous := Null
	if st, err := os.Stat(position); err == nil && st.Mode().IsRegular() {
		if b, err := os.ReadFile(position); err == nil {
			values, whole := parseJQPrefix(b)
			for _, v := range values {
				o, hb, sha, l, ok := positionLine(v, c.format, path)
				if !ok {
					continue
				}
				// 文件变小，或开头那一段的摘要变了：当作被改写，从头读。
				if size >= o && headDigest(path, hb) == sha {
					// 位置文件后面坏了：capture.sh 取上次的状态时整份读不出，这一次什么都不写（下次还是这样）。
					if !whole {
						return
					}
					offset, lines, previous = o, l, values[0]
				}
				break
			}
		}
	}
	if size > offset {
		f, err := os.Open(path)
		if err != nil {
			return
		}
		chunk := make([]byte, size-offset)
		got, _ := f.ReadAt(chunk, offset)
		f.Close()
		chunk = chunk[:got]
		if complete := bytes.LastIndexByte(chunk, '\n') + 1; complete > 0 && c.readIncrement(path, chunk[:complete], offset, size, mtime, lines, previous) {
			return
		}
	}
	// 没有读到新条目时位置照旧：SessionEnd 只记上会话已结束，SessionStart（新开或恢复）只去掉它。
	switch {
	case previous.k != kObject:
	case c.event == "SessionEnd" && get(previous, "ended_at").IsNull():
		replaceFile(position, previous.With("ended_at", Str(nowISO())).JSON()+"\n", c.work)
	case c.event == "SessionStart" && !get(previous, "ended_at").IsNull():
		replaceFile(position, previous.Without("ended_at").JSON()+"\n", c.work)
	}
}

// readIncrement 读一段增量，写了位置文件交 true。
func (c *capturer) readIncrement(path string, data []byte, offset, size, mtime, base int64, previous Value) bool {
	inc := parseIncrement(c.format, c.from, int(base), previous, data)
	// 认不出是这种格式（Claude 没有带会话 id 的消息，Codex 还没有 session_meta）：不前进，下次从同一处再读。
	if !inc.recognized {
		return false
	}
	offset += int64(len(data))
	headBytes := min(offset, 4096)
	headSha := headDigest(path, headBytes)
	// 先列队列、再读已送出：后台轮是先记已送出、再删队列文件，这个顺序下刚送出的条目不会被重新排进来。
	inQueue := listNames(c.queue)
	done := deliveredNames(filepath.Join(c.home, "delivered", c.format+".jsonl"), ".json")
	seen := nowISO()
	issues, ok := mergeIssues(previous, inc.issues)
	if !ok {
		return false
	}
	key := sha256Hex([]byte(path))
	position := Obj("path", Str(path), "format", Str(c.format), "offset", Int(offset), "size", Int(size), "mtime", Int(mtime),
		"head_bytes", Int(headBytes), "head_sha256", Str(headSha), "lines", Int(int64(inc.lines)), "state", inc.state, "issues", issues,
		"updated_at", Str(seen))
	written := set{}
	type queued struct{ name, body string }
	var fresh []queued
	for _, e := range inc.entries {
		item, version := itemIdentity(c.format, e)
		name := item + "@" + version + ".json"
		if inQueue[name] || done[name] || written[name] {
			continue
		}
		written[name] = true
		body := Obj("item_id", Str(item), "item_version", Str(version), "locator", Str("local-capture:"+c.sourceID+"/"+item+"@"+version),
			"role", Str(e.role), "reported_at", Str(e.reportedAt), "text", Str(e.text), "first_seen_at", Str(seen),
			"session", Str(key), "line", Int(int64(e.line))).JSON()
		fresh = append(fresh, queued{name, body})
	}
	sort.Slice(fresh, func(i, j int) bool { return fresh[i].name < fresh[j].name })
	// 先把条目放进队列，再写位置：中途断了，下次从旧位置重读，同名条目不会重复。
	for _, q := range fresh {
		replaceFile(filepath.Join(c.queue, q.name), q.body+"\n", c.work)
	}
	// 会话已结束就一直记着，直到 SessionStart（会话恢复）去掉：写之前再读一次盘上的位置文件，同时在读的另一个进程刚记上的也不丢。
	file := filepath.Join(c.home, "transcripts", key+".json")
	ended := Null
	if current, ok := readJSONFile(file); ok && field(current, "ended_at").k == kString && c.event != "SessionStart" {
		ended = field(current, "ended_at")
	} else if c.event == "SessionEnd" {
		ended = Str(seen)
	}
	if !ended.IsNull() {
		position = position.With("ended_at", ended)
	}
	replaceFile(file, position.JSON()+"\n", c.work)
	return true
}

// mergeIssues：上次位置文件里的 issues 加上这一段的，键按字母排。
func mergeIssues(previous Value, current map[string]int) (Value, bool) {
	return try(func() Value {
		var all []Value
		old := alt(get(alt(previous, Obj()), "issues"), Obj())
		if old.k != kObject {
			raise("issues")
		}
		for _, k := range old.Keys() {
			all = append(all, Obj("key", Str(k), "value", get(old, k)))
		}
		names := make([]string, 0, len(current))
		for k := range current {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, k := range names {
			all = append(all, Obj("key", Str(k), "value", Int(int64(current[k]))))
		}
		out := Obj()
		for _, group := range groupBy(all, func(v Value) Value { return get(v, "key") }) {
			values := make([]Value, len(group))
			for i, g := range group {
				values[i] = get(g, "value")
			}
			out = out.With(get(group[0], "key").s, sum(values))
		}
		return out
	})
}

// listNames 是 ls 列出的名字（不含以 . 开头的）。
func listNames(dir string) set {
	out := set{}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") {
			out[e.Name()] = true
		}
	}
	return out
}

// deliveredNames：delivered/<格式>.jsonl 里每一行读得出的对象的 "<item_id>@<item_version>"（加上 suffix）。
func deliveredNames(file, suffix string) set {
	out := set{}
	b, err := os.ReadFile(file)
	if err != nil {
		return out
	}
	for _, line := range jqSplit(string(jqValidUTF8(b)), "\n") {
		v, ok := fromJSON(line)
		if !ok || v.k != kObject {
			continue
		}
		out[nameOf(v)+suffix] = true
	}
	return out
}

// parseJQPrefix：一串值里读得出的前面那些（jq 读到坏的地方才停，之前的照样输出）。
func parseJQPrefix(b []byte) ([]Value, bool) {
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
			return out, false
		}
		out = append(out, v)
	}
}

func itoa(n int) string { return Int(int64(n)).JSON() }
