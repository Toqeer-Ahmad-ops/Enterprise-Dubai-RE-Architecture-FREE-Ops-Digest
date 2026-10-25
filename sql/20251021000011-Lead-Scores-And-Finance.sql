-- supabase/migrations/20251021000011_lead_scores_and_finance.sql
-- Day 11: Lead Scoring + Finance docs - FK to leads(id), explainable

-- 1. Lead Scores table (explainable)
create table if not exists public.lead_scores (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  score int not null check (score >= 0 and score <= 100),
  tier text not null check (tier in ('hot','warm','cold')),
  investor_signal boolean not null default false,
  owner_signal boolean not null default false,
  reasons jsonb not null default '{}'::jsonb,
  relevance int not null default 0,
  confidence int not null default 0,
  model_version text not null default 'day11-v1-gemini-flash',
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  constraint uq_lead_scores_lead_id unique (lead_id)
);

create index if not exists idx_lead_scores_tier on public.lead_scores(tier);
create index if not exists idx_lead_scores_investor on public.lead_scores(investor_signal) where investor_signal = true;
create index if not exists idx_lead_scores_score on public.lead_scores(score desc);

create or replace function public.handle_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end; $$ language plpgsql;
drop trigger if exists trg_lead_scores_updated_at on public.lead_scores;
create trigger trg_lead_scores_updated_at before update on public.lead_scores for each row execute function public.handle_updated_at();

alter table public.lead_scores enable row level security;
drop policy if exists "service can do all" on public.lead_scores;
create policy "service can do all" on public.lead_scores for all using (true) with check (true);

-- 2. Finance docs RAG - ensure documents table supports doc_type
do $$ begin
  if not exists (select 1 from information_schema.columns where table_name='documents' and column_name='doc_type') then
    alter table public.documents add column doc_type text default 'general' check (doc_type in ('general','finance','dld','payment_plan','roi'));
  end if;
end $$;

create index if not exists idx_documents_doc_type on public.documents(doc_type) where doc_type = 'finance';

-- 3. Vector search function with filter (use only for investor leads)
create or replace function public.match_finance_docs(
  query_embedding vector(768),
  match_threshold float default 0.78,
  match_count int default 5
)
returns table (id uuid, content text, metadata jsonb, similarity float)
language plpgsql as $$
begin
  return query
  select d.id, d.content, d.metadata, 1 - (d.embedding <=> query_embedding) as similarity
  from public.documents d
  where d.doc_type = 'finance'
    and 1 - (d.embedding <=> query_embedding) > match_threshold
  order by d.embedding <=> query_embedding
  limit match_count;
end; $$;
