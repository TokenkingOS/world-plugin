//go:build windows

package main

// Windows 上的部分：照 0.1.6 的 capture.ps1（数据目录、程序位置、命令行引号、权限、脱离方式）。

import (
	"errors"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf16"
	"unsafe"
)

const (
	createNoWindow         = 0x08000000
	detachedProcess        = 0x00000008
	createNewProcessGroup  = 0x00000200
	createBreakawayFromJob = 0x01000000
)

// supportReason：Windows 上没有不支持的情形。os_version 照 [Environment]::OSVersion.Version 的写法。
func supportReason() (reason, system, version string) {
	type osVersionInfo struct {
		size, major, minor, build, platform uint32
		csd                                 [128]uint16
	}
	info := osVersionInfo{}
	info.size = uint32(unsafe.Sizeof(info))
	proc := syscall.NewLazyDLL("ntdll.dll").NewProc("RtlGetVersion")
	if proc.Find() == nil {
		proc.Call(uintptr(unsafe.Pointer(&info)))
	}
	return "", "Windows", strconv.Itoa(int(info.major)) + "." + strconv.Itoa(int(info.minor)) + "." + strconv.Itoa(int(info.build)) + ".0"
}

// joinPath 是 PowerShell 的 Join-Path：前一段末尾已有分隔符就不再加。
func joinPath(base, child string) string {
	if base == "" {
		return child
	}
	if strings.HasSuffix(base, `\`) || strings.HasSuffix(base, "/") {
		return base + child
	}
	return base + `\` + child
}

func stateHome() (string, bool) {
	if h := os.Getenv("TKOS_CAPTURE_HOME"); h != "" {
		return h, true
	}
	if h := os.Getenv("USERPROFILE"); h != "" {
		return joinPath(h, `.tkos-world\capture`), true
	}
	return "", false
}

func componentDir() string {
	if a := os.Getenv("APPDATA"); a != "" {
		return joinPath(joinPath(a, "World Capture"), "capture")
	}
	return ""
}

func reparsePoint(path string) bool {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return false
	}
	attrs, err := syscall.GetFileAttributes(p)
	return err == nil && attrs&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0
}

func hidden(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}

// privateDir：状态目录本身收到当前用户和 SYSTEM（icacls，子目录和文件继承）；它下面的子目录只是建出来。
func privateDir(dir string, root bool) bool {
	if !root {
		return os.MkdirAll(dir, 0o700) == nil
	}
	if isDir(dir) {
		if reparsePoint(dir) {
			return false
		}
	} else if os.MkdirAll(dir, 0o700) != nil {
		return false
	}
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return true
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return true
	}
	sid, err := user.User.Sid.String()
	if err != nil {
		return true
	}
	cmd := exec.Command(filepath.Join(os.Getenv("SystemRoot"), "System32", "icacls.exe"), dir, "/inheritancelevel:r", "/grant:r",
		"*"+sid+":(OI)(CI)F", "*S-1-5-18:(OI)(CI)F")
	hidden(cmd)
	cmd.Run()
	return true
}

// linkNew：目标已在时不动它（File.Move 的语义：MoveFile 不覆盖已有的文件）。
func linkNew(tmp, path string) bool {
	from, err1 := syscall.UTF16PtrFromString(tmp)
	to, err2 := syscall.UTF16PtrFromString(path)
	return err1 == nil && err2 == nil && syscall.MoveFile(from, to) == nil
}

// ERROR_NOT_SAME_DEVICE
func crossDevice(err error) bool { return errors.Is(err, syscall.Errno(17)) }

// pathRooted 是 [System.IO.Path]::IsPathRooted：以 \ 或 / 开头，或者是盘符加冒号。
func pathRooted(p string) bool {
	if p != "" && (p[0] == '\\' || p[0] == '/') {
		return true
	}
	return len(p) >= 2 && p[1] == ':' && (p[0] >= 'A' && p[0] <= 'Z' || p[0] >= 'a' && p[0] <= 'z')
}

var rootedPattern = regexp.MustCompile(`\A(?:[A-Za-z]:[\\/]|\\\\)`)

func rootedFolder(s string) bool {
	if !rootedPattern.MatchString(s) {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 {
			return false
		}
	}
	return true
}

func absolute(p string) bool { return rootedPattern.MatchString(p) }

// transcriptOK：确认过的文件夹下面的 .jsonl，本身不是重解析点；规范化后（.. 已消掉）在文件夹里（不区分大小写），
// 从文件夹往下到它所在目录的每一层都不是重解析点。
func transcriptOK(path, folder string) bool {
	if !rootedPattern.MatchString(path) || !strings.HasSuffix(path, ".jsonl") || !isFile(path) || reparsePoint(path) {
		return false
	}
	full, err1 := filepath.Abs(path)
	root, err2 := filepath.Abs(folder)
	if err1 != nil || err2 != nil {
		return false
	}
	root = strings.TrimRight(root, `\/`)
	if !strings.HasPrefix(strings.ToLower(full), strings.ToLower(root+`\`)) {
		return false
	}
	for dir := filepath.Dir(full); len(dir) > len(root); dir = filepath.Dir(dir) {
		if reparsePoint(dir) {
			return false
		}
	}
	return true
}

// locateProgram：TKOS_CAPTURE_CLAUDE / TKOS_CAPTURE_CODEX 指定的；否则 PATH 里的 <名字>.exe/.cmd/.bat；再找常见的安装位置。
func locateProgram(agent string) string {
	override := os.Getenv("TKOS_CAPTURE_CLAUDE")
	if agent == "codex" {
		override = os.Getenv("TKOS_CAPTURE_CODEX")
	}
	if override != "" {
		if isFile(override) {
			return override
		}
		return ""
	}
	for _, dir := range strings.Split(os.Getenv("PATH"), ";") {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			continue
		}
		for _, ext := range []string{".exe", ".cmd", ".bat"} {
			if candidate := joinPath(dir, agent+ext); isFile(candidate) {
				return candidate
			}
		}
	}
	var candidates []string
	if agent == "claude" {
		candidates = []string{joinPath(os.Getenv("USERPROFILE"), `.local\bin\claude.exe`), os.Getenv("CLAUDE_CODE_EXECPATH")}
	} else {
		candidates = []string{joinPath(os.Getenv("APPDATA"), `npm\codex.cmd`)}
	}
	for _, c := range candidates {
		if c != "" && isFile(c) {
			return c
		}
	}
	return ""
}

func claudeConfigDir() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	return joinPath(os.Getenv("USERPROFILE"), ".claude")
}

func codexHome() string {
	if d := os.Getenv("CODEX_HOME"); d != "" {
		return d
	}
	return joinPath(os.Getenv("USERPROFILE"), ".codex")
}

var versionName = regexp.MustCompile(`\A([0-9]+)\.([0-9]+)\.([0-9]+)\z`)

// worldSkill：Claude Code 从 installed_plugins.json 取（用户级优先），第一个装着提炼技能的绝对路径；
// Codex 取插件缓存里 tkos-world\world 下版本号最大的目录。
func worldSkill(agent string) (plugin, skill string) {
	const relative = `skills\world-source-extract\SKILL.md`
	if agent == "claude" {
		installed := joinPath(claudeConfigDir(), `plugins\installed_plugins.json`)
		if !isFile(installed) {
			return "", ""
		}
		data, ok := readJSONFile(installed)
		if !ok {
			return "", ""
		}
		entries := field(field(data, "plugins"), "world@tkos-world")
		if entries.k != kArray {
			return "", ""
		}
		var ordered []Value
		for _, e := range entries.arr {
			if is(field(e, "scope"), "user") {
				ordered = append(ordered, e)
			}
		}
		for _, e := range append(ordered, entries.arr...) {
			p := field(e, "installPath")
			if p.k == kString && pathRooted(p.s) && isFile(joinPath(p.s, relative)) {
				return p.s, joinPath(p.s, relative)
			}
		}
		return "", ""
	}
	cache := joinPath(codexHome(), `plugins\cache\tkos-world\world`)
	entries, err := os.ReadDir(cache)
	if err != nil {
		return "", ""
	}
	best, bestKey := "", [3]int64{}
	for _, e := range entries {
		m := versionName.FindStringSubmatch(e.Name())
		if m == nil || !isDir(joinPath(cache, e.Name())) {
			continue
		}
		var key [3]int64
		for i := range key {
			key[i], _ = strconv.ParseInt(m[i+1], 10, 64)
		}
		better := best == ""
		for i := 0; !better && i < 3; i++ {
			if key[i] != bestKey[i] {
				better = key[i] > bestKey[i]
				break
			}
		}
		if better {
			best, bestKey = joinPath(cache, e.Name()), key
		}
	}
	if best == "" || !isFile(joinPath(best, relative)) {
		return "", ""
	}
	return best, joinPath(best, relative)
}

// childEnv：子进程只拿到这些环境变量，不带钩子环境里 Agent 会话自己的变量。
func childEnv(agent, program, tmp, round string) []string {
	var env []string
	for _, k := range []string{"SystemRoot", "SystemDrive", "windir", "ComSpec", "PATHEXT", "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "HOME", "APPDATA",
		"LOCALAPPDATA", "ProgramData", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "CommonProgramFiles", "CommonProgramFiles(x86)", "USERNAME",
		"USERDOMAIN", "COMPUTERNAME", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "OS", "CLAUDE_CONFIG_DIR", "CODEX_HOME"} {
		if v := os.Getenv(k); v != "" {
			env = append(env, k+"="+v)
		}
	}
	system := joinPath(os.Getenv("SystemRoot"), "System32")
	env = append(env, "PATH="+filepath.Dir(program)+";"+system+";"+os.Getenv("SystemRoot")+";"+joinPath(system, `WindowsPowerShell\v1.0`)+";"+os.Getenv("PATH"),
		"TEMP="+tmp, "TMP="+tmp, "WORLD_AUTO_EXTRACT_ROUND="+round)
	// 账号上的 claude.ai 连接器连上后，claude 会在下一次请求里补发它们的工具定义（Mac 上实测约 12 万 token），
	// --setting-sources、--tools、--disallowedTools 都拦不住。后台轮只用 world 插件的连接，把它们关掉。
	if agent == "claude" {
		env = append(env, "ENABLE_CLAUDEAI_MCP_SERVERS=false")
	}
	return env
}

// quoteArg：Windows 命令行的引号规则（CommandLineToArgvW）：空格、制表符、引号要加引号，引号前的反斜杠加倍。
func quoteArg(a string) string {
	if a != "" && !strings.ContainsFunc(a, func(r rune) bool { return r == '"' || unicode.IsSpace(r) }) {
		return a
	}
	var b strings.Builder
	b.WriteByte('"')
	slashes := 0
	for _, r := range a {
		switch r {
		case '\\':
			slashes++
			continue
		case '"':
			b.WriteString(strings.Repeat(`\`, 2*slashes+1))
			b.WriteByte('"')
			slashes = 0
			continue
		}
		if slashes > 0 {
			b.WriteString(strings.Repeat(`\`, slashes))
			slashes = 0
		}
		b.WriteRune(r)
	}
	b.WriteString(strings.Repeat(`\`, 2*slashes))
	b.WriteByte('"')
	return b.String()
}

// runCLI：起一次 CLI，最多等 limit 秒，到点连同子进程一起结束（taskkill /T /F）。
// talk 不为空时标准输入是一条管道，由 talk 往里写（stdinOf）；为空时是提示词文件 files[0]。
func runCLI(program string, args, env []string, dir string, files [3]string, limit int64, talk talker) (run cliRun) {
	started := time.Now()
	defer func() {
		run.stdout, _ = os.ReadFile(files[1])
		run.stderr, _ = os.ReadFile(files[2])
	}()
	stdout, err1 := os.OpenFile(files[1], os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	stderr, err2 := os.OpenFile(files[2], os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err1 != nil || err2 != nil {
		return cliRun{status: 127}
	}
	defer stdout.Close()
	defer stderr.Close()
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = quoteArg(a)
	}
	name, line := program, `"`+program+`" `+strings.Join(quoted, " ")
	// npm 装的 claude、codex 是 .cmd，由 cmd /c 起。capture.ps1 的 Process.Start 不把程序名交给 CreateProcess，
	// 系统转给 cmd /c 时整行外面多一层引号；Go 交了程序名，就不加这一层，cmd 剥掉整行第一个和最后一个引号，命令行就坏了。这里自己加。
	if ext := strings.ToLower(filepath.Ext(program)); ext == ".cmd" || ext == ".bat" {
		name = joinPath(os.Getenv("SystemRoot"), `System32\cmd.exe`)
		line = `"` + name + `" /c "` + line + `"`
	}
	cmd := exec.Command(name)
	cmd.Dir, cmd.Env = dir, env
	cmd.Stdout, cmd.Stderr = stdout, stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow, CmdLine: line}
	feed, finish, ok := stdinOf(cmd, files[0], talk)
	if !ok {
		return cliRun{status: 127}
	}
	defer finish()
	if cmd.Start() != nil {
		return cliRun{status: 127}
	}
	child = cmd.Process
	feed()
	done := make(chan struct{})
	go func() { cmd.Wait(); close(done) }()
	timedOut := false
	select {
	case <-done:
	case <-time.After(time.Duration(limit) * time.Second):
		timedOut = true
		kill := exec.Command(filepath.Join(os.Getenv("SystemRoot"), "System32", "taskkill.exe"), "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid))
		hidden(kill)
		kill.Run()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
		}
	}
	child = nil
	status := 137
	select {
	case <-done:
		status = cmd.ProcessState.ExitCode()
	default:
	}
	return cliRun{status: status, timedOut: timedOut, seconds: int64(math.RoundToEven(time.Since(started).Seconds()))}
}

// tidyClaude：claude -p 每次在 projects 下按工作目录留一个目录；删掉存下的工具返回，再删空目录。目录名是工作目录里每个不是字母数字的字符换成 -。
func tidyClaude(work string) {
	units := utf16.Encode([]rune(work))
	slug := make([]rune, len(units))
	for i, u := range units {
		if u >= 'A' && u <= 'Z' || u >= 'a' && u <= 'z' || u >= '0' && u <= '9' {
			slug[i] = rune(u)
		} else {
			slug[i] = '-'
		}
	}
	dir := joinPath(joinPath(claudeConfigDir(), "projects"), string(slug))
	if !isDir(dir) {
		return
	}
	empty := func(d string) bool { entries, err := os.ReadDir(d); return err == nil && len(entries) == 0 }
	sessions, _ := os.ReadDir(dir)
	for _, s := range sessions {
		if !s.IsDir() {
			continue
		}
		session := joinPath(dir, s.Name())
		results := joinPath(session, "tool-results")
		if !isDir(results) {
			continue
		}
		files, _ := os.ReadDir(results)
		for _, f := range files {
			if !f.IsDir() && strings.HasPrefix(strings.ToLower(f.Name()), "toolu_") {
				os.Remove(joinPath(results, f.Name()))
			}
		}
		for _, d := range []string{results, session} {
			if empty(d) {
				os.Remove(d)
			}
		}
	}
	for _, d := range []string{joinPath(dir, "memory"), dir} {
		if isDir(d) && empty(d) {
			os.Remove(d)
		}
	}
}

func lockStale(lock string) bool {
	info, err := os.Stat(lock)
	if err != nil {
		return false
	}
	return info.ModTime().Before(time.Now().Add(-time.Duration(roundLimit()+lockMargin) * time.Second))
}

// detach：拉起脱离的进程读这一段增量，钩子马上返回。会话文件路径经环境变量传，免得命令行引号出错。
// 先试着脱离钩子所在的作业对象（Agent 结束钩子时整组结束的话，脱离的进程也跟着没了）；作业不许脱离时退回不带这一项。
func detach(agent, event, path string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	for _, flags := range []uint32{detachedProcess | createNewProcessGroup | createBreakawayFromJob, detachedProcess | createNewProcessGroup} {
		cmd := exec.Command(exe, "__worker", agent, event)
		cmd.Env = append(os.Environ(), "TKOS_CAPTURE_TRANSCRIPT="+path)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: flags}
		if cmd.Start() == nil {
			cmd.Process.Release()
			return
		}
	}
}

func onSignals(cleanup func()) {}

func dataFolder(agent string) string {
	if agent == "claude" {
		return joinPath(claudeConfigDir(), "projects")
	}
	return joinPath(codexHome(), "sessions")
}

func dataDirName(agent string) string {
	if agent == "claude" {
		if os.Getenv("CLAUDE_CONFIG_DIR") != "" {
			return "CLAUDE_CONFIG_DIR"
		}
		return "~/.claude"
	}
	if os.Getenv("CODEX_HOME") != "" {
		return "CODEX_HOME"
	}
	return "~/.codex"
}

// sessionFiles：文件夹下（不进重解析点）所有 .jsonl。
func sessionFiles(root string) []string {
	var found []string
	if !isDir(root) {
		return found
	}
	pending := []string{root}
	for len(pending) > 0 {
		dir := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			p := joinPath(dir, e.Name())
			if e.IsDir() {
				if !reparsePoint(p) {
					pending = append(pending, p)
				}
			} else if strings.HasSuffix(strings.ToLower(e.Name()), ".jsonl") {
				found = append(found, p)
			}
		}
	}
	return found
}

var setStdHandle = syscall.NewLazyDLL("kernel32.dll").NewProc("SetStdHandle")

// STD_OUTPUT_HANDLE、STD_ERROR_HANDLE（DWORD 的 -11、-12）。
var stdOutputHandle, stdErrorHandle = ^uint32(10), ^uint32(11)

func silence(stdoutToo bool) {
	null, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		return
	}
	if stdoutToo {
		setStdHandle.Call(uintptr(stdOutputHandle), null.Fd())
		os.Stdout = null
	}
	setStdHandle.Call(uintptr(stdErrorHandle), null.Fd())
	os.Stderr = null
}

// staleTemp：临时目录里超过一天的残留目录。
func staleTemp(info fs.FileInfo, now time.Time) bool {
	return info.IsDir() && info.ModTime().Before(now.Add(-24*time.Hour))
}

func stopChild(p *os.Process) { p.Kill() }

func modifiedBefore(path string, since int64) bool {
	info, err := os.Stat(path)
	return err == nil && info.ModTime().Before(time.Unix(since, 0))
}
