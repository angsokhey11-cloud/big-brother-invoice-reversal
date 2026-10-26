-- BIG BROTHER settlement approval prototype (NOT DEPLOYED).
-- Depends on sql/customer-settlement-foundation-draft.sql.
-- Only a trusted database operator may execute this. No application role receives EXECUTE.
-- Approval is a single transaction with source row lock, protecting against concurrent spending.
begin;
create or replace function public.bb_approve_customer_settlement_internal(p_movement_id uuid)
returns table (movement_id uuid, source_id uuid, approved_remaining numeric)
language plpgsql security invoker set search_path = ''
as $$
declare
 v_m public.bb_customer_settlement_movements%rowtype;
 v_s public.bb_customer_settlement_sources%rowtype;
 v_used numeric(18,4);
 v_delta numeric(18,4);
begin
 select * into v_m from public.bb_customer_settlement_movements
 where bb_customer_settlement_movements.movement_id=p_movement_id;
 if not found then raise exception 'Movement not found'; end if;

 -- Always lock SOURCE before the movement to serialize all spending of this credit.
 select * into v_s from public.bb_customer_settlement_sources where
 bb_customer_settlement_sources.source_id=v_m.source_id for update;
 if not found then raise exception 'Source not found'; end if;

 select * into v_m from public.bb_customer_settlement_movements where
 bb_customer_settlement_movements.movement_id=p_movement_id for update;
 if v_m.status='APPROVED' then
   select coalesce(sum(case when action in ('REINSTATE','VOID_ALLOCATION')
                        then -amount else amount end),0)
     into v_used from public.bb_customer_settlement_movements
    where bb_customer_settlement_movements.source_id=v_s.source_id and status='APPROVED';
   return query select v_m.movement_id,v_s.source_id,v_s.original_amount-v_used;
   return;
 end if;
 if v_m.status<>'PENDING' then raise exception 'Movement not pending'; end if;
 if v_s.status<>'AVAILABLE' then raise exception 'Customer credit not available'; end if;
 if v_s.currency<>v_m.currency then raise exception 'Currency mismatch'; end if;

 select coalesce(sum(case when action in ('REINSTATE','VOID_ALLOCATION')
                        then -amount else amount end),0)
   into v_used from public.bb_customer_settlement_movements
  where bb_customer_settlement_movements.source_id=v_s.source_id and status='APPROVED';
 v_delta:=case when v_m.action in ('REINSTATE','VOID_ALLOCATION')
               then -v_m.amount else v_m.amount end;
 if v_used+v_delta<0 or v_used+v_delta>v_s.original_amount then
   raise exception 'Customer credit balance would be invalid';
 end if;

 -- Each pending refund requires external payment confirmation and authorization
 -- before this trusted approval routine may be called.
 update public.bb_customer_settlement_movements
 set status='APPROVED',approved_at=now()
 where bb_customer_settlement_movements.movement_id=p_movement_id;
 return query select v_m.movement_id,v_s.source_id,v_s.original_amount-v_used-v_delta;
end $$;
revoke all on function public.bb_approve_customer_settlement_internal(uuid) from public,anon,authenticated;
commit;

-- Remaining before launch:
-- 1. move RPC into a restricted non-API schema and define proper operator permissions
-- 2. validate refund proof, payer/batch ownership and invoice/AP references on server
-- 3. add atomic request-create + approve idempotent API; cross-currency allocation
-- 4. ensure reversals of applied credits are source-linked and not credited twice
-- 5. test on isolated database with concurrency and Local Brain replication.
