package main

// 起轮决定与后台轮：0.1.6 的 capture.sh 的 decide、round、run_round 及其各步（ADR 决定三、九），加上准备一步和按会话分组的判断。
// 一轮里每次模型调用是一次单独的 claude -p 或 codex exec：准备那次只有两个只读工具，读本轮各批共用的选择和目标；
// 判断那次不带任何工具、不连 world，一次答完，交回的判断由这里核对、落盘；送出那次只有送出和读回两个工具，
// 参数是这里算好的骨架加上已落盘的判断；然后只报运行回执。到了每周复核的时候，末尾再按判断的调法重判一批抽样（audit.go）。

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 后台轮的 world 连接：服务名 world 和地址要与 world 插件的 mcp.json 逐字一致，令牌按这两样找。
const worldURL = "https://world.tokenkingos.com/app/mcp"

// 锁比一轮的硬时限再老这么多秒，就当持锁的进程已经不在了。
const lockMargin = 600

func roundLimit() int64 {
	v := os.Getenv("TKOS_CAPTURE_ROUND_LIMIT")
	if v == "" || strings.Trim(v, "0123456789") != "" {
		return 1200
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 1200
	}
	return n
}

// entryFiles：目录（含子目录）下的 entry-*.json。
func entryFiles(dir string) []string {
	var out []string
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasPrefix(d.Name(), "entry-") && strings.HasSuffix(d.Name(), ".json") {
			out = append(out, p)
		}
		return nil
	})
	return out
}

// planInput：排一轮要读的本机状态。读不出的文件只跳过它自己。
func (c *capturer) planInput(omitted string) planInput {
	in := planInput{format: c.format, omitted: omitted, screen: c.screen, ended: set{}, contexts: map[string][]Value{}, now: time.Now().Unix()}
	for _, v := range byFile(labeledFiles(c.queue)) {
		in.queue = append(in.queue, v.value)
	}
	if len(listNames(filepath.Join(c.home, "results"))) > 0 {
		in.results = byFile(labeledFiles(filepath.Join(c.home, "results")))
	}
	in.delivered, _ = readText(filepath.Join(c.home, "delivered", c.format+".jsonl"))
	transcripts := filepath.Join(c.home, "transcripts")
	for name := range listNames(transcripts) {
		if v, ok := readJSONFile(filepath.Join(transcripts, name)); ok && is(field(v, "format"), c.format) && field(v, "ended_at").k == kString {
			in.ended[strings.TrimSuffix(name, ".json")] = true
		}
	}
	for name := range listNames(c.contextDir()) {
		if v, ok := readJSONFile(filepath.Join(c.contextDir(), name)); ok && v.k == kArray {
			in.contexts[strings.TrimSuffix(name, ".json")] = v.arr
		}
	}
	return in
}

// contextDir：前文存放，context/<格式>/<会话>.json。
func (c *capturer) contextDir() string {
	return filepath.Join(c.home, "context", filepath.FromSlash(c.format))
}

// 前文存放超过这么多秒没改过、队列里也没有它的会话的条目，就删掉。
const contextStale = 86400

// sweepContexts：队列里已没有这个会话的条目时删掉它的前文存放：会话已结束（位置文件有 ended_at），
// 或前文存放超过 24 小时没改过（Claude 被杀、Codex 的 SessionEnd 没拉起程序时，ended_at 一直记不上）。
func (c *capturer) sweepContexts(in planInput) {
	active := set{}
	for _, q := range in.queue {
		if q.k == kObject {
			active[sessionOf(q)] = true
		}
	}
	for name := range listNames(c.contextDir()) {
		k, file := strings.TrimSuffix(name, ".json"), filepath.Join(c.contextDir(), name)
		if active[k] {
			continue
		}
		if info, err := os.Stat(file); in.ended[k] || (err == nil && in.now-info.ModTime().Unix() > contextStale) {
			os.Remove(file)
		}
	}
}

