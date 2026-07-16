# FlowOps — Solo Plan, Task Breakdown & Working Guide

**Project:** FlowOps: Multi-Tenant Customer Operations Control Plane
**Repo:** `flowops-control-plane-on-n8n`

*Working document. Read top to bottom once, then work from Section 6 (the backlog) and Section 3 (the interface seams).*

**Team:** 1 person (solo build). **Repo:** `flowops-control-plane-on-n8n` (GitHub, continuous commits).
**Project:** **FlowOps: Multi-Tenant Customer Operations Control Plane** — zero-cost multi-tenant operations control plane on n8n queue mode (see `FlowOps - Full Plan.md` for the full spec).

> **Changed 2026-07-15:** this project was originally planned as a 2-person build (Lead: automation/backend, Teammate: frontend/observability). It is now a **solo build — one person owns everything**. The interface contracts in `CONTRACTS.md` are kept as internal architecture seams (backend ↔ frontend), not as a people-API. Historical "Lead/Teammate" attributions in the git history and change logs are preserved as-is.

---

## 1. Ownership model

| | **You** — everything |
|---|---|
| Share | 100% |
| Owns | n8n queue-mode infra, DB schema + RLS, all service workflows (1–11), policy engine, saga/compensating actions, HITL, Stripe, correlation-ID propagation, the reliability subsystem (idempotency-check, global error→DLQ handler, DLQ-replay), **and** the Next.js operator UI, Grafana observability, CI/CD, Uptime Kuma, demo video |
| Interview story | "I designed and built the entire platform solo — the orchestration engine, the reliability layer (idempotency + DLQ replay + error handling), every business workflow, the operator UI, and the observability stack" |

**Why this is stronger solo:** the automation architecture remains the star of the portfolio — queue mode, tenant policy resolution, compensating actions, HITL approvals, correlation IDs, the reliability primitives, and every service workflow. Now the operator UI and the observability/CI glue are *also* demonstrably yours. Full-stack ownership of a production-grade control plane is the story.

**Rule unchanged:** git history is part of the portfolio — commits must clearly show the build order (infra → schema → backbone → services → UI → observability).

---

## 2. Repo structure

```
flowops-control-plane-on-n8n/
├── README.md                  # pitch + paid→free table + architecture + UI/obs sections
├── docker-compose.yml         # n8n queue-mode stack
├── .env.example               # all env vars (backend + frontend), no values
├── CODEOWNERS                 # single owner
├── infra/
│   ├── oracle-setup.md
│   └── grafana/               # dashboard JSON
├── db/
│   ├── schema.sql             # ← Contract A (frozen base)
│   ├── rls-policies.sql
│   ├── seed.sql               # unblocks UI work before workflows exist
│   └── *.sql                  # additive per-service tables (incidents, renewals, …)
├── workflows/                 # all exported n8n JSON
├── frontend/                  # Next.js operator UI
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   └── production-topology.md
└── .github/workflows/ci.yml
```

---

## 3. Interface seams (formerly "contracts") — STILL THE MOST IMPORTANT SECTION

Originally these were the API between two people. Solo, they are **architecture seams between the backend and the frontend** — and they still matter for the same reason: they let you build either side without the other running, and they keep the design honest. `CONTRACTS.md` remains the authoritative spec.

### Contract A — Database schema (backend → frontend)
- `db/schema.sql` + `db/seed.sql` applied to Supabase. The UI is built entirely against this seeded database — no workflow needs to be running to develop frontend pages.
- The base schema is **frozen for renames/removals**; additive changes only (new columns/tables), recorded in the repo.
- Tables: `tenants`, `tenant_policies`, `audit_log`, `dead_letter_queue`, `idempotency_keys`, `seats`, `entitlements`, `health_signals`, `invoices`, `dsar_requests`, plus view `v_pending_approvals` (+ additive: `incidents`, `renewal_packages`, `reconciliation_runs`, `compliance_exports`).

### Contract B — DLQ Replay webhook (UI button → n8n)
- **Endpoint:** `POST <N8N_DOMAIN>/webhook/dlq-replay`
- **Request:** `{ "dlq_id": "<uuid>", "operator": "<name>" }`
- **Response:** `{ "status": "queued" | "error", "correlation_id": "<uuid>", "message": "..." }`
- The UI's "Replay" button calls this; the replay workflow re-injects the original trigger with the same correlation_id.

