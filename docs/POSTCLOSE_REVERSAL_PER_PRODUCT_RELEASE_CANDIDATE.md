# BIG BROTHER — Post-Close Invoice Reversal, Per-Product Destination (release candidate)

## Agreed user workflow
- When the source invoice belongs to a **Closed** batch, preserve the original batch and select the physical stock destination for **each** reversed product.
- Default each product to **Warehouse (from stock_cutover_state.default_warehouse_location_code)**.
- Alternatives are **eligible Open batches in the same original location that already contain that product**.
- Different products in ONE invoice/reversal may go to different destinations.
- Preserve Purchased/Zero-Cost classification, undo A/R and COGS once, retain a permanent audit trail and block double reversals.
- Existing open-batch and direct-sale reversals must retain their old pathways.

## Data design
SQL candidate: `sql/20261021_postclose_reversal_per_product_v1.sql`

- `bb_postclose_reversal_routes`: one protected routing plan per return ID, original closed batch recorded.
- `bb_postclose_reversal_allocations`: physical product, quantity, original cost category, stock movement ID, destination.
- `bb_invoice_reversal_postclose_options_v1`: read-only, checks view permission and permitted location.
- `bb_invoice_reversal_postclose_save_v1`: independent clone of the existing V2 validation/accounting/audit path plus per-line destination plan.
- Existing Batch return triggers skip restoring **the Closed source batch only for a matching private route record**.
- New stock trigger returns products to WAREHOUSE_GOOD / WAREHOUSE_ZERO_COST (default warehouse) or BATCH_PENDING / BATCH_ZERO_COST (selected open batch).
- `v_batch_reconciliation` excludes postclose return quantities from the *source Closed batch's physical snapshot* but the standard Sales Returns / invoice reversal amount remains available for accounting and COGS calculations.

## Verified
- PostgreSQL compatibility issue `max(jsonb)` repaired to `(jsonb_agg(value))->0` and its single-product lookup tested read-only.
- Schema installation inside BEGIN / ROLLBACK succeeded, with new route tables, trigger and Save/Options RPCs detected. This dry run was rolled back and left Live schema unchanged.
- Frontend JS syntax check passed.
- UI unit tests: exact product, GROUP products, Warehouse default, mixed Warehouse/Open Batch destinations, and reject ineligible batch.
- Existing closed source batch BAT-000002 is currently balanced. Requested sample target BAT-000032 is Open, in the same location and contains both products.

## Incomplete / release blockers
- **NO successful end-to-end posting test**. A proposed live-database reversal test with ROLLBACK was blocked, so it was NOT performed. Do not claim the workflow is tested or release-ready.
- A dedicated staging database (Supabase development branch, which incurs a charge and needs user's explicit approval) or a controlled local disposable test DB is required for integrated writes.
- Validate every quantity/cost category, both destination paths, A/R, COGS reports, closed-source reconciliation, physical ledger, UI receipt, duplicate attempts, rolled-back error cases and triggers with staff module/location permissions.
- Existing `bb_notify_batch_route_overdue` may request a Telegram alert when the chosen target batch is updated (pg_net requests are sent only after COMMIT). Verify expected notifications on staging.
- Validate compatibility with Local Brain SQL migration and Schema Guard before Local rollout.
- No live schema, operational stock, A/R, or inventory rows have been changed by this draft.

## Test fixtures (staging ONLY)
- Invoice ID `BB-20260924-122528-216` / Invoice No. `INV-003448` on CLOSED `BAT-000002`, SR-01, 14 AF-2L + 6 FF-2L, total $85.40.
- Suggested destination: 14 AF-2L -> warehouse PP-01; 6 FF-2L -> open `BAT-000032` (on a staging snapshot ONLY).
- Expected before->after: two sales_returns rows; two positive stock activity movements; batch BAT-000002 snapshots unchanged; BAT-000032 issued/pending +6 FF-2L; warehouse GOOD +14 AF-2L; A/R reversal_amount 85.40; both batch reconciliations balanced; one combined reversal receipt.

## Release instructions
Do **not** merge this feature branch or apply the SQL on Live until the test matrix passes. Once it passes, apply SQL on Cloud with a versioned migration, merge the UI/adapter, then mirror the SQL into Dashboard Local Code SQL Migration manifest with verified SHA-256. Do Code Sync + SQL Migration (not Cloud->Local business-data sync).
