-- supabase/migrations/20251021000013_daily_ops_reporting.sql
-- Day 11: Lead Operations Reporting & Sales Manager Digest
-- 100% free, deterministic counts - no Gemini needed

create or replace function public.get_daily_ops_metrics()
returns jsonb language plpgsql as $$
declare
  dubai_today_start timestamptz := ( (now() at time zone 'Asia/Dubai')::date ) at time zone 'Asia/Dubai';
  result jsonb;
begin
  result := jsonb_build_object(
    'generated_at', now(),
    'dubai_date', (now() at time zone 'Asia/Dubai')::date,
    'new_leads_today', (select count(*) from public.leads where created_at >= dubai_today_start),
    'qualified_leads_today', (select count(*) from public.leads where created_at >= dubai_today_start and status in ('qualified','hot','warm')),
    'hot_leads_today', (select count(*) from public.lead_scores where created_at >= dubai_today_start and tier='hot'),
    'needs_followup', (select count(*) from public.leads where follow_up_due_at <= now() and status not in ('closed','won','lost','converted')),
    'human_handoff', (select count(*) from public.leads where handoff = true or status = 'handoff'),
    'sla_breaches_overdue', (select count(*) from public.leads where follow_up_due_at < now() - interval '1 minute' and status not in ('closed','won','lost','converted')),
    'followups_sent_today', (select count(*) from public.follow_ups where sent_at >= dubai_today_start),
    'errors_24h', (select count(*) from public.workflow_errors where created_at >= now() - interval '24 hours'),
    'errors_today', (select count(*) from public.workflow_errors where created_at >= dubai_today_start),
    'investor_leads_today', (select count(*) from public.lead_scores where created_at >= dubai_today_start and investor_signal = true),
    'owner_leads_today', (select count(*) from public.lead_scores where created_at >= dubai_today_start and owner_signal = true),
    'total_active_leads', (select count(*) from public.leads where status not in ('closed','won','lost','converted'))
  );
  return result;
end; $$;

create or replace function public.get_top_action_leads()
returns table (
  lead_id uuid,
  full_name text,
  phone text,
  location text,
  budget_max bigint,
  tier text,
  score int,
  status text,
  owner text,
  follow_up_due_at timestamptz,
  minutes_overdue int,
  action_reason text
) language plpgsql as $$
begin
  return query
  select 
    l.id,
    l.full_name,
    l.phone,
    l.location,
    l.budget_max,
    coalesce(ls.tier, 'unscored') as tier,
    coalesce(ls.score, 0) as score,
    l.status,
    l.owner,
    l.follow_up_due_at,
    extract(epoch from (now() - l.follow_up_due_at))/60::int as minutes_overdue,
    case 
      when l.follow_up_due_at < now() - interval '1 minute' then 'SLA BREACH - ' || extract(epoch from (now() - l.follow_up_due_at))/60::int || 'min overdue'
      when l.handoff = true then 'HUMAN HANDOFF - needs owner'
      when l.follow_up_due_at <= now() + interval '2 hours' then 'FOLLOW-UP DUE SOON'
      else 'NEW QUALIFIED - needs contact'
    end as action_reason
  from public.leads l
  left join public.lead_scores ls on ls.lead_id = l.id
  where l.status not in ('closed','won','lost','converted')
    and (
      l.follow_up_due_at <= now() + interval '2 hours'
      or l.handoff = true
      or ls.tier = 'hot'
    )
  order by 
    case when l.follow_up_due_at < now() then 0 else 1 end,
    l.follow_up_due_at asc nulls last,
    ls.score desc nulls last
  limit 5;
end; $$;

create or replace view public.v_daily_ops_report as
select * from public.get_top_action_leads();