### Contract C — DSAR intake webhook (UI form → n8n)
- **Endpoint:** `POST <N8N_DOMAIN>/webhook/dsar`
- **Request:** `{ "tenant_id": "<uuid>", "email": "<string>", "type": "export" | "delete" }`
- **Response:** `{ "status": "received", "request_id": "<uuid>" }`

### Contract D — Approvals & audit (read-only, workflows' data → UI)
- The UI reads `audit_log` (filter by `correlation_id`) and `v_pending_approvals` directly from Supabase with the **anon key + RLS**.
- HITL workflows keep `v_pending_approvals` populated. The UI never writes these tables.

### Contract E — Metrics endpoint (n8n → Grafana)
- `N8N_METRICS=true` exposes `/metrics` (Prometheus format).
- Grafana Cloud scrapes it (Grafana Agent / remote-write); dashboards: executions, queue depth, error rate, per-service throughput.

### Contract F — Stripe (external) — **DECIDED: real Stripe test mode**
- Free Stripe account, **test mode**, two webhooks pointing at n8n:
  - `checkout.session.completed` → `POST /webhook/stripe-onboarding` (drives Service 1)
  - `invoice.payment_failed` → `POST /webhook/stripe-dunning` (drives Service 3)
- Fire events on demand via Stripe CLI (`stripe trigger invoice.payment_failed`) — no real card, fully reproducible.
- The UI only ever reads the *effects* in Supabase (`tenants`, `invoices`, `entitlements`, `audit_log`) and never touches Stripe. If Stripe is down during the demo, a manual webhook curl produces identical rows.

### Contract G — Reliability primitives
- **G1 — Global error → DLQ handler:** set as n8n's global error workflow; writes `dead_letter_queue` rows with `correlation_id`, payload, error class, attempt count; fires a Telegram alert. Service workflows "fail normally" and trust the handler. *(Shipped: `04-global-error-handler.json` + `bump_dlq` RPC.)*
- **G2 — `idempotency-check` sub-workflow:** called at ingress of every service workflow (Execute Workflow node or `POST /webhook/idempotency-check`). Input `{key, tenant_id}` → output `{dup}` via atomic `INSERT … ON CONFLICT DO NOTHING`. *(Shipped: `02-idempotency-check.json`.)*

> **Freeze discipline still applies** — even solo. If a seam must change, the change is a commit that updates `CONTRACTS.md` — never a silent drift. Future-you (and interview reviewers reading the repo) are the other party now.

---

## 4. Git workflow (solo)

- **Branching:** short-lived feature branches off `main`, e.g. `lead/workflow-onboarding`, `lead/db-schema`, `fe/dlq-table`, `obs/grafana`. (The `lead/` prefix is kept for continuity with the existing history.)
- **`main`:** merge via `--no-ff` so each feature is a visible unit in history. PR-to-self is optional; direct merge after a self-review pass is fine. CI must pass before merge.
- **Commit convention** (Conventional Commits):
  - `feat(workflow): onboarding provisioning with telegram HITL`
  - `feat(db): tenant RLS policies`
  - `feat(fe): DLQ table with replay button`
  - `fix(worker): idempotency race on duplicate webhook`
  - `docs: paid→free mapping table`
- **Commit cadence:** every working checkpoint (~30–45 min). A rich, steady history is itself portfolio evidence.
- **n8n workflow versioning:** export each workflow to `workflows/NN-name.json` after every meaningful change and commit it. This is how the automation work becomes reviewable in the repo.

---

## 5. Sequential timeline with checkpoints

Solo, the two parallel tracks become one sequence. The checkpoints stay — they're now self-imposed go/no-go gates.

