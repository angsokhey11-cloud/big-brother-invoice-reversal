-- Baseline routine/view definitions, captured before Live post-close release.
-- RESTORE ONLY AFTER CONFIRMING ZERO REAL POSTCLOSE REVERSALS.
-- Never drop post-close ledger or change return logic after posting actual returns without a migration-specific accounting rollback plan.

CREATE OR REPLACE FUNCTION public.bb_batch_return_allocate_internal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_invoice public.invoices%rowtype;
  v_line public.invoice_lines%rowtype;
  v_batch public.stock_batches%rowtype;
  v_elem jsonb;
  v_code text;
  v_orig numeric;
  v_prev numeric;
  v_avail numeric;
  v_take numeric;
  v_need numeric:=new.qty;
  v_alloc jsonb:='[]'::jsonb;
begin
  select * into v_invoice from public.invoices where invoice_id=new.invoice_id;
  if not found or v_invoice.batch_id is null then return new; end if;
  perform pg_advisory_xact_lock(hashtext('BB_STOCK_WRITE'));
  select * into v_batch from public.stock_batches where batch_id=v_invoice.batch_id for update;
  if upper(coalesce(v_batch.status,''))='CLOSED' then
    raise exception 'Invoice % belongs to closed Batch %. Closed Batch stock is final; use the dedicated post-close return workflow.',v_invoice.invoice_no,v_batch.batch_id;
  end if;
  if upper(coalesce(v_batch.status,'')) in ('CANCELLED','CANCELED') then raise exception 'Batch % is cancelled',v_batch.batch_id; end if;
  select * into v_line from public.invoice_lines where line_id=new.line_id and invoice_id=new.invoice_id;
  if not found then raise exception 'Invoice line was not found for Batch return'; end if;

  if upper(coalesce(v_line.entry_type,'EXACT'))='EXACT' then
    new.stock_allocation_json:=jsonb_build_array(jsonb_build_object('productCode',v_line.product_code,'qty',new.qty));
    return new;
  end if;

  if jsonb_typeof(coalesce(v_line.stock_allocation_json,'[]'::jsonb))<>'array' then raise exception 'Original Batch Group allocation is missing'; end if;
  for v_elem in select value from jsonb_array_elements(v_line.stock_allocation_json)
  loop
    exit when v_need<=0.000001;
    v_code:=v_elem->>'productCode';
    v_orig:=coalesce(nullif(v_elem->>'qty','')::numeric,0);
    select coalesce(sum(coalesce((a->>'qty')::numeric,0)),0) into v_prev
    from public.sales_returns sr cross join lateral jsonb_array_elements(coalesce(sr.stock_allocation_json,'[]'::jsonb)) a
    where sr.line_id=v_line.line_id and a->>'productCode'=v_code;
    v_avail:=greatest(v_orig-v_prev,0);
    v_take:=least(v_need,v_avail);
    if v_take>0 then v_alloc:=v_alloc||jsonb_build_array(jsonb_build_object('productCode',v_code,'qty',v_take)); v_need:=v_need-v_take; end if;
  end loop;
  if v_need>0.000001 then raise exception 'Return Qty exceeds remaining Batch allocation by %',v_need; end if;
  new.stock_allocation_json:=v_alloc;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.bb_batch_return_stock_internal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare


  v_invoice
    public.invoices%rowtype;


  v_batch
    public.stock_batches%rowtype;


  v_batch_item
    public.stock_batch_items%rowtype;


  v_elem jsonb;


  v_code text;

  v_qty numeric;


  v_purchase_restore numeric;

  v_zero_restore numeric;


  v_movement_id text;

  v_transaction_id text;


  v_name text;

  v_unit text;


  v_purchase_cost numeric;


