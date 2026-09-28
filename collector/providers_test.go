package main

import (
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"
)

var testNow = time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)

func payload(t *testing.T, s string) object {
	t.Helper()
	var m object
	d := json.NewDecoder(strings.NewReader(s))
	d.UseNumber()
	if e := d.Decode(&m); e != nil {
		t.Fatal(e)
	}
	return m
}
func checkPercent(t *testing.T, w Window, want float64) {
	t.Helper()
	if w.Percent == nil || math.Abs(*w.Percent-want) > 0.000001 {
		t.Fatalf("%s: got %v, want %v", w.ID, w.Percent, want)
	}
}

func TestKimiRatioPools(t *testing.T) {
	s := parseKimi(payload(t, `{"usages":{"limit_5h":{"used_ratio":0.82,"reset_time":"2026-09-26T15:00:00Z"},"limit_7d":{"used_ratio":0.95},"limit_month_total":{"used_ratio":0.43}},"user":{"membership":{"level":"LEVEL_INTERMEDIATE"}}}`), testNow)
	checkPercent(t, s.Windows[0], 82)
	checkPercent(t, s.Windows[1], 95)
	checkPercent(t, s.Windows[2], 43)
	if s.Plan != "Allegretto" || s.Windows[0].ResetAt == nil {
		t.Fatal(s)
	}
}
func TestKimiLegacyAndMissingMonthly(t *testing.T) {
	s := parseKimi(payload(t, `{"usage":{"limit":"100","remaining":"20"},"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"used":7}}],"usages":{"limit_5h":{"used_ratio":0},"limit_7d":{"used_ratio":0}}}`), testNow)
	checkPercent(t, s.Windows[0], 7)
	checkPercent(t, s.Windows[1], 80)
	if s.Windows[2].Percent != nil {
		t.Fatal("unknown monthly must not be zero")
	}
}
func TestMissingCountersAreNotZero(t *testing.T) {
	s := parseKimi(payload(t, `{"usage":{"limit":100},"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"remaining":101}}]}`), testNow)
	if validWindows(s.Windows) {
		t.Fatal("missing/invalid counters must stay unknown")
	}
}
func TestKimiOverageAndUnknownPlanVersion(t *testing.T) {
	s := parseKimi(payload(t, `{"usage":{"limit":100,"used":110},"version":"GOODS_VERSION_V2","user":{"membership":{"level":"LEVEL_INTERMEDIATE"}}}`), testNow)
	checkPercent(t, s.Windows[1], 110)
	if s.Plan == "Allegretto" {
		t.Fatal("must not rename new plans with old catalog")
	}
}
func TestCommandSharedCreditsAndMonthlyBalance(t *testing.T) {
	s := parseCommand(payload(t, `{"credits":{"monthlyCredits":"17.5","monthlyCreditsGranted":70,"purchasedCredits":20},"windowLimits":{"fiveHour":{"used":12.6,"cap":14,"resetAt":1790449200000},"weekly":{"used":28,"cap":35}}}`), nil, testNow)
	checkPercent(t, s.Windows[0], 90)
	checkPercent(t, s.Windows[1], 80)
	checkPercent(t, s.Windows[2], 75)
	if *s.Windows[0].ResetAt != 1790449200 {
		t.Fatal("milliseconds were not normalized")
	}
	if len(s.Notes) == 0 {
		t.Fatal("extra credits must be separated")
	}
}
func TestCommandUnknownGrantAndSubscriptionFallback(t *testing.T) {
	root := payload(t, `{"credits":{"monthlyCredits":35},"windowLimits":{"fiveHour":{"cap":14}}}`)
	s := parseCommand(root, nil, testNow)
	if s.Windows[2].Percent != nil || s.Windows[0].Percent != nil {
		t.Fatal("must not invent grant or usage")
	}
	s = parseCommand(root, payload(t, `{"success":true,"data":{"planId":"individual-goat","currentPeriodEnd":"2026-10-01T00:00:00Z"}}`), testNow)
	checkPercent(t, s.Windows[2], 50)
}
func TestOpenCodeSmallPercentIsNotFraction(t *testing.T) {
	s := parseOpenCode(payload(t, `{"usage":{"rolling":{"usagePercent":0.5,"resetInSec":3600},"weekly":{"usedMicroCents":"25","limitMicroCents":"100"},"monthly":{"usagePercent":81}}}`), testNow)
	checkPercent(t, s.Windows[0], 0.5)
	checkPercent(t, s.Windows[1], 25)
	checkPercent(t, s.Windows[2], 81)
	if *s.Windows[0].ResetAt != testNow.Unix()+3600 {
		t.Fatal("reset countdown not anchored")
	}
}
func TestOpenCodeMissingMonthlyAndModels(t *testing.T) {
	s := parseOpenCode(payload(t, `{"usage":{"rolling":{"percent":20},"models":{"model-b":{"rolling":{"percent":90}},"model-a":{"rolling":{"percent":10}}}}}`), testNow)
	if s.Windows[2].Percent != nil {
		t.Fatal("missing monthly must stay unknown")
	}
	if len(s.Windows) != 9 || s.Windows[3].Pool != "model-a" {
		t.Fatal(s)
	}
}
func TestCodexUsesDurationsAndAvoidsDuplicateLegacyPool(t *testing.T) {
	s := parseCodex(payload(t, `{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":81,"windowDurationMins":10080}},"other":{"limitName":"Other","primary":{"usedPercent":50,"windowDurationMins":60}}}}`), testNow)
	if len(s.Windows) != 3 || s.Windows[1].Label != "周额度" || s.Windows[2].Label != "60 分钟" {
		t.Fatal(s)
	}
	checkPercent(t, s.Windows[0], 0)
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestTransportAuthAndErrorRedaction(t *testing.T) {
	f := newFetcher()
	f.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != "https://api.kimi.com/coding/v1/usages" || r.Header.Get("Authorization") != "Bearer test-secret" {
			t.Fatal("bad request")
		}
		return &http.Response{StatusCode: 401, Body: io.NopCloser(strings.NewReader("test-secret")), Header: http.Header{}}, nil
	})
	s := f.fetch(context.Background(), Request{Provider: "kimi", Credential: "test-secret"})
	if s.ErrorCode != "auth" || strings.Contains(s.Error, "test-secret") {
		t.Fatal(s)
	}
}
func TestRateLimitBackoff(t *testing.T) {
	f := newFetcher()
	f.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 429, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{"Retry-After": []string{"600"}}}, nil
	})
	s := f.fetch(context.Background(), Request{Provider: "opencode", Credential: "test"})
	if s.RetryAfter != 600 || s.ErrorCode != "rate_limited" {
		t.Fatal(s)
	}
}
func TestCredentialRedirectNeverFollowed(t *testing.T) {
	f := newFetcher()
	calls := 0
	f.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 302, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{"Location": []string{"https://untrusted.example/"}}, Request: r}, nil
	})
	s := f.fetch(context.Background(), Request{Provider: "opencode", Credential: "test"})
	if calls != 1 || s.Error == "" {
		t.Fatal("followed auth redirect")
	}
}

