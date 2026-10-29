-- Run as the authenticated application user: RLS applies before aggregation.
-- Monthly boundaries are explicit, rather than depending on the database server timezone.
-- Choose the reporting timezone for the user before using this in a product report.
SELECT
    date_trunc('month', date AT TIME ZONE 'Europe/Madrid')::date AS month,
    sum(amount_minor) AS actual_expense_minor,
    sum(coalesce(reserved_amount_minor, 0)) AS reserved_expense_minor,
    sum(amount_minor - coalesce(reserved_amount_minor, 0)) AS monthly_budget_expense_minor
FROM public.finance_transactions
WHERE workspace_id = :'workspace_id'::uuid
  AND owner_id = auth.uid()
  AND deleted_at IS NULL
  AND type IN ('expense', 'fee')
GROUP BY 1
ORDER BY 1;
