"""Checks one outcome run against the exported files and prints it as JSON.
Standard library only. usage: outcome_report.py DIR TASK_ID"""
import glob
import json
import os
import sys

directory, task_id = sys.argv[1:3]


def read(prefix):
    return [json.loads(line) for path in glob.glob(os.path.join(directory, prefix + "-*.jsonl"))
            for line in open(path) if line.strip()]


all_spans = read("spans")
trace_ids = {s["context"]["trace_id"] for s in all_spans if s["attributes"].get("anm.task.id") == task_id}
spans = [s for s in all_spans if s["context"]["trace_id"] in trace_ids]
run = next(r for r in read("results") if r["task_id"] == task_id)
evaluation = [e for e in read("events") if e.get("attributes", {}).get("anm.task.id") == task_id][-1]
span_ids = {s["context"]["span_id"] for s in spans}
roots = [s for s in spans if not s["parent_id"]]
children = [s for s in spans if s["parent_id"]]

result = {
    **{k: run[k] for k in ("task_id", "scenario", "question", "answer", "tool_result", "trace_id", "span_id", "policy")},
    "span_count": len(spans),
    "trace_count": len(trace_ids),
    "parent_links_valid": len(roots) == 1 and all(s["parent_id"] in span_ids for s in children),
    "statuses": sorted({s["status"]["status_code"] for s in spans}),
    "http_statuses": sorted({s["attributes"]["http.response.status_code"] for s in spans
                             if "http.response.status_code" in s["attributes"]}),
    "evaluation": evaluation,
    "resource": roots[0]["resource"]["attributes"],
    "spans": [{"name": s["name"], "kind": s["kind"], "span_id": s["context"]["span_id"], "parent_id": s["parent_id"],
               "status": s["status"]["status_code"], "attributes": s["attributes"], "events": s["events"]}
              for s in spans],
}

# Every scenario runs clean: one trace, five spans, HTTP 200, nothing in error.
assert result["span_count"] == 5 and result["trace_count"] == 1, "expected five spans in one trace"
assert result["parent_links_valid"], "a span points at a parent outside the trace"
assert result["statuses"] == ["UNSET"] and result["http_statuses"] == [200]
# The evaluation lands on the agent span.
assert evaluation["trace_id"].removeprefix("0x") == run["trace_id"]
assert evaluation["span_id"].removeprefix("0x") == run["span_id"]
expected = "fail" if run["scenario"] in ("wrong_answer", "pods_unhealthy") else "pass"
assert evaluation["attributes"]["gen_ai.evaluation.score.label"] == expected
if run["scenario"] == "injection_blocked":
    assert run["policy"] == {"tool": "send_demo_secret", "decision": "blocked", "executed": False}
    assert any(e["name"] == "anm.policy.decision" for s in spans for e in s["events"])
print(json.dumps(result, indent=2))
