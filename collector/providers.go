package main

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

func (f *fetcher) fetchKimi(ctx context.Context, r Request) (Snapshot, error) {
	if strings.HasPrefix(r.Credential, "web:") {
		return f.fetchKimiWeb(ctx, r)
	}
	host := "api.kimi.com"
	if r.Region == "global" {
		host = "api.kimi.ai"
	}
	root, e := f.get(ctx, "https://"+host+"/coding/v1/usages", r.Credential, false)
	if e != nil {
		return Snapshot{}, e
	}
	return parseKimi(root, f.now()), nil
}
func parseKimi(root object, now time.Time) Snapshot {
	s := Snapshot{Plan: "Kimi Code"}
	pools := obj(root["usages"])
	level := str(obj(obj(root["user"])["membership"])["level"])
	names := map[string]string{"LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro", "LEVEL_BASIC": "Moderato", "LEVEL_TRIAL": "Andante"}
	if name := names[level]; name != "" && (root["version"] == nil || str(root["version"]) == "GOODS_VERSION_V1") {
		s.Plan = name
	} else if level != "" {
		s.Plan = level
	}
	legacy := map[string]Window{}
	if detail := obj(root["usage"]); detail != nil {
		legacy["week"] = countWindow("week", "周额度", "", detail, now)
	}
	if limits, ok := root["limits"].([]any); ok {
		for _, raw := range limits {
			limit := obj(raw)
			window := obj(limit["window"])
			n, _ := num(window, "duration")
			switch str(window["timeUnit"]) {
			case "TIME_UNIT_HOUR":
				n *= 60
			case "TIME_UNIT_DAY":
				n *= 1440
			case "TIME_UNIT_MINUTE":
			default:
				continue
			}
			id := ""
			switch n {
			case 300:
				id = "5h"
			case 10080:
				id = "week"
			default:
				continue
			}
			legacy[id] = countWindow(id, labelForMinutes(n), "", obj(limit["detail"]), now)
		}
	}
	for _, spec := range []struct{ id, label, key string }{{"5h", "5 小时", "limit_5h"}, {"week", "周额度", "limit_7d"}, {"month", "月额度", "limit_month_total"}} {
		w, has := legacy[spec.id]
		pool := obj(pools[spec.key])
		if ratio, ok := num(pool, "used_ratio"); ok && ratio >= 0 {
			// Some old accounts return placeholder zero pools alongside populated counters.
			if !(ratio == 0 && has && w.Percent != nil && *w.Percent > 0) {
				w = percentWindow(spec.id, spec.label, "", ratio*100, reset(pool, now))
				has = true
			}
		}
		if !has {
			w = Window{ID: spec.id, Label: spec.label, Note: "接口未提供"}
		}
		s.Windows = append(s.Windows, w)
	}
	if s.Windows[2].Percent == nil {
		s.Notes = append(s.Notes, "月总额度未由当前接口返回，请以会员订阅页为准。")
	}
	return s
}