// decide：起轮决定。有可判的候选（或已判完、待送出、待读回的条目），并且这次是会话结束，或其中最早入队的已等满 30 分钟；
// 再看组件、间隔与锁。
func (c *capturer) decide() {
	in := c.planInput("")
	c.sweepContexts(in)
	var seen, counted []Value
	queued := 0
	for _, q := range in.queue {
		if q.k == kObject && get(q, "item_id").k == kString {
			queued++
			if t := get(q, "first_seen_at"); t.k == kString {
				seen = append(seen, t)
			}
		}
	}
	judgeable := Null
	if p, ok := try(func() plan { return planRound(in) }); ok {
		counted, judgeable = p.due, Int(int64(p.judgeable))
	} else {
		// 排不出（状态文件坏了）：退回原来的规则，起一轮把问题记进 rounds/。
		counted = seen
	}
	oldest := minOf(counted)
	reason := Null
	switch {
	case len(counted) == 0:
	case c.event == "SessionEnd":
		reason = Str("session_end")
	default:
		if oldest.k == kString {
			if since, ok := fromDate(oldest.s); ok && in.now-since >= limitQuiet {
				reason = Str("waited")
			}
		}
	}
	decision := Obj("agent", Str(c.agent), "event", Str(c.event), "format", Str(c.format), "due", Bool(!reason.IsNull()), "reason", reason,
		"queued", Int(int64(queued)), "judgeable", judgeable, "oldest_first_seen_at", minOf(seen), "decided_at", Str(nowISO()))
	rounds := roundsOfFormat(c.home, c.format)
	lock := filepath.Join(c.home, "round.lock")
	locked := isDir(lock) && !lockStale(lock)
	capturing := false
	if dir := componentDir(); dir != "" && exists(filepath.Join(dir, "agent-channel.json")) {
		capturing = true
		c.paused("component_capturing")
	} else {
		os.Remove(filepath.Join(c.home, "paused.json"))
	}
	g := gate(rounds, nowISO())
	due := !reason.IsNull()
	blocked := Null
	switch {
	case !due:
	case capturing:
		blocked = Str("component_capturing")
	case locked:
		blocked = Str("round_running")
	case g.tooSoon:
		blocked = Str("too_soon")
	}
	run := due && !capturing && !g.tooSoon && !locked
	gated := decision.Merge(Obj("run", Bool(run), "blocked", blocked, "failures", Int(int64(g.failures)), "next_round_at", g.next))
	if file := os.Getenv("TKOS_CAPTURE_DECISION_FILE"); file != "" {
		replaceFile(file, gated.JSON()+"\n", c.work)
	}
	if run {
		c.round(reason.s)
	}
}

// paused.json：后台轮不起的原因（首次和最近一次碰到的时刻）；原因不在了，下一次钩子删掉它。
func (c *capturer) paused(reason string) {
	file := filepath.Join(c.home, "paused.json")
	seen := nowISO()
	first := firstSeenIn(file)
	if first == "" {
		first = seen
	}
	replaceFile(file, `{"reason":"`+reason+`","first_seen_at":"`+first+`","last_seen_at":"`+seen+`"}`+"\n", c.work)
}

var firstSeenSed = regexp.MustCompile(`"first_seen_at":"([0-9TZ:-]*)"`)

// firstSeenIn 是 sed -n 's/.*"first_seen_at":"\([0-9TZ:-]*\)".*/\1/p'：每一行最后一处，几行就拼几行。
func firstSeenIn(file string) string {
	b, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	var found []string
	for _, line := range strings.Split(string(b), "\n") {
		if m := firstSeenSed.FindAllStringSubmatch(line, -1); m != nil {
			found = append(found, m[len(m)-1][1])
		}
	}
	return strings.TrimRight(strings.Join(found, "\n"), "\n")
}

// roundsOfFormat：rounds/ 下各文件接起来当一串 JSON 读，这种格式的各轮；有一处读不出就当没有。
func roundsOfFormat(home, format string) []Value {
	var all []byte
	var names []string
	filepath.WalkDir(filepath.Join(home, "rounds"), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".json") {
			names = append(names, p)
		}
		return nil
	})
	sort.Strings(names)
	for _, n := range names {
		b, _ := os.ReadFile(n)
		all = append(all, b...)
	}
	values, ok := parseJQ(all)
	if !ok {
		return nil
	}
	var out []Value
	for _, v := range values {
		if v.k == kObject && is(get(v, "format"), format) {
			out = append(out, v)
		}
	}
	return out
}

// ---------- 一轮 ----------

