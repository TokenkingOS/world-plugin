// world-capture 的启动程序：0.1.6 的 capture.sh、capture.jq、round.jq、setup.jq 与 capture.ps1 移植成一个 Go 程序。
//
//	capture <claude|codex> <事件>                         钩子：stdin 是钩子的 JSON（transcript_path）
//	capture <check|enable|import> <claude|codex> [文件]    「开始采集」那次对话里的 Agent 调用
//	capture export <claude|codex> [选择记录 读回记录]       回退到组件时调用
//
// 钩子模式任何情况下退出码都是 0，标准输出和标准错误都不写：Agent 会解析钩子的标准输出，Stop 钩子输出 {"decision":"block"} 会拦住会话。
// 子命令在标准输出上交一行 JSON，拒绝时退出码 1。
package main

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var stdout = bufio.NewWriter(os.Stdout)

// out 写子命令的那一行。
func out(v Value) {
	stdout.WriteString(v.JSON())
	stdout.WriteByte(10)
	stdout.Flush()
	answered = true
}

var answered bool

func main() { os.Exit(run(os.Args[1:])) }

var letters = regexp.MustCompile(`\A[A-Za-z]+\z`)

func run(args []string) (code int) {
	if os.Getenv("WORLD_AUTO_EXTRACT_ROUND") != "" {
		return 0
	}
	command, mode := "", "hook"
	if len(args) > 0 {
		switch args[0] {
		case "check", "enable", "import", "export":
			command, mode, args = args[0], args[0], args[1:]
		case "__worker":
			mode, args = "worker", args[1:]
		}
	}
	silence(command == "")
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		if command == "" {
			code = 0
			return
		}
		why := "failed"
		if f, ok := r.(refusal); ok {
			why = f.reason
		}
		if !answered {
			out(Obj("ok", False, "reason", Str(why)))
		}
		code = 1
	}()
	arg := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	agent, event := arg(0), arg(1)
	var format string
	switch agent {
	case "claude":
		format = claudeFormat
	case "codex":
		format = codexFormat
	default:
		if command != "" {
			refuse("unknown_agent")
		}
		return 0
	}
	if command == "" && !letters.MatchString(event) {
		return 0
	}
	home, ok := stateHome()
	if !ok {
		if command != "" {
			refuse("no_home")
		}
		return 0
	}
	s := &setup{agent: agent, format: format, home: home}
	switch mode {
	case "check":
		s.check()
	case "enable":
		s.enable(arg(1))
	case "import":
		s.importFrom(arg(1))
	case "export":
		s.export(arg(1), arg(2))
	case "worker":
		worker(agent, event, format, home, os.Getenv("TKOS_CAPTURE_TRANSCRIPT"))
	default:
		hook(agent, event, format, home)
	}
	return 0
}

type setup struct{ agent, format, home string }

func (s *setup) configFile() string { return filepath.Join(s.home, "config.json") }

func (s *setup) componentFile(name string) string {
	dir := componentDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, name)
}

func (s *setup) componentRunning() bool {
	f := s.componentFile("agent-channel.json")
	return f != "" && exists(f)
}

func (s *setup) supported() {
	if reason, _, _ := supportReason(); reason != "" {
		refuse(reason)
	}
}

// ---------- 钩子 ----------

func hook(agent, event, format, home string) {
	if unsupported(home) {
		return
	}
	os.Remove(filepath.Join(home, "unsupported.json"))
	configFile := filepath.Join(home, "config.json")
	if !isFile(configFile) {
		return
	}
	config, ok := readJSONFile(configFile)
	if !ok {
		return
	}
	if _, _, _, ok := configEntry(config, agent, format); !ok {
		return
	}
	input, _ := io.ReadAll(os.Stdin)
	values, ok := parseJQ(input)
	if !ok {
		return
	}
	var paths []string
	for _, v := range values {
		if p := field(v, "transcript_path"); p.k == kString {
			paths = append(paths, p.s)
		}
	}
	path := strings.Join(paths, "\n")
	if path == "" {
		return
	}
	if os.Getenv("TKOS_CAPTURE_FOREGROUND") == "1" {
		worker(agent, event, format, home, path)
		return
	}
	detach(agent, event, path)
}

// unsupported：这台机器不能采集时只把原因写进 unsupported.json（临时文件再改名），别的什么都不做。
func unsupported(home string) bool {
	reason, system, version := supportReason()
	if reason == "" {
		return false
	}
	if !isDir(home) && !privateDir(home, true) {
		return true
	}
	file := filepath.Join(home, "unsupported.json")
	seen := nowISO()
	first := firstSeenIn(file)
	if first == "" {
		first = seen
	}
	replaceFile(file, `{"reason":"`+reason+`","system":"`+system+`","os_version":"`+version+`","first_seen_at":"`+first+`","last_seen_at":"`+seen+`"}`+"\n", home)
	return true
}

// worker：读这个会话文件上次读到的位置之后、已经写完整的行，新条目放进队列，最后做起轮决定。
func worker(agent, event, format, home, path string) {
	configFile := filepath.Join(home, "config.json")
	if !isFile(configFile) {
		return
	}
	config, ok := readJSONFile(configFile)
	if !ok {
		return
	}
	sourceID, from, folder, ok := configEntry(config, agent, format)
	if !ok || !transcriptOK(path, folder) {
		return
	}
	c := &capturer{agent: agent, event: event, format: format, home: home, sourceID: sourceID, from: from, folder: folder,
		screen: equal(field(config, "screen_short"), True)}
	if !c.prepare() {
		return
	}
	defer c.cleanup()
	onSignals(c.cleanup)
	c.readFile(path)
	c.decide()
}

// prepare：本机状态目录和这一次运行的临时目录。
func (c *capturer) prepare() bool {
	home := c.home
	if !privateDir(home, true) || !privateDir(filepath.Join(home, "transcripts"), false) || !privateDir(filepath.Join(home, "tmp"), false) {
		return false
	}
	prefix, _, _ := strings.Cut(c.format, "/")
	c.queue = filepath.Join(home, "queue", filepath.FromSlash(c.format))
	for _, dir := range []string{filepath.Join(home, "queue"), filepath.Join(home, "queue", prefix), c.queue} {
		if !privateDir(dir, false) {
			return false
		}
	}
	// 超过一天的残留（中途被杀的运行留下的）删掉。
	tmp := filepath.Join(home, "tmp")
	entries, _ := os.ReadDir(tmp)
	for _, e := range entries {
		if info, err := e.Info(); err == nil && staleTemp(info, time.Now()) {
			os.RemoveAll(filepath.Join(tmp, e.Name()))
		}
	}
	work, err := os.MkdirTemp(tmp, "run.")
	if err != nil {
		return false
	}
	c.work = work
	return true
}

func (c *capturer) cleanup() {
	if child != nil {
		stopChild(child)
	}
	if r := activeRound; r != nil {
		r.releaseLock()
	}
	if c.work != "" {
		os.RemoveAll(c.work)
	}
}
