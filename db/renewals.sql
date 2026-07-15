-- FlowOps - renewal packages table (Service 7, additive to Contract A)
-- Apply: supabase db query --linked -f db/renewals.sql  (after schema.sql)
-- Re-runnable, additive-only. Reuses set_updated_at() from schema.sql.

create table if not exists renewal_packages (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references tenants(id) on delete cascade,
  correlation_id   uuid not null,
  renewal_due_at   timestamptz,
  risk_level       text not null default 'watch' check (risk_level in ('low','watch','high','critical')),
  status           text not null default 'draft' check (status in ('draft','scheduled','sent','skipped')),
  package_md       text not null default '',
  package          jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists idx_renewal_packages_tenant on renewal_packages(tenant_id);
create index if not exists idx_renewal_packages_correlation on renewal_packages(correlation_id);
create index if not exists idx_renewal_packages_status on renewal_packages(status);
create index if not exists idx_renewal_packages_due on renewal_packages(renewal_due_at);

drop trigger if exists trg_renewal_packages_updated on renewal_packages;
create trigger trg_renewal_packages_updated before update on renewal_packages
  for each row execute function set_updated_at();

alter table renewal_packages enable row level security;
drop policy if exists renewal_packages_dev_read on renewal_packages;
create policy renewal_packages_dev_read on renewal_packages for select to anon using (true);

-- Writes go through n8n's service key (bypasses RLS).
