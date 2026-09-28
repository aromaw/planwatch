package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"strings"
	"time"
)

type queryError struct {
	code, message string
	retry         int64
}

func (e *queryError) Error() string      { return e.message }
func failure(code, message string) error { return &queryError{code: code, message: message} }

type fetcher struct {
	client *http.Client
	now    func() time.Time
}

func newFetcher() *fetcher {
	return &fetcher{client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}, now: time.Now}
}

func (f *fetcher) get(ctx context.Context, url, credential string, cookie bool) (object, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, failure("request", "请求配置错误")
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "PlanWatch/0.1 (quota monitor)")
	if cookie {
		req.Header.Set("Cookie", credential)
		req.Header.Set("Origin", "https://commandcode.ai")
		req.Header.Set("Referer", "https://commandcode.ai/")
	} else {
		req.Header.Set("Authorization", "Bearer "+credential)
	}
	return f.send(req)
}
func (f *fetcher) send(req *http.Request) (object, error) {
	resp, err := f.client.Do(req)
	if err != nil {
		return nil, failure("network", "连接失败，请检查网络后重试")
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return nil, failure("auth", "登录已失效或没有查询权限，请重新接入")
	}
	if resp.StatusCode == 429 {
		retry := int64(120)
		if t, e := http.ParseTime(resp.Header.Get("Retry-After")); e == nil {
			retry = int64(t.Sub(f.now()).Seconds())
		} else if n, ok := number(resp.Header.Get("Retry-After")); ok && n > 0 && n < 86400 {
			retry = int64(n)
		}
		if retry < 30 {
			retry = 30
		}
		if retry > 86400 {
			retry = 86400
		}
		return nil, &queryError{code: "rate_limited", message: "查询频率受限，稍后自动重试", retry: retry}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, failure("upstream", "服务暂时不可用，请稍后重试")
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024+1))
	if err != nil || len(data) > 2*1024*1024 {
		return nil, failure("schema", "额度响应过大或不完整")
	}
	var root object
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	if dec.Decode(&root) != nil || root == nil {
		return nil, failure("schema", "未收到有效的额度数据，接口可能已变更")
	}
	return root, nil
}
func (f *fetcher) fetch(ctx context.Context, r Request) Snapshot {
	s := Snapshot{Provider: r.Provider, Windows: []Window{}, FetchedAt: f.now().Unix()}
	r.Credential = strings.TrimSpace(r.Credential)
	var err error
	if r.Provider != "codex" && r.Credential == "" {
		err = failure("setup", "请先在设置中接入账号")
	} else {
		switch r.Provider {
		case "codex":
			s, err = fetchCodex(ctx, r, f.now())
		case "kimi":
			s, err = f.fetchKimi(ctx, r)
		case "commandcode":
			s, err = f.fetchCommand(ctx, r)
		case "opencode":
			s, err = f.fetchOpenCode(ctx, r)
		default:
			err = failure("setup", "未知服务")
		}
	}
	s.Provider = r.Provider
	s.FetchedAt = f.now().Unix()
	if s.Windows == nil {
		s.Windows = []Window{}
	}
	for i := range s.Windows {
		if p := s.Windows[i].Percent; p != nil && (math.IsNaN(*p) || math.IsInf(*p, 0) || *p < 0) {
			s.Windows[i].Percent = nil
		}
	}
	if err == nil && !validWindows(s.Windows) {
		err = failure("schema", "接口未返回可识别的额度，无法判断剩余量")
	}
	if err != nil {
		var q *queryError
		if errors.As(err, &q) {
			s.Error = q.message
			s.ErrorCode = q.code
			s.RetryAfter = q.retry
		} else {
			s.Error = "查询失败，请稍后重试"
			s.ErrorCode = "unknown"
		}
	}
	return s
}
func main() {
	var r Request
	dec := json.NewDecoder(io.LimitReader(os.Stdin, 128*1024))
	dec.DisallowUnknownFields()
	if dec.Decode(&r) != nil {
		json.NewEncoder(os.Stdout).Encode(Snapshot{Windows: []Window{}, Error: "无效的查询参数", ErrorCode: "input"})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	json.NewEncoder(os.Stdout).Encode(newFetcher().fetch(ctx, r))
}
