package main

// 「开始采集」、迁移与回退（ADR 决定七、八）：check、enable、import、export 四个子命令。0.1.6 的 setup.jq 与 capture.sh 的 setup_*。
// 每次在标准输出上交一行 JSON，标准错误不写；拒绝时交 {"ok":false,"reason":…}、退出码 1，什么都不写。

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type refusal struct{ reason string }

// refuse 交出拒绝：由 main 写那一行、退出码 1。
func refuse(reason string) { panic(refusal{reason}) }

// raw 是 --rawfile：文件不在就是空串。
func raw(path string) string {
	if path == "" || !isFile(path) {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(jqValidUTF8(b))
}

// parsed：空串是 null，读不出是字符串 "unreadable"。
func parsed(s string) Value {
	if s == "" {
		return Null
	}
	if v, ok := fromJSON(s); ok {
		return v
	}
	return Str("unreadable")
}

var (
	lowerUUID    = regexp.MustCompile(`\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z`)
	hostDevice   = regexp.MustCompile(`\A[0-9a-f-]{36}\z`)
	configDevice = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z`)
	wellFormedID = regexp.MustCompile(`\Aentry-[0-9a-f]{64}\z`)
)

func isUUID(v Value) bool      { return v.k == kString && lowerUUID.MatchString(v.s) }
func positiveInt(v Value) bool { return v.k == kNumber && v.f >= 1 && v.f == floorF(v.f) }
func isHex64(v Value) bool     { return v.k == kString && hex64.MatchString(v.s) }
func wellFormedItem(v Value) bool {
	id := get(v, "item_id")
	return id.k == kString && wellFormedID.MatchString(id.s) && isHex64(get(v, "item_version"))
}

var scopeWords = map[string][]string{
	"claude": {"Claude Code", "projects", "以后新开", "持续"},
	"codex":  {"Codex", "sessions", ".jsonl", "以后新开", "持续"},
}

// componentSettings：组件 settings.json（host.mjs 的格式）合用时交出要用的几项，否则 null。
func componentSettings(s Value) Value {
	d := get(s, "device_id")
	if s.k != kObject || !is(get(s, "format"), "world-capture-host/1") || d.k != kString || !hostDevice.MatchString(d.s) {
		return Null
	}
	orNull := func(v Value, ok bool) Value {
		if ok {
			return v
		}
		return Null
	}
	sf, sel, root := get(s, "source_format"), get(s, "selection_id"), field(get(s, "location"), "root")
	return Obj("device_id", d, "source_format", orNull(sf, sf.k == kString), "selection_id", orNull(sel, isUUID(sel)),
		"root", orNull(root, root.k == kString), "capture_enabled", Bool(equal(get(s, "capture_enabled"), True)),
		"open_at_login", Bool(!equal(get(s, "open_at_login"), False)))
}

func configDeviceOf(config Value) Value {
	d := field(config, "device_id")
	if d.k == kString && configDevice.MatchString(d.s) {
		return d
	}
	return Null
}

// deviceChoice：这台设备的 id：已有 config.json 的；没有就用组件的；都没有是 null，由调用方新起一个。
func deviceChoice(config, settings Value) Value {
	if c := configDeviceOf(config); !c.IsNull() {
		return Obj("device", c, "from", Str("config"))
	}
	if s := field(componentSettings(settings), "device_id"); !s.IsNull() {
		return Obj("device", s, "from", Str("component"))
	}
	return Null
}

func deviceOf(v Value, agent string) Value {
	prefix := "local-capture-" + agent + "-"
	if v.k == kString && strings.HasPrefix(v.s, prefix) {
		return Str(v.s[len(prefix):])
	}
	return Null
}

// selectionEntry：选择记录对得上这台设备这种 Agent 的本机采集时，交出 config.json 里的那一项和设备 id；否则 refused。
func selectionEntry(sel Value, agent, format, mode string, device Value, folder string) (entry Value, own Value, refused string) {
	c := field(sel, "choice")
	src, h, k := field(c, "source"), field(c, "history"), field(sel, "confirmation")
	sid := field(src, "source_id")
	own = deviceOf(sid, agent)
	switch {
	case sel.k != kObject || !isUUID(get(sel, "selection_id")) || !positiveInt(get(sel, "version")):
		return Null, Null, "selection_unreadable"
	case !is(get(sel, "status"), "active"):
		return Null, Null, "selection_not_active"
	case !is(field(src, "adapter"), "work-increment/0.1") || own.IsNull() || !sourceIDPattern.MatchString(sid.s) ||
		!is(field(src, "locator"), "local-capture:"+sid.s):
		return Null, Null, "source_mismatch"
	case (!device.IsNull() && !equal(own, device)) || (device.IsNull() && !isUUID(own)):
		return Null, Null, "device_mismatch"
	}
	if _, ok := utc(field(h, "start_at")); !is(field(c, "version_scope"), "authorized_increments") || !ok || !field(h, "end_at").IsNull() {
		return Null, Null, "history_mismatch"
	}
	if !is(field(k, "mode"), mode) {
		return Null, Null, "confirmation_mismatch"
	}
	if mode == "current_dialogue" {
		t := field(k, "text")
		if t.k != kString {
			return Null, Null, "scope_not_confirmed"
		}
		for _, w := range scopeWords[agent] {
			if !strings.Contains(t.s, w) {
				return Null, Null, "scope_not_confirmed"
			}
		}
	}
	return Obj("selection_id", get(sel, "selection_id"), "selection_version", get(sel, "version"), "source_id", sid, "format", Str(format),
		"history_from", get(h, "start_at"), "confirmed_at", field(k, "confirmed_at"), "folder", Str(folder)), own, ""
}

// withEntry：config.json 换上这种 Agent 的一项；本人打开的 screen_short 开关留着。
func withEntry(config Value, agent string, device, entry Value) Value {
	agents := field(config, "agents")
	if agents.k != kObject {
		agents = Obj()
	}
	out := Obj("device_id", device)
	if screen, ok := config.Lookup("screen_short"); ok {
		out = out.With("screen_short", screen)
	}
	return out.With("agents", agents.Merge(Obj(agent, entry)))
}

func configured(config Value, agent, format string) bool {
	_, _, _, ok := configEntry(config, agent, format)
	return ok
}

// ---------- check ----------

func (s *setup) check() {
	reason, system, version := supportReason()
	if reason != "" {
		out(Obj("supported", False, "reason", Str(reason), "system", Str(system), "os_version", Str(version)))
		return
	}
	config, settings := parsed(raw(s.configFile())), parsed(raw(s.componentFile("settings.json")))
	d := deviceChoice(config, settings)
	device := alt(field(d, "device"), Str(newUUID()))
	comp := componentSettings(settings)
	capturing := Null
	if configured(config, s.agent, s.format) {
		e := get(get(config, "agents"), s.agent)
		capturing = Obj("selection_id", get(e, "selection_id"), "selection_version", get(e, "selection_version"),
			"history_from", get(e, "history_from"), "confirmed_at", get(e, "confirmed_at"))
	}
	component := Null
	if !comp.IsNull() {
		component = Obj("selection_id", get(comp, "selection_id"), "source_format", get(comp, "source_format"), "capture_enabled", get(comp, "capture_enabled"),
			"running", Bool(s.componentRunning()), "open_at_login", get(comp, "open_at_login"))
	}
	folder := dataFolder(s.agent)
	out(Obj("supported", True, "system", Str(system), "os_version", Str(version), "agent", Str(s.agent), "format", Str(s.format),
		"data_dir", Str(dataDirName(s.agent)), "folder", Str(baseName(folder)), "folder_present", Bool(isDir(folder)), "device_id", device,
		"device_from", alt(field(d, "from"), Str("new")), "source_id", Str("local-capture-"+s.agent+"-"+tostring(device)),
		"capturing", capturing, "component", component))
}

// ---------- enable ----------

func (s *setup) enable(file string) {
	s.supported()
	if file == "" || !isFile(file) {
		refuse("selection_file_missing")
	}
	// 数据目录是相对路径时，钩子按会话的工作目录解释它，读的范围对不上，从此静默不采；直接拒。
	folder := dataFolder(s.agent)
	if !absolute(folder) {
		refuse("data_dir_not_absolute")
	}
	config, settings := parsed(raw(s.configFile())), parsed(raw(s.componentFile("settings.json")))
	if !config.IsNull() && config.k != kObject {
		refuse("config_unreadable")
	}
	entry, own, why := selectionEntry(parsed(raw(file)), s.agent, s.format, "current_dialogue", field(deviceChoice(config, settings), "device"), folder)
	if why != "" {
		refuse(why)
	}
	old := field(field(field(config, "agents"), s.agent), "selection_id")
	if !privateDir(s.home, true) {
		refuse("state_unwritable")
	}
	if !replaceFile(s.configFile(), withEntry(config, s.agent, own, entry).JSON()+"\n", s.home) {
		refuse("state_unwritable")
	}
	replaced := Null
	if !old.IsNull() && !equal(old, get(entry, "selection_id")) {
		replaced = old
	}
	out(Obj("ok", True, "agent", Str(s.agent), "selection_id", get(entry, "selection_id"), "selection_version", get(entry, "selection_version"),
		"history_from", get(entry, "history_from"), "replaced", replaced))
}

// ---------- import ----------

func checkpointOK(cp Value) bool {
	p := get(cp, "progress")
	return cp.k == kObject && is(get(cp, "format"), "world-source-run-checkpoint/0.1") &&
		(p.IsNull() || (p.k == kObject && is(get(p, "format"), "world-capture-progress/0.1") && get(p, "entries").k == kObject))
}

func extractionOK(ex Value, format string) bool {
	return ex.k == kObject && is(get(ex, "format"), "world-capture-extraction/0.1") && is(get(ex, "source_format"), format) &&
		get(ex, "pending").k == kArray && get(ex, "results").k == kArray
}

// chosen：组件 settings.json 里的选择（读不出就没有）。
func (s *setup) chosen() string {
	b, err := os.ReadFile(s.componentFile("settings.json"))
	if err != nil {
		return ""
	}
	values, _ := parseJQPrefix(b)
	var lines []string
	for _, v := range values {
		if sel := get(componentSettings(v), "selection_id"); sel.Truthy() {
			lines = append(lines, tostring(sel))
		}
	}
	return strings.Join(lines, "\n")
}

func (s *setup) importFrom(file string) {
	s.supported()
	if file == "" || !isFile(file) {
		refuse("selection_file_missing")
	}
	if !isFile(s.componentFile("settings.json")) {
		refuse("component_missing")
	}
	if s.componentRunning() {
		refuse("component_running")
	}
	chosen := s.chosen()
	checkpointRaw, extractionRaw := "", ""
	if chosen != "" {
		checkpointRaw, extractionRaw = raw(s.componentFile("source-"+chosen+".json")), raw(s.componentFile("extraction-"+chosen+".json"))
	}
	config := parsed(raw(s.configFile()))
	comp := componentSettings(parsed(raw(s.componentFile("settings.json"))))
	sel, cp, ex := parsed(raw(file)), parsed(checkpointRaw), parsed(extractionRaw)
	root := get(comp, "root")
	switch {
	case comp.IsNull():
		refuse("component_settings_unreadable")
	case !is(get(comp, "source_format"), s.format):
		refuse("component_format_mismatch")
	case get(comp, "selection_id").IsNull():
		refuse("component_no_selection")
	case get(comp, "capture_enabled").Truthy():
		refuse("component_capture_enabled")
	case root.IsNull() || !rootedFolder(root.s):
		refuse("component_location_unreadable")
	case !config.IsNull() && config.k != kObject:
		refuse("config_unreadable")
	case !configDeviceOf(config).IsNull() && !equal(get(config, "device_id"), get(comp, "device_id")):
		refuse("device_mismatch")
	case !equal(field(sel, "selection_id"), get(comp, "selection_id")):
		refuse("selection_mismatch")
	}
	entry, _, why := selectionEntry(sel, s.agent, s.format, "component_window", get(comp, "device_id"), root.s)
	old := field(field(config, "agents"), s.agent)
	isConfigured := configured(config, s.agent, s.format)
	switch {
	case why != "":
		refuse(why)
	case isConfigured && equal(get(old, "selection_id"), get(comp, "selection_id")):
		out(Obj("ok", True, "agent", Str(s.agent), "selection_id", get(comp, "selection_id"), "already", True))
		return
	case isConfigured:
		refuse("agent_already_configured")
	case !cp.IsNull() && !checkpointOK(cp):
		refuse("checkpoint_unreadable")
	case !ex.IsNull() && !extractionOK(ex, s.format):
		refuse("extraction_unreadable")
	}
	from, _ := utc(get(entry, "history_from"))
	newConfig := withEntry(config, s.agent, get(comp, "device_id"), entry)
	c := &capturer{agent: s.agent, format: s.format, home: s.home, sourceID: get(entry, "source_id").s, from: from, folder: root.s}
	if !c.prepare() {
		refuse("state_unwritable")
	}
	defer c.cleanup()
	for _, dir := range []string{"delivered", "results"} {
		if !privateDir(filepath.Join(s.home, dir), false) {
			refuse("state_unwritable")
		}
	}
	prefix, _, _ := strings.Cut(s.format, "/")
	if !privateDir(filepath.Join(s.home, "delivered", prefix), false) {
		refuse("state_unwritable")
	}
	doneFile := filepath.Join(s.home, "delivered", s.format+".jsonl")
	at := nowISO()
	// 组件检查点里已处理的条目（送出的和判为无增量的），还不在 delivered/ 里的。
	done := deliveredSet(raw(doneFile))
	var lines []Value
	entries := alt(field(field(cp, "progress"), "entries"), Obj())
	for _, k := range entries.Keys() {
		row := Obj("item_id", Str(k), "item_version", get(entries, k))
		if wellFormedItem(row) && !done[nameOf(row)] {
			lines = append(lines, row)
		}
	}
	var component []string
	for _, row := range uniqueBy(lines, func(v Value) Value { return Str(nameOf(v)) }) {
		component = append(component, Obj("item_id", get(row, "item_id"), "item_version", get(row, "item_version"), "import_id", Null,
			"status", Str("component"), "round_id", Null, "at", Str(at)).JSON())
	}
	if len(component) > 0 && !appendLines(doneFile, component) {
		refuse("state_unwritable")
	}
	// 补读确认过的文件夹：组件检查点里记着的和之后新出现的会话文件都在这里，按读增量的同一套规则从头读。唯一一次扫目录。
	before := len(listNames(c.queue))
	since, _ := fromDate(first19(from) + "Z")
	files, skipped := 0, 0
	for _, f := range sessionFiles(root.s) {
		if !transcriptOK(f, root.s) {
			continue
		}
		// 最后修改早于历史起点的文件里没有起点以后的条目（与库相同）。
		if modifiedBefore(f, since) {
			skipped++
			continue
		}
		files++
		c.readFile(f)
	}
	queuedNames := listNames(c.queue)
	queued := len(queuedNames) - before
	judged := set{}
	for n := range listNames(filepath.Join(s.home, "results")) {
		judged[strings.TrimSuffix(n, ".json")] = true
	}
	inQueue := set{}
	for n := range queuedNames {
		inQueue[strings.TrimSuffix(n, ".json")] = true
	}
	// 组件交回了、还没送出的结果：重送时内容与当初逐字相同，world 认得出同一条。
	var carriedRows []Value
	for _, r := range eachOpt(alt(field(ex, "results"), Arr())) {
		_, hasResult := r.Lookup("result")
		if r.k == kObject && wellFormedItem(r) && hasResult && inQueue[nameOf(r)] && !judged[nameOf(r)] {
			carriedRows = append(carriedRows, r)
		}
	}
	carried := 0
	for _, r := range uniqueBy(carriedRows, func(v Value) Value { return Str(nameOf(v)) }) {
		judgedAt := get(r, "submitted_at")
		if judgedAt.k != kString {
			judgedAt = Null
		}
		value := Obj("format", Str(s.format), "item_id", get(r, "item_id"), "item_version", get(r, "item_version"), "result", get(r, "result"),
			"attempt", Int(1), "round_id", Str("import"), "judged_at", judgedAt)
		if createFile(filepath.Join(s.home, "results", nameOf(r)+".json"), value.JSON()+"\n", c.work) {
			carried++
		}
	}
	doneNow := deliveredSet(raw(doneFile))
	var missingRows []Value
	for _, r := range append(eachOpt(alt(field(ex, "pending"), Arr())), eachOpt(alt(field(ex, "results"), Arr()))...) {
		if r.k == kObject && wellFormedItem(r) && !inQueue[nameOf(r)] && !doneNow[nameOf(r)] {
			missingRows = append(missingRows, Obj("item_id", get(r, "item_id"), "item_version", get(r, "item_version")))
		}
	}
	missing := ArrOf(uniqueBy(missingRows, func(v Value) Value { return Str(nameOf(v)) }))
	record := Obj("format", Str("world-capture-import/0.1"), "agent", Str(s.agent), "selection_id", get(comp, "selection_id"), "imported_at", Str(at),
		"delivered", Int(int64(len(component))), "queued", Int(int64(queued)), "results", Int(int64(carried)), "missing", Int(int64(len(missing.arr))),
		"missing_items", missing, "files", Int(int64(files)), "skipped_files", Int(int64(skipped)),
		"component_plan_pending", Bool(!cp.IsNull() && !get(cp, "pending").IsNull()), "open_at_login", get(comp, "open_at_login"))
	if !replaceFile(filepath.Join(s.home, "import.json"), record.JSON()+"\n", c.work) ||
		!replaceFile(s.configFile(), newConfig.JSON()+"\n", c.work) {
		refuse("state_unwritable")
	}
	out(Obj("ok", True, "agent", Str(s.agent), "selection_id", get(comp, "selection_id"), "already", False).
		Merge(record.Without("format", "agent", "selection_id", "imported_at", "missing_items")))
}

func appendLines(file string, lines []string) bool {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return false
	}
	_, err = f.WriteString(strings.Join(lines, "\n") + "\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err == nil
}

// ---------- export ----------

type exportPlan struct {
	selection  Value
	device     Value
	root       Value
	entry      Value
	configured bool
	config     Value
}

func (s *setup) exportPlan(config, comp, rec, cp, backup Value) (exportPlan, bool) {
	isConfigured := configured(config, s.agent, s.format)
	switch {
	case comp.IsNull():
		refuse("component_settings_unreadable")
	case !is(get(comp, "source_format"), s.format):
		refuse("component_format_mismatch")
	case get(comp, "selection_id").IsNull():
		refuse("component_no_selection")
	case get(comp, "capture_enabled").Truthy():
		refuse("component_capture_enabled")
	case !config.IsNull() && config.k != kObject:
		refuse("config_unreadable")
	case !configDeviceOf(config).IsNull() && !equal(get(config, "device_id"), get(comp, "device_id")):
		refuse("device_mismatch")
	case !rec.IsNull() && rec.k != kObject:
		refuse("export_record_unreadable")
	}
	selection := get(comp, "selection_id")
	resume := !rec.IsNull() && rec.k == kObject && is(get(rec, "format"), "world-capture-export/0.1") && is(get(rec, "agent"), s.agent) &&
		equal(get(rec, "selection_id"), selection)
	if !isConfigured && resume && !get(rec, "done_at").IsNull() && (backup.IsNull() || !equal(backup, cp)) {
		return exportPlan{selection: selection}, true
	}
	entry := Null
	if isConfigured {
		entry = get(get(config, "agents"), s.agent)
	} else if resume {
		entry = get(rec, "entry")
	}
	switch {
	case entry.IsNull():
		refuse("not_migrated")
	case !equal(field(entry, "selection_id"), selection):
		refuse("selection_mismatch")
	case cp.IsNull() || !checkpointOK(cp):
		refuse("checkpoint_unreadable")
	case get(cp, "progress").IsNull():
		refuse("checkpoint_without_progress")
	}
	p := exportPlan{selection: selection, device: get(comp, "device_id"), root: get(comp, "root"), entry: entry, configured: isConfigured, config: Null}
	if isConfigured {
		p.config = config.With("agents", get(config, "agents").Without(s.agent))
	}
	return p, false
}

type exportCalc struct {
	checkpoint     Value
	added          int
	pendingCleared bool
	readback       []Value
	found          int
	unjudged       int
	rejudge        int
}

func exportEntries(cp Value, deliveredRaw, resultsRaw, readbackRaw string, selection Value, format string) exportCalc {
	var lines []Value
	for _, l := range jqSplit(deliveredRaw, "\n") {
		if v, ok := fromJSON(l); ok && v.k == kObject && wellFormedItem(v) {
			lines = append(lines, v)
		}
	}
	done := set{}
	for _, l := range lines {
		done[nameOf(l)] = true
	}
	var open []Value
	for _, l := range jqSplit(resultsRaw, "\n") {
		if v, ok := fromJSON(l); ok && v.k == kObject && is(get(v, "format"), format) && wellFormedItem(v) && !done[nameOf(v)] {
			open = append(open, v)
		}
	}
	open = uniqueBy(open, func(v Value) Value { return Str(nameOf(v)) })
	rb := parsed(readbackRaw)
	world := set{}
	if rb.k == kObject && get(rb, "imports").k == kArray {
		for _, x := range get(rb, "imports").arr {
			if x.k == kObject && equal(get(x, "selection_id"), selection) && get(x, "source_item_id").k == kString && get(x, "source_version").k == kString {
				world[get(x, "source_item_id").s+"@"+get(x, "source_version").s] = true
			}
		}
	}
	var nulls, sent, found []Value
	unjudged := 0
	for _, o := range open {
		_, has := o.Lookup("result")
		switch {
		case !has:
			unjudged++
		case get(o, "result").IsNull():
			nulls = append(nulls, o)
		default:
			sent = append(sent, o)
			if world[nameOf(o)] {
				found = append(found, o)
			}
		}
	}
	when := func(v Value, key string) Value {
		if t := get(v, key); t.k == kString {
			return t
		}
		return Str("")
	}
	var rows []Value
	for _, o := range append(append([]Value{}, nulls...), found...) {
		rows = append(rows, Obj("item_id", get(o, "item_id"), "item_version", get(o, "item_version"), "t", when(o, "judged_at")))
	}
	for _, l := range lines {
		rows = append(rows, Obj("item_id", get(l, "item_id"), "item_version", get(l, "item_version"), "t", when(l, "at")))
	}
	add := Obj()
	for _, group := range groupBy(rows, func(v Value) Value { return get(v, "item_id") }) {
		latest := maxBy(group, func(v Value) Value { return get(v, "t") })
		add = add.Merge(Obj(get(latest, "item_id").s, get(latest, "item_version")))
	}
	progress := get(cp, "progress")
	before := get(progress, "entries")
	calc := exportCalc{checkpoint: cp.With("progress", progress.With("entries", before.Merge(add))).With("pending", Null),
		pendingCleared: !get(cp, "pending").IsNull(), found: len(found), unjudged: unjudged, rejudge: len(open) - len(nulls) - len(found)}
	for _, k := range add.Keys() {
		if !equal(get(before, k), get(add, k)) {
			calc.added++
		}
	}
	for _, o := range sent {
		calc.readback = append(calc.readback, Obj("item_id", get(o, "item_id"), "item_version", get(o, "item_version")))
	}
	return calc
}

// resultsLines：results/ 里每个文件的每个值一行（读不出的文件只跳过它自己读不出的那部分）。
func (s *setup) resultsLines() string {
	var out []string
	filepath.WalkDir(filepath.Join(s.home, "results"), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".json") {
			if b, err := os.ReadFile(p); err == nil {
				values, _ := parseJQPrefix(b)
				for _, v := range values {
					out = append(out, v.JSON())
				}
			}
		}
		return nil
	})
	if len(out) == 0 {
		return ""
	}
	return strings.Join(out, "\n") + "\n"
}

func (s *setup) export(selectionFile, readbackFile string) {
	s.supported()
	if selectionFile != "" {
		if !isFile(selectionFile) {
			refuse("selection_file_missing")
		}
		if readbackFile == "" || !isFile(readbackFile) {
			refuse("readback_file_missing")
		}
	}
	if !isFile(s.componentFile("settings.json")) {
		refuse("component_missing")
	}
	if s.componentRunning() {
		refuse("component_running")
	}
	chosen := s.chosen()
	checkpointRaw := ""
	if chosen != "" {
		checkpointRaw = raw(s.componentFile("source-" + chosen + ".json"))
	}
	backupFile := filepath.Join(s.home, "export", "source-"+chosen+".json")
	cp := parsed(checkpointRaw)
	plan, already := s.exportPlan(parsed(raw(s.configFile())), componentSettings(parsed(raw(s.componentFile("settings.json")))),
		parsed(raw(filepath.Join(s.home, "export.json"))), cp, parsed(raw(backupFile)))
	if already {
		out(Obj("ok", True, "agent", Str(s.agent), "selection_id", plan.selection, "already", True))
		return
	}
	doneFile := filepath.Join(s.home, "delivered", s.format+".jsonl")
	lock := filepath.Join(s.home, "round.lock")
	running := isDir(lock) && !lockStale(lock)
	if selectionFile == "" {
		e := exportEntries(cp, raw(doneFile), s.resultsLines(), "", plan.selection, s.format)
		out(Obj("ok", True, "agent", Str(s.agent), "selection_id", plan.selection, "dry_run", True, "configured", Bool(plan.configured),
			"round_running", Bool(running), "added", Int(int64(e.added)), "pending_cleared", Bool(e.pendingCleared), "readback", ArrOf(e.readback),
			"rejudge", Int(int64(e.unjudged))))
		return
	}
	sel := parsed(raw(selectionFile))
	if !equal(field(sel, "selection_id"), plan.selection) {
		refuse("selection_mismatch")
	}
	entry, _, why := selectionEntry(sel, s.agent, s.format, "component_window", plan.device, tostring(plan.root))
	if why != "" {
		refuse(why)
	}
	if !equal(get(entry, "selection_version"), get(plan.entry, "selection_version")) {
		refuse("selection_version_changed")
	}
	readbackRaw := raw(readbackFile)
	rb := parsed(readbackRaw)
	switch {
	case rb.k != kObject || get(rb, "imports").k != kArray:
		refuse("readback_unreadable")
	case !equal(get(rb, "selection_id"), plan.selection):
		refuse("readback_mismatch")
	case !equal(get(rb, "complete"), True):
		refuse("readback_incomplete")
	}
	c := &capturer{agent: s.agent, format: s.format, home: s.home}
	if !c.prepare() {
		refuse("state_unwritable")
	}
	defer c.cleanup()
	at := nowISO()
	recordFile := filepath.Join(s.home, "export.json")
	if plan.configured {
		record := Obj("format", Str("world-capture-export/0.1"), "agent", Str(s.agent), "selection_id", plan.selection, "entry", plan.entry,
			"started_at", Str(at), "done_at", Null)
		if !replaceFile(recordFile, record.JSON()+"\n", c.work) {
			refuse("state_unwritable")
		}
		// 新的一次：上一次回退存的检查点不再是「改之前」的那份。
		os.Remove(backupFile)
		if !replaceFile(s.configFile(), plan.config.JSON()+"\n", c.work) {
			refuse("state_unwritable")
		}
	}
	// 这一项已经摘掉，不会再起新的一轮；手上那一轮还在跑，等它结束再跑一次。
	if isDir(lock) && !lockStale(lock) {
		refuse("round_running")
	}
	calc := exportEntries(cp, raw(doneFile), s.resultsLines(), readbackRaw, plan.selection, s.format)
	if !privateDir(filepath.Join(s.home, "export"), false) {
		refuse("state_unwritable")
	}
	checkpointFile := s.componentFile("source-" + chosen + ".json")
	if !isFile(backupFile) && !copyPreserving(checkpointFile, backupFile) {
		refuse("state_unwritable")
	}
	if !replaceComponentFile(checkpointFile, calc.checkpoint.JSON()+"\n") {
		refuse("component_unwritable")
	}
	record, ok := readJSONFile(recordFile)
	if !ok || record.k != kObject {
		refuse("state_unwritable")
	}
	record = record.With("done_at", Str(at)).With("added", Int(int64(calc.added))).With("pending_cleared", Bool(calc.pendingCleared)).
		With("readback", Int(int64(len(calc.readback)))).With("found", Int(int64(calc.found))).With("rejudge", Int(int64(calc.rejudge)))
	if !replaceFile(recordFile, record.JSON()+"\n", c.work) {
		refuse("state_unwritable")
	}
	out(Obj("ok", True, "agent", Str(s.agent), "selection_id", plan.selection, "already", False, "added", Int(int64(calc.added)),
		"pending_cleared", Bool(calc.pendingCleared), "readback", Int(int64(len(calc.readback))), "found", Int(int64(calc.found)),
		"rejudge", Int(int64(calc.rejudge))))
}

// copyPreserving 是 cp -p：内容、权限位和修改时刻都照原样。
func copyPreserving(from, to string) bool {
	info, err := os.Stat(from)
	if err != nil {
		return false
	}
	b, err := os.ReadFile(from)
	if err != nil || os.WriteFile(to, b, info.Mode().Perm()) != nil {
		return false
	}
	os.Chmod(to, info.Mode().Perm())
	os.Chtimes(to, time.Now(), info.ModTime())
	return true
}

// replaceComponentFile：组件检查点先写在它旁边的临时文件（0600），再改名。改不了名时（Windows 上杀毒、索引或组件一时占着文件）
// 隔一会儿再试，最多十次，同 capture.ps1 的 Write-Replace；Mac 上改名不会这样一时失败，多试几次结果不变。
func replaceComponentFile(path, content string) bool {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+"."+itoa(os.Getpid())+".tmp")
	defer os.Remove(tmp)
	if os.WriteFile(tmp, []byte(content), 0o600) != nil || os.Chmod(tmp, 0o600) != nil {
		return false
	}
	for attempt := 1; os.Rename(tmp, path) != nil; attempt++ {
		if attempt >= 10 {
			return false
		}
		time.Sleep(time.Duration(10*attempt) * time.Millisecond)
	}
	return true
}

func baseName(p string) string {
	p = strings.TrimRight(p, `/\`)
	if i := strings.LastIndexAny(p, `/\`); i >= 0 {
		return p[i+1:]
	}
	return p
}
