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

## Environment

The stack passes these into the n8n containers (see `docker-compose.yml` env block); set real
values in `../.env`:

| Var | Used for |
|---|---|
| `SUPABASE_URL` | PostgREST base (`$env.SUPABASE_URL/rest/v1/...`) |
| `SUPABASE_SERVICE_KEY` | `apikey` + `Authorization: Bearer` on every DB call |
| `N8N_DOMAIN` | n8n's own public URL (= ngrok / `WEBHOOK_URL`); used to call `/webhook/idempotency-check` |
| `TELEGRAM_CHAT_ID` | approver / CSM chat for HITL + notifications |

No Supabase n8n *credential* is needed — auth is via `$env` headers.

## Credentials to create in n8n (once)

- **`telegramBot`** (type *Telegram API*) — bot token from `@BotFather`. The two Telegram nodes in
  `03` reference it by name; n8n prompts to map on import.

## Import order

1. Import `00-resolve-policy.json`, then `01-write-audit.json`, then `02-idempotency-check.json`,
   then `03-onboarding.json`.
2. **Activate `00`, `01`, and `02`.** All three are called by `03` as **Execute Workflow**
   nodes, and current `n8nio/n8n` refuses to run an inactive called workflow
   ("Workflow is not active and cannot be executed"). `02` additionally exposes
   `POST /webhook/idempotency-check`, which likewise only serves while active.
3. In `03`, open the five **Execute Workflow** nodes (`Idempotency Check`, `Resolve Policy`,
   `Audit: *`) and confirm they point at the imported `00` / `01` / `02` (n8n may need a
   re-select — the stable workflow ids `a10b0000-…0001/0002/0004` help it auto-link).
4. Map the `telegramBot` credential on the two Telegram nodes.
5. **Activate** `03-onboarding` (last, after its four called sub-workflows are active).

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
- DLQ-replay re-processing (Teammate owns `/webhook/dlq-replay`), DSAR (Contract C), Services 2–11.
