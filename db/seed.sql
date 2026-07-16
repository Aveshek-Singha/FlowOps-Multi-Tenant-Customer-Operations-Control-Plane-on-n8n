-- FlowOps — Seed data (Contract A)
-- Run AFTER schema.sql + rls-policies.sql. Re-runnable (truncates first).
-- Deterministic fixed UUIDs so the demo is reproducible and relations are stable.
-- Gives the operator UI data on every page without any workflow running.
-- NOTE: seed runs via the SQL editor (service role) → bypasses RLS, so inserts
-- are not blocked by the anon policies.

truncate table
  dsar_requests, invoices, health_signals, entitlements, seats,
  idempotency_keys, dead_letter_queue, audit_log, tenant_policies, tenants
  restart identity cascade;

-- ── tenants (6) ─────────────────────────────────────────────────────────────
insert into tenants (id, name, plan, region, status, health_score, created_at) values
 ('11111111-1111-1111-1111-111111111111','Acme Corp',        'enterprise','us-east-1','active',   92, now() - interval '120 days'),
 ('22222222-2222-2222-2222-222222222222','Globex Inc',       'pro',       'eu-west-1','active',   68, now() - interval '90 days'),
 ('33333333-3333-3333-3333-333333333333','Initech',          'pro',       'us-east-1','active',   41, now() - interval '75 days'),
 ('44444444-4444-4444-4444-444444444444','Umbrella LLC',     'enterprise','ap-south-1','suspended',23, now() - interval '200 days'),
 ('55555555-5555-5555-5555-555555555555','Hooli',            'free',      'us-west-2','active',   85, now() - interval '30 days'),
 ('66666666-6666-6666-6666-666666666666','Stark Industries', 'enterprise','us-east-1','churned',  12, now() - interval '365 days');

-- ── tenant_policies (JSONB drives retry/approval/entitlement per tenant) ─────
insert into tenant_policies (tenant_id, policy) values
 ('11111111-1111-1111-1111-111111111111','{"retry":{"max_attempts":5,"backoff":"exponential"},"approval":{"required_over_usd":10000,"approver":"csm-lead","second_approver":"ops-lead"},"entitlements":{"sso":true,"api":true}}'),
 ('22222222-2222-2222-2222-222222222222','{"retry":{"max_attempts":3,"backoff":"linear"},"approval":{"required_over_usd":5000,"approver":"csm","second_approver":"csm-lead"},"entitlements":{"sso":true,"api":false}}'),
 ('33333333-3333-3333-3333-333333333333','{"retry":{"max_attempts":3,"backoff":"linear"},"approval":{"required_over_usd":5000,"approver":"csm","second_approver":"csm-lead"},"entitlements":{"sso":false,"api":false}}'),
 ('44444444-4444-4444-4444-444444444444','{"retry":{"max_attempts":5,"backoff":"exponential"},"approval":{"required_over_usd":10000,"approver":"csm-lead","second_approver":"ops-lead"},"entitlements":{"sso":true,"api":true}}'),
 ('55555555-5555-5555-5555-555555555555','{"retry":{"max_attempts":1,"backoff":"none"},"approval":{"required_over_usd":1000,"approver":"csm","second_approver":"csm-lead"},"entitlements":{"sso":false,"api":false}}'),
 ('66666666-6666-6666-6666-666666666666','{"retry":{"max_attempts":3,"backoff":"linear"},"approval":{"required_over_usd":10000,"approver":"csm-lead","second_approver":"ops-lead"},"entitlements":{"sso":true,"api":true}}');

-- ── audit_log — correlation-ID traces. Two 'waiting' rows feed pending approvals.
insert into audit_log (tenant_id, correlation_id, service, step, status, payload, created_at) values
 -- Acme onboarding trace (complete)
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','onboarding','ingest',          'started','{"source":"stripe"}',       now() - interval '2 hours'),
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','onboarding','resolve-policy',  'success','{"plan":"enterprise"}',     now() - interval '2 hours'),
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','onboarding','create-workspace','success','{"workspace":"acme"}',      now() - interval '119 minutes'),
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','onboarding','notify-csm',      'success','{"channel":"telegram"}',    now() - interval '118 minutes'),
 -- Globex dunning trace with a HITL approval currently WAITING
 ('22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000002','dunning','ingest',            'started','{"invoice":"in_globex_01"}', now() - interval '40 minutes'),
 ('22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000002','dunning','resolve-policy',    'success','{"max_attempts":3}',        now() - interval '39 minutes'),
 ('22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000002','dunning','approve-writeoff',  'waiting','{"amount_usd":6200,"approver":"csm","second_approver":"csm-lead"}',        now() - interval '38 minutes'),
 -- Initech SLA escalation with a HITL approval currently WAITING
 ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000003','sla','scan-breach',          'success','{"issue":42,"age_h":52}',    now() - interval '20 minutes'),
 ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000003','sla','approve-escalation',   'waiting','{"priority":"P1","approver":"csm","second_approver":"csm-lead"}',          now() - interval '18 minutes'),
 -- Initech incident trace that errored (this one lands in DLQ below)
 ('33333333-3333-3333-3333-333333333333','dddddddd-0000-0000-0000-000000000004','incident','segment-tenants', 'error','{"reason":"api timeout"}',    now() - interval '10 minutes');

