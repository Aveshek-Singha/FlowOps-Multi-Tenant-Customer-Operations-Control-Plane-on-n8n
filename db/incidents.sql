-- FlowOps — incidents table (Service 5, additive to Contract A)
-- Apply: supabase db query --linked -f db/incidents.sql  (after schema.sql)
-- Re-runnable, additive-only. NOT added to the frozen schema.sql (mirrors the
-- db/dlq-bump.sql precedent). Reuses the existing set_updated_at() from schema.sql.
create table if not exists incidents (
  id             uuid primary key default gen_random_uuid(),
  correlation_id uuid not null,
  monitor_id     text not null,
  monitor_name   text,
  severity       text not null default 'major' check (severity in ('minor','major','critical')),
  status         text not null default 'open' check (status in ('open','monitoring','resolved')),
  region         text,
  impact_count   int  not null default 0,
  postmortem     jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_incidents_status      on incidents(status);
create index if not exists idx_incidents_correlation on incidents(correlation_id);
create index if not exists idx_incidents_monitor     on incidents(monitor_id);
drop trigger if exists trg_incidents_updated on incidents;
create trigger trg_incidents_updated before update on incidents
  for each row execute function set_updated_at();
-- RLS: MUST enable, else Supabase default grants expose the table to anon writes.
alter table incidents enable row level security;
drop policy if exists incidents_dev_read on incidents;
create policy incidents_dev_read on incidents for select to anon using (true);
-- ^ tenant-agnostic status info; read-only for the UI. Same spirit as the DEV-READ
-- block in rls-policies.sql. No anon insert/update/delete (deny-by-default).
-- Writes go through n8n's service key (bypasses RLS).
