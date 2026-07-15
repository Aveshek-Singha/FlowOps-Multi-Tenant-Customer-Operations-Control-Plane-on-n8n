# FlowOps Workflows — Contract B (backbone + Service 1 Onboarding)

Lead-owned n8n automation. Exported workflow JSON, importable into the queue-mode stack
(`../docker-compose.yml`). Data lives in **Supabase** (Contract A schema); n8n reaches it over
**PostgREST** with the service-role key (RLS bypassed on the Lead side).

| File | Kind | Purpose |
|---|---|---|
| `00-resolve-policy.json` | backbone sub-workflow | `{tenant_id, correlation_id}` → tenant row + JSONB policy (retry / approval / entitlements), with defaults. |
| `01-write-audit.json` | backbone sub-workflow | `{tenant_id, correlation_id, service, step, status, payload}` → inserts an `audit_log` row. |
| `02-idempotency-check.json` | backbone sub-workflow | `{key, tenant_id}` → `{dup}` via atomic `INSERT … ON CONFLICT DO NOTHING` on `idempotency_keys` (Contract G2). Callable as an Execute Workflow node **or** `POST /webhook/idempotency-check`. |
| `03-onboarding.json` | Service 1 | `checkout.session.completed` (or manual) → idempotency → provision tenant/seat → **Telegram HITL approval** → entitlements → audit. |
| `04-global-error-handler.json` | reliability | Global error workflow → `bump_dlq` RPC → Telegram failure alert. |
| `05-dlq-replay.json` | Service 9 / Contract B | `POST /webhook/dlq-replay` → claim DLQ row → re-inject original trigger into the source workflow with the same correlation id. |
| `06-billing-dunning.json` | Service 3 | `invoice.payment_failed` (or manual) → idempotency → invoice upsert → retry/escalation policy → health impact → Telegram. |
| `07-support-sla-escalation.json` | Service 4 | GitHub Issue SLA breach scan/manual payload → idempotency → tenant policy → Telegram HITL escalation → GitHub comment + audit. |
| `08-incident-comms.json` | Service 5 | Uptime Kuma/manual incident webhook → idempotency → incident row → impacted-tenant segmentation → Telegram broadcast + audit. |
| `09-health-churn-risk.json` | Service 6 | Cron/manual scan over Supabase health signals → churn-risk classification → playbook routing → Telegram + audit. |
| `10-renewal-expansion.json` | Service 7 | Cron/manual renewal run → candidate selection → renewal package artifact → outreach scheduling audit. |
| `11-dsar-privacy.json` | Service 8 / Contract C | `POST /webhook/dsar` → idempotency → DSAR evidence package or suppression action → `dsar_requests` + audit. |

## Environment

The stack passes these into the n8n containers (see `docker-compose.yml` env block); set real
values in `../.env`:

| Var | Used for |
|---|---|
| `SUPABASE_URL` | PostgREST base (`$env.SUPABASE_URL/rest/v1/...`) |
| `SUPABASE_SERVICE_KEY` | `apikey` + `Authorization: Bearer` on every DB call |
| `N8N_DOMAIN` | n8n's own public URL (= ngrok / `WEBHOOK_URL`); used to call `/webhook/idempotency-check` |
| `TELEGRAM_CHAT_ID` | approver / CSM chat for HITL + notifications |
| `TELEGRAM_BOT_TOKEN` | non-throwing Telegram alerts from Code nodes (global error, dunning, incident comms) |
| `GITHUB_TOKEN` | GitHub Issues API for Service 4 scans/comments |
| `GITHUB_REPO` | `owner/repo` scanned by Service 4 cron path |
| `GITHUB_SLA_LABEL` | issue label scanned for SLA breaches (default `sla-watch`) |
| `GITHUB_SLA_HOURS` | minimum open age for Service 4 breach detection (default `48`) |
| `HEALTH_RISK_THRESHOLD` | Service 6 watch threshold for tenant `health_score` (default `70`) |
| `RENEWAL_WINDOW_DAYS` | Service 7 renewal lookahead window (default `45`) |

No Supabase n8n *credential* is needed — auth is via `$env` headers.

## Credentials to create in n8n (once)

- **`telegramBot`** (type *Telegram API*) — bot token from `@BotFather`. The two Telegram nodes in
  `03` reference it by name; n8n prompts to map on import.

## Import order

1. Run additive SQL after the frozen base schema: `../db/dlq-bump.sql`, `../db/incidents.sql`, and `../db/renewals.sql`.
2. Import `00-resolve-policy.json`, then `01-write-audit.json`, then `02-idempotency-check.json`,
   then `03-onboarding.json`, `04-global-error-handler.json`, `05-dlq-replay.json`,
   `06-billing-dunning.json`, `07-support-sla-escalation.json`, `08-incident-comms.json`,
   `09-health-churn-risk.json`, `10-renewal-expansion.json`, and `11-dsar-privacy.json`.
3. **Activate `00`, `01`, and `02`.** All three are called by service workflows as **Execute Workflow**
   nodes, and current `n8nio/n8n` refuses to run an inactive called workflow
   ("Workflow is not active and cannot be executed"). `02` additionally exposes
   `POST /webhook/idempotency-check`, which likewise only serves while active.
4. In service workflows, open the **Execute Workflow** nodes (`Idempotency Check`, `Resolve Policy`,
   `Audit: *`) and confirm they point at the imported `00` / `01` / `02` (n8n may need a
   re-select — the stable workflow ids `a10b0000-…0001/0002/0004` help it auto-link).
