# FlowOps — Multi-Tenant Customer Operations Control Plane

> A self-hosted, multi-tenant customer-operations control plane built on **n8n in queue mode**. It ingests lifecycle events from CRM, billing, support, identity, and incident systems, resolves each tenant's policy, orchestrates downstream APIs with idempotency and compensating actions, supports human-in-the-loop approvals, and gives operators full audit trails plus one-click DLQ replay — all running at zero infrastructure cost.

**Portfolio target:** Automation Expert role. Built to be grilled on in an interview.

---

## Why this exists

A zero-cost, open-source reimplementation of an enterprise customer-ops platform. Same 11 services, same core functionalities (multi-tenant policy resolution, HITL approvals, idempotency, replay/DLQ, audit trails, correlation IDs, observability) — every enterprise/paid dependency swapped for a free open-source equivalent.

## The magic trick: paid → free mapping

| Enterprise (paid) | Free equivalent | Why it's valid |
|---|---|---|
| Kubernetes queue mode | **n8n queue mode** (main + webhook + workers + Redis) on Oracle ARM VM | Same architecture & reliability semantics |
| EventBridge/SQS + DLQ | **Redis** (n8n's queue) + Postgres `dead_letter_queue` | Real durable queue + real DLQ isolation |
| Stripe | **Stripe test mode** (free forever) | Full API + webhooks, no cost |
| Okta/Entra (IdP) | **Authentik** (OSS) or mock SCIM | Real OIDC/SCIM endpoints |
| Zendesk/Intercom | **GitHub Issues** as ticket system | Tickets, priorities, ages, webhooks |
| PagerDuty | **Uptime Kuma** (OSS) | Fires real incident webhooks |
| Snowflake/warehouse | **Supabase Postgres** + SQL views | Real warehouse-style queries |
| Slack (notify + approvals) | **Telegram Bot** with inline buttons | Full HITL: wait states, reminders, escalation |
| Aurora Global + RLS | **Supabase Postgres + Row-Level Security** | Identical tenant-isolation mechanism |
| Prometheus/Grafana/Loki | **n8n metrics** + **Grafana Cloud free** | Real metrics, logs, dashboards |

## Architecture

```
                    ┌─────────────────────────────────────────────┐
   External events  │              ORACLE ARM VM (free)            │
   (webhooks)       │  ┌──────────┐   ┌───────┐   ┌────────────┐   │
  GitHub Issues ───▶│  │ n8n      │──▶│ Redis │──▶│ n8n workers│   │
  Stripe test   ───▶│  │ webhook  │   │ queue │   │  (x2)      │   │
  Uptime Kuma   ───▶│  │ pod      │   └───────┘   └─────┬──────┘   │
  Telegram      ───▶│  └────┬─────┘                     │          │
                    │       └──────────┬────────────────┘          │
                    │                  ▼                           │
                    │            ┌───────────┐   DLQ table         │
                    │            │  policy   │   audit_log         │
                    └────────────┤  engine   ├─────────────────────┘
                                 └─────┬─────┘
                    correlation_id flows through every step
        ┌──────────────────────────────┼───────────────────────────┐
        ▼                              ▼                            ▼
  ┌──────────┐              ┌─────────────────────┐          ┌────────────┐
  │ Supabase │◀── RLS ─────▶│ Next.js control UI  │          │  Telegram  │
  │ Postgres │   tenant_id  │ (Vercel, free)      │          │  HITL bot  │
  └──────────┘              └─────────────────────┘          └────────────┘
```

<!-- UI + observability sections to be added below as the frontend and Grafana stack land (solo build — same author). -->

---

## Status

🚧 Under construction — solo build (originally planned as a 2-person project; single-owner as of 2026-07-15). All 11 service workflows + backbone + reliability layer + approval reminder/escalation cron shipped; frontend + observability next. See `FlowOps - Full Plan.md` and `FlowOps - Team Plan & Task Division.md` (the solo plan) for the build plan.
