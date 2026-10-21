-- BIG BROTHER Invoice Reversal — authorized search across full invoice history.
-- 2026-10-21. Adds one read-only RPC; preserves every existing reversal/save function.
-- Safe on Cloud and Local Brain. No business records are changed.
CREATE OR REPLACE FUNCTION public.bb_invoice_reversal_search_v2(
  p_query text,
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $bb_reversal_search$
DECLARE
  v_query text := trim(coalesce(p_query, ''));
  v_lower text := lower(trim(coalesce(p_query, '')));
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 50);
  v_invoices jsonb := '[]'::jsonb;
  v_total integer := 0;
BEGIN
  -- SECURITY DEFINER means authentication AND module/location checks are mandatory.
  IF auth.uid() IS NULL
     OR NOT public.bb_has_module_access('invoice_reversal', 'view') THEN
    RAISE EXCEPTION 'Invoice Reversal access denied';
  END IF;
  IF v_query = '' THEN
    RETURN jsonb_build_object('success', true, 'invoices', v_invoices, 'totalMatches', 0);
  END IF;

  WITH permitted AS (
    SELECT
      i.invoice_id,
      i.invoice_no,
      i.invoice_date,
      coalesce(i.customer_name_snapshot, '') AS customer_name_snapshot,
      i.location_code,
      i.batch_id,
      CASE
        WHEN lower(coalesce(i.invoice_no,'')) = v_lower THEN 0
        WHEN left(lower(coalesce(i.invoice_no,'')), char_length(v_lower)) = v_lower THEN 1
        ELSE 2
      END AS match_rank
    FROM public.invoices i
    WHERE public.bb_has_location_access(i.location_code)
      AND EXISTS (
        SELECT 1 FROM public.invoice_lines il WHERE il.invoice_id = i.invoice_id
      )
      AND (
        position(v_lower in lower(coalesce(i.invoice_no,''))) > 0
        OR position(v_lower in lower(coalesce(i.customer_name_snapshot,''))) > 0
        OR position(v_lower in lower(coalesce(i.location_code,''))) > 0
        OR position(v_lower in lower(i.invoice_date::text)) > 0
      )
  ),
  numbered AS (
    SELECT p.*, count(*) OVER () AS total_matches
    FROM permitted p
  ),
  picked AS (
    SELECT *
    FROM numbered
    ORDER BY match_rank, invoice_date DESC, invoice_no DESC, invoice_id
    LIMIT v_limit
  ),
  balances AS (
    SELECT p.*,
      coalesce((
        SELECT sum(
          coalesce(il.qty,0) - coalesce((
            SELECT sum(sr.qty)
            FROM public.sales_returns sr
            WHERE sr.line_id = il.line_id
          ),0)
        )
        FROM public.invoice_lines il
        WHERE il.invoice_id = p.invoice_id
      ),0) AS remaining_qty
    FROM picked p
  )
  SELECT
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'invoiceId', b.invoice_id,
          'invoiceNo', b.invoice_no,
          'invoiceDate', b.invoice_date::text,
          'customer', b.customer_name_snapshot,
          'locationCode', b.location_code,
          'saleMode', CASE WHEN b.batch_id IS NULL THEN 'DIRECT' ELSE 'BATCH' END,
          'remainingQty', b.remaining_qty,
          'fullyReversed', b.remaining_qty <= 0.000001
        )
        ORDER BY b.match_rank, b.invoice_date DESC, b.invoice_no DESC, b.invoice_id
      ),
      '[]'::jsonb
    ),
    coalesce(max(b.total_matches),0)::integer
  INTO v_invoices, v_total
  FROM balances b;

  RETURN jsonb_build_object(
    'success', true,
    'version', 'INVOICE-REVERSAL-V2',
    'invoices', v_invoices,
    'totalMatches', v_total
  );
END;
$bb_reversal_search$;

-- Never expose SECURITY DEFINER RPCs through implicit PUBLIC/anon grants.
REVOKE ALL ON FUNCTION public.bb_invoice_reversal_search_v2(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bb_invoice_reversal_search_v2(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.bb_invoice_reversal_search_v2(text, integer) TO authenticated, service_role;

-- Postinstall checks (read-only).
DO $bb_reversal_verify$
BEGIN
 IF to_regprocedure('public.bb_invoice_reversal_search_v2(text,integer)') IS NULL THEN
   RAISE EXCEPTION 'Invoice Reversal search RPC installation failed';
 END IF;
 IF has_function_privilege('anon','public.bb_invoice_reversal_search_v2(text,integer)','EXECUTE') THEN
   RAISE EXCEPTION 'Invoice Reversal search security failure: anon EXECUTE is enabled';
 END IF;
 IF NOT has_function_privilege('authenticated','public.bb_invoice_reversal_search_v2(text,integer)','EXECUTE') THEN
   RAISE EXCEPTION 'Invoice Reversal search security failure: authenticated EXECUTE missing';
 END IF;
END;
$bb_reversal_verify$;
