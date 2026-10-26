-- BIG BROTHER / Customer Settlement foundation (DRAFT — NOT DEPLOYED)
-- Existing bank balance allocation engine remains authoritative for registered bank sources.
-- No data backfill; INV-7492 requires manual reconciliation before any credit creation.
-- SECURITY: RLS enabled, API roles have no table privileges. Server-side transactional
-- settlement functions and role-based authorization must be implemented before activation.
begin;

create table if not exists public.bb_customer_settlement_sources (
  source_id uuid primary key default gen_random_uuid(),
  customer_id text not null,
  source_type text not null check (source_type in ('REVERSAL_CREDIT','MANUAL_ADJUSTMENT')),
  origin_invoice_id text,
  origin_reversal_id text,
  currency text not null check (currency in ('USD','KHR')),
  original_amount numeric(18,4) not null check (original_amount > 0),
  status text not null default 'DRAFT' check (status in ('DRAFT','AVAILABLE','FROZEN','CLOSED','VOID')),
  created_at timestamptz not null default now(),
  created_by uuid,
  metadata jsonb not null default '{}'::jsonb,
  constraint bb_settlement_reversal_unique unique(origin_reversal_id,source_type),
  constraint bb_source_reversal_required check (source_type <> 'REVERSAL_CREDIT' or origin_reversal_id is not null)
);

create table if not exists public.bb_customer_settlement_movements (
  movement_id uuid primary key default gen_random_uuid(),
  source_id uuid not null references public.bb_customer_settlement_sources(source_id),
  action text not null check (action in ('APPLY_INVOICE','APPLY_AR','CASH_REFUND','BANK_REFUND','REINSTATE','VOID_ALLOCATION')),
  amount numeric(18,4) not null check (amount > 0),
  currency text not null check (currency in ('USD','KHR')),
  invoice_id text,
  payment_id text,
  cash_collection_id text,
  bank_reference text,
  settlement_batch_id text,
  salesman_id text,
  idempotency_key text not null unique,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','VOID')),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  constraint bb_settlement_cash_batch check (action <> 'CASH_REFUND' or (cash_collection_id is not null or settlement_batch_id is not null)),
  constraint bb_settlement_bank_reference check (action <> 'BANK_REFUND' or bank_reference is not null)
);

create index if not exists bb_settlement_sources_customer on public.bb_customer_settlement_sources(customer_id,currency,status);
create index if not exists bb_settlement_movements_source on public.bb_customer_settlement_movements(source_id,status);
create index if not exists bb_settlement_movements_cash on public.bb_customer_settlement_movements(cash_collection_id);

-- Prevent accidental direct browser writes/reads before permission model and atomic RPC exist.
alter table public.bb_customer_settlement_sources enable row level security;
alter table public.bb_customer_settlement_movements enable row level security;
revoke all on public.bb_customer_settlement_sources from anon,authenticated;
revoke all on public.bb_customer_settlement_movements from anon,authenticated;

-- Balance is computed only from APPROVED movements; never from a mutable client cache.
-- REINSTATE/VOID_ALLOCATION restore funds, other movement types consume funds.
create or replace view public.bb_customer_settlement_balance
with (security_invoker=true)
as
select s.source_id,s.customer_id,s.source_type,s.origin_invoice_id,s.currency,
       s.original_amount,s.status,
       (s.original_amount-coalesce(sum(case
          when m.status <> 'APPROVED' then 0
          when m.action in ('REINSTATE','VOID_ALLOCATION') then -m.amount
          else m.amount end),0))::numeric(18,4) as remaining_amount
from public.bb_customer_settlement_sources s
left join public.bb_customer_settlement_movements m on m.source_id=s.source_id
group by s.source_id;
revoke all on public.bb_customer_settlement_balance from anon,authenticated;
commit;

-- Next implementation: authenticated, role-checked, SERIALIZABLE / row-locked RPC
-- for approval, allocation, refunds and reversals. Do NOT grant client INSERT/UPDATE.
-- Cross-currency spending must record both native and invoice currency amounts.
-- Stock destination batch and actual cash payer must be tracked separately.