type roundRun struct {
	c          *capturer
	id         string
	trigger    string
	started    string
	startEpoch int64
	limit      int64
	lock       string
	held       bool
	delivered  string
	state      Value
	cfg        Value
	program    string
	plugin     string
	skill      string
	rules      string
	prompts    string
	plan       plan
	planBroken bool
	prepared   prepared
	auditing   bool     // 准备时定下的：这一轮末尾要做每周复核
	audited    prepared // 要复核的轮：准备读到的、since 放宽过的那一份，复核用；prepared 里的 recorded 只留原 since 以来的
	submitted  []Value  // 本轮前几批已经交出的非 null 结论：target_ref、value、occurred_at
	send       *sendOutcome
	sendRan    bool
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (c *capturer) round(trigger string) {
	r := &roundRun{c: c, trigger: trigger, limit: roundLimit(), lock: filepath.Join(c.home, "round.lock")}
	r.id = time.Now().UTC().Format("20060102T150405Z") + "-" + randomHex(4)
	r.started = nowISO()
	r.startEpoch = time.Now().Unix()
	if !r.enterLock() {
		return
	}
	defer r.releaseLock()
	activeRound = r
	defer func() { activeRound = nil }()
	prefix, _, _ := strings.Cut(c.format, "/")
	for _, dir := range []string{"rounds", "results", "delivered", "work", "context", filepath.Join("context", prefix), filepath.Join("context", filepath.FromSlash(c.format))} {
		if !privateDir(filepath.Join(c.home, dir), false) {
			return
		}
	}
	privateDir(filepath.Join(c.home, "delivered", prefix), false)
	r.delivered = filepath.Join(c.home, "delivered", c.format+".jsonl")
	r.state = Obj("taken", Int(0), "accepted", Int(0), "nulls", Int(0), "rejected", Int(0), "screened", Int(0), "calls", Arr(), "mismatches", Arr(), "failed_batches", Arr(), "imports", Arr(),
		"usage", Null, "exit_code", Null, "failure", Null, "report", Null, "backlog", Null, "audit", Null)
	r.run()
	c.sweepContexts(c.planInput(""))
	record := Obj("round_id", Str(r.id), "agent", Str(c.agent), "format", Str(c.format), "trigger", Str(trigger), "started_at", Str(r.started),
		"finished_at", Str(nowISO())).Merge(r.state)
	// 下一轮最早几点：同一条 gate 规则算出，日进展查漏照这里报，不另写一份规则。
	record = record.With("next_round_at", gate(append(roundsOfFormat(c.home, c.format), record), nowISO()).next)
	replaceFile(filepath.Join(c.home, "rounds", r.id+".json"), record.JSON()+"\n", c.work)
	// 只留最近 400 份。
	var names []string
	for name := range listNames(filepath.Join(c.home, "rounds")) {
		names = append(names, name)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	for i, name := range names {
		if i >= 400 {
			os.Remove(filepath.Join(c.home, "rounds", name))
		}
	}
}

func (r *roundRun) enterLock() bool {
	if err := os.Mkdir(r.lock, 0o700); err != nil {
		if !lockStale(r.lock) {
			return false
		}
		if os.Rename(r.lock, filepath.Join(r.c.work, "stale-lock")) != nil {
			return false
		}
		if os.Mkdir(r.lock, 0o700) != nil {
			return false
		}
	}
	r.held = true
	os.Chmod(r.lock, 0o700)
	os.WriteFile(filepath.Join(r.lock, "owner"),
		[]byte(`{"pid":`+strconv.Itoa(os.Getpid())+`,"round_id":"`+r.id+`","started_at":"`+r.started+`"}`+"\n"), 0o600)
	return true
}

// 只删自己的锁：这一轮被判为无主、另一轮接手以后，锁里的 owner 已是别人的。
func (r *roundRun) releaseLock() {
	if !r.held {
		return
	}
	r.held = false
	if b, err := os.ReadFile(filepath.Join(r.lock, "owner")); err == nil && bytes.Contains(b, []byte(`"round_id":"`+r.id+`"`)) {
		os.RemoveAll(r.lock)
	}
}

// fail：这一轮的第一个失败记下来，后面的不覆盖。
func (r *roundRun) fail(f Value) {
	if !get(r.state, "failure").Truthy() {
		r.state = r.state.With("failure", f)
	}
}

func (r *roundRun) left() int64 { return r.limit - time.Now().Unix() + r.startEpoch }

func (r *roundRun) run() {
	c := r.c
	config, _ := readJSONFile(filepath.Join(c.home, "config.json"))
	cfg, ok := roundConfig(config, c.agent, c.format)
	if !ok {
		r.fail(failure("other", "config_changed"))
		return
	}
	r.cfg = cfg
	if r.program = locateProgram(c.agent); r.program == "" {
		r.fail(failure("program_missing", "not_found"))
		return
	}
	if r.plugin, r.skill = worldSkill(c.agent); r.skill == "" {
		r.fail(failure("world_unavailable", "world_plugin_missing"))
		return
	}
	prompts, err1 := readText(filepath.Join(pluginRoot(), "hooks", "round-prompt.md"))
	skill, err2 := readText(r.skill)
	if err1 != nil || err2 != nil {
		r.fail(failure("world_unavailable", "skill_rules_missing"))
		return
	}
	r.prompts = prompts
	rulesFrom, ok := try(func() string { return promptSection(prompts, "rules-from") })
	rules, found := skillRules(skill, rulesFrom)
	if !ok || !found {
		r.fail(failure("world_unavailable", "skill_rules_missing"))
		return
	}
	r.rules = rules
	r.makePlan()
	r.settle()
	// 有要判的候选才准备；准备失败（world 连不上、选择已变、目标为空）整轮停在这里，不花判断的用量。
	if !r.planBroken && len(r.plan.judge) > 0 && !r.prepare() {
		return
	}
	for i := 0; !r.planBroken && i < len(r.plan.judge); i++ {
		switch r.judgeBatch(i) {
		case 1:
			return
		case 2:
			i = len(r.plan.judge)
		}
	}
	// 再排一次：判完的候选前面挡下的，这时才落地。
	r.makePlan()
	r.settle()
	if !r.planBroken && len(r.plan.send)+len(r.plan.readback) > 0 {
		if !r.sendBatch() {
			return
		}
	}
	r.makePlan()
	r.reportRun()
	r.audit()
}

// readText 读一个文本文件（jq 的 --rawfile）：不合法的 UTF-8 换成 U+FFFD。Windows 上的检出可能是 CRLF，一律按 LF 读。
func readText(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.ReplaceAll(string(jqValidUTF8(b)), "\r\n", "\n"), nil
}

type namedFile struct {
	name   string
	joined string
}

// labeledFiles：一个目录（含子目录）下的 entry-*.json，按 capture.sh 的 labeled_lines 与 round.jq 的 by_file：
// 文件名去掉 .json，内容按行接回去（末尾的换行去掉）；空文件不算。
func labeledFiles(dir string) []namedFile {
	byName := map[string][]string{}
	for _, f := range entryFiles(dir) {
		b, err := os.ReadFile(f)
		if err != nil || len(b) == 0 {
			continue
		}
		name := strings.TrimSuffix(filepath.Base(f), ".json")
		text := string(jqValidUTF8(b))
		byName[name] = append(byName[name], strings.Split(strings.TrimSuffix(text, "\n"), "\n")...)
	}
	names := make([]string, 0, len(byName))
	for n := range byName {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]namedFile, len(names))
	for i, n := range names {
		out[i] = namedFile{n, strings.Join(byName[n], "\n")}
	}
	return out
}

// makePlan：队列、results/、delivered/、位置文件和前文存放读一遍，算这一轮该做什么。
func (r *roundRun) makePlan() {
	p, ok := try(func() plan { return planRound(r.c.planInput(promptSection(r.prompts, "omitted"))) })
	r.plan, r.planBroken = p, !ok
}

// applyEffects：先并进前文存放，再把 delivered 记上，再删队列文件和 results/（读增量时先列队列、再读 delivered，这个顺序下不会重排）。
// 中途断了，条目还在队列里，下一轮再挡或再判一次，并进前文存放的结果相同。
func (r *roundRun) applyEffects(e effects) {
	c := r.c
	bySession := map[string][]Value{}
	var sessions []string
	for _, row := range e.context {
		k := sessionOf(row)
		if strings.HasPrefix(k, "item:") {
			continue
		}
		if _, ok := bySession[k]; !ok {
			sessions = append(sessions, k)
		}
		bySession[k] = append(bySession[k], row)
	}
	held := map[string][]Value{}
	if len(sessions) > 0 {
		held = r.heldEntries(e)
	}
	for _, k := range sessions {
		file := filepath.Join(c.contextDir(), k+".json")
		old, _ := readJSONFile(file)
		if merged, ok := try(func() Value { return mergeContext(old, bySession[k], held[k]) }); ok {
			replaceFile(file, merged.JSON()+"\n", c.work)
		}
	}
	if len(e.deliver) > 0 {
		f, err := os.OpenFile(r.delivered, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
		if err == nil {
			f.WriteString(strings.Join(e.deliver, "\n") + "\n")
			f.Close()
		}
	}
	for _, name := range e.remove {
		os.Remove(filepath.Join(c.queue, name+".json"))
		os.Remove(filepath.Join(c.home, "results", name+".json"))
	}
	for _, w := range e.write {
		target := filepath.Join(c.home, "results", w.name+".json")
		// 新判断只在还没有这一条时写：已有的判断不改，重送用的就是落盘的那一份。
		if w.replace {
			replaceFile(target, w.value.JSON()+"\n", c.work)
		} else {
			createFile(target, w.value.JSON()+"\n", c.work)
		}
	}
}

// heldEntries：这些落盘做完以后还留在队列、还没判完的条目，按会话分，它们前面的前文不挤掉。照本机现在的状态重排一次（这一轮前几批
// 判成 null 的这时已在 results/），再去掉这一次要移出队列的和这一次判成 null 的。排不出时退回这一轮开头排的那份，只会多留。
func (r *roundRun) heldEntries(e effects) map[string][]Value {
	p, ok := try(func() plan { return planRound(r.c.planInput("")) })
	if !ok {
		p = r.plan
	}
	gone := set{}
	for _, name := range e.remove {
		gone[name] = true
	}
	for _, row := range e.context {
		if v, has := row.Lookup("result"); has && v.IsNull() {
			gone[nameOf(row)] = true
		}
	}
	out := map[string][]Value{}
	for k, list := range p.held {
		for _, x := range list {
			if !gone[nameOf(x)] {
				out[k] = append(out[k], x)
			}
		}
	}
	return out
}

// settle：可以落地的挡下条目和已判为 null 的记进 delivered/，移出队列。
func (r *roundRun) settle() {
	if r.planBroken {
		return
	}
	e := settleEffects(r.plan, r.id, nowISO())
	r.applyEffects(e)
	nulls := 0
	for _, line := range e.deliver {
		if v, _ := fromJSON(line); is(get(v, "status"), "null") {
			nulls++
		}
	}
	r.state = r.state.With("nulls", add(get(r.state, "nulls"), Int(int64(nulls)))).
		With("screened", add(get(r.state, "screened"), Int(int64(len(r.plan.screen)))))
}

// judgeBudget：一次准备或判断最多等多久；要给送出和回执留够时间，不够交 0。
func (r *roundRun) judgeBudget() int64 {
	limit := r.limit
	budget := r.left() - limit*9/20
	if budget <= limit/20 {
		return 0
	}
	return min(budget, limit/4)
}

// prepare：一次只带两个只读工具的调用，读选择和目标，本轮各批都用这一份。since 是这一轮要判的候选里最早的上报时刻往前 24 小时。
// 这一轮末尾要做每周复核时，since 取它和复核窗口起点往前 24 小时里更早的那个：复核抽的条目跨 7 天，当初判成 null 的可能是因为
// 同一件事那时已经记过。放宽读到的全量只给复核用，判断用的 recorded 在这里按原 since 筛回去，和不复核的轮一样。
func (r *roundRun) prepare() bool {
	budget := r.judgeBudget()
	if budget == 0 {
		r.fail(failure("other", "no_time_to_prepare"))
		return false
	}
	var candidates []Value
	for _, b := range r.plan.judge {
		candidates = append(candidates, b.items...)
	}
	now := time.Now().Unix()
	judgeSince, sinceOK := try(func() string { return since(candidates) })
	from := judgeSince
	if r.auditing = auditDue(r.c.auditDir(), now); r.auditing {
		if floor := toDate(float64(now - auditEvery - 86400)); floor < from {
			from = floor
		}
	}
	prompt, ok := try(func() string { return preparePrompt(promptSection(r.prompts, "prepare"), r.cfg, from) + "\n" })
	if !ok || !sinceOK {
		prompt = ""
	}
	result := r.call("prepare", budget, prompt)
	if result.failure.Truthy() {
		r.fail(result.failure)
		return false
	}
	type outcome struct {
		p prepared
		f Value
	}
	o, ok := try(func() outcome { p, f := prepareOutcomeOf(result, r.cfg); return outcome{p, f} })
	switch {
	case !ok:
		r.fail(failure("other", "output_unreadable"))
		return false
	case !o.f.IsNull():
		r.fail(o.f)
		return false
	}
	r.prepared = o.p
	if r.auditing {
		r.audited = o.p
		r.prepared.targets = recordedSince(o.p.targets, judgeSince)
	}
	return true
}

// judgeBatch 交 0（照常）、1（失败，这一轮到此为止）、2（时间不够，不再起新的一批）。
// 回复解析不了时这一批不落判断、整批留在队列，各条在 results/ 记一笔失败，这一批记进 rounds/ 的 failed_batches，接着判下一批（决定六第 3 条）。
func (r *roundRun) judgeBatch(i int) int {
	budget := r.judgeBudget()
	if budget == 0 {
		return 2
	}
	batch := r.plan.judge[i]
	prompt, ok := try(func() string {
		return judgePrompt(promptSection(r.prompts, "judge"), trimRightJQ(r.rules), r.prepared, r.submitted, batch) + "\n"
	})
	if !ok {
		prompt = ""
	}
	result := r.call("judge", budget, prompt)
	if result.failure.Truthy() {
		r.fail(result.failure)
		return 1
	}
	outcome, ok := try(func() judgeOutcome { return judgeOutcomeOf(result, batch.items) })
	if !ok {
		r.fail(failure("other", "output_unreadable"))
		return 1
	}
	e, ok := try(func() effects { return judgeEffects(outcome, r.c.format, r.id, nowISO()) })
	if !ok {
		r.fail(failure("other", "effects_unreadable"))
		return 1
	}
	r.applyEffects(e)
	if !outcome.failure.IsNull() {
		var names []string
		for _, e := range batch.items {
			names = append(names, nameOf(e))
		}
		failed := append(eachOpt(get(r.state, "failed_batches")), Obj("batch", Int(int64(i+1)), "detail", get(outcome.failure, "detail"), "items", strs(names)))
		r.state = r.state.With("failed_batches", ArrOf(failed))
		return 0
	}
	mismatches := each(get(r.state, "mismatches"))
	for _, m := range outcome.mismatches {
		mismatches = append(mismatches, m.Merge(Obj("call", Str("judge"))))
	}
	for _, m := range outcome.missed {
		if is(get(m, "reason"), "unanswered") {
			mismatches = append(mismatches, Obj("name", get(m, "name"), "reason", Str("unanswered"), "call", Str("judge")))
		}
	}
	r.state = r.state.With("taken", add(get(r.state, "taken"), Int(int64(len(outcome.accepted)+len(outcome.invalid))))).
		With("mismatches", ArrOf(append([]Value{}, mismatches...)))
	for _, a := range outcome.accepted {
		if res := get(a, "result"); !res.IsNull() {
			r.submitted = append(r.submitted, Obj("target_ref", get(res, "target_ref"), "value", get(res, "value"), "occurred_at", get(res, "occurred_at")))
		}
	}
	return 0
}

func (r *roundRun) sendBatch() bool {
	limit := r.limit
	budget := min(r.left()-limit/4, limit/5)
	if budget < 1 {
		r.fail(failure("other", "no_time_to_send"))
		return false
	}
	increments, ok := try(func() []Value { return incrementsOf(r.plan.send, r.cfg, r.id) })
	prompt, _ := try(func() string {
		if !ok {
			raise("increments")
		}
		return sendPrompt(promptSection(r.prompts, "send"), promptSection(r.prompts, "send-readback"), promptSection(r.prompts, "send-ingest"),
			r.cfg, increments, r.plan.readback) + "\n"
	})
	result := r.call("send", budget, prompt)
	r.sendRan = true
	built := ok
	outcome, ok := try(func() *sendOutcome { return sendOutcomeOf(result, increments) })
	if !ok || !built {
		outcome = nil
	}
	r.send = outcome
	e, ok := try(func() effects { return sendEffects(r.plan, outcome, r.id, nowISO()) })
	if !ok {
		r.fail(failure("other", "effects_unreadable"))
		return false
	}
	r.applyEffects(e)
	if outcome != nil {
		accepted := 0
		imports := each(get(r.state, "imports"))
		for _, line := range e.deliver {
			v, _ := fromJSON(line)
			if is(get(v, "status"), "imported") {
				accepted++
			}
			if !get(v, "import_id").IsNull() {
				imports = append(imports, Obj("item_id", get(v, "item_id"), "item_version", get(v, "item_version"), "import_id", get(v, "import_id")))
			}
		}
		mismatches := each(get(r.state, "mismatches"))
		rejected := 0
		var sendErrors []Value
		for _, inc := range outcome.increments {
			if inc.sent && !inc.exact {
				mismatches = append(mismatches, Obj("items", strs(inc.items), "reason", Str("copy_mismatch"), "call", Str("send")))
			}
			rejected += len(inc.rejected)
			if !inc.err.IsNull() {
				sendErrors = append(sendErrors, Obj("items", strs(inc.items), "error", inc.err))
			}
		}
		for _, names := range outcome.unknown {
			mismatches = append(mismatches, Obj("items", strs(names), "reason", Str("unknown_import"), "call", Str("send")))
		}
		r.state = r.state.With("accepted", add(get(r.state, "accepted"), Int(int64(accepted)))).
			With("imports", ArrOf(append([]Value{}, imports...))).
			With("mismatches", ArrOf(append([]Value{}, mismatches...))).
			With("rejected", add(get(r.state, "rejected"), Int(int64(rejected)))).
			With("send_errors", ArrOf(sendErrors))
	}
	if !result.failure.IsNull() {
		r.fail(result.failure)
		return false
	}
	return true
}

func (r *roundRun) reportRun() {
	c := r.c
	budget := min(r.left(), r.limit/4)
	if budget < 1 {
		r.state = r.state.With("report", Obj("status", Str("skipped"), "reason", Str("no_time")))
		return
	}
	files := transcriptTotals(c.home, c.format)
	var args Value
	hasArgs := false
	if !r.planBroken {
		args, hasArgs = try(func() Value {
			return reportArgs(r.cfg, r.id, r.started, nowISO(), r.plan, files, r.send, get(r.state, "taken"))
		})
	}
	if !hasArgs {
		args = Null
	}
	prompt, _ := try(func() string { return reportPrompt(promptSection(r.prompts, "report"), args) + "\n" })
	result := r.call("report", budget, prompt)
	report, ok := try(func() Value {
		var runs []toolCall
		for _, call := range result.calls {
			if is(call.tool, "world_app_sources_report_run") {
				runs = append(runs, call)
			}
		}
		parsedError := func(call toolCall) Value {
			if v, ok := fromJSONText(call.text); ok {
				return v
			}
			return Null
		}
		if len(runs) == 0 {
			return Obj("status", Str("not_called"))
		}
		for _, call := range runs {
			if equal(call.args, args) && !call.failed && get(parsedError(call), "error").IsNull() {
				return Obj("status", Str("reported"))
			}
		}
		for _, call := range runs {
			if !equal(call.args, args) {
				return Obj("status", Str("copy_mismatch"))
			}
		}
		code := Null
		for _, call := range runs {
			v := parsedError(call)
			var x Value
			if e := get(v, "error"); e.k == kObject || e.k == kNull {
				x = get(e, "code")
			} else {
				x = Null
			}
			if x.Truthy() && code.IsNull() {
				code = x
			}
		}
		return Obj("status", Str("failed"), "error", code)
	})
	if ok {
		r.state = r.state.With("report", report).With("backlog", get(args, "pending_count"))
	}
}

// fromJSONText 是 .text | try fromjson catch null。
func fromJSONText(v Value) (Value, bool) {
	if v.k != kString {
		return Null, false
	}
	return fromJSON(v.s)
}

// transcriptTotals：位置文件里这种格式的文件数和已读字节；有一处读不出（或类型不对）就是 null。
func transcriptTotals(home, format string) Value {
	var all []byte
	var names []string
	filepath.WalkDir(filepath.Join(home, "transcripts"), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".json") {
			names = append(names, p)
		}
		return nil
	})
	sort.Strings(names)
	for _, n := range names {
		b, _ := os.ReadFile(n)
		all = append(all, b...)
	}
	out, ok := try(func() Value {
		values, ok := parseJQ(all)
		if !ok {
			raise("parse")
		}
		var offsets []Value
		count := 0
		for _, v := range values {
			if is(get(v, "format"), format) {
				count++
				offsets = append(offsets, alt(get(v, "offset"), Int(0)))
			}
		}
		return Obj("count", Int(int64(count)), "bytes", alt(sum(offsets), Int(0)))
	})
	if !ok {
		return Null
	}
	return out
}

