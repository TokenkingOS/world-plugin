//go:build !windows

package main

// Mac 上的部分：照 0.1.6 的 capture.sh。

import (
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// supportReason：这台机器上采集能不能工作，不能时 reason 是原因。只支持 macOS 15 以上（本人 11/17 定的）。
// TKOS_CAPTURE_OS_VERSION 换掉系统版本，只给测试用。
func supportReason() (reason, system, version string) {
	if runtime.GOOS != "darwin" {
		return "not_macos", runtime.GOOS, ""
	}
	system = "Darwin"
	raw := os.Getenv("TKOS_CAPTURE_OS_VERSION")
	if raw == "" {
		out, _ := exec.Command("/usr/bin/sw_vers", "-productVersion").Output()
		raw = string(out)
	}
	version = keepChars(raw, "0123456789.")
	major, _, _ := strings.Cut(version, ".")
	if n, err := strconv.Atoi(major); major == "" || err != nil {
		return "os_version_unknown", system, version
	} else if n < 15 {
		return "macos_too_old", system, version
	}
	return "", system, version
}

func keepChars(s, allowed string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if strings.IndexByte(allowed, s[i]) >= 0 {
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func stateHome() (string, bool) {
	if h := os.Getenv("TKOS_CAPTURE_HOME"); h != "" {
		return h, true
	}
	if h := os.Getenv("HOME"); h != "" {
		return h + "/.tkos-world/capture", true
	}
	return "", false
}

// World Capture 组件的私有目录（Electron 的 userData 下的 capture/）。迁移只读它；它在采集时这里有 agent-channel.json。
func componentDir() string {
	return os.Getenv("HOME") + "/Library/Application Support/World Capture/capture"
}

// privateDir：目录 0700，已有的也收紧；是符号链接的不用。
func privateDir(dir string, root bool) bool {
	if info, err := os.Lstat(dir); err == nil && info.Mode()&fs.ModeSymlink != 0 {
		return false
	}
	if os.MkdirAll(dir, 0o700) != nil {
		return false
	}
	return os.Chmod(dir, 0o700) == nil
}

func linkNew(tmp, path string) bool { return os.Link(tmp, path) == nil }

func crossDevice(err error) bool { return errors.Is(err, syscall.EXDEV) }

func rootedFolder(s string) bool {
	if !strings.HasPrefix(s, "/") {
		return false
	}
	for _, r := range s {
		if r < 32 {
			return false
		}
	}
	return true
}

// dirname 照 POSIX：不按 .. 化简（cd -P 要按实际所在的目录走）。
func dirname(p string) string {
	p = strings.TrimRight(p, "/")
	i := strings.LastIndexByte(p, '/')
	if i < 0 {
		return "."
	}
	d := strings.TrimRight(p[:i], "/")
	if d == "" {
		return "/"
	}
	return d
}

// physical 是 cd -P 再 pwd -P：按实际所在的目录（符号链接解开，.. 按解开后的走）。
func physical(dir string) (string, bool) {
	real, err := filepath.EvalSymlinks(dir)
	if err != nil || !isDir(real) {
		return "", false
	}
	return real, true
}

// transcriptOK：确认过的文件夹下面的 .jsonl，本身不是符号链接；按实际所在的目录比，用 .. 或文件夹里的符号链接绕到外面的不读。
func transcriptOK(path, folder string) bool {
	if !strings.HasPrefix(path, "/") || !strings.HasSuffix(path, ".jsonl") {
		return false
	}
	if !isFile(path) {
		return false
	}
	if info, err := os.Lstat(path); err != nil || info.Mode()&fs.ModeSymlink != 0 {
		return false
	}
	dir, ok := physical(dirname(path))
	if !ok {
		return false
	}
	root, ok := physical(folder)
	if !ok {
		return false
	}
	return strings.HasPrefix(dir+"/", root+"/")
}

func executable(path string) bool {
	return path != "" && isFile(path) && syscall.Access(path, 0x1) == nil
}

// locateProgram：TKOS_CAPTURE_CLAUDE / TKOS_CAPTURE_CODEX 指定的；否则钩子环境里的 PATH（command -v）；再找常见的安装位置。
func locateProgram(agent string) string {
	override := os.Getenv("TKOS_CAPTURE_CLAUDE")
	if agent == "codex" {
		override = os.Getenv("TKOS_CAPTURE_CODEX")
	}
	if override != "" {
		if executable(override) {
			return override
		}
		return ""
	}
	for _, dir := range strings.Split(agentPath(), ":") {
		candidate := agent
		if dir != "" {
			candidate = dir + "/" + agent
		}
		if executable(candidate) {
			if strings.HasPrefix(candidate, "/") {
				return candidate
			}
			break
		}
	}
	var candidates []string
	if agent == "claude" {
		candidates = []string{os.Getenv("HOME") + "/.local/bin/claude", os.Getenv("CLAUDE_CODE_EXECPATH")}
	} else {
		candidates = []string{"/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"}
	}
	for _, c := range candidates {
		if executable(c) {
			return c
		}
	}
	return ""
}

// agentPath：钩子环境里的 PATH（经 TKOS_CAPTURE_AGENT_PATH 传给脱离的进程）。
func agentPath() string {
	if p := os.Getenv("TKOS_CAPTURE_AGENT_PATH"); p != "" {
		return p
	}
	return os.Getenv("PATH")
}

func claudeConfigDir() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	return os.Getenv("HOME") + "/.claude"
}

func codexHome() string {
	if d := os.Getenv("CODEX_HOME"); d != "" {
		return d
	}
	return os.Getenv("HOME") + "/.codex"
}

// worldSkill：已装的 world 插件和它的提炼技能。Claude Code 从 installed_plugins.json 取 installPath（用户级优先，版本升级后目录会变）；
// Codex 取插件缓存里 tkos-world/world 下版本号最大的目录。
func worldSkill(agent string) (plugin, skill string) {
	const relative = "/skills/world-source-extract/SKILL.md"
	if agent == "claude" {
		installed := claudeConfigDir() + "/plugins/installed_plugins.json"
		if !isFile(installed) {
			return "", ""
		}
		data, ok := readJSONFile(installed)
		if !ok {
			return "", ""
		}
		plugin, ok = try(func() string { return installedWorld(data) })
		if !ok || plugin == "" || !isFile(plugin+relative) {
			return "", ""
		}
		return plugin, plugin + relative
	}
	cache := codexHome() + "/plugins/cache/tkos-world/world"
	version := newestVersion(sortedNames(cache))
	if version == "" || !isFile(cache+"/"+version+relative) {
		return "", ""
	}
	return cache + "/" + version, cache + "/" + version + relative
}

// programDir 是 ${program%/*}：没有 / 时原样。
func programDir(program string) string {
	if i := strings.LastIndexByte(program, '/'); i >= 0 {
		return program[:i]
	}
	return program
}

func childEnv(agent, program, tmp, round string) []string {
	user, _ := exec.Command("/usr/bin/id", "-un").Output()
	name := strings.TrimRight(string(user), "\n")
	lang := os.Getenv("LANG")
	if lang == "" {
		lang = "en_US.UTF-8"
	}
	env := []string{"HOME=" + os.Getenv("HOME"), "USER=" + name, "LOGNAME=" + name,
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin:" + programDir(program), "LANG=" + lang, "TMPDIR=" + tmp,
		"WORLD_AUTO_EXTRACT_ROUND=" + round}
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" && agent == "claude" {
		env = append(env, "CLAUDE_CONFIG_DIR="+d)
	}
	// 账号上的 claude.ai 连接器连上后，claude 会在下一次请求里补发它们的工具定义（本机实测约 12 万 token），
	// --setting-sources、--tools、--disallowedTools 都拦不住。后台轮只用 world 插件的连接，把它们关掉。
	if agent == "claude" {
		env = append(env, "ENABLE_CLAUDEAI_MCP_SERVERS=false")
	}
	if d := os.Getenv("CODEX_HOME"); d != "" && agent == "codex" {
		env = append(env, "CODEX_HOME="+d)
	}
	return env
}

// runCLI：起一次 CLI，最多等 limit 秒，到点先 TERM、过一秒再 KILL。退出码照 sh 的 wait：被信号结束的是 128 加信号。
// talk 不为空时标准输入是一条管道，由 talk 往里写（stdinOf）；为空时是提示词文件 files[0]。
func runCLI(program string, args, env []string, dir string, files [3]string, limit int64, talk talker) (run cliRun) {
	started := time.Now().Unix()
	defer func() {
		run.stdout, _ = os.ReadFile(files[1])
		run.stderr, _ = os.ReadFile(files[2])
	}()
	if !isDir(dir) {
		return cliRun{status: 1}
	}
	stdout, err1 := os.OpenFile(files[1], os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	stderr, err2 := os.OpenFile(files[2], os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err1 != nil || err2 != nil {
		return cliRun{status: 1}
	}
	defer stdout.Close()
	defer stderr.Close()
	cmd := exec.Command(program, args...)
	cmd.Dir, cmd.Env = dir, env
	cmd.Stdout, cmd.Stderr = stdout, stderr
	feed, finish, ok := stdinOf(cmd, files[0], talk)
	if !ok {
		return cliRun{status: 1}
	}
	defer finish()
	if err := cmd.Start(); err != nil {
		status := 127
		if errors.Is(err, fs.ErrPermission) {
			status = 126
		}
		return cliRun{status: status, seconds: time.Now().Unix() - started}
	}
	child = cmd.Process
	feed()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	timedOut := false
	select {
	case <-done:
	case <-time.After(time.Duration(limit) * time.Second):
		timedOut = true
		cmd.Process.Signal(syscall.SIGTERM)
		time.Sleep(time.Second)
		cmd.Process.Kill()
		<-done
	}
	child = nil
	status := 0
	if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok {
		if ws.Signaled() {
			status = 128 + int(ws.Signal())
		} else {
			status = ws.ExitStatus()
		}
	}
	return cliRun{status: status, timedOut: timedOut, seconds: time.Now().Unix() - started}
}

// tidyClaude：claude -p 每次在 projects 下按工作目录留一个目录：里面是空的 memory/，工具返回超过约 50 KB 时还有
// <会话 id>/tool-results/ 下存的完整返回（--no-session-persistence 也存）。这个目录只属于后台轮的 work/，
// 删掉存下的工具返回，再删空目录；别的文件不动。目录名是工作目录的实际路径里每个不是字母数字的字节换成 -。
func tidyClaude(work string) {
	real, ok := physical(work)
	if !ok {
		return
	}
	slug := []byte(real)
	for i, c := range slug {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			slug[i] = '-'
		}
	}
	dir := claudeConfigDir() + "/projects/" + string(slug)
	if !isDir(dir) {
		return
	}
	for _, session := range sortedNames(dir) {
		results := dir + "/" + session + "/tool-results"
		if !isDir(results) {
			continue
		}
		entries, _ := os.ReadDir(results)
		for _, f := range entries {
			if strings.HasPrefix(f.Name(), "toolu_") && f.Type().IsRegular() {
				os.Remove(results + "/" + f.Name())
			}
		}
		syscall.Rmdir(results)
		syscall.Rmdir(dir + "/" + session)
	}
	syscall.Rmdir(dir + "/memory")
	syscall.Rmdir(dir)
}

// lockStale：锁比一轮的硬时限再老一截（find -mmin +N，分钟向上取整），说明持锁的进程已经不在了。
func lockStale(lock string) bool {
	info, err := os.Lstat(lock)
	if err != nil {
		return false
	}
	n := (roundLimit() + lockMargin + 59) / 60
	minutes := (time.Now().Unix() - info.ModTime().Unix() + 59) / 60
	return minutes > n
}

// detach：拉起脱离的进程读这一段增量，钩子马上返回。会话文件路径经环境变量传。
func detach(agent, event, path string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return
	}
	defer null.Close()
	cmd := exec.Command(exe, "__worker", agent, event)
	cmd.Env = append(os.Environ(), "TKOS_CAPTURE_TRANSCRIPT="+path, "TKOS_CAPTURE_AGENT_PATH="+agentPath())
	cmd.Stdin, cmd.Stdout, cmd.Stderr = null, null, null
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if cmd.Start() == nil {
		cmd.Process.Release()
	}
}

// onSignals：脱离的进程不理会 HUP（nohup）；INT、TERM 时结束手上的 CLI、放掉锁、删掉临时目录再退出。
func onSignals(cleanup func()) {
	signal.Ignore(syscall.SIGHUP)
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		cleanup()
		os.Exit(0)
	}()
}

