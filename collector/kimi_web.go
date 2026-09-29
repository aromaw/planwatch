package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strings"
	"time"
)

func (f *fetcher) kimiPost(ctx context.Context, host, path, token, body string) (object, error) {
	req, e := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+host+"/apiv2/"+path, strings.NewReader(body))
	if e != nil {
		return nil, failure("request", "请求配置错误")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Cookie", "kimi-auth="+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "PlanWatch/0.1 (quota monitor)")
	req.Header.Set("Origin", "https://"+host)
	req.Header.Set("Referer", "https://"+host+"/code/console")
	req.Header.Set("Connect-Protocol-Version", "1")
	req.Header.Set("X-Msh-Platform", "web")
	// Forward this web session's own identifiers if present, without treating JWT contents as trusted claims.
	parts := strings.Split(token, ".")
	if len(parts) == 3 {
		if b, e := base64.RawURLEncoding.DecodeString(parts[1]); e == nil {
			var claims object
			if json.Unmarshal(b, &claims) == nil {
				for claim, header := range map[string]string{"device_id": "X-Msh-Device-Id", "ssid": "X-Msh-Session-Id", "sub": "X-Traffic-Id"} {
					if v := str(claims[claim]); v != "" && len(v) < 1024 && printableASCII(v) {
						req.Header.Set(header, v)
					}
				}
			}
		}
	}
	return f.send(req)
}
func (f *fetcher) fetchKimiWeb(ctx context.Context, r Request) (Snapshot, error) {
	host := "www.kimi.com"
	if r.Region == "global" {
		host = "www.kimi.ai"
	}
	token := strings.TrimPrefix(r.Credential, "web:")
	usage, e := f.kimiPost(ctx, host, "kimi.gateway.billing.v1.BillingService/GetUsages", token, `{"scope":["FEATURE_CODING"]}`)
	if e != nil {
		return Snapshot{}, e
	}
	stats, statsErr := f.kimiPost(ctx, host, "kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats", token, `{}`)
	s := parseKimiWeb(usage, stats, f.now())
	if statsErr != nil {
		s.Notes = append(s.Notes, "会员月额度查询失败，请重新登录或稍后刷新。")
		var q *queryError
		if errors.As(statsErr, &q) {
			s.RetryAfter = q.retry
		}
	}
	return s, nil
}
func parseKimiWeb(usage, stats object, now time.Time) Snapshot {
	var code object
	if list, ok := usage["usages"].([]any); ok {
		for _, v := range list {
			if m := obj(v); str(m["scope"]) == "FEATURE_CODING" {
				code = m
				break
			}
		}
	}
	s := parseKimi(object{"usage": code["detail"], "limits": code["limits"]}, now)
	balance := obj(stats["subscriptionBalance"])
	feature, kind := str(balance["feature"]), str(balance["type"])
	if (feature == "" || feature == "FEATURE_OMNI") && (kind == "" || kind == "SUBSCRIPTION") {
		if ratio, ok := num(balance, "amountUsedRatio"); ok && ratio >= 0 {
			// This is the shared membership monthly pool, not the code-only component.
			s.Windows[2] = percentWindow("month", "月总额度", "", ratio*100, date(balance["expireTime"]))
			s.Notes = nil
		}
	}
	week := obj(stats["ratelimitCode7d"])
	if week["enabled"] == false {
		s.Windows[1] = Window{ID: "week", Label: "周额度", Note: "套餐未启用周限制"}
	} else if ratio, ok := num(week, "ratio"); ok && ratio >= 0 {
		w := percentWindow("week", "周额度", "", ratio*100, reset(week, now))
		if s.Windows[1].Percent == nil {
			s.Windows[1] = w
		} else if math.Abs(*s.Windows[1].Percent-ratio*100) > 1 {
			w.ID = "membership-week"
			w.Label = "会员 Code 周额度"
			s.Windows = append(s.Windows, w)
		}
	}
	return s
}

// Header values from untrusted token claims must be plain printable ASCII, or the
// HTTP client rejects the whole request.
func printableASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return false
		}
	}
	return true
}