5. Map the `telegramBot` credential on Telegram nodes in `03` and `07`.
6. **Activate** `03`, `05`, `06`, `07`, `08`, `09`, `10`, and `11` after their called sub-workflows are active.

## Verify end-to-end

Happy path (no approval — amount under policy threshold):
```bash
curl -XPOST "$N8N_DOMAIN/webhook/stripe-onboarding" \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"11111111-1111-1111-1111-111111111111","email":"ops@acme.com","plan":"enterprise","amount_usd":0,"event_id":"evt_demo_1"}'
```
Expect `{"status":"queued","correlation_id":"..."}`; then a tenant upsert, a seat, entitlements, and
an `onboarding` audit trace searchable by that `correlation_id`.

HITL path (amount over `policy.approval.required_over_usd`):
```bash
curl -XPOST "$N8N_DOMAIN/webhook/stripe-onboarding" \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"11111111-1111-1111-1111-111111111111","email":"ops@acme.com","plan":"enterprise","amount_usd":15000,"event_id":"evt_demo_2"}'
```
A Telegram message with **Approve / Reject** buttons arrives. Tap **Approve** → entitlements granted
+ `success` audit row. Tap **Reject** → `skipped` audit row, no entitlements.

Idempotency: replay either call with the **same `event_id`** → the second run is deduped (one effect).

Service 4 SLA escalation (manual payload; GitHub token is only needed for the optional comment):
```bash
curl -XPOST "$N8N_DOMAIN/webhook/support-sla" \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"33333333-3333-3333-3333-333333333333","repo":"demo/support","issue_number":42,"title":"Enterprise customer blocked","priority":"P1","age_h":52,"event_id":"issue_42_sla"}'
```
Expect `{"status":"queued","correlation_id":"..."}` plus a `sla/approve-escalation` waiting row in
`v_pending_approvals`. Approve from Telegram to write the success audit row.

Service 5 incident comms (manual Uptime Kuma-style payload):
```bash
curl -XPOST "$N8N_DOMAIN/webhook/uptime-kuma-incident" \
  -H 'content-type: application/json' \
  -d '{"monitor_id":"api-gw","monitor_name":"API Gateway","status":"down","severity":"critical","region":"us-east-1","event_id":"hb_api_gw_down_1"}'
```
Expect an `incidents` row, impacted active tenants segmented by region in `postmortem`, and an
`incident/segment-tenants` audit row.

Service 6 health/churn scan:
```bash
curl -XPOST "$N8N_DOMAIN/webhook/health-risk" \
  -H 'content-type: application/json' \
  -d '{"event_id":"health_demo_1","threshold":70}'
```
Expect `{"status":"queued","correlation_id":"..."}` plus `health/scan-risk` and
`health/route-playbook` audit rows summarizing at-risk tenants.

Service 7 renewal package generation:
```bash
curl -XPOST "$N8N_DOMAIN/webhook/renewal-expansion" \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"11111111-1111-1111-1111-111111111111","event_id":"renewal_acme_demo_1","force":true}'
```
Expect `{"status":"queued","correlation_id":"..."}`, a `renewal_packages` row, and
`renewal/build-package` + `renewal/schedule-outreach` audit rows.

Service 8 DSAR/privacy fulfillment:
```bash
curl -XPOST "$N8N_DOMAIN/webhook/dsar" \
  -H 'content-type: application/json' \
  -d '{"tenant_id":"11111111-1111-1111-1111-111111111111","email":"ops@acme.com","type":"export","event_id":"dsar_acme_export_1"}'
```
Expect `{"status":"received","request_id":"..."}`, a `dsar_requests` row with `status='completed'`,
and `dsar/intake` + `dsar/fulfill` audit rows. For `"type":"delete"`, the workflow performs a
demo-safe suppression by disabling matching seats while retaining audit/financial records as evidence.

## Design notes

- **Correlation ID** (Lead-owned): a uuid v4 generated at ingress (the `audit_log.correlation_id`
  column is `uuid`), propagated to every sub-workflow call and audit row. `$execution.id` is logged
  in the payload.
- **Idempotency** (Contract G2, now Lead-owned): the key is derived from the stable source
  event id (`onboarding:<event_id>` or `onboarding:<tenant_id>:<email>`, never random). The
  endpoint ships as **`02-idempotency-check`**, doing an atomic `INSERT … ON CONFLICT DO
  NOTHING` on `idempotency_keys`. `03` calls it **in-process** as an Execute Workflow node
  (`Idempotency Check` → `02`), so there is no `N8N_DOMAIN` / HTTP hop and no racy fallback.
  `02` is *also* reachable at `POST /webhook/idempotency-check` for out-of-process callers.
- **HITL**: Wait node (`resume: webhook`) exposes `$execution.resumeUrl`; the Telegram message's two
  URL buttons append `?decision=approve|reject`. Wait + Telegram live in the same execution, as n8n
  requires for `resumeUrl`.

## Known import caveats (hand-authored JSON)

- Node sub-properties (Telegram `reply_markup`, Wait resume options, IF operator shapes) target
  current n8n. On a newer `n8nio/n8n:latest` a field may need a one-click touch-up in the editor.
- The HITL `reply_markup` expression + `$execution.resumeUrl` is the single most version-sensitive
  spot — verify the buttons render and point at the resume URL before demoing.

## Deferred (not in Contract B)

- `telegram-approve` extracted as its own reusable sub-workflow (currently inline in `03`).
- Approval **reminder cron** + **SLA escalation** to a second approver.
- Stripe **signature verification** on the webhook.
- Services 2, 10, 11.