func (f *fetcher) fetchCommand(ctx context.Context, r Request) (Snapshot, error) {
	root, e := f.get(ctx, "https://api.commandcode.ai/internal/billing/credits", r.Credential, true)
	if e != nil {
		return Snapshot{}, e
	}
	sub, subErr := f.get(ctx, "https://api.commandcode.ai/internal/billing/subscriptions", r.Credential, true)
	s := parseCommand(root, sub, f.now())
	if subErr != nil {
		s.Notes = append(s.Notes, "套餐信息暂时无法读取，月额度或重置时间可能缺失。")
		var q *queryError
		if errors.As(subErr, &q) {
			s.RetryAfter = q.retry
		}
	}
	return s, nil
}
func parseCommand(root, sub object, now time.Time) Snapshot {
	s := Snapshot{Plan: "Command Code"}
	credits := obj(root["credits"])
	limits := obj(root["windowLimits"])
	if limits == nil {
		limits = obj(credits["windowLimits"])
	}
	for _, spec := range []struct{ id, label, key string }{{"5h", "5 小时", "fiveHour"}, {"week", "周额度", "weekly"}} {
		w := countWindow(spec.id, spec.label, "", obj(limits[spec.key]), now)
		w.Unit = "credits"
		s.Windows = append(s.Windows, w)
	}
	monthly := Window{ID: "month", Label: "月额度", Unit: "credits"}
	granted, hasGrant := num(credits, "monthlyCreditsGranted")
	if sub["success"] == true {
		data := obj(sub["data"])
		id := str(data["planId"])
		if id != "" {
			s.Plan = strings.TrimPrefix(id, "individual-")
		}
		monthly.ResetAt = date(data["currentPeriodEnd"])
		// Only the explicitly identified GOAT plan uses its published fallback grant.
		if !hasGrant && id == "individual-goat" {
			granted = 70
			hasGrant = true
			s.Notes = append(s.Notes, "月上限使用 GOAT 官方公布的 70 credits；已用量来自账号余额。")
		}
	}
	if remain, ok := num(credits, "monthlyCredits"); ok && hasGrant && granted > 0 && remain >= 0 && remain <= granted {
		used := granted - remain
		monthly.Percent = pointer(used / granted * 100)
		monthly.Used = &used
		monthly.Limit = &granted
	}
	s.Windows = append(s.Windows, monthly)
	if n, ok := num(credits, "purchasedCredits"); ok && n > 0 {
		s.Notes = append(s.Notes, "账号另有充值余额；订阅额度耗尽后可能继续扣费。")
	}
	return s
}

func (f *fetcher) fetchOpenCode(ctx context.Context, r Request) (Snapshot, error) {
	root, e := f.get(ctx, "https://opencode.ai/zen/go/v1/usage", r.Credential, false)
	if e != nil {
		return Snapshot{}, e
	}
	return parseOpenCode(root, f.now()), nil
}
func parseOpenCode(root object, now time.Time) Snapshot {
	s := Snapshot{Plan: "OpenCode Go"}
	usage := obj(root["usage"])
	add := func(u object, pool string) {
		for _, spec := range []struct{ id, label, key string }{{"5h", "5 小时", "rolling"}, {"week", "周额度", "weekly"}, {"month", "月额度", "monthly"}} {
			m := obj(u[spec.key])
			w := countWindow(spec.id, spec.label, pool, m, now)
			// API percentages are 0..100. In particular 0.5 means 0.5%, never 50%.
			if n, ok := num(m, "usagePercent", "usedPercent", "used_percent", "percent", "percentage"); ok && n >= 0 {
				w.Percent = &n
			}
			if w.ResetAt == nil && spec.id == "month" {
				for _, k := range []string{"renewsAt", "renewAt", "renew_at"} {
					if t := date(u[k]); t != nil {
						w.ResetAt = t
						break
					}
					if t := date(root[k]); t != nil {
						w.ResetAt = t
						break
					}
				}
			}
			if pool != "" {
				w.ID = pool + "/" + spec.id
			}
			s.Windows = append(s.Windows, w)
		}
	}
	if obj(usage["rolling"]) != nil || obj(usage["weekly"]) != nil || obj(usage["monthly"]) != nil {
		add(usage, "")
	}
	// Accept only explicit per-model usage maps; never infer scopes from arbitrary numbers.
	if models := obj(usage["models"]); models != nil {
		keys := make([]string, 0, len(models))
		for k := range models {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			m := obj(models[k])
			if m == nil {
				continue
			}
			if u := obj(m["usage"]); u != nil {
				m = u
			}
			add(m, k)
		}
	}
	if len(s.Windows) > 0 && len(obj(usage["models"])) == 0 {
		s.Notes = append(s.Notes, "当前接口返回套餐汇总；未返回的模型明细不作估算。")
	}
	return s
}
