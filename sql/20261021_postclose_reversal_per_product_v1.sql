-- BIG BROTHER Post-Close Invoice Reversal — PER PRODUCT destination.
-- Install only after reviewing live permission/stock/accounting snapshot.
-- No existing invoice, batch, stock or cash rows are changed by installation.
-- All reversal posts occur atomically in a single RPC call.

CREATE TABLE IF NOT EXISTS public.bb_postclose_reversal_routes (
 return_id text PRIMARY KEY,
 invoice_id text NOT NULL,
 original_batch_id text NOT NULL,
 destinations jsonb NOT NULL CHECK (jsonb_typeof(destinations)='array'),
 created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bb_postclose_routes_source_idx
 ON public.bb_postclose_reversal_routes(original_batch_id,invoice_id);
ALTER TABLE public.bb_postclose_reversal_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bb_postclose_reversal_routes FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.bb_postclose_reversal_routes FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.bb_postclose_reversal_routes TO service_role;

CREATE TABLE IF NOT EXISTS public.bb_postclose_reversal_allocations (
 return_id text NOT NULL REFERENCES public.bb_postclose_reversal_routes(return_id),
 invoice_id text NOT NULL,
 original_batch_id text NOT NULL,
 product_code text NOT NULL,
 stock_source text NOT NULL CHECK (stock_source IN ('PURCHASED','ZERO_COST')),
 qty numeric NOT NULL CHECK (qty>0),
 destination_type text NOT NULL CHECK (destination_type IN ('WAREHOUSE','OPEN_BATCH')),
 destination_batch_id text,
 destination_location text NOT NULL,
 stock_transaction_id text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (return_id,product_code,stock_source)
);
CREATE INDEX IF NOT EXISTS bb_postclose_allocation_source_idx
 ON public.bb_postclose_reversal_allocations(original_batch_id,product_code,stock_source);
ALTER TABLE public.bb_postclose_reversal_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bb_postclose_reversal_allocations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.bb_postclose_reversal_allocations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.bb_postclose_reversal_allocations TO service_role;

-- Authorized UI lookup. No financial or stock writes.
CREATE OR REPLACE FUNCTION public.bb_invoice_reversal_postclose_options_v1(p_invoice_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $postclose_options$
DECLARE v_invoice public.invoices%rowtype;
        v_status text; v_warehouse text; v_batches jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.bb_has_module_access('invoice_reversal','view')
 THEN RAISE EXCEPTION 'Invoice Reversal view access denied'; END IF;
 SELECT * INTO v_invoice FROM public.invoices
 WHERE invoice_id=trim(coalesce(p_invoice_id,'')) LIMIT 1;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invoice was not found'; END IF;
 IF NOT public.bb_has_location_access(v_invoice.location_code)
 THEN RAISE EXCEPTION 'Invoice location access denied'; END IF;
 SELECT b.status INTO v_status FROM public.stock_batches b WHERE b.batch_id=v_invoice.batch_id;
 SELECT s.default_warehouse_location_code INTO v_warehouse
 FROM public.stock_cutover_state s WHERE s.state_id='MAIN';
 IF v_status IS DISTINCT FROM 'Closed' THEN
  RETURN jsonb_build_object('success',true,'isPostClose',false,'originalBatchId',v_invoice.batch_id);
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'batchId',q.batch_id,
   'batchDate',q.batch_date::text,
   'salesman',q.salesman_name_snapshot,
   'locationCode',q.location_code,
   'products',q.products
 ) ORDER BY q.batch_date DESC,q.batch_id DESC),'[]'::jsonb)
 INTO v_batches FROM (
   SELECT b.batch_id,b.batch_date,b.salesman_name_snapshot,b.location_code,
          coalesce(jsonb_agg(bi.product_code ORDER BY bi.product_code)
          FILTER (WHERE bi.product_code IS NOT NULL),'[]'::jsonb) AS products
   FROM public.stock_batches b
   LEFT JOIN public.stock_batch_items bi ON bi.batch_id=b.batch_id
   WHERE b.location_code=v_invoice.location_code AND upper(b.status)='OPEN'
     AND b.batch_id<>v_invoice.batch_id AND public.bb_has_location_access(b.location_code)
   GROUP BY b.batch_id,b.batch_date,b.salesman_name_snapshot,b.location_code
   ORDER BY b.batch_date DESC,b.batch_id DESC LIMIT 70
 )q;
 RETURN jsonb_build_object('success',true,'isPostClose',true,
   'originalBatchId',v_invoice.batch_id,'warehouseLocation',coalesce(v_warehouse,'PP-01'),
   'openBatches',v_batches);
