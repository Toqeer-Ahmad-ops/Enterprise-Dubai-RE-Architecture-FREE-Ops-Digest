-- supabase/migrations/20251021000012_sla_idempotency_fix.sql
-- Day 10 Safeguard: Prove 1-min SLA cron cannot send duplicate Gmail alerts
-- Free, deterministic, no extra infra

alter table public.leads add column if not exists last_sla_alert_at timestamptz;
alter table public.leads add column if not exists sla_breach_count int default 0;
alter table public.leads add column if not exists handoff boolean default false;

create table if not exists public.sla_alert_log (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  alert_type text not null check (alert_type in ('sla_breach_1min','followup_overdue','handoff_pending')),
  sent_at timestamptz not null default now(),
  gmail_message_id text,
  constraint uq_sla_alert_hour unique (lead_id, alert_type, date_trunc('hour', sent_at))
);

create index if not exists idx_sla_alert_lead on public.sla_alert_log(lead_id);
create index if not exists idx_sla_alert_sent on public.sla_alert_log(sent_at desc);

alter table public.sla_alert_log enable row level security;
drop policy if exists "service can do all" on public.sla_alert_log;
create policy "service can do all" on public.sla_alert_log for all using (true) with check (true);

create or replace function public.get_sla_breached_leads()
returns table (
  lead_id uuid,
  full_name text,
  phone text,
  follow_up_due_at timestamptz,
  minutes_overdue int,
  owner text
) language plpgsql as $$
begin
  return query
  select 
    l.id,
    l.full_name,
    l.phone,
    l.follow_up_due_at,
    extract(epoch from (now() - l.follow_up_due_at))/60::int as minutes_overdue,
    l.owner
  from public.leads l
  left join public.sla_alert_log sal 
    on sal.lead_id = l.id 
    and sal.alert_type = 'sla_breach_1min'
    and sal.sent_at > now() - interval '60 minutes'
  where l.follow_up_due_at is not null
    and l.follow_up_due_at < now() - interval '1 minute'
    and l.status not in ('closed','won','lost','converted')
    and sal.id is null
  order by l.follow_up_due_at asc
  limit 50;
end; $$;