func TestKimiWebUsesSharedMonthlyNotCodingOnly(t *testing.T) {
	usage := payload(t, `{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":100,"used":70},"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"used":40}}]}]}`)
	stats := payload(t, `{"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.9,"kimiCodeUsedRatio":0.2,"expireTime":"2026-10-01T00:00:00Z"},"ratelimitCode7d":{"enabled":true,"ratio":0.7}}`)
	s := parseKimiWeb(usage, stats, testNow)
	checkPercent(t, s.Windows[0], 40)
	checkPercent(t, s.Windows[1], 70)
	checkPercent(t, s.Windows[2], 90)
	if len(s.Windows) != 3 || s.Windows[2].ResetAt == nil {
		t.Fatal(s)
	}
}
func TestKimiWebDisabledWeekAndNonSubscriptionBalance(t *testing.T) {
	stats := payload(t, `{"subscriptionBalance":{"feature":"FEATURE_CODING","type":"EXTRA","amountUsedRatio":0.5},"ratelimitCode7d":{"enabled":false}}`)
	s := parseKimiWeb(nil, stats, testNow)
	if s.Windows[1].Percent != nil || s.Windows[1].Note != "套餐未启用周限制" || s.Windows[2].Percent != nil {
		t.Fatal(s)
	}
}
func TestKimiWebTransport(t *testing.T) {
	f := newFetcher()
	calls := 0
	f.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "POST" || r.URL.Host != "www.kimi.ai" || r.Header.Get("Authorization") != "Bearer test-token" || r.Header.Get("Cookie") != "kimi-auth=test-token" {
			t.Fatal("invalid Kimi web query")
		}
		body := `{"usages":[{"scope":"FEATURE_CODING","detail":{"used":10,"limit":100}}]}`
		if strings.HasSuffix(r.URL.Path, "GetSubscriptionStats") {
			body = `{"subscriptionBalance":{"amountUsedRatio":0.3}}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})
	s := f.fetch(context.Background(), Request{Provider: "kimi", Region: "global", Credential: "web:test-token"})
	if calls != 2 || s.Error != "" {
		t.Fatal(s)
	}
	checkPercent(t, s.Windows[2], 30)
}
func TestMalformedRatiosCannotBreakJSONOutput(t *testing.T) {
	f := newFetcher()
	f.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"usages":{"limit_5h":{"used_ratio":"1e308"}}}`)), Header: http.Header{}}, nil
	})
	s := f.fetch(context.Background(), Request{Provider: "kimi", Credential: "test"})
	if _, e := json.Marshal(s); e != nil {
		t.Fatal(e)
	}
	if s.ErrorCode != "schema" {
		t.Fatal("overflow must be unknown")
	}
}

func TestPartialCommandLookupPreservesUpstreamBackoff(t *testing.T) {
	f := newFetcher()
	f.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "subscriptions") {
			return &http.Response{StatusCode: 429, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{"Retry-After": []string{"600"}}}, nil
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"credits":{"monthlyCredits":35,"monthlyCreditsGranted":70},"windowLimits":{"fiveHour":{"used":2,"cap":14}}}`)), Header: http.Header{}}, nil
	})
	s := f.fetch(context.Background(), Request{Provider: "commandcode", Credential: "session=test"})
	if s.Error != "" || s.RetryAfter != 600 {
		t.Fatal(s)
	}
	checkPercent(t, s.Windows[2], 50)
}