// ---------- 一次模型调用 ----------

func (r *roundRun) cliArgs(kind string) []string {
	model := os.Getenv("TKOS_CAPTURE_CLAUDE_MODEL")
	if model == "" {
		model = "sonnet"
	}
	tail := []string{"--permission-mode", "dontAsk", "--output-format", "stream-json", "--verbose", "--model", model}
	// 判断和复核不带 world 插件，也不放行任何工具：--tools "" 关内置工具，--strict-mcp-config 不读别处的 MCP 配置，
	// --disable-slash-commands 不带技能和命令清单（claude 2.1.327 实测 init 里 tools、mcp_servers、skills 都是空的）。
	if r.c.agent == "claude" && offline(kind) {
		return append([]string{"-p", "--no-session-persistence", "--setting-sources", "", "--tools", "", "--strict-mcp-config",
			"--disable-slash-commands"}, tail...)
	}
	if r.c.agent == "claude" {
		tools := make([]string, len(roundTools[kind]))
		for i, t := range roundTools[kind] {
			tools[i] = claudePrefix + t
		}
		args := []string{"-p", "--no-session-persistence", "--setting-sources", "", "--plugin-dir", r.plugin, "--tools", "",
			"--allowedTools", strings.Join(tools, ",")}
		if hidden := r.hiddenTools(kind); hidden != "" {
			args = append(args, "--disallowedTools", hidden)
		}
		// 提示词经 stream-json 输入交：先问 world 连没连上（preflight.go）。
		return append(append(args, "--input-format", "stream-json"), tail...)
	}
	args := []string{"exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "--sandbox", "read-only", "-C", filepath.Join(r.c.home, "work"),
		"-c", "features.shell_tool=false", "-c", "features.view_image=false", "-c", `web_search="disabled"`,
		"-c", "tools.experimental_request_user_input.enabled=false", "-c", "agents.enabled=false", "-c", "features.goals=false",
		"-c", "features.sleep_tool=false", "-c", "features.image_generation=false", "-c", "features.tool_suggest=false", "-c", "features.apps=false",
		"-c", "cloud.skills.enabled=false", "-c", "features.code_mode=false"}
	// 判断和复核不配 world。codex 0.167 不读本人配置也会连上远程的官方插件（各带 MCP 工具，本机调试日志实测），连插件一起关掉就一个 MCP 都没有。
	if offline(kind) {
		return append(args, "-c", "features.plugins=false", "--json", "-")
	}
	return append(args, "-c", `mcp_servers.world.url="`+worldURL+`"`, "-c", "mcp_servers.world.enabled_tools="+strs(roundTools[kind]).JSON(),
		"-c", `mcp_servers.world.default_tools_approval_mode="approve"`, "-c", "mcp_servers.world.required=true",
		"-c", `mcp_servers.world.omit_tools_from=["deferred","code_mode"]`, "--json", "-")
}