END;
$postclose_options$;
REVOKE ALL ON FUNCTION public.bb_invoice_reversal_postclose_options_v1(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bb_invoice_reversal_postclose_options_v1(text) TO authenticated,service_role;

-- Exact posted product allocation routes determine the actual destination.
-- The existing closed source batch is never modified.
CREATE OR REPLACE FUNCTION public.bb_postclose_reversal_stock_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $postclose_stock$
DECLARE v_route public.bb_postclose_reversal_routes%rowtype;
        v_invoice public.invoices%rowtype;
        v_original public.stock_batch_items%rowtype;
        v_target public.stock_batches%rowtype;
        v_target_item public.stock_batch_items%rowtype;
        v_entry jsonb; v_dest jsonb; v_part jsonb;
        v_code text; v_type text; v_batch_id text; v_source text;
        v_qty numeric; v_purchased numeric; v_zero numeric; v_total numeric:=0;
        v_prior_p numeric; v_prior_z numeric; v_source_qty numeric;
        v_bucket text; v_location text; v_cost numeric;
        v_movement_id text; v_transaction_id text; v_product text; v_unit text;
        v_warehouse_location text; v_match_count integer;
BEGIN
 SELECT * INTO v_route FROM public.bb_postclose_reversal_routes r
 WHERE r.return_id=new.return_id AND r.invoice_id=new.invoice_id;
 IF NOT FOUND THEN RETURN new; END IF;
 SELECT * INTO v_invoice FROM public.invoices WHERE invoice_id=new.invoice_id;
 IF NOT FOUND OR v_invoice.batch_id IS DISTINCT FROM v_route.original_batch_id
 THEN RAISE EXCEPTION 'Post-close source invoice mismatch'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.stock_batches b
     WHERE b.batch_id=v_invoice.batch_id AND upper(b.status)='CLOSED')
 THEN RAISE EXCEPTION 'Original Batch is no longer Closed'; END IF;
 IF new.line_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.invoice_lines il
   WHERE il.invoice_id=new.invoice_id AND il.line_id=new.line_id)
 THEN RAISE EXCEPTION 'Post-close invoice line mismatch'; END IF;
 IF jsonb_typeof(new.stock_allocation_json) IS DISTINCT FROM 'array'
 THEN RAISE EXCEPTION 'Post-close product allocation is missing'; END IF;

 SELECT s.default_warehouse_location_code INTO v_warehouse_location
 FROM public.stock_cutover_state s WHERE s.state_id='MAIN';
 IF v_warehouse_location IS NULL
 THEN RAISE EXCEPTION 'Warehouse location configuration missing'; END IF;
 v_movement_id := public.bb_next_prefixed_id(
    'public.stock_activity'::regclass,'movement_id','STK',6);

 FOR v_entry IN SELECT value FROM jsonb_array_elements(new.stock_allocation_json)
 LOOP
  v_code := nullif(trim(coalesce(v_entry->>'productCode','')),'');
  v_qty := coalesce(nullif(v_entry->>'qty','')::numeric,0);
  IF v_code IS NULL OR v_qty<=0
  THEN RAISE EXCEPTION 'Invalid post-close product allocation'; END IF;
  v_total:=v_total+v_qty;

  SELECT count(*),max(value) INTO v_match_count,v_dest
  FROM jsonb_array_elements(v_route.destinations)
  WHERE trim(coalesce(value->>'productCode',''))=v_code;
  IF v_match_count<>1 THEN
   RAISE EXCEPTION 'Choose exactly one stock destination for product %',v_code;
  END IF;
  v_type:=upper(trim(coalesce(v_dest->>'destinationType','')));
  v_batch_id:=nullif(trim(coalesce(v_dest->>'batchId','')),'');
  IF v_type NOT IN ('WAREHOUSE','OPEN_BATCH')
  THEN RAISE EXCEPTION 'Invalid destination for %',v_code; END IF;

  SELECT * INTO v_original FROM public.stock_batch_items
  WHERE batch_id=v_invoice.batch_id AND product_code=v_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Original Batch does not contain %',v_code; END IF;

  IF v_type='OPEN_BATCH' THEN
   IF v_batch_id IS NULL OR v_batch_id=v_invoice.batch_id
   THEN RAISE EXCEPTION 'Invalid target Batch for %',v_code; END IF;
   SELECT * INTO v_target FROM public.stock_batches
   WHERE batch_id=v_batch_id FOR UPDATE;
   IF NOT FOUND OR upper(coalesce(v_target.status,''))<>'OPEN'
    OR v_target.location_code IS DISTINCT FROM v_invoice.location_code
   THEN RAISE EXCEPTION 'Target Batch must be Open in the same location for %',v_code; END IF;
   SELECT * INTO v_target_item FROM public.stock_batch_items
   WHERE batch_id=v_batch_id AND product_code=v_code FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Product % is missing from target Batch %',v_code,v_batch_id; END IF;
   v_location:=v_target.location_code;
  ELSE
   IF v_batch_id IS NOT NULL THEN RAISE EXCEPTION 'Warehouse destination cannot have Batch ID'; END IF;
   v_location:=v_warehouse_location;
  END IF;

  SELECT coalesce(sum(qty) FILTER (WHERE stock_source='PURCHASED'),0),
         coalesce(sum(qty) FILTER (WHERE stock_source='ZERO_COST'),0)
    INTO v_prior_p,v_prior_z
  FROM public.bb_postclose_reversal_allocations
  WHERE original_batch_id=v_invoice.batch_id AND product_code=v_code;
  v_purchased:=least(v_qty,greatest(coalesce(v_original.purchased_sold_qty_snapshot,0)-v_prior_p,0));
  v_zero:=v_qty-v_purchased;
  IF v_zero>greatest(coalesce(v_original.zero_cost_sold_qty_snapshot,0)-v_prior_z,0)+0.000001
  THEN RAISE EXCEPTION 'Post-close source stock shortage for %',v_code; END IF;
  IF v_purchased+v_zero>v_qty+0.000001
  THEN RAISE EXCEPTION 'Post-close source stock mismatch'; END IF;

  SELECT p.product_name,p.unit INTO v_product,v_unit FROM public.products p
  WHERE p.product_code=v_code;
  v_cost:=coalesce(public.bb_stock_average_cost_internal(v_code),0);

  FOR v_part IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
    jsonb_build_object('source','PURCHASED','qty',v_purchased),
    jsonb_build_object('source','ZERO_COST','qty',v_zero)
  ))
  LOOP
   v_source:=v_part->>'source';v_source_qty:=(v_part->>'qty')::numeric;
   IF v_source_qty<=0.000001 THEN CONTINUE; END IF;
   v_bucket:=CASE
    WHEN v_type='WAREHOUSE' AND v_source='PURCHASED' THEN 'WAREHOUSE_GOOD'
    WHEN v_type='WAREHOUSE' THEN 'WAREHOUSE_ZERO_COST'
    WHEN v_source='PURCHASED' THEN 'BATCH_PENDING'
    ELSE 'BATCH_ZERO_COST' END;

   v_transaction_id:=public.bb_next_prefixed_id(
     'public.stock_activity'::regclass,'transaction_id','TRX',6);
   INSERT INTO public.stock_activity(
     transaction_id,batch_id,activity_date,activity_type,
     product_code,product_name_snapshot,qty,unit_snapshot,
     location_code,to_location_code,salesman_staff_id,salesman_name_snapshot,
     reference_no,related_invoice_no,note,source_created_at,
     movement_id,flow,movement_type,from_bucket,to_bucket,
     source_entity_type,source_id,source_name,customer_id,customer_name_snapshot,
     unit_cost,line_value,location_name_snapshot,client_request_id
   ) VALUES (
     v_transaction_id,CASE WHEN v_type='OPEN_BATCH' THEN v_batch_id ELSE NULL END,
     new.return_date,'Stock In',v_code,coalesce(v_product,v_code),v_source_qty,
     coalesce(v_unit,''),v_location,v_location,v_invoice.salesperson_staff_id,
     v_invoice.salesperson_name_snapshot,new.return_id,v_invoice.invoice_no,
     'Post-close reversal: original closed Batch '||v_invoice.batch_id||
     ' -> '||v_type||coalesce(' '||v_batch_id,'')||' ('||v_source||')',
     now(),v_movement_id,'INFLOW','POSTCLOSE_SALE_RETURN',
     'EXTERNAL',v_bucket,'CUSTOMER',v_invoice.customer_id,
     v_invoice.customer_name_snapshot,v_invoice.customer_id,
     v_invoice.customer_name_snapshot,
     CASE WHEN v_source='PURCHASED' THEN v_cost ELSE 0 END,
     round(v_source_qty*CASE WHEN v_source='PURCHASED' THEN v_cost ELSE 0 END,6),
     coalesce((select l.location_name from public.locations l
               where l.location_code=v_location),v_location),
     'POSTCLOSE-RETURN:'||new.return_id||':'||v_code||':'||v_source
   );
   INSERT INTO public.bb_postclose_reversal_allocations(
     return_id,invoice_id,original_batch_id,product_code,stock_source,qty,
     destination_type,destination_batch_id,destination_location,stock_transaction_id
   ) VALUES(new.return_id,new.invoice_id,v_invoice.batch_id,
     v_code,v_source,v_source_qty,v_type,v_batch_id,v_location,v_transaction_id);

   IF v_type='OPEN_BATCH' THEN
    UPDATE public.stock_batch_items bi
    SET issued_qty=issued_qty+v_source_qty,
        pending_qty_snapshot=pending_qty_snapshot+v_source_qty,
        purchased_issued_qty=coalesce(purchased_issued_qty,0)+
           CASE WHEN v_source='PURCHASED' THEN v_source_qty ELSE 0 END,
        zero_cost_issued_qty=coalesce(zero_cost_issued_qty,0)+
           CASE WHEN v_source='ZERO_COST' THEN v_source_qty ELSE 0 END,
        purchased_pending_qty_snapshot=coalesce(purchased_pending_qty_snapshot,0)+
           CASE WHEN v_source='PURCHASED' THEN v_source_qty ELSE 0 END,
        zero_cost_pending_qty_snapshot=coalesce(zero_cost_pending_qty_snapshot,0)+
           CASE WHEN v_source='ZERO_COST' THEN v_source_qty ELSE 0 END,
        updated_at=now(),source_updated_at=now()
    WHERE bi.batch_id=v_batch_id AND bi.product_code=v_code;
    UPDATE public.stock_batches b SET issued_qty=issued_qty+v_source_qty,
      updated_at=now(),source_updated_at=now()
    WHERE b.batch_id=v_batch_id;
   END IF;
  END LOOP;
  IF v_type='OPEN_BATCH' THEN
   PERFORM public.bb_stock_refresh_batch_status_internal(v_batch_id);
  END IF;
 END LOOP;
 IF abs(v_total-new.qty)>0.000001
 THEN RAISE EXCEPTION 'Post-close physical product Qty does not match invoice line Qty'; END IF;
 PERFORM public.bb_stock_touch_revision_internal();
 RETURN new;
