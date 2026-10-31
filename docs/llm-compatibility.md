# LLM compatibility: which Claude model actually runs ARTEX

This is a deployment-specific finding, English only (not translated like the rest of this fork),, not upstream behaviour, recorded here because the fork's own
`deploy/` is where provider choice gets made. It supersedes the general "use a capable frontier
model" advice in the root README for anyone specifically choosing between Claude 5-series models.

## The finding (31 October 2026)

Pointed at `claude-sonnet-5-5`, every planning call ARTEX makes (`agent/goals.go`'s goal
decomposition, and the planner's own call) came back from the Anthropic API refused outright:

```json
"stop_reason": "refusal",
"stop_details": {
  "type": "refusal",
  "category": "cyber",
  "explanation": "This request triggered restrictions on violative cyber content and was
  blocked under Anthropic's Usage Policy."
}
```

0 output tokens, in roughly 1-1.5 seconds, reproduced with three different goal texts (one long and
compliance-heavy, one short and plain, one minimal debug one). This is a safety-classifier
reaction to the *shape* of what ARTEX sends — a system prompt framing the model as a
"penetration-test target decomposer" with tool names like `set_goals`, `add_task_scope`,
`set_constraints` — not to the target named in the goal. It happens before any tool call, so
neither target in the test below was ever actually contacted on this model.

**`claude-sonnet-5` has no such issue.** Same prompts, same tool schema, no refusals. A full
dual-target test run (see below) completed normally.

This matters because the root README's own validation (`#use-a-capable-frontier-model`) only ever
tested `claude-opus-4-8` and `gpt-4o`, and reported no refusals on either. Nobody had pointed ARTEX
at a Claude 5-series Sonnet model before 31 October 2026, and the two closest versions (5 and 5.5)
behave differently. **Check this again for any future model, including later Sonnet or Opus
versions** — don't assume one Claude generation's behaviour predicts the next's.

## How to check it yourself

1. Create the LLM profile you want to test (`POST /api/llm/profiles`), make it active.
2. Turn on call recording so a refusal (or anything else unusual) is captured in full:
   `PUT /api/settings {"llm_record": true}` (off by default — it stores complete request/response
   bodies in Postgres, so turn it back off afterwards if you don't want that retained).
3. Create a task with a plain goal naming an authorised, isolated target.
4. If `goals_total` stays at 0 after a couple of planner cycles with no error logged, check
   `GET /api/llm/records` for that task — a refusal shows up there as `"stop_reason":"refusal"`
   with `output_tokens: 0`, distinct from a genuine model/network error.

## The functional security review this unblocked

Once on `claude-sonnet-5`, a dual-target run (an isolated internal OWASP Juice Shop instance, plus
the public `demo.testfire.net` demo app, both explicitly named in the goal with an instruction to
stay off everything else) completed in under five minutes. Both per-target goals were marked met;
8 confirmed findings were produced, each with a verbatim request/response proof-of-concept:

| Target | Severity | Finding |
|---|---|---|
| testfire.net | critical | SQL injection login bypass (`admin'--`) |
| testfire.net | high | Broken access control — another account's transaction history via `showAccount` |
| testfire.net | medium | Reflected XSS in `search.jsp` |
| Juice Shop | critical | SQL injection (`UNION SELECT`) on `/rest/products/search` |
| Juice Shop | critical | SQLi login bypass on `/rest/user/login` |
| Juice Shop | critical | JWT `alg:none` forgery to a forged admin token |
| Juice Shop | medium | Unauthenticated disclosure of `/rest/admin/application-configuration` |
| Juice Shop | low | `/api/Feedbacks` exposes user emails with no auth |

Every proof-of-concept in every finding named only the two authorised hosts. This satisfies this
fork's standing rule (`Design-Reference.md` decision 53/open item 9) that a fork gets a real,
run-for-real functional security review, not just a dependency scan — next due six months out, or
sooner on a triggering event.

**One gap worth knowing, not yet fixed:** the "ask for approval before anything destructive" rule
in the goal text never actually triggered an approval prompt, including for a state-changing write
(a mass-assignment account-creation `POST`) during an earlier single-target pass. No harm was done
— the target was the disposable Juice Shop sandbox — but this is a real gap in ARTEX's own
approval-gating design, not something patched here; it needs its own review before this tool is
pointed at anything less disposable than a sandbox.

**Also not verified here:** real network-level proof of what left the agent container. ARTEX's own
traffic-recording proxy (`:8788`) wasn't wired up for this run (it needs `HTTP_PROXY` and a
trusted CA set on the container — see `start.sh`/`docker-compose.yml`'s own `HTTP_PROXY` note);
what's verified above is the agent's own evidence, not an independent packet capture.
