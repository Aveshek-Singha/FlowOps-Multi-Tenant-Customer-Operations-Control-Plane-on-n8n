-- Additive tables for Services 10 and 11.
-- Base Contract A tables stay unchanged; these store durable workflow artifacts.

create table if not exists reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  correlation_id uuid not null,
  tenant_id uuid references tenants(id) on delete set null,
  status text not null default 'completed' check (status in ('completed','error')),
  summary jsonb not null default '{}'::jsonb,
  findings jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_reconciliation_runs_tenant on reconciliation_runs(tenant_id);
create index if not exists idx_reconciliation_runs_correlation on reconciliation_runs(correlation_id);
create index if not exists idx_reconciliation_runs_created on reconciliation_runs(created_at desc);

drop trigger if exists trg_reconciliation_runs_updated on reconciliation_runs;
create trigger trg_reconciliation_runs_updated before update on reconciliation_runs
  for each row execute function set_updated_at();

alter table reconciliation_runs enable row level security;

drop policy if exists "reconciliation_runs_read" on reconciliation_runs;
create policy "reconciliation_runs_read"
on reconciliation_runs for select
to anon
using (true);
-- ^ aggregates only; read-only for the operator UI (DEV-READ convention, same as
-- incidents.sql / renewals.sql). No anon insert/update/delete (deny-by-default).

create table if not exists compliance_exports (
  id uuid primary key default gen_random_uuid(),
  correlation_id uuid not null,
  tenant_id uuid references tenants(id) on delete set null,
  status text not null default 'completed' check (status in ('completed','error')),
  report_md text not null,
  report jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_compliance_exports_tenant on compliance_exports(tenant_id);
create index if not exists idx_compliance_exports_correlation on compliance_exports(correlation_id);
create index if not exists idx_compliance_exports_created on compliance_exports(created_at desc);

drop trigger if exists trg_compliance_exports_updated on compliance_exports;
create trigger trg_compliance_exports_updated before update on compliance_exports
  for each row execute function set_updated_at();

alter table compliance_exports enable row level security;

drop policy if exists "compliance_exports_read" on compliance_exports;
create policy "compliance_exports_read"
on compliance_exports for select
to anon
using (true);
-- ^ report holds counts/aggregates only (data minimization enforced in workflow 13);
-- read-only for the operator UI. No anon insert/update/delete (deny-by-default).