begin


  select *

  into v_invoice

  from public.invoices

  where invoice_id =
        new.invoice_id;



  if not found

     or

     v_invoice.batch_id is null

  then

    return new;

  end if;



  perform pg_advisory_xact_lock(
    hashtext(
      'BB_STOCK_WRITE'
    )
  );



  select *

  into v_batch

  from public.stock_batches

  where batch_id =
        v_invoice.batch_id

  for update;



  if upper(
    coalesce(
      v_batch.status,
      ''
    )
  ) = 'CLOSED'
  then

    raise exception
      'Closed Batch % cannot be changed by Invoice Reversal',
      v_batch.batch_id;

  end if;



  v_movement_id :=

    public.bb_next_prefixed_id(

      'public.stock_activity'::regclass,

      'movement_id',

      'STK',

      6

    );



  for v_elem in

    select value

    from jsonb_array_elements(

      coalesce(
        new.stock_allocation_json,
        '[]'::jsonb
      )

    )

  loop


    v_code :=
      v_elem->>'productCode';


    v_qty :=
      coalesce(
        nullif(
          v_elem->>'qty',
          ''
        )::numeric,
        0
      );



    select *

    into v_batch_item

    from public.stock_batch_items

    where batch_id =
          v_batch.batch_id

      and product_code =
          v_code

    for update;



    if not found then

      raise exception
        'Return Product % is not in Batch %',
        v_code,
        v_batch.batch_id;

    end if;



    if v_qty >
       v_batch_item.sold_qty_snapshot
       +
       0.000001
    then

      raise exception
        'Return Qty % exceeds Batch sold Qty % for %',
        v_qty,
        v_batch_item.sold_qty_snapshot,
        v_code;

    end if;



    -- Reverse PURCHASED sold units first.
    -- Then ZERO-COST if the return exceeds Purchased Sold.

    v_purchase_restore :=

      least(

        v_qty,

        greatest(
          v_batch_item.purchased_sold_qty_snapshot,
          0
        )

      );


    v_zero_restore :=

      greatest(

        v_qty
        -
        v_purchase_restore,

        0

      );



    if v_zero_restore >
       v_batch_item.zero_cost_sold_qty_snapshot
       +
       0.000001
    then

      raise exception
        '%: Batch sale source reversal mismatch',
        v_code;

    end if;



    update public.stock_batch_items

    set

      sold_qty_snapshot =
        greatest(
          sold_qty_snapshot
          -
          v_qty,
          0
        ),


      pending_qty_snapshot =
        pending_qty_snapshot
        +
        v_qty,


      purchased_sold_qty_snapshot =
        greatest(
          purchased_sold_qty_snapshot
          -
          v_purchase_restore,
          0
        ),


      purchased_pending_qty_snapshot =
        purchased_pending_qty_snapshot
        +
        v_purchase_restore,


      zero_cost_sold_qty_snapshot =
        greatest(
          zero_cost_sold_qty_snapshot
          -
          v_zero_restore,
          0
        ),


      zero_cost_pending_qty_snapshot =
        zero_cost_pending_qty_snapshot
        +
        v_zero_restore,


      source_updated_at =
        now(),


      updated_at =
        now()


    where batch_id =
          v_batch.batch_id

      and product_code =
          v_code;



    select

      coalesce(
        product_name,
        v_code
      ),

      coalesce(
        unit,
        ''
      )

    into
      v_name,
      v_unit

    from public.products

    where product_code =
          v_code;



    -- ========================================================
    -- PURCHASED RESTORE
    -- ========================================================

    if v_purchase_restore > 0 then


      v_purchase_cost :=

        public.bb_stock_average_cost_internal(
          v_code
        );



      v_transaction_id :=

        public.bb_next_prefixed_id(

          'public.stock_activity'::regclass,

          'transaction_id',

          'TRX',

          6

        );



      insert into public.stock_activity(

        transaction_id,

        batch_id,

        activity_date,
        activity_type,

        product_code,
        product_name_snapshot,

        qty,

        unit_snapshot,

        location_code,
        to_location_code,

        salesman_staff_id,
        salesman_name_snapshot,

        reference_no,
        related_invoice_no,

        note,

        source_created_at,

        movement_id,

        flow,
        movement_type,

        from_bucket,
        to_bucket,

        source_entity_type,

        source_id,
        source_name,

        customer_id,
        customer_name_snapshot,

        unit_cost,
        line_value,

        location_name_snapshot,

        client_request_id

      )
      values(

        v_transaction_id,

        v_batch.batch_id,

        new.return_date,
        'Stock In',

        v_code,
        v_name,

        v_purchase_restore,

        v_unit,

        v_batch.location_code,
        v_batch.location_code,

        v_batch.salesman_staff_id,
        v_batch.salesman_name_snapshot,

        new.return_id,
        v_invoice.invoice_no,

        'Invoice Reversal restored PURCHASED stock to live Batch',

        now(),

        v_movement_id,

        'INFLOW',
        'BATCH_SALE_RETURN',

        'EXTERNAL',
        'BATCH_PENDING',

        'CUSTOMER',

        v_invoice.customer_id,
        v_invoice.customer_name_snapshot,

        v_invoice.customer_id,
        v_invoice.customer_name_snapshot,

        v_purchase_cost,

        round(
          v_purchase_restore
          *
          v_purchase_cost,
          6
        ),

        coalesce(
          v_batch.location_name_snapshot,
          v_batch.location_code
        ),

        'BATCH-RETURN:'
        ||
        new.return_id
        ||
        ':'
        ||
        v_code
        ||
        ':PURCHASED'

      );


    end if;



    -- ========================================================
    -- ZERO-COST RESTORE
    -- ========================================================

    if v_zero_restore > 0 then


      v_transaction_id :=

        public.bb_next_prefixed_id(

          'public.stock_activity'::regclass,

          'transaction_id',

          'TRX',

          6

        );



      insert into public.stock_activity(

        transaction_id,

        batch_id,

        activity_date,
        activity_type,

        product_code,
        product_name_snapshot,

        qty,

        unit_snapshot,

        location_code,
        to_location_code,

        salesman_staff_id,
        salesman_name_snapshot,

        reference_no,
        related_invoice_no,

        note,

        source_created_at,

        movement_id,

        flow,
        movement_type,

        from_bucket,
        to_bucket,

        source_entity_type,

        source_id,
        source_name,

        customer_id,
        customer_name_snapshot,

        unit_cost,
        line_value,

        location_name_snapshot,

        client_request_id

      )
      values(

        v_transaction_id,

        v_batch.batch_id,

        new.return_date,
        'Stock In',

        v_code,
        v_name,

        v_zero_restore,

        v_unit,

        v_batch.location_code,
        v_batch.location_code,

        v_batch.salesman_staff_id,
        v_batch.salesman_name_snapshot,

        new.return_id,
        v_invoice.invoice_no,

        'Invoice Reversal restored ZERO-COST stock to live Batch',

        now(),

        v_movement_id,

        'INFLOW',
        'BATCH_SALE_RETURN',

        'EXTERNAL',
        'BATCH_ZERO_COST',

        'CUSTOMER',

        v_invoice.customer_id,
        v_invoice.customer_name_snapshot,

        v_invoice.customer_id,
        v_invoice.customer_name_snapshot,

        0,
        0,

        coalesce(
          v_batch.location_name_snapshot,
          v_batch.location_code
        ),

        'BATCH-RETURN:'
        ||
        new.return_id
        ||
        ':'
        ||
        v_code
        ||
        ':ZERO'

      );


    end if;


  end loop;



  update public.stock_batches

  set

    sold_qty =

      (

        select coalesce(
          sum(
            sold_qty_snapshot
          ),
          0
        )

        from public.stock_batch_items

        where batch_id =
              v_batch.batch_id

      ),


    updated_at =
      now(),


    source_updated_at =
      now()


  where batch_id =
        v_batch.batch_id;



  perform public.bb_stock_refresh_batch_status_internal(
    v_batch.batch_id
  );



  perform public.bb_stock_touch_revision_internal();


  return new;


