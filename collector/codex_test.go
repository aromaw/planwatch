package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The test binary acts as a fake stdio server; it never invokes a real Codex installation.
func TestCodexRPCSubprocessHelper(t *testing.T) {
	if os.Getenv("PLANWATCH_RPC_HELPER") != "1" {
		return
	}
	if os.Getenv("PLANWATCH_RPC_HANG") == "1" {
		time.Sleep(30 * time.Second)
		os.Exit(0)
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var m object
		if json.Unmarshal(scanner.Bytes(), &m) != nil {
			os.Exit(2)
		}
		switch str(m["method"]) {
		case "initialize":
			fmt.Println(`{"id":1,"result":{"userAgent":"test"}}`)
		case "initialized":
		case "account/rateLimits/read":
			fmt.Println(`{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":82,"windowDurationMins":300,"resetsAt":1790450000}}}}`)
		case "account/read":
			fmt.Println(`{"id":3,"result":{"account":{"type":"chatgpt","email":"example@example.test","planType":"plus"}}}`)
		default:
			os.Exit(3)
		}
	}
	os.Exit(0)
}
func fakeCodex(t *testing.T) string {
	t.Helper()
	binary, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	t.Setenv("PLANWATCH_TEST_BINARY", binary)
	t.Setenv("PLANWATCH_RPC_HELPER", "1")
	dir := filepath.Join(t.TempDir(), "path with spaces")
	if e = os.MkdirAll(dir, 0700); e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(dir, "codex")
	script := "#!/bin/sh\nexec \"$PLANWATCH_TEST_BINARY\" -test.run=TestCodexRPCSubprocessHelper\n"
	if e = os.WriteFile(path, []byte(script), 0700); e != nil {
		t.Fatal(e)
	}
	return path
}
func TestCodexSubprocessHandshakeAndAccount(t *testing.T) {
	path := fakeCodex(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s, e := fetchCodex(ctx, Request{CodexPath: path}, testNow)
	if e != nil {
		t.Fatal(e)
	}
	checkPercent(t, s.Windows[0], 82)
	if s.Account != "example@example.test" || s.Plan != "plus" {
		t.Fatal(s)
	}
}
func TestCodexSubprocessTimeout(t *testing.T) {
	path := fakeCodex(t)
	t.Setenv("PLANWATCH_RPC_HANG", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, e := fetchCodex(ctx, Request{CodexPath: path}, testNow)
	if e == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("timeout failed: %v", e)
	}
}
func TestCodexRejectsRelativeOverride(t *testing.T) {
	_, e := codexExecutable("./codex")
	if e == nil || strings.Contains(e.Error(), "secret") {
		t.Fatal(e)
	}
}
