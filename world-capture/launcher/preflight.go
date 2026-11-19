package main

// 预检：Claude Code 连 world 的调用（准备、送出、回执）用 stream-json 输入，先发 initialize、mcp_status 两个控制请求问 world 的状态，
// connected 才把提示词作为一条用户消息写进去；不是 connected 就不写，关掉标准输入，CLI 不调模型就退出（claude 2.1.327 实测约 1–3 秒、
// 退出码 0、没有 result 行、0 token）。world 没令牌、令牌被拒（needs-auth）或连不上（failed）时 claude -p 不会自己停，照样调一次模型。
// Codex 不用：world 在那边是 required，没连上 codex 在调模型之前就退出。

import (
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// talker 往子进程的标准输入写；exited 关上表示子进程已退出。
type talker func(w io.Writer, exited <-chan struct{})

// stdinOf：子进程的标准输入。talk 为空时是提示词文件（同 capture.sh 的 < 重定向）；不为空时是一条管道，进程起来以后（start）
// 另起一路由 talk 往里写，写完关上。finish 在进程退出或没起来以后调用，最多等那一路 2 秒：子进程已退出时写不进去的那一下会报错返回。
// 标准输出、标准错误照旧写文件、不走管道（Node 写的 CLI 往管道写时，进程一退出没写完的就丢了），预检的回复也从输出文件里读。
func stdinOf(cmd *exec.Cmd, promptFile string, talk talker) (start, finish func(), ok bool) {
	if talk == nil {
		f, err := os.Open(promptFile)
		if err != nil {
			return nil, nil, false
		}
		cmd.Stdin = f
		return func() {}, func() { f.Close() }, true
	}
	w, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, false
	}
	exited, done := make(chan struct{}), make(chan struct{})
	started := false
	start = func() {
		started = true
		go func() {
			defer close(done)
			talk(w, exited)
			w.Close()
		}()
	}
	finish = func() {
		close(exited)
		if !started {
			w.Close()
			return
		}
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	}
	return start, finish, true
}

// preflight：一次连 world 的 claude 调用的预检。status 是问到的 world 状态（mcp_status 里 plugin:world:world 那一行的 status，
// 列表里没有它是 missing）；问不出来（没回复、回复读不出、进程先退了）时是空串，这一次照输出本身分类。
type preflight struct {
	out    string // CLI 的标准输出文件
	prompt string
	wait   time.Duration // pending 时最多问多久
	status string
}

// pendingWait：pending 时最多再问多久。world 连得慢时 claude 先报 pending，连接超时（MCP_TIMEOUT，缺省 30 秒，启动程序不设）以后
// 自己改成 failed（2.1.327 实测：起进程后约 28 秒）；连得上的也是第一次问报 pending、约 0.1 秒后 connected。所以最多问 45 秒，
// 不超过这次调用的时限减 10 秒，留出关掉标准输入以后 CLI 退出的时间，免得被当成超时；但至少问 5 秒，时限只剩几秒的调用也要等到
// 连得上的 world 报 connected，不能把第一次的 pending 当结果。时限比 5 秒还短的，到点照旧停掉、记超时。
func pendingWait(limit int64) time.Duration {
	return time.Duration(max(min(45, limit-10), 5)) * time.Second
}

func newPreflight(out, prompt string, limit int64) *preflight {
	return &preflight{out: out, prompt: prompt, wait: pendingWait(limit)}
}

func controlRequest(id, subtype string) string {
	return Obj("type", Str("control_request"), "request_id", Str(id), "request", Obj("subtype", Str(subtype))).JSON() + "\n"
}

// replyWait：一次 mcp_status 最多等多久回复（实测 0.1–0.2 秒就回）。不回就当预检出错。
const replyWait = 10 * time.Second

// talk：initialize，再问 mcp_status；pending 每秒再问一次，到 wait 为止。connected 才写提示词（提示词为空时也不写，CLI 没有输入就退出，
// 同原来交空文件）。写不进去（进程已退出）就作罢。
func (p *preflight) talk(w io.Writer, exited <-chan struct{}) {
	pendingUntil := time.Now().Add(p.wait)
	if _, err := io.WriteString(w, controlRequest("initialize", "initialize")); err != nil {
		return
	}
	tail := &outTail{path: p.out}
	for n := 1; ; n++ {
		id := "mcp_status-" + strconv.Itoa(n)
		if _, err := io.WriteString(w, controlRequest(id, "mcp_status")); err != nil {
			return
		}
		status, ok := tail.await(id, time.Now().Add(replyWait), exited)
		if !ok {
			return
		}
		if status != "pending" || !time.Now().Add(time.Second).Before(pendingUntil) {
			p.status = status
			break
		}
		select {
		case <-exited:
			return
		case <-time.After(time.Second):
		}
	}
	if p.status == "connected" && p.prompt != "" {
		message := Obj("type", Str("user"), "message", Obj("role", Str("user"), "content", Str(p.prompt)))
		io.WriteString(w, message.JSON()+"\n")
	}
}

// stopped：问到了 world 的状态，不是 connected，这一次没写提示词。
func (p *preflight) stopped() bool { return p != nil && p.status != "" && p.status != "connected" }

// outTail：边读输出文件边找控制回复。只认已经写完一整行的；没写完的留到下一次读。
type outTail struct {
	path   string
	offset int64
	rest   string
}

func (t *outTail) lines() []string {
	f, err := os.Open(t.path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if _, err := f.Seek(t.offset, io.SeekStart); err != nil {
		return nil
	}
	b, _ := io.ReadAll(f)
	t.offset += int64(len(b))
	parts := strings.Split(t.rest+string(b), "\n")
	t.rest = parts[len(parts)-1]
	return parts[:len(parts)-1]
}

// await：等 request_id 为 id 的控制回复，交回 world 的状态。回复不是 success、读不出，或者到了 deadline、进程先退了，交 false。
func (t *outTail) await(id string, deadline time.Time, exited <-chan struct{}) (string, bool) {
	for {
		for _, line := range t.lines() {
			v, ok := fromJSON(line)
			if !ok || v.k != kObject || !is(get(v, "type"), "control_response") {
				continue
			}
			status, ok := try(func() string { return worldStatus(get(v, "response"), id) })
			if ok && status == "" {
				continue
			}
			return status, ok && status != "\x00"
		}
		select {
		case <-exited:
			return "", false
		default:
		}
		if !time.Now().Before(deadline) {
			return "", false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// worldStatus：一条控制回复里 world 的状态；不是这一问的回复交空串，是这一问的但出错或读不出交 "\x00"。
func worldStatus(r Value, id string) string {
	if !is(get(r, "request_id"), id) {
		return ""
	}
	servers := path(r, "response", "mcpServers")
	if !is(get(r, "subtype"), "success") || servers.k != kArray {
		return "\x00"
	}
	for _, s := range servers.arr {
		if is(field(s, "name"), "plugin:world:world") {
			if status := field(s, "status"); status.k == kString && status.s != "" {
				return status.s
			}
			return "\x00"
		}
	}
	return "missing"
}