// hiddenTools：world-tools.json 里学到的、这次用不到的 world 工具（全名，逗号分隔）。
func (r *roundRun) hiddenTools(kind string) string {
	b, err := os.ReadFile(filepath.Join(r.c.home, "world-tools.json"))
	if err != nil {
		return ""
	}
	values, ok := parseJQ(b)
	if !ok {
		return ""
	}
	var lines []string
	for _, v := range values {
		lines = append(lines, hiddenTools(v, kind))
	}
	return strings.Join(lines, "\n")
}

// call：一次模型调用，最多等 limit 秒。
func (r *roundRun) call(kind string, limit int64, prompt string) cliResult {
	c := r.c
	tmp := filepath.Join(c.work, "tmp")
	os.MkdirAll(tmp, 0o700)
	// 两路输出写进文件（同 capture.sh 的重定向）：Node 写的 CLI 往管道写时，进程一退出没写完的就丢了。
	// 提示词：Claude Code 连 world 的调用先预检、连上了才经管道写进去；别的调用照旧从文件交给标准输入。
	files := [3]string{filepath.Join(c.work, "prompt"), filepath.Join(c.work, "out"), filepath.Join(c.work, "err")}
	var pre *preflight
	var talk talker
	if c.agent == "claude" && !offline(kind) {
		pre = newPreflight(files[1], prompt, max(limit, 1))
		talk = pre.talk
		os.Remove(files[0]) // 上一次调用的提示词不留在盘上
	} else {
		os.WriteFile(files[0], []byte(prompt), 0o600)
	}
	run := runCLI(r.program, r.cliArgs(kind), childEnv(c.agent, r.program, tmp, r.id), filepath.Join(c.home, "work"), files, max(limit, 1), talk)
	errTail := run.stderr
	if len(errTail) > 4000 {
		errTail = errTail[len(errTail)-4000:]
	}
	if c.agent == "claude" {
		tidyClaude(filepath.Join(c.home, "work"))
	}
	result, ok := try(func() cliResult {
		var rows []Value
		for _, line := range strings.Split(strings.TrimSuffix(string(jqValidUTF8(run.stdout)), "\n"), "\n") {
			// 预检的控制回复不是 CLI 的事件流，不算进去：没写提示词时这一次就是没有输出。
			if v, ok := fromJSON(line); ok && v.Truthy() && !(pre != nil && v.k == kObject && is(get(v, "type"), "control_response")) {
				rows = append(rows, v)
			}
		}
		var res cliResult
		if c.agent == "claude" {
			res = parseClaude(rows)
		} else {
			res = parseCodex(rows)
		}
		res.failure = classify(res, c.agent, run.status, run.timedOut, string(jqValidUTF8(errTail)), !offline(kind))
		return res
	})
	if !ok {
		result = cliResult{failure: failure("other", "output_unreadable"), worldTools: Null, usage: Null, requests: Null}
	}
	// 预检问到 world 不是 connected、没写提示词：这一次没调模型，用量和请求数记 0。
	if pre.stopped() && !run.timedOut {
		result = cliResult{failure: failure("world_unavailable", "mcp_"+pre.status), worldTools: Null, requests: Int(0),
			usage: Obj("input_tokens", Int(0), "cached_input_tokens", Int(0), "output_tokens", Int(0))}
	}
	if c.agent == "claude" {
		r.learnTools(result)
	}
	visible := Null
	if result.worldTools.k == kArray {
		visible = Int(int64(len(result.worldTools.arr)))
	}
	call := Obj("kind", Str(kind), "exit_code", Int(int64(run.status)), "seconds", Int(run.seconds), "timed_out", Bool(run.timedOut),
		"failure", result.failure, "usage", result.usage, "visible_tools", visible, "requests", result.requests)
	r.state = r.state.With("calls", add(get(r.state, "calls"), Arr(call))).With("exit_code", Int(int64(run.status))).
		With("usage", addUsage(get(r.state, "usage"), result.usage))
	return result
}

