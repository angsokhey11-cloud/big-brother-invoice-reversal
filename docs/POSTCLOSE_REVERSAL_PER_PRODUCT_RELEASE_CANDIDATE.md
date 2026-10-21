# BIG BROTHER — Post-Close Reversal Per-Product Destination V1
QA completed on 2026-10-21 (Supabase isolated staging branch).

## User-approved workflow
- Original CLOSED batch stays closed, its issued and sold snapshots do not change.
- Reversal is keyed by original internal invoice_id and line_id.
- In one reversal action, each original physical product may go to Warehouse (default, configured location) or a user-selected eligible Open batch in the original sale location.
- Purchased and zero-cost sources maintain separate quantity/value buckets.
- Finance, stock, and audit history update in one database transaction or none.

## High-fidelity code testing
Supabase's automatic branch migrations failed because the baseline Live schema was not reproducible from migration history alone. For QA, a new isolated development DB was populated with schema-only copies of 18 relevant Live table structures, nine exact original functions, both stock-return triggers, the exact credit-balance trigger and relevant COGS/reconciliation/stock-ledger views, plus an explicitly identified **synthetic fixture**. Other functions for login/report revision were restricted QA-only stubs. **No production business rows were copied.** This is a focused integration test, not a full replica.

### Database outcomes (all QA-only)
1. Single invoice: 14 AF-2L -> Warehouse and 6 FF-2L -> Open batch. One RPC call, two returns and two stock movements. Source closed batch preserved. Balanced reconciliation.
2. Another invoice: 14 AF-2L -> Open batch and 6 FF-2L -> Warehouse. Fully reversed $85.40 credit; outstanding $0; status Reversed.
3. Historical-cost invoice with original BATCH_SALE stock activity identified by unique BATCH-INVOICE:lineId prefix. Return used original COGS $54.88 + $22.68, **not current stock average**. The daily period COGS report decreased by exactly -$54.88 / -$22.68 at original sales location SR-01.
4. GROUP invoice: AF-2L 6 units (4 purchased, 2 zero-cost) -> Warehouse (4 WAREHOUSE_GOOD and 2 WAREHOUSE_ZERO_COST at PP-01), FF-2L 4 purchased -> BATCH_PENDING at SR-01. All buckets reconciled; original Closed batch preserved; credit balance 0 and status Reversed.
5. Ineligible/Closed target on second line -> whole save failed; returned rows 0, stock movements 0 and invoice reversal amount unchanged.
6. Repeated full reversal -> rejected before any further posting due to zero available qty.
7. Daily COGS includes POSTCLOSE_SALE_RETURN; monthly COGS correctly includes returned units under **existing company monthly weighted-average cost policy** (which is intentionally a different valuation method from daily historical movement value).
8. Read-only stock-ledger check: physical Warehouse location PP-01, COGS sale location SR-01.
9. Read-only options RPC returns default configured Warehouse and only eligible Open batches in original location.
10. Final DDL installation dry-run on Live inside BEGIN/ROLLBACK passed, without modifying Live stock or financial rows.

### Data guards and audit
- Original BATCH_SALE must be attributable to exactly the original invoice **line ID**, product, customer, batch and invoice number via client_request_id; all 1,652 currently recorded BATCH_SALE events in Live carry such line identifiers.
- Missing original sale provenance or purchased cost **rejects** post-close posting instead of estimating current cost.
- Previous returned quantities per original invoice line and source are deducted before restore.
- COGS report adjusted minimally for new movement type, leaving all other report classifications unchanged.
- Private route and allocation ledger tables have RLS FORCE and are not writable by authenticated/anon. The Save RPC retains the existing module/location checks.
- Stock target must be Open in original location, must contain exact product, and must be permitted by source invoice access. Warehouse location must be configured.

### Before staff use
- Apply versioned Cloud migration `sql/20261021_postclose_reversal_per_product_v1.sql`, verify security grants/schema, then merge/reload frontend UI adapter.
- Add same migration with SHA-256 into Dashboard `local-db-migrations/manifest.json`. Use V3.4 Code Sync + Code SQL Migration to enable Local; **do not trigger Cloud-to-Local DB sync just for code**.
- Real signed-in browser acceptance test on a known closed batch before widespread staff use. Do not post synthetic fixtures to Live.
- Staging branch should be deleted after QA to stop its hourly charges.

## Scope
GitHub PR #2. No existing receipt or A/R paid invoice manually rewritten as part of QA. The real `INV-003448` remains to be tested by the operator only after deployment.