### Phase 1 — Foundation
| Step | Work | Gate |
|---|---|---|
| 1 | Repo, Supabase project, Telegram bot, `.env` (not committed) | |
| 2 | n8n queue mode up (main/webhook/2 workers/redis; local: ngrok, prod: Caddy HTTPS) | |
| 3 | `schema.sql` + `rls-policies.sql` + `seed.sql` applied to Supabase | 🔴 **GATE 1:** schema frozen — additive-only after this |
| 4 | Backbone: `00-resolve-policy`, `01-write-audit`, `02-idempotency-check` (G2), `04-global-error-handler` (G1) | |
| 5 | **Service 1 Onboarding end-to-end** with Telegram HITL (the reference pattern) | 🔴 **GATE 2 (go/no-go):** pattern proven + idempotency reliable? If not, fix before scaling to more services |

### Phase 2 — Services
| Step | Work |
|---|---|
| 6 | Showcase five first: 3 Dunning, 4 SLA, 5 Incident, 9 Replay (Contract B), then 2 Identity, 6 Health, 7 Renewal, 8 DSAR (Contract C), 10 Reconciliation, 11 Compliance |
| 7 | Test every service end-to-end (webhook → effects → audit trail → idempotency → replay) |

### Phase 3 — Frontend
| Step | Work |
|---|---|
| 8 | Scaffold Next.js, deploy to Vercel, Supabase client (anon key, RLS-aware) |
| 9 | Pages off seed + live data: tenants list, audit trail with **correlation-ID search**, DLQ table + Replay button (Contract B), pending approvals, health dashboard, DSAR form (Contract C) |
| 10 | 🔴 **GATE 3:** frontend ↔ backend integrated end-to-end (Replay + DSAR live) |

### Phase 4 — Observability, polish, ship
| Step | Work |
|---|---|
| 11 | `N8N_METRICS=true` → Grafana Cloud dashboards; Uptime Kuma → Service 5 |
| 12 | GitHub Actions CI (validate workflow JSON, lint frontend, smoke test) |
| 13 | Harden the demo path; export all workflows; `architecture.md` + `production-topology.md` + runbook |
| 14 | README (pitch + paid→free table + arch + UI/obs sections) |
| 15 | Record 3-min demo (script below), two rehearsals, tag `v1.0` | 🔴 **GATE 4:** ship |

### Fallback (if time pressure hits)
Ship the **showcase five** fully — **1 Onboarding, 3 Dunning, 4 SLA escalation, 5 Incident comms, 9 Replay** — and mark the rest "documented + stubbed" in the README. Cut breadth, never cut the queue-mode/HITL/DLQ core.

---

## 6. Detailed backlog (single owner — everything below is yours)

**Infra**
- [ ] Oracle ARM VM (Ubuntu, Docker, ports, Caddy HTTPS) — *local dev stack with ngrok already running*
- [x] `docker-compose.yml`: n8n main + webhook + 2 workers + Redis, `EXECUTIONS_MODE=queue`
- [x] `N8N_METRICS=true` (Contract E)
- [ ] Demonstrate scaling: `docker compose up --scale n8n-worker=3`

**Database**
- [x] `schema.sql` (all 10 tables + `v_pending_approvals`)
- [x] `rls-policies.sql` (RLS on every `tenant_id` table)
- [x] `seed.sql` (fake tenants/audit/DLQ/health)
- [x] Additive: `dlq-bump.sql`, `incidents.sql`, `renewals.sql`, `ops-reporting.sql`

**Backbone workflows**
- [x] `00-resolve-policy` (tenant_id → policy JSON)
- [x] `01-write-audit` (writes row with shared `correlation_id`)
- [x] `02-idempotency-check` (Contract G2) — atomic `INSERT … ON CONFLICT DO NOTHING`
- [x] `04-global-error-handler` (Contract G1) → `bump_dlq` RPC + Telegram alert
- [ ] `telegram-approve` extracted as reusable sub-workflow (currently inline in 03/07) — deferred

**Reliability (Contract G + Contract B)**
- [x] `05-dlq-replay`: CAS claim, registry, re-injection with original correlation_id, poison/cap parking, re-fail bump
- [x] Demo loop verified: force failure → DLQ isolation → Replay → success

**Stripe (Contract F)**
- [ ] Free Stripe account, test mode; install Stripe CLI
- [ ] Register the two webhooks; verify signature; `stripe trigger` reproducibly
- *(Manual curl fallback already proven for all services)*