// addUsage：用量合计加上一次调用的；这一次没有用量时照旧。
func addUsage(total, u Value) Value {
	if u.IsNull() {
		return total
	}
	return Obj("input_tokens", add(alt(get(total, "input_tokens"), Int(0)), get(u, "input_tokens")),
		"cached_input_tokens", add(alt(get(total, "cached_input_tokens"), Int(0)), get(u, "cached_input_tokens")),
		"output_tokens", add(alt(get(total, "output_tokens"), Int(0)), get(u, "output_tokens")))
}

// offline：判断和每周复核，一个工具都不带，也不连 world。
func offline(kind string) bool { return len(roundTools[kind]) == 0 }

// learnTools：init 里列过的 world 工具名并进 world-tools.json；文件坏了就只按这一次的重写。
func (r *roundRun) learnTools(result cliResult) {
	file := filepath.Join(r.c.home, "world-tools.json")
	var next []string
	if b, err := os.ReadFile(file); err == nil {
		if values, ok := parseJQ(b); ok {
			for _, v := range values {
				next = append(next, knownTools(v, result.worldTools).JSON())
			}
		}
	}
	if len(next) == 0 {
		next = []string{knownTools(Null, result.worldTools).JSON()}
	}
	content := strings.Join(next, "\n") + "\n"
	if old, err := os.ReadFile(file); err == nil && string(old) == content {
		return
	}
	replaceFile(file, content, r.c.work)
}

type cliRun struct {
	status   int
	timedOut bool
	seconds  int64
	stdout   []byte
	stderr   []byte
}

// activeRound：正在跑的一轮，收到 TERM 时由 cleanup 结束它的子进程、放掉锁。
var activeRound *roundRun
