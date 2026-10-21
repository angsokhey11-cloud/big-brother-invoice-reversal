# BIG BROTHER Invoice Reversal — full-history invoice search (2026-10-21)

## Root cause
The original reversal UI loaded `bb_invoice_reversal_recent_v2(p_limit=50)`, which has a server-side cap of 100, and filtered only those already loaded rows. An older invoice such as INV-003448 (24-Sep-2026) was beyond the recent list despite existing in `public.invoices`.

## Code
- New RPC: `public.bb_invoice_reversal_search_v2(p_query text, p_limit integer DEFAULT 50)`.
- Searches all accessible invoices on the server *before* limiting the returned choices; supports invoice number, customer, date, or location keywords. Maximum 50 choices, with a `totalMatches` count.
- Uses the existing `bb_has_module_access('invoice_reversal','view')` and per-record `bb_has_location_access` guards, requires an authenticated JWT, and grants EXECUTE only to authenticated/service_role.
- Typed invoice numbers use this RPC to locate the **exact** invoice and its unique `invoiceId`. Duplicate display invoice numbers require customer/date selection and never arbitrarily choose a row.
- All stock source calculations, reversal save RPCs, and Reversal History remain unchanged.

## Cloud rollout
Cloud migration `invoice_reversal_search_all_history_20261021` was applied through Supabase, and execution privileges checked. The UI's adapter query version is `20261021-allhistory1`.

## Local Brain rollout
The same SQL is registered in the Dashboard repository:
`local-db-migrations/20261021_invoice_reversal_search_v2.sql`.
First run **Code Sync** to download the latest GitHub UI/SQL, then use the V3.4 **Code SQL Migration** operation to add the new read-only RPC to Local PostgreSQL (the migration runner may need previously pending migrations resolved; do not bypass failed safeguards).

Do **not** use Cloud-to-Local customer data sync merely for this code fix.

## Checks
- Database contains 1 matching INV-003448 with invoice lines (observed 2026-10-21).
- Function exists; anonymous EXECUTE revoked; authenticated EXECUTE permitted.
- Simulated UI loads old invoice by stable ID; duplicate numbers open selection instead of loading wrong customer.
- Real signed-in web and offline Local Brain acceptance tests still required.
