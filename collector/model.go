package main

import (
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"time"
)

// Secrets are accepted only on stdin, never in command arguments or logs.
type Request struct {
	Provider   string `json:"provider"`
	Credential string `json:"credential"`
	Region     string `json:"region"`
	CodexPath  string `json:"codexPath"`
}

type Window struct {
	ID      string   `json:"id"`
	Label   string   `json:"label"`
	Pool    string   `json:"pool,omitempty"`
	Percent *float64 `json:"percent,omitempty"`
	Used    *float64 `json:"used,omitempty"`
	Limit   *float64 `json:"limit,omitempty"`
	Unit    string   `json:"unit,omitempty"`
	ResetAt *int64   `json:"resetAt,omitempty"`
	Note    string   `json:"note,omitempty"`
}

type Snapshot struct {
	Provider   string   `json:"provider"`
	Plan       string   `json:"plan,omitempty"`
	Account    string   `json:"account,omitempty"`
	Windows    []Window `json:"windows"`
	Notes      []string `json:"notes,omitempty"`
	FetchedAt  int64    `json:"fetchedAt"`
	Error      string   `json:"error,omitempty"`
	ErrorCode  string   `json:"errorCode,omitempty"`
	RetryAfter int64    `json:"retryAfter,omitempty"`
}

type object map[string]any

func obj(v any) object {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	if m, ok := v.(object); ok {
		return m
	}
	return nil
}
func str(v any) string { s, _ := v.(string); return s }
func number(v any) (float64, bool) {
	var n float64
	var err error
	switch x := v.(type) {
	case float64:
		n = x
	case json.Number:
		n, err = x.Float64()
	case string:
		n, err = strconv.ParseFloat(strings.TrimSpace(x), 64)
	default:
		return 0, false
	}
	return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
}
func num(m object, keys ...string) (float64, bool) {
	for _, k := range keys {
		if n, ok := number(m[k]); ok {
			return n, true
		}
	}
	return 0, false
}
func date(v any) *int64 {
	if n, ok := number(v); ok && n > 0 && n < 1e15 {
		if n > 1e11 {
			n /= 1000
		}
		t := int64(n)
		return &t
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if t, e := time.Parse(layout, str(v)); e == nil {
			n := t.Unix()
			return &n
		}
	}
	return nil
}
func reset(m object, now time.Time) *int64 {
	for _, k := range []string{"resetsAt", "resetAt", "reset_at", "resetTime", "reset_time", "reset_at_ms", "renewsAt"} {
		if t := date(m[k]); t != nil {
			return t
		}
	}
	if n, ok := num(m, "resetInSec", "resetInSeconds", "reset_in_seconds"); ok && n >= 0 && n < 366*86400 {
		t := now.Unix() + int64(n)
		return &t
	}
	return nil
}
func pointer(n float64) *float64 { return &n }
func percentWindow(id, label, pool string, p float64, r *int64) Window {
	return Window{ID: id, Label: label, Pool: pool, Percent: pointer(p), ResetAt: r}
}
func countWindow(id, label, pool string, m object, now time.Time) Window {
	w := Window{ID: id, Label: label, Pool: pool, ResetAt: reset(m, now)}
	limit, ok := num(m, "limit", "cap", "total", "limitMicroCents")
	if !ok || limit <= 0 {
		return w
	}
	used, ok := num(m, "used", "usedMicroCents")
	if !ok {
		if remain, valid := num(m, "remaining"); valid && remain >= 0 && remain <= limit {
			used = limit - remain
			ok = true
		}
	}
	if ok && used >= 0 {
		w.Percent = pointer(used / limit * 100)
		w.Used = pointer(used)
		w.Limit = pointer(limit)
	}
	return w
}
func validWindows(ws []Window) bool {
	for _, w := range ws {
		if w.Percent != nil {
			return true
		}
	}
	return false
}
func labelForMinutes(n float64) string {
	switch n {
	case 300:
		return "5 小时"
	case 10080:
		return "周额度"
	}
	if n >= 1440 && math.Mod(n, 1440) == 0 {
		return strconv.FormatFloat(n/1440, 'f', -1, 64) + " 天"
	}
	if n >= 60 && math.Mod(n, 60) == 0 {
		return strconv.FormatFloat(n/60, 'f', -1, 64) + " 小时"
	}
	return strconv.FormatFloat(n, 'f', -1, 64) + " 分钟"
}