**Service workflows (all 11)**
- [x] 1 Onboarding · 3 Dunning · 4 SLA escalation · 5 Incident comms · 9 Replay
- [x] 2 Identity · 6 Health · 7 Renewal · 8 DSAR · 10 Reconciliation · 11 Compliance
- [x] Export every workflow to `workflows/NN-*.json` and commit

**Frontend (Next.js on Vercel)**
- [ ] Scaffold + deploy to Vercel + Supabase client (anon key, RLS-aware)
- [ ] Tenants list page
- [ ] Audit trail view with **correlation-ID search** (the observability hero feature)
- [ ] DLQ table + **Replay button** → Contract B
- [ ] Pending-approvals view (reads `v_pending_approvals`)
- [ ] Health-scores dashboard
- [ ] DSAR intake form → Contract C
- *(See `FlowOps - Teammate Frontend Guide.md` — now the solo frontend guide — for the page-by-page build path.)*

**Observability**
- [ ] Grafana Cloud account, scrape n8n `/metrics` (Contract E)
- [ ] Dashboard: executions, queue depth, error rate, per-service throughput
- [ ] Uptime Kuma on the VM → webhook feeds Service 5

**CI/CD & docs**
- [ ] `.github/workflows/ci.yml`: validate workflow JSON, lint frontend, smoke test
- [ ] README UI + observability sections; architecture diagram polish
- [ ] `architecture.md`, `production-topology.md`, runbook
- [ ] Record + edit the 3-min demo

---

## 7. Definition of Done (per component) — unchanged

- **A workflow is done when:** it resolves tenant policy, writes audit rows with a `correlation_id`, is idempotent on replayed input, routes failures to DLQ, and is exported to `/workflows` + committed.
- **A UI page is done when:** it reads live Supabase data, handles empty/error states, is deployed to Vercel, and (if it triggers automation) successfully calls the real webhook contract.
- **Observability is done when:** Grafana shows live n8n metrics and you can trace one `correlation_id` from Telegram → execution → audit row → dashboard.

---

## 8. 3-minute demo script (solo)

| Time | Content |
|---|---|
| 0:30 | Problem: multi-tenant ops chaos. One vivid sentence. |
| 0:30 | Solution: n8n queue-mode control plane; name the architecture. |
| 1:00 | Live: trigger onboarding → Telegram approval → approve → tenant provisioned → audit row appears in UI. Then force a failure → it lands in DLQ → click **Replay** → succeeds. |
| 0:20 | Architecture diagram + Grafana dashboard (queue depth, correlation-ID trace). |
| 0:20 | Impact + the paid→free table ("enterprise architecture at $0"). |
| 0:20 | What I'd scale next (K8s HPA, multi-region). |

Record a **backup screen capture** before any live showing — if a live call fails, switch to the recording without apology.

---

## 9. Golden rules (solo edition)

1. **Seams before code.** The contracts in Section 3 / `CONTRACTS.md` stay frozen; changes are commits, never silent drift.
2. **Commit every 30–45 min.** Steady history = portfolio evidence.
3. **Never block yourself.** The UI works off `seed.sql`; workflows work off webhook contracts. Build either side independently.
4. **Cut breadth, never the core.** Queue mode + HITL + DLQ + RLS + correlation IDs are non-negotiable; extra services are.
5. **Frontend uses the anon key + RLS, always.** The service key never ships to a browser — this is itself an interview talking point.

---

## 10. Secrets & environment map

Nothing secret is committed. One private `.env` + platform secret stores.