-- ── dead_letter_queue — failed executions for the DLQ table + Replay button ──
insert into dead_letter_queue (tenant_id, correlation_id, workflow, error, error_class, attempts, payload, status, created_at) values
 ('33333333-3333-3333-3333-333333333333','dddddddd-0000-0000-0000-000000000004','05-incident-comms','ETIMEDOUT calling status API','transient',2,'{"monitor":"api-gw","impacted":true}','open',   now() - interval '9 minutes'),
 ('22222222-2222-2222-2222-222222222222','eeeeeeee-0000-0000-0000-000000000005','03-billing-dunning','Stripe 500 on retry',        'transient',1,'{"invoice":"in_globex_02"}',           'open',   now() - interval '25 minutes'),
 ('44444444-4444-4444-4444-444444444444','ffffffff-0000-0000-0000-000000000006','01-onboarding','malformed payload: missing tenant','poison',   3,'{"raw":"{bad json"}',                  'manual', now() - interval '3 hours');

-- ── seats (identity lifecycle) ──────────────────────────────────────────────
insert into seats (tenant_id, user_email, status, last_seen) values
 ('11111111-1111-1111-1111-111111111111','ceo@acme.com',    'active',  now() - interval '1 day'),
 ('11111111-1111-1111-1111-111111111111','ops@acme.com',    'active',  now() - interval '3 hours'),
 ('22222222-2222-2222-2222-222222222222','admin@globex.com','active',  now() - interval '2 days'),
 ('33333333-3333-3333-3333-333333333333','stale@initech.com','revoked',now() - interval '95 days'),
 ('55555555-5555-5555-5555-555555555555','founder@hooli.com','active', now() - interval '5 hours');

-- ── entitlements (feature flags flipped by billing) ─────────────────────────
insert into entitlements (tenant_id, feature, enabled) values
 ('11111111-1111-1111-1111-111111111111','sso',true),
 ('11111111-1111-1111-1111-111111111111','api',true),
 ('22222222-2222-2222-2222-222222222222','sso',true),
 ('22222222-2222-2222-2222-222222222222','api',false),
 ('33333333-3333-3333-3333-333333333333','api',false),
 ('44444444-4444-4444-4444-444444444444','sso',false),   -- suspended → sso revoked
 ('55555555-5555-5555-5555-555555555555','api',false);

-- ── health_signals — 2+ points per (tenant,metric) so v_health_latest has deltas
insert into health_signals (tenant_id, metric, value, ts) values
 ('11111111-1111-1111-1111-111111111111','login_frequency', 40, now() - interval '7 days'),
 ('11111111-1111-1111-1111-111111111111','login_frequency', 45, now() - interval '1 day'),
 ('22222222-2222-2222-2222-222222222222','login_frequency', 30, now() - interval '7 days'),
 ('22222222-2222-2222-2222-222222222222','login_frequency', 22, now() - interval '1 day'),   -- dropping
 ('33333333-3333-3333-3333-333333333333','ticket_volume',    5, now() - interval '7 days'),
 ('33333333-3333-3333-3333-333333333333','ticket_volume',   14, now() - interval '1 day'),   -- rising = risk
 ('44444444-4444-4444-4444-444444444444','feature_usage',   60, now() - interval '30 days'),
 ('44444444-4444-4444-4444-444444444444','feature_usage',    8, now() - interval '2 days'),   -- silent drop-off
 ('66666666-6666-6666-6666-666666666666','login_frequency', 20, now() - interval '30 days'),
 ('66666666-6666-6666-6666-666666666666','login_frequency',  0, now() - interval '2 days');   -- churned

-- ── invoices (billing / reconciliation; one payment_failed drives dunning) ──
insert into invoices (tenant_id, stripe_id, status, amount, attempt) values
 ('11111111-1111-1111-1111-111111111111','in_acme_001',  'paid',           4800.00, 0),
 ('22222222-2222-2222-2222-222222222222','in_globex_001','payment_failed',  620.00, 2),
 ('22222222-2222-2222-2222-222222222222','in_globex_002','open',            620.00, 0),
 ('33333333-3333-3333-3333-333333333333','in_initech_001','paid',           299.00, 0),
 ('44444444-4444-4444-4444-444444444444','in_umbrella_001','uncollectible',9800.00, 5);

-- ── dsar_requests (privacy intake) ──────────────────────────────────────────
insert into dsar_requests (tenant_id, email, type, status, evidence) values
 ('11111111-1111-1111-1111-111111111111','ceo@acme.com',    'export','completed','{"package":"acme_export.json","rows":142}'),
 ('33333333-3333-3333-3333-333333333333','stale@initech.com','delete','processing','{}');

-- ── sanity output ───────────────────────────────────────────────────────────
select 'tenants' t, count(*) from tenants
union all select 'audit_log',         count(*) from audit_log
union all select 'pending_approvals', count(*) from v_pending_approvals
union all select 'dead_letter_queue', count(*) from dead_letter_queue
union all select 'health_latest',     count(*) from v_health_latest;