END;
$postclose_stock$;

DROP TRIGGER IF EXISTS trg_sales_returns_postclose_stock ON public.sales_returns;
CREATE TRIGGER trg_sales_returns_postclose_stock
 AFTER INSERT ON public.sales_returns
 FOR EACH ROW EXECUTE FUNCTION public.bb_postclose_reversal_stock_v1();

-- Safely extend the two existing Batch triggers to skip the original closed
-- Batch ONLY when a secured, matching post-close routing record exists.
-- All standard reversal behavior stays byte-identical beyond this guard.
DO $postclose_patch$
DECLARE v_before text;
        v_after text;
        v_save text;
        v_view text;
        v_patched text;
        v_before_old text:='if upper(coalesce(v_batch.status,''''))=''CLOSED'' then';
        v_before_new text:='if upper(coalesce(v_batch.status,''''))=''CLOSED'' and not exists ('||
           'select 1 from public.bb_postclose_reversal_routes r where r.return_id=new.return_id '||
           'and r.invoice_id=new.invoice_id and r.original_batch_id=v_batch.batch_id) then';
        v_after_anchor text;
        v_inject text;
BEGIN
 SELECT pg_get_functiondef('public.bb_batch_return_allocate_internal()'::regprocedure)
 INTO v_before;
 SELECT pg_get_functiondef('public.bb_batch_return_stock_internal()'::regprocedure)
 INTO v_after;
 SELECT pg_get_functiondef('public.bb_invoice_reversal_save_by_id_v2(jsonb)'::regprocedure)
 INTO v_save;
 SELECT pg_get_viewdef('public.v_batch_reconciliation'::regclass,true) INTO v_view;
 IF v_before IS NULL OR v_after IS NULL OR v_save IS NULL OR v_view IS NULL
 THEN RAISE EXCEPTION 'Post-close install blocked: source functions missing'; END IF;
 IF position('Closed Batch stock is final' in v_before)=0
    OR position('Closed Batch % cannot be changed by Invoice Reversal' in v_after)=0
    OR position('insert into public.sales_returns(' in v_save)=0
    OR position('FROM v_sales_return_stock r' in v_view)=0
 THEN RAISE EXCEPTION 'Post-close install blocked: existing reversal engine differs from reviewed version'; END IF;

 v_patched:=replace(v_before,v_before_old,v_before_new);
 IF v_patched=v_before THEN RAISE EXCEPTION 'Post-close allocator guard anchor missing'; END IF;
 EXECUTE v_patched;

 v_after_anchor:='  if upper('||E'\r\n'||'    coalesce('||E'\r\n'||
 '      v_batch.status,';
 v_inject:='  if exists (select 1 from public.bb_postclose_reversal_routes r '||
 'where r.return_id=new.return_id and r.invoice_id=new.invoice_id '||
 'and r.original_batch_id=v_batch.batch_id) then return new; end if;'||E'\n\n';
 IF position(v_after_anchor in v_after)=0 THEN
    v_after_anchor:='  if upper('||E'\n'||'    coalesce('||E'\n'||'      v_batch.status,';
 END IF;
 IF position(v_after_anchor in v_after)=0
 THEN RAISE EXCEPTION 'Post-close original-stock skip anchor missing'; END IF;
 EXECUTE replace(v_after,v_after_anchor,v_inject||v_after_anchor);

 -- Keep all current Save V2 validations, A/R updates, invoice-ID checks,
 -- stock source rules, and audit behavior, while adding a guarded route stage.
 v_patched:=replace(v_save,
    'public.bb_invoice_reversal_save_by_id_v2(p_payload jsonb)',
    'public.bb_invoice_reversal_postclose_save_v1(p_payload jsonb)');
 IF v_patched=v_save THEN RAISE EXCEPTION 'Cannot clone reversal Save function'; END IF;
 v_patched:=replace(v_patched,
   '  v_payload_count integer;',
   '  v_destinations jsonb;'||E'\n'||'  v_dest jsonb;'||E'\n'||
   '  v_dest_code text;'||E'\n'||'  v_dest_type text;'||E'\n'||
   '  v_dest_batch text;'||E'\n'||'  v_dest_batch_row public.stock_batches%rowtype;'||E'\n'||
   '  v_payload_count integer;');
 IF position('v_destinations jsonb' in v_patched)=0
 THEN RAISE EXCEPTION 'Clone variable insertion failed'; END IF;

 -- Secure each closed source invoice before processing.
 v_inject:=E'\n'||
   '  IF v_invoice.batch_id IS NULL OR NOT EXISTS ('||
   'SELECT 1 FROM public.stock_batches b WHERE b.batch_id=v_invoice.batch_id '||
   'AND upper(b.status)=''CLOSED'') THEN '||
   'RAISE EXCEPTION ''Post-close reversal requires an original Closed Batch''; END IF;'||E'\n'||
   '  IF v_invoice.invoice_no IS DISTINCT FROM v_invoice_no THEN '||
   'RAISE EXCEPTION ''Invoice No / ID mismatch''; END IF;'||E'\n'||
   '  PERFORM pg_advisory_xact_lock(hashtext(''BB_STOCK_WRITE''));'||E'\n';
 IF position('  /* =========================================================='||E'\n'||
   '     DUPLICATE PAYLOAD LINE CHECK' in v_patched)=0
 THEN RAISE EXCEPTION 'Clone validation insertion anchor missing'; END IF;
 v_patched:=replace(v_patched,
    '  /* =========================================================='||E'\n'||
    '     DUPLICATE PAYLOAD LINE CHECK',
    v_inject||'  /* =========================================================='||E'\n'||
    '     DUPLICATE PAYLOAD LINE CHECK');

 -- Validate all selected product routes and target batch statuses.
 -- The existing allocation trigger still decides *how many units of each
 -- real product* are reversed, before the new stock trigger routes them.
 v_inject:=E'\n'||
 '    v_destinations:=v_item->''destinations'';'||E'\n'||
 '    IF jsonb_typeof(v_destinations) IS DISTINCT FROM ''array'' '||
 'OR jsonb_array_length(v_destinations)=0 THEN '||
 'RAISE EXCEPTION ''Select stock destination(s) for each returned product''; END IF;'||E'\n'||
 '    IF (SELECT count(*) FROM jsonb_array_elements(v_destinations)) <> '||
 '(SELECT count(DISTINCT nullif(trim(value->>''productCode''),'''')) '||
 'FROM jsonb_array_elements(v_destinations)) THEN '||
 'RAISE EXCEPTION ''Duplicate or missing product destination''; END IF;'||E'\n'||
 '    FOR v_dest IN SELECT value FROM jsonb_array_elements(v_destinations) LOOP'||E'\n'||
 '      v_dest_code:=nullif(trim(v_dest->>''productCode''),'''');'||E'\n'||
 '      v_dest_type:=upper(trim(coalesce(v_dest->>''destinationType'','''')));'||E'\n'||
 '      v_dest_batch:=nullif(trim(coalesce(v_dest->>''batchId'','''')),'''');'||E'\n'||
 '      IF v_dest_code IS NULL OR v_dest_type NOT IN (''WAREHOUSE'',''OPEN_BATCH'') THEN '||
 'RAISE EXCEPTION ''Invalid stock destination''; END IF;'||E'\n'||
 '      IF upper(coalesce(v_line.entry_type,''EXACT''))=''EXACT'' THEN'||E'\n'||
 '        IF v_dest_code IS DISTINCT FROM v_line.product_code THEN '||
 'RAISE EXCEPTION ''Stock destination product does not match Invoice line''; END IF;'||E'\n'||
 '      ELSIF NOT EXISTS(SELECT 1 FROM jsonb_array_elements('||
 'coalesce(v_line.stock_allocation_json,''[]''::jsonb)) e '||
 'WHERE e->>''productCode''=v_dest_code) THEN '||
 'RAISE EXCEPTION ''Stock destination product is outside Invoice Group''; END IF;'||E'\n'||
 '      IF v_dest_type=''OPEN_BATCH'' THEN'||E'\n'||
 '        SELECT * INTO v_dest_batch_row FROM public.stock_batches b '||
 'WHERE b.batch_id=v_dest_batch FOR UPDATE;'||E'\n'||
 '        IF NOT FOUND OR upper(coalesce(v_dest_batch_row.status,''''))<>''OPEN'' '||
 'OR v_dest_batch_row.location_code IS DISTINCT FROM v_invoice.location_code '||
 'OR v_dest_batch=v_invoice.batch_id THEN '||
 'RAISE EXCEPTION ''Target Batch must be Open in the same location''; END IF;'||E'\n'||
 '        IF NOT EXISTS (SELECT 1 FROM public.stock_batch_items bi WHERE '||
 'bi.batch_id=v_dest_batch AND bi.product_code=v_dest_code) THEN '||
 'RAISE EXCEPTION ''Target Batch does not contain selected product''; END IF;'||E'\n'||
 '      ELSIF v_dest_batch IS NOT NULL THEN '||
 'RAISE EXCEPTION ''Warehouse destination cannot have Batch ID''; END IF;'||E'\n'||
 '    END LOOP;'||E'\n'||
 '    INSERT INTO public.bb_postclose_reversal_routes('||
 'return_id,invoice_id,original_batch_id,destinations,created_by) '||
 'VALUES(v_return_id,v_invoice.invoice_id,v_invoice.batch_id,v_destinations,auth.uid());'||E'\n\n';
 IF position('    insert into public.sales_returns(' in v_patched)=0
 THEN RAISE EXCEPTION 'Clone save-insert marker missing'; END IF;
 v_patched:=replace(v_patched,
    '    insert into public.sales_returns(',
    v_inject||'    insert into public.sales_returns(');
 v_patched:=replace(v_patched,'''Invoice Reversal V2''','''Post-Close Invoice Reversal V1''');
 EXECUTE v_patched;

 -- Reconciliation of the CLOSED ORIGINAL must keep its historical gross
 -- sold stock, since its sold/pending snapshots deliberately stay unchanged.
 -- In A/R & COGS the actual sales_returns rows still apply normally.
 v_patched:=replace(v_view,
   'FROM v_sales_return_stock r'||E'\n'||
   '             JOIN invoices i ON i.invoice_id = r.invoice_id'||E'\n'||
   '          WHERE i.batch_number IS NOT NULL AND i.batch_number <> ''''::text',
   'FROM v_sales_return_stock r'||E'\n'||
   '             JOIN invoices i ON i.invoice_id = r.invoice_id'||E'\n'||
   '          WHERE i.batch_number IS NOT NULL AND i.batch_number <> ''''::text'||E'\n'||
   '            AND NOT EXISTS(SELECT 1 FROM public.bb_postclose_reversal_routes pc '||
   'WHERE pc.return_id=r.return_id)');
 IF v_patched=v_view THEN RAISE EXCEPTION 'Closed Batch reconciliation guard anchor missing'; END IF;
 EXECUTE 'CREATE OR REPLACE VIEW public.v_batch_reconciliation AS '||v_patched;

 IF to_regprocedure('public.bb_invoice_reversal_postclose_save_v1(jsonb)') IS NULL
 THEN RAISE EXCEPTION 'Post-close save RPC missing after install'; END IF;
END;
$postclose_patch$;
REVOKE ALL ON FUNCTION public.bb_invoice_reversal_postclose_save_v1(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bb_invoice_reversal_postclose_save_v1(jsonb) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.bb_postclose_reversal_stock_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.bb_postclose_reversal_stock_v1() TO service_role;

-- Fail closed on unexpected grants.
DO $postclose_security$
BEGIN
 IF has_function_privilege('anon','public.bb_invoice_reversal_postclose_save_v1(jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'Post-close Save improperly exposed to anon'; END IF;
 IF has_table_privilege('authenticated','public.bb_postclose_reversal_routes','INSERT')
 OR has_table_privilege('anon','public.bb_postclose_reversal_routes','INSERT')
 THEN RAISE EXCEPTION 'Post-close staging route writes must be private'; END IF;
END;
$postclose_security$;
