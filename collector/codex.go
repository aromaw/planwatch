package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

func codexExecutable(override string) (string, error) {
	if override != "" {
		if !filepath.IsAbs(override) {
			return "", failure("setup", "Codex 路径必须是可执行文件的绝对路径")
		}
		if i, e := os.Stat(override); e == nil && !i.IsDir() && i.Mode()&0111 != 0 {
			return override, nil
		}
		return "", failure("setup", "找不到指定的 Codex 可执行文件")
	}
	if p, e := exec.LookPath("codex"); e == nil {
		return p, nil
	}
	home, _ := os.UserHomeDir()
	for _, p := range []string{filepath.Join(home, ".local/bin/codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"} {
		if i, e := os.Stat(p); e == nil && !i.IsDir() && i.Mode()&0111 != 0 {
			return p, nil
		}
	}
	return "", failure("setup", "未找到 Codex CLI。请先安装并登录，或在设置中选择其路径。")
}

func fetchCodex(ctx context.Context, r Request, now time.Time) (Snapshot, error) {
	path, e := codexExecutable(r.CodexPath)
	if e != nil {
		return Snapshot{}, e
	}
	cmd := exec.CommandContext(ctx, path, "app-server")
	cmd.Dir = os.TempDir()
	cmd.Stderr = io.Discard
	// Kill the whole process group on timeout so helper subprocesses do not linger.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 2 * time.Second
	stdin, e := cmd.StdinPipe()
	if e != nil {
		return Snapshot{}, failure("cli", "无法启动 Codex 查询")
	}
	stdout, e := cmd.StdoutPipe()
	if e != nil {
		return Snapshot{}, failure("cli", "无法启动 Codex 查询")
	}
	if cmd.Start() != nil {
		return Snapshot{}, failure("cli", "无法启动 Codex CLI，请检查路径")
	}
	defer func() { stdin.Close(); _ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); _ = cmd.Wait() }()
	encoder := json.NewEncoder(stdin)
	if encoder.Encode(object{"id": 1, "method": "initialize", "params": object{"clientInfo": object{"name": "planwatch", "title": "PlanWatch", "version": "0.1.0"}, "capabilities": object{}}}) != nil {
		return Snapshot{}, failure("cli", "Codex 初始化失败")
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 8192), 2*1024*1024)
	var rates, account object
	for scanner.Scan() {
		var m object
		if json.Unmarshal(scanner.Bytes(), &m) != nil {
			continue
		}
		id, _ := num(m, "id")
		switch id {
		case 1:
			if m["error"] != nil {
				return Snapshot{}, failure("cli", "Codex CLI 版本不兼容，请更新")
			}
			encoder.Encode(object{"method": "initialized"})
			encoder.Encode(object{"id": 2, "method": "account/rateLimits/read"})
			encoder.Encode(object{"id": 3, "method": "account/read", "params": object{"refreshToken": false}})
		case 2:
			if m["error"] != nil {
				return Snapshot{}, failure("auth", "无法读取 Codex 订阅额度。请在 Codex CLI 登录 ChatGPT 账号。")
			}
			rates = obj(m["result"])
		case 3:
			account = obj(m["result"])
			if account == nil {
				account = object{}
			}
		}
		if rates != nil && account != nil {
			s := parseCodex(rates, now)
			a := obj(account["account"])
			s.Account = str(a["email"])
			if p := str(a["planType"]); p != "" {
				s.Plan = p
			}
			return s, nil
		}
	}
	if rates != nil {
		return parseCodex(rates, now), nil
	}
	return Snapshot{}, failure("cli", "Codex 查询超时或连接已关闭，请更新 CLI 后重试")
}
func parseCodex(root object, now time.Time) Snapshot {
	s := Snapshot{Plan: "Codex"}
	pools := obj(root["rateLimitsByLimitId"])
	if len(pools) == 0 {
		if r := obj(root["rateLimits"]); r != nil {
			pools = object{"codex": r}
		}
	}
	keys := make([]string, 0, len(pools))
	for k := range pools {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, key := range keys {
		pool := obj(pools[key])
		name := str(pool["limitName"])
		if name == "" && key != "codex" {
			name = key
		}
		for _, slot := range []string{"primary", "secondary"} {
			m := obj(pool[slot])
			if m == nil {
				continue
			}
			p, ok := num(m, "usedPercent")
			minutes, hasDuration := num(m, "windowDurationMins")
			if !ok || p < 0 {
				continue
			}
			label := "额度窗口"
			if hasDuration && minutes > 0 {
				label = labelForMinutes(minutes)
			}
			w := percentWindow(key+"/"+slot, label, name, p, reset(m, now))
			s.Windows = append(s.Windows, w)
		}
		if p := str(pool["planType"]); p != "" {
			s.Plan = p
		}
	}
	if !strings.Contains(s.Plan, "Codex") {
		s.Plan = "Codex · " + s.Plan
	}
	return s
}
