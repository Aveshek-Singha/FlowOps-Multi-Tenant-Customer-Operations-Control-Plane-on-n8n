-- FlowOps — Row-Level Security (Contract A)
-- Run AFTER schema.sql. The tenant-isolation mechanism — same idea OpsFabric
-- used with Aurora + RLS. This is the interview centerpiece.
--
-- MODEL:
--   * n8n backend connects with the Supabase SERVICE ROLE key → bypasses RLS
--     (BYPASSRLS) → workflows read/write any tenant freely. Correct + intended.
--   * The frontend connects with the ANON key → RLS is enforced → it can only
--     see rows for the tenant in its JWT `tenant_id` claim.
--
--   Helper current_tenant_id() reads the tenant_id claim from the request JWT.
--   With no JWT (plain anon), it returns NULL → strict policies see nothing.
--
--   ⚠️ DEV BOOTSTRAP: auth isn't wired yet, so a clearly-marked permissive DEV
--   read policy lets the operator UI read seed data with just the anon key
--   TODAY. Search "DEV READ" and drop those policies to demo strict isolation.

-- ── claim helper ────────────────────────────────────────────────────────────
-- Returns the tenant_id from the request JWT, or NULL if there is no valid
-- JWT / claim. PL/pgSQL body so a missing or malformed claims string can NEVER
-- raise — a bad token degrades to "see nothing" rather than crashing the query.
create or replace function current_tenant_id() returns uuid
language plpgsql stable as $$
declare
  v_claims text;
begin
  v_claims := nullif(current_setting('request.jwt.claims', true), '');
  if v_claims is null then
    return null;
  end if;
  begin
    return nullif(v_claims::jsonb ->> 'tenant_id', '')::uuid;
  exception when others then
    return null;
  end;
end;
$$;

-- ── enable RLS on every table ───────────────────────────────────────────────
alter table tenants           enable row level security;
alter table tenant_policies   enable row level security;
alter table audit_log         enable row level security;
alter table dead_letter_queue enable row level security;
alter table idempotency_keys  enable row level security;
alter table seats             enable row level security;
alter table entitlements      enable row level security;
alter table health_signals    enable row level security;
alter table invoices          enable row level security;
alter table dsar_requests     enable row level security;

-- ════════════════════════════════════════════════════════════════════════════
-- STRICT tenant-isolation policies (the real mechanism).
-- Applied to the `anon` role. tenants keys on id; all others on tenant_id.
-- Policy names are suffixed per-table so Supabase's Auth Policies UI reads cleanly.
-- ════════════════════════════════════════════════════════════════════════════

-- tenants (root entity; keys on its own id)
create policy tenants_isolation_select on tenants
  for select to anon using (id = current_tenant_id());

-- tenant_policies (backend-owned config; anon = SELECT only)
create policy tenant_policies_isolation_select on tenant_policies
  for select to anon using (tenant_id = current_tenant_id());

-- audit_log (backend writes via service_role; anon = SELECT only)
create policy audit_log_isolation_select on audit_log
  for select to anon using (tenant_id = current_tenant_id());

-- dead_letter_queue (backend-owned; anon = SELECT only)
create policy dlq_isolation_select on dead_letter_queue
  for select to anon using (tenant_id = current_tenant_id());

-- seats (frontend may invite members → SELECT + INSERT, both tenant-scoped)
create policy seats_isolation_select on seats
  for select to anon using (tenant_id = current_tenant_id());
create policy seats_isolation_insert on seats
  for insert to anon with check (tenant_id = current_tenant_id());

-- entitlements (backend-owned; anon = SELECT only)
create policy entitlements_isolation_select on entitlements
  for select to anon using (tenant_id = current_tenant_id());

-- health_signals (backend writes; anon = SELECT only)
create policy health_signals_isolation_select on health_signals
  for select to anon using (tenant_id = current_tenant_id());

-- invoices (backend writes from Stripe; anon = SELECT only)
create policy invoices_isolation_select on invoices
  for select to anon using (tenant_id = current_tenant_id());

-- dsar_requests (end-user submits a data request → SELECT + INSERT, tenant-scoped)
create policy dsar_requests_isolation_select on dsar_requests
  for select to anon using (tenant_id = current_tenant_id());
create policy dsar_requests_isolation_insert on dsar_requests
  for insert to anon with check (tenant_id = current_tenant_id());

-- idempotency_keys: internal plumbing, no anon access at all (RLS on, no anon
-- policy = deny-by-default for SELECT/INSERT/UPDATE/DELETE).

-- ════════════════════════════════════════════════════════════════════════════
-- DEV READ — REMOVE FOR STRICT-ISOLATION DEMO. ────────────────────────────────
-- Lets the operator UI read all seed data with the plain anon key while auth is
-- not yet wired. Operator console is cross-tenant by nature, so anon SELECT-all
-- is acceptable for dev. To demo isolation: drop these, issue a JWT with a
-- tenant_id claim, show the UI see only that tenant.
-- ════════════════════════════════════════════════════════════════════════════
create policy dev_read_all on tenants           for select to anon using (true);
create policy dev_read_all on tenant_policies   for select to anon using (true);
create policy dev_read_all on audit_log         for select to anon using (true);
create policy dev_read_all on dead_letter_queue for select to anon using (true);
create policy dev_read_all on seats             for select to anon using (true);
create policy dev_read_all on entitlements      for select to anon using (true);
create policy dev_read_all on health_signals    for select to anon using (true);
create policy dev_read_all on invoices          for select to anon using (true);
create policy dev_read_all on dsar_requests     for select to anon using (true);
-- ── END DEV READ ────────────────────────────────────────────────────────────
