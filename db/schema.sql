-- FlowOps — Database schema (Contract A)
-- Target: Supabase Postgres (PG15+). Apply in Supabase SQL Editor.
-- Re-runnable: drops + recreates. FROZEN for renames/removals after Day 1 h3 (additive-only after).
-- Order: run schema.sql → rls-policies.sql → seed.sql

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- ── Clean slate (dev; safe because everything below is recreated) ───────────
drop view  if exists v_pending_approvals cascade;
drop view  if exists v_health_latest      cascade;
drop table if exists dsar_requests     cascade;
drop table if exists invoices          cascade;
drop table if exists health_signals     cascade;
drop table if exists entitlements       cascade;
drop table if exists seats              cascade;
drop table if exists idempotency_keys   cascade;
drop table if exists dead_letter_queue  cascade;
drop table if exists audit_log          cascade;
drop table if exists tenant_policies    cascade;
drop table if exists tenants            cascade;
drop function if exists set_updated_at() cascade;

-- ── updated_at auto-touch trigger ───────────────────────────────────────────
create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- tenants — the root entity. Everything is scoped to a tenant_id.
-- ════════════════════════════════════════════════════════════════════════════
create table tenants (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  plan         text not null default 'free'   check (plan   in ('free','pro','enterprise')),
  region       text not null default 'us-east-1',
  status       text not null default 'active' check (status in ('active','suspended','churned')),
  health_score int  not null default 100      check (health_score between 0 and 100),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger trg_tenants_updated before update on tenants
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- tenant_policies — one JSONB policy doc per tenant. Drives retry/approval/
-- entitlement behavior. Read by the resolve-policy sub-workflow at ingress.
-- ════════════════════════════════════════════════════════════════════════════
create table tenant_policies (
  tenant_id  uuid primary key references tenants(id) on delete cascade,
  policy     jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create trigger trg_policies_updated before update on tenant_policies
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- audit_log — every workflow step writes a row here, tagged with correlation_id.
-- The correlation-ID search in the UI is the observability hero feature.
-- status='waiting' rows feed v_pending_approvals (HITL).
-- ════════════════════════════════════════════════════════════════════════════
create table audit_log (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid references tenants(id) on delete cascade,
  correlation_id uuid not null,
  service        text not null,          -- 'onboarding','dunning','sla','incident',...
  step           text not null,          -- workflow step name
  status         text not null check (status in ('started','success','error','skipped','waiting')),
  payload        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);
create index idx_audit_correlation on audit_log(correlation_id);
create index idx_audit_tenant      on audit_log(tenant_id);
create index idx_audit_created     on audit_log(created_at desc);

-- ════════════════════════════════════════════════════════════════════════════
-- dead_letter_queue — failed executions isolated here by the global error
-- workflow. Operator replays from the UI (Contract B).
-- ════════════════════════════════════════════════════════════════════════════
create table dead_letter_queue (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid references tenants(id) on delete set null,
  correlation_id uuid,
  workflow       text not null,
  error          text not null,
  error_class    text,                    -- classification for replay safety (poison detection)
  attempts       int  not null default 0,
  payload        jsonb not null default '{}'::jsonb,
  status         text not null default 'open' check (status in ('open','replayed','manual','resolved')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_dlq_status      on dead_letter_queue(status);
create index idx_dlq_correlation on dead_letter_queue(correlation_id);
create trigger trg_dlq_updated before update on dead_letter_queue
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- idempotency_keys — INSERT ... ON CONFLICT DO NOTHING. key derived from the
-- source event's stable id (Stripe event id, GitHub issue id) — never random.
-- ════════════════════════════════════════════════════════════════════════════
create table idempotency_keys (
  key        text primary key,
  tenant_id  uuid references tenants(id) on delete cascade,
  workflow   text,
  created_at timestamptz not null default now()
);

-- ════════════════════════════════════════════════════════════════════════════
-- seats — identity lifecycle. SCIM-style seat reconciliation.
-- ════════════════════════════════════════════════════════════════════════════
create table seats (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  user_email text not null,
  status     text not null default 'active' check (status in ('active','revoked','pending')),
  last_seen  timestamptz,
  created_at timestamptz not null default now(),
  unique (tenant_id, user_email)
);
create index idx_seats_tenant on seats(tenant_id);

-- ════════════════════════════════════════════════════════════════════════════
-- entitlements — per-tenant feature flags, flipped by billing/dunning.
-- ════════════════════════════════════════════════════════════════════════════
create table entitlements (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  feature    text not null,
  enabled    boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (tenant_id, feature)
);
create index idx_entitlements_tenant on entitlements(tenant_id);
create trigger trg_entitlements_updated before update on entitlements
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- health_signals — time-series health metrics. Views compute deltas / churn risk.
-- ════════════════════════════════════════════════════════════════════════════
create table health_signals (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  metric    text not null,                 -- 'login_frequency','ticket_volume','feature_usage'
  value     numeric not null,
  ts        timestamptz not null default now()
);
create index idx_health_tenant_metric on health_signals(tenant_id, metric, ts desc);

-- ════════════════════════════════════════════════════════════════════════════
-- invoices — billing / reconciliation. stripe_id links to Stripe test-mode.
-- ════════════════════════════════════════════════════════════════════════════
create table invoices (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  stripe_id  text unique,
  status     text not null check (status in ('draft','open','paid','payment_failed','void','uncollectible')),
  amount     numeric(12,2) not null default 0,
  currency   text not null default 'usd',
  attempt    int  not null default 0,       -- dunning retry attempt
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_invoices_tenant on invoices(tenant_id);
create index idx_invoices_status on invoices(status);
create trigger trg_invoices_updated before update on invoices
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- dsar_requests — DSAR / privacy fulfillment (Contract C intake).
-- ════════════════════════════════════════════════════════════════════════════
create table dsar_requests (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid references tenants(id) on delete set null,
  email      text not null,
  type       text not null check (type in ('export','delete')),
  status     text not null default 'received' check (status in ('received','processing','completed','rejected')),
  evidence   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_dsar_tenant on dsar_requests(tenant_id);
create trigger trg_dsar_updated before update on dsar_requests
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════════════════
-- VIEWS
-- ════════════════════════════════════════════════════════════════════════════

-- v_pending_approvals (Contract D) — HITL approvals currently waiting.
-- A 'waiting' audit row is pending until a later row (same correlation_id+step)
-- resolves it (success/error/skipped). security_invoker so RLS of audit_log
-- applies to the caller.
create view v_pending_approvals with (security_invoker = on) as
select a.id            as audit_id,
       a.tenant_id,
       t.name          as tenant_name,
       a.correlation_id,
       a.service,
       a.step,
       a.payload,
       a.created_at
from audit_log a
join tenants t on t.id = a.tenant_id
where a.status = 'waiting'
  and not exists (
    select 1 from audit_log b
    where b.correlation_id = a.correlation_id
      and b.step           = a.step
      and b.status in ('success','error','skipped')
      and b.created_at     > a.created_at
  )
order by a.created_at desc;

-- v_health_latest — latest value per (tenant, metric) + previous value + delta.
-- Powers the health dashboard and churn-risk detection.
create view v_health_latest with (security_invoker = on) as
select distinct on (h.tenant_id, h.metric)
       h.tenant_id,
       t.name as tenant_name,
       h.metric,
       h.value as latest_value,
       lag(h.value) over (partition by h.tenant_id, h.metric order by h.ts) as prev_value,
       h.value - lag(h.value) over (partition by h.tenant_id, h.metric order by h.ts) as delta,
       h.ts as latest_ts
from health_signals h
join tenants t on t.id = h.tenant_id
order by h.tenant_id, h.metric, h.ts desc;