func dataFolder(agent string) string {
	if agent == "claude" {
		return claudeConfigDir() + "/projects"
	}
	return codexHome() + "/sessions"
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

func absolute(p string) bool { return strings.HasPrefix(p, "/") }

// sessionFiles：find -H <文件夹> -type f -name '*.jsonl'：文件夹本身是符号链接的跟进去，里面的不跟。
func sessionFiles(folder string) []string {
	root := folder
	if real, err := filepath.EvalSymlinks(folder); err == nil {
		root = real
	}
	var out []string
	filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".jsonl") {
			out = append(out, folder+strings.TrimPrefix(p, root))
		}
		return nil
	})
	return out
}

// silence：钩子模式下标准输出、标准错误都接到 /dev/null（连运行时的报错也不让它写出去）；子命令只接标准错误。
func silence(stdoutToo bool) {
	// 同 capture.sh 的 umask 077：本机状态目录 0700、文件 0600，起的 CLI 也照这个建文件。
	syscall.Umask(0o077)
	null, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		return
	}
	if stdoutToo {
		syscall.Dup2(int(null.Fd()), 1)
	}
	syscall.Dup2(int(null.Fd()), 2)
}

// staleTemp：find -mtime +0，修改时刻满一天的。
func staleTemp(info fs.FileInfo, now time.Time) bool {
	return now.Unix()-info.ModTime().Unix() >= 86400
}

func stopChild(p *os.Process) { p.Signal(syscall.SIGTERM) }

// modifiedBefore：stat -f %m（整秒）早于 since。
func modifiedBefore(path string, since int64) bool {
	info, err := os.Stat(path)
	return err == nil && info.ModTime().Unix() < since
}