| Secret / var | Held where | Used by |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` | n8n env (`.env` → compose) | workflows (service key, bypasses RLS) |
| `SUPABASE_ANON_KEY` | Vercel env | frontend (RLS enforced) |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | n8n env | HITL + alerts |
| `TELEGRAM_ESCALATION_CHAT_ID`, `FLOWOPS_SECOND_APPROVER`, `APPROVAL_*_MINUTES` | n8n env | approval reminders + second-approver escalation |
| `STRIPE_SECRET_KEY` (test), `STRIPE_WEBHOOK_SECRET` | n8n credentials | Services 1 & 3 |
| `GITHUB_TOKEN` (issues API) | n8n env | Service 4 |
| `GRAFANA_CLOUD_*` | Grafana Agent on VM | observability |
| `N8N_ENCRYPTION_KEY` | VM `.env` (never rotate mid-project) | n8n |

- Commit a `.env.example` with **keys but no values**.
- `.env`, `.env.local`, `*.local` in `.gitignore` before the first commit.

---

## 11. Risk register (solo edition)

| Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|
| Oracle ARM VM provisioning fails / capacity error | Med | Blocks prod deploy | Try a different region/AD; Railway/Fly trial as documented backup. Local ngrok stack already works for dev/demo. |
| Queue mode misconfig (workers not picking up jobs) | Low (proven) | Core feature broken | Already verified locally. Re-verify with a trivial workflow after any infra change. |
| Schema change after UI pages are built | Med | Frontend rework | **Base schema frozen; additive-only.** Same discipline as before — the seam protects future-you now. |
| Stripe webhook signature / tunnel issues | Low-Med | Services 1 & 3 | Manual `curl` fallback producing identical rows (proven for all services). |
| Telegram HITL Wait node doesn't resume | Low (proven) | HITL demo | Resume loop verified end-to-end (approve + reject). Screen recording as backup. |
| **Solo bandwidth: UI + observability + polish all on one plate** | **High** | Half-done everything | The fallback gate (Section 5) exists for exactly this. Showcase-five + working UI beats eleven services + no UI. Automation depth > UI polish. |
| **No second pair of eyes** | Med | Bugs ship unreviewed | Self-review discipline: expert-review pass per service (already done for 2, 4–11), test every path live before merging, CI validation on every PR. |
| Scope creep past showcase-five | High | Everything half-done | GATE 2 go/no-go; cut to five services if the backbone wobbles. |
| Time lost to "perfect" UI polish | Med | Automation under-built | Automation is the star; UI needs to look production-grade, not pixel-perfect. |

---

## 12. Making the portfolio unmistakably remarkable (solo)

All eight evidence items are now yours to produce **and** narrate:

1. **Queue mode, not single mode.** Main + webhook + workers + Redis; `--scale` workers live on camera.
2. **A real policy engine.** `tenant_policies` JSONB driving different retry/approval/entitlement behavior per tenant — not hardcoded branches.
3. **Idempotency you can prove.** Fire the same webhook twice on camera → one effect. You own the key-derivation design AND the mechanics.
4. **Compensating actions.** When multi-step provisioning fails midway, show the rollback. Saga pattern in n8n = standout.
5. **DLQ + operator replay — the full loop.** Force a failure → global error handler isolates it in the DLQ → click Replay in **your** UI → **your** re-processing workflow resumes with the same correlation ID. Every piece is yours now.
6. **Correlation ID end-to-end.** One ID traceable across Telegram message → n8n execution → audit row → Grafana.
7. **HITL with escalation.** Approval → reminder → escalate on SLA breach.
8. **Clean git history.** Commits tell the story: infra → schema → backbone → services → UI → observability.

**In the demo, narrate items 3, 5, and 7 personally** — those are the moments that make a hiring manager believe you can own production automation.

---

## 13. Pre-decided architecture choices (unchanged — do not re-debate mid-build)

- **Billing:** Stripe test mode (Contract F). ✅ decided.
- **Correlation ID:** generated at the ingress node of every workflow (`{{ $execution.id }}` + a UUID), passed to every sub-workflow call and written to every audit/DLQ row.
- **Idempotency key:** derived from the source event's stable ID (Stripe event id, GitHub issue id, etc.), never random — retries dedupe correctly. Derived keys for recurring scans carry a day bucket.
- **Policy storage:** one JSONB column `tenant_policies.policy`, resolved by `00-resolve-policy` at the start of every service workflow.
- **Tenant isolation:** Postgres RLS on `tenant_id`; frontend uses the anon key so RLS is actually exercised.
- **Error handling:** one global n8n error workflow → DLQ table + Telegram alert; service workflows fail normally and trust the handler.
- **Replay:** operator-driven DLQ redrive with CAS claim, poison detection, and attempt caps.
- **Retries:** policy-driven (max attempts + backoff from `tenant_policies`), not node-default retries.
- **Time source for SLAs:** DB `now()` in Postgres, not n8n node time.

If a decision here turns out wrong mid-build, change it in ONE place and commit an update to this file.