end;

$function$;

CREATE OR REPLACE FUNCTION public.bb_cogs_period_rows_internal(p_start_date date, p_end_date_exclusive date)
 RETURNS TABLE(report_date date, location_code text, location_name text, product_code text, product_name text, unit text, purchased_sold_qty_gross numeric, zero_cost_sold_qty_gross numeric, total_sold_qty_gross numeric, purchased_return_qty numeric, zero_cost_return_qty numeric, total_return_qty numeric, purchased_sold_qty numeric, zero_cost_sold_qty numeric, total_sold_qty numeric, cogs_usd numeric, purchased_unit_cost numeric, transaction_count integer, missing_cost_row_count integer, missing_cost_qty numeric, unknown_source_row_count integer, unknown_source_qty numeric, zero_cost_nonzero_value_row_count integer, zero_cost_nonzero_value_usd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$


with


-- ============================================================
-- RAW SALE / RETURN STOCK ACTIVITY
-- ============================================================

raw_activity as (

  select


    a.transaction_id,

    a.activity_date,

    a.movement_type,

    a.flow,

    a.from_bucket,

    a.to_bucket,


    coalesce(

      nullif(
        trim(
          a.location_code
        ),
        ''
      ),

      'UNASSIGNED'

    )
    as report_location_code,


    coalesce(

      nullif(
        trim(
          l.location_name
        ),
        ''
      ),

      nullif(
        trim(
          a.location_name_snapshot
        ),
        ''
      ),

      nullif(
        trim(
          a.location_code
        ),
        ''
      ),

      'Unassigned Location'

    )
    as report_location_name,


    coalesce(

      nullif(
        trim(
          a.product_code
        ),
        ''
      ),

      'UNKNOWN'

    )
    as report_product_code,


    coalesce(

      nullif(
        trim(
          p.product_name
        ),
        ''
      ),

      nullif(
        trim(
          a.product_name_snapshot
        ),
        ''
      ),

      nullif(
        trim(
          a.product_code
        ),
        ''
      ),

      'Unknown Product'

    )
    as report_product_name,


    coalesce(

      nullif(
        trim(
          p.unit
        ),
        ''
      ),

      nullif(
        trim(
          a.unit_snapshot
        ),
        ''
      ),

      ''

    )
    as report_unit,


    coalesce(
      a.qty,
      0
    )::numeric
    as qty,


    a.unit_cost,


    a.line_value,


    -- ========================================================
    -- EVENT
    -- ========================================================

    case


      when

        upper(
          coalesce(
            a.movement_type,
            ''
          )
        )

        in (

          'BATCH_SALE',

          'DIRECT_SALE'

        )

        and

        upper(
          coalesce(
            a.flow,
            ''
          )
        )
        =
        'OUTFLOW'

        and

        upper(
          coalesce(
            a.to_bucket,
            ''
          )
        )
        =
        'EXTERNAL'

      then
        'SALE'


      when

        upper(
          coalesce(
            a.movement_type,
            ''
          )
        )

        in (

          'BATCH_SALE_RETURN',

          'DIRECT_SALE_RETURN'

        )

        and

        upper(
          coalesce(
            a.flow,
            ''
          )
        )
        =
        'INFLOW'

        and

        upper(
          coalesce(
            a.from_bucket,
            ''
          )
        )
        =
        'EXTERNAL'

      then
        'RETURN'


      else
        'IGNORE'


    end
    as event_kind,


    -- ========================================================
    -- INVENTORY SOURCE
    -- ========================================================

    case


      -- ------------------------------------------------------
      -- PURCHASED SALE
      -- ------------------------------------------------------

      when

        upper(
          coalesce(
            a.movement_type,
            ''
          )
        )

        in (

          'BATCH_SALE',

          'DIRECT_SALE'

        )

        and

        upper(
          coalesce(
            a.from_bucket,
            ''
          )
        )

        in (

          'BATCH_PENDING',

          'WAREHOUSE_GOOD'

        )

      then
        'PURCHASED'


      -- ------------------------------------------------------
      -- ZERO-COST SALE
      -- ------------------------------------------------------

      when

        upper(
          coalesce(
            a.movement_type,
            ''
          )
        )

        in (

          'BATCH_SALE',

          'DIRECT_SALE'

        )

        and

        upper(
          coalesce(
            a.from_bucket,
            ''
          )
        )

        in (

          'BATCH_ZERO_COST',

          'WAREHOUSE_ZERO_COST'

        )

      then
        'ZERO_COST'


      -- ------------------------------------------------------
      -- PURCHASED RETURN
      -- ------------------------------------------------------

      when

        upper(
          coalesce(
            a.movement_type,
            ''
          )
        )

        in (

          'BATCH_SALE_RETURN',

          'DIRECT_SALE_RETURN'

        )

        and

        upper(
          coalesce(
            a.to_bucket,
            ''
          )
        )

        in (

          'BATCH_PENDING',

          'WAREHOUSE_GOOD'

        )

      then
        'PURCHASED'


      -- ------------------------------------------------------
      -- ZERO-COST RETURN
      -- ------------------------------------------------------

      when

        upper(
          coalesce(
            a.movement_type,
            ''
          )
        )

        in (

          'BATCH_SALE_RETURN',

          'DIRECT_SALE_RETURN'

        )

        and

        upper(
          coalesce(
            a.to_bucket,
            ''
          )
        )

        in (

          'BATCH_ZERO_COST',

          'WAREHOUSE_ZERO_COST'

        )

      then
        'ZERO_COST'


      else
        'UNKNOWN'


    end
    as inventory_source


  from public.stock_activity a


  left join public.locations l

    on l.location_code =
       a.location_code


  left join public.products p

    on p.product_code =
       a.product_code


  where

    a.activity_date >=
      p_start_date


    and

    a.activity_date <
      p_end_date_exclusive


    and

    upper(
      coalesce(
        a.movement_type,
        ''
      )
    )

    in (

      'BATCH_SALE',

      'DIRECT_SALE',

      'BATCH_SALE_RETURN',

      'DIRECT_SALE_RETURN'

    )

),



-- ============================================================
-- VALID REPORT EVENTS
-- ============================================================

classified as (

  select


    r.*,


    -- ========================================================
    -- MISSING PURCHASED COST
    --
    -- Purchased source with $0 cost is NOT automatically
    -- Zero-Cost stock.
    --
    -- It is a data-quality warning.
    -- ========================================================

    case

      when

        r.event_kind
        in (
          'SALE',
          'RETURN'
        )

        and

        r.inventory_source =
          'PURCHASED'

        and

        r.qty >
          0

        and

        (

          r.unit_cost is null

          or

          r.unit_cost <= 0

          or

          r.line_value is null

          or

          r.line_value <= 0

        )

      then
        1

      else
        0

    end
    as missing_cost_flag,


    -- ========================================================
    -- UNKNOWN SOURCE
    -- ========================================================

    case

      when

        r.event_kind
        in (
          'SALE',
          'RETURN'
        )

        and

        r.inventory_source =
          'UNKNOWN'

      then
        1

      else
        0

    end
    as unknown_source_flag,


    -- ========================================================
    -- ZERO-COST MUST ALWAYS HAVE $0 INVENTORY VALUE
    -- ========================================================

    case

      when

        r.event_kind
        in (
          'SALE',
          'RETURN'
        )

        and

        r.inventory_source =
          'ZERO_COST'

        and

        abs(
          coalesce(
            r.line_value,
            0
          )
        )
        >
        0.000001

      then
        1

      else
        0

    end
    as zero_cost_nonzero_value_flag


  from raw_activity r


  where

    r.event_kind
    <>
    'IGNORE'

),



-- ============================================================
-- SKU / LOCATION / DATE AGGREGATION
-- ============================================================

aggregated as (

  select


    c.activity_date
    as report_date,


    c.report_location_code
    as location_code,


    c.report_location_name
    as location_name,


    c.report_product_code
    as product_code,


    max(
      c.report_product_name
    )
    as product_name,


    max(
      c.report_unit
    )
    as unit,


    -- ========================================================
    -- GROSS SALES
    -- ========================================================

    sum(

      case

        when

          c.event_kind =
            'SALE'

          and

          c.inventory_source =
            'PURCHASED'

        then
          c.qty

        else
          0

      end

    )::numeric
    as purchased_sold_qty_gross,


    sum(

      case

        when

          c.event_kind =
            'SALE'

          and

          c.inventory_source =
            'ZERO_COST'

        then
          c.qty

        else
          0

      end

    )::numeric
    as zero_cost_sold_qty_gross,


    -- ========================================================
    -- RETURNS
    -- ========================================================

    sum(

      case

        when

          c.event_kind =
            'RETURN'

          and

          c.inventory_source =
            'PURCHASED'

        then
          c.qty

        else
          0

      end

    )::numeric
    as purchased_return_qty,


    sum(

      case

        when

          c.event_kind =
            'RETURN'

          and

          c.inventory_source =
            'ZERO_COST'

        then
          c.qty

        else
          0

      end

    )::numeric
    as zero_cost_return_qty,


    -- ========================================================
    -- COGS
    --
    -- SALE PURCHASED VALUE
    -- MINUS
    -- PURCHASED RETURN VALUE
    -- ========================================================

    sum(

      case

        when

          c.event_kind =
            'SALE'

          and

          c.inventory_source =
            'PURCHASED'

        then
          coalesce(
            c.line_value,
            0
          )

        when

          c.event_kind =
            'RETURN'

          and

          c.inventory_source =
            'PURCHASED'

        then
          -
          coalesce(
            c.line_value,
            0
          )

        else
          0

      end

    )::numeric
    as net_cogs_usd,


    count(*)::integer
    as transaction_count,


    sum(
      c.missing_cost_flag
    )::integer
    as missing_cost_row_count,


    sum(

      case

        when
          c.missing_cost_flag = 1

        then
          c.qty

        else
          0

      end

    )::numeric
    as missing_cost_qty,


    sum(
      c.unknown_source_flag
    )::integer
    as unknown_source_row_count,


    sum(

      case

        when
          c.unknown_source_flag = 1

        then
          c.qty

        else
          0

      end

    )::numeric
    as unknown_source_qty,


    sum(
      c.zero_cost_nonzero_value_flag
    )::integer
    as zero_cost_nonzero_value_row_count,


    sum(

      case

        when
          c.zero_cost_nonzero_value_flag = 1

        then
          abs(
            coalesce(
              c.line_value,
              0
            )
          )

        else
          0

      end

    )::numeric
    as zero_cost_nonzero_value_usd


  from classified c


  group by

    c.activity_date,

    c.report_location_code,

    c.report_location_name,

    c.report_product_code

)



-- ============================================================
-- FINAL PERIOD ROWS
-- ============================================================

select


  a.report_date,


  a.location_code,


  a.location_name,


  a.product_code,


  a.product_name,


  a.unit,


  round(
    a.purchased_sold_qty_gross,
    6
  )
  as purchased_sold_qty_gross,


  round(
    a.zero_cost_sold_qty_gross,
    6
  )
  as zero_cost_sold_qty_gross,


  round(

    a.purchased_sold_qty_gross

    +

    a.zero_cost_sold_qty_gross,

    6

  )
  as total_sold_qty_gross,


  round(
    a.purchased_return_qty,
    6
  )
  as purchased_return_qty,


  round(
    a.zero_cost_return_qty,
    6
  )
  as zero_cost_return_qty,


  round(

    a.purchased_return_qty

    +

    a.zero_cost_return_qty,

    6

  )
  as total_return_qty,


  -- ==========================================================
  -- NET PURCHASED SOLD
  -- ==========================================================

  round(

    a.purchased_sold_qty_gross

    -

    a.purchased_return_qty,

    6

  )
  as purchased_sold_qty,


  -- ==========================================================
  -- NET ZERO-COST SOLD
  -- ==========================================================

  round(

    a.zero_cost_sold_qty_gross

    -

    a.zero_cost_return_qty,

    6

  )
  as zero_cost_sold_qty,


  -- ==========================================================
  -- NET TOTAL SOLD
  -- ==========================================================

  round(

    (

      a.purchased_sold_qty_gross

      -

      a.purchased_return_qty

    )

    +

    (

      a.zero_cost_sold_qty_gross

      -

      a.zero_cost_return_qty

    ),

    6

  )
  as total_sold_qty,


  -- ==========================================================
  -- COGS
  -- ==========================================================

  round(
    a.net_cogs_usd,
    2
  )
  as cogs_usd,


  -- ==========================================================
  -- DISPLAY COST
  --
  -- Weighted Purchased Cost for the resulting NET quantity.
  -- ==========================================================

  case

    when

      abs(

        a.purchased_sold_qty_gross

        -

        a.purchased_return_qty

      )
      >
      0.000001

    then

      round(

        a.net_cogs_usd

        /

        (

          a.purchased_sold_qty_gross

          -

          a.purchased_return_qty

        ),

        6

      )

    else
      0::numeric

  end
  as purchased_unit_cost,


  a.transaction_count,


  a.missing_cost_row_count,


  round(
    a.missing_cost_qty,
    6
  )
  as missing_cost_qty,


  a.unknown_source_row_count,


  round(
    a.unknown_source_qty,
    6
  )
  as unknown_source_qty,


  a.zero_cost_nonzero_value_row_count,


  round(
    a.zero_cost_nonzero_value_usd,
    2
  )
  as zero_cost_nonzero_value_usd


from aggregated a;


$function$;

CREATE OR REPLACE VIEW public.v_batch_reconciliation AS
 WITH gross AS (
         SELECT i.batch_number AS batch_id,
            s_1.product_code,
            sum(s_1.qty) AS invoice_sold_qty
           FROM v_invoice_stock_sales s_1
             JOIN invoices i ON i.invoice_id = s_1.invoice_id
          WHERE i.batch_number IS NOT NULL AND i.batch_number <> ''::text
          GROUP BY i.batch_number, s_1.product_code
        ), returned AS (
         SELECT i.batch_number AS batch_id,
            r.product_code,
            sum(r.qty) AS return_qty
           FROM v_sales_return_stock r
             JOIN invoices i ON i.invoice_id = r.invoice_id
          WHERE i.batch_number IS NOT NULL AND i.batch_number <> ''::text
          GROUP BY i.batch_number, r.product_code
        ), sold AS (
         SELECT g.batch_id,
            g.product_code,
            GREATEST(g.invoice_sold_qty - COALESCE(r.return_qty, 0::numeric), 0::numeric) AS invoice_sold_qty
           FROM gross g
             LEFT JOIN returned r ON r.batch_id = g.batch_id AND r.product_code = g.product_code
        )
 SELECT bi.batch_id,
    b.batch_date,
    b.status AS batch_status,
    b.location_code,
    b.salesman_staff_id,
    b.salesman_name_snapshot,
    bi.product_code,
    p.product_name,
    p.unit,
    bi.issued_qty,
    COALESCE(s.invoice_sold_qty, 0::numeric) AS invoice_sold_qty,
    bi.back_sale_qty,
    bi.damaged_qty,
    bi.other_out_qty,
    bi.issued_qty - COALESCE(s.invoice_sold_qty, 0::numeric) - bi.back_sale_qty - bi.damaged_qty - bi.other_out_qty AS difference_qty,
        CASE
            WHEN abs(bi.pending_qty_snapshot - (bi.issued_qty - COALESCE(s.invoice_sold_qty, 0::numeric) - bi.back_sale_qty - bi.damaged_qty - bi.other_out_qty)) < 0.0000001 THEN 'Balanced'::text
            ELSE 'Mismatch'::text
        END AS reconciliation_status
   FROM stock_batch_items bi
     JOIN stock_batches b ON b.batch_id = bi.batch_id
     LEFT JOIN sold s ON s.batch_id = bi.batch_id AND s.product_code = bi.product_code
     LEFT JOIN products p ON p.product_code = bi.product_code;
;
