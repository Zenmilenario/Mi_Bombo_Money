-- Read-only audit: no names, emails, descriptions, tokens or monetary values.
-- Intended for the project administrator in the Supabase SQL editor.
WITH counts AS (
SELECT 'institutions' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_institutions
UNION ALL
SELECT 'accounts' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_accounts
UNION ALL
SELECT 'categories' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_categories
UNION ALL
SELECT 'cards' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_cards
UNION ALL
SELECT 'reservedFunds' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_reserved_funds
UNION ALL
SELECT 'categoryRules' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_category_rules
UNION ALL
SELECT 'recurringBudgets' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_recurring_budgets
UNION ALL
SELECT 'budgets' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_monthly_budgets
UNION ALL
SELECT 'goals' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_savings_goals
UNION ALL
SELECT 'recurringMovements' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_recurring_movements
UNION ALL
SELECT 'importBatches' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_import_batches
UNION ALL
SELECT 'snapshots' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_balance_snapshots
UNION ALL
SELECT 'transactions' AS entidad,count(*) FILTER(WHERE deleted_at IS NULL) AS activos,count(*) FILTER(WHERE deleted_at IS NOT NULL) AS eliminados,max(updated_at) AS ultima_escritura FROM public.finance_transactions
), missing_links AS (
SELECT count(*) AS n FROM public.finance_accounts c WHERE c.deleted_at IS NULL AND c.institution_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_institutions p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.institution_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_cards c WHERE c.deleted_at IS NULL AND c.institution_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_institutions p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.institution_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_cards c WHERE c.deleted_at IS NULL AND c.linked_account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.linked_account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_reserved_funds c WHERE c.deleted_at IS NULL AND c.account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_category_rules c WHERE c.deleted_at IS NULL AND c.category_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_categories p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.category_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_recurring_budgets c WHERE c.deleted_at IS NULL AND c.category_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_categories p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.category_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_monthly_budgets c WHERE c.deleted_at IS NULL AND c.category_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_categories p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.category_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_savings_goals c WHERE c.deleted_at IS NULL AND c.linked_account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.linked_account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_recurring_movements c WHERE c.deleted_at IS NULL AND c.source_account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.source_account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_recurring_movements c WHERE c.deleted_at IS NULL AND c.destination_account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.destination_account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_recurring_movements c WHERE c.deleted_at IS NULL AND c.category_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_categories p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.category_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_balance_snapshots c WHERE c.deleted_at IS NULL AND c.account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_transactions c WHERE c.deleted_at IS NULL AND c.source_account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.source_account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_transactions c WHERE c.deleted_at IS NULL AND c.destination_account_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_accounts p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.destination_account_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_transactions c WHERE c.deleted_at IS NULL AND c.category_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_categories p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.category_id AND p.deleted_at IS NULL)
UNION ALL
SELECT count(*) AS n FROM public.finance_transactions c WHERE c.deleted_at IS NULL AND c.reserved_fund_id IS NOT NULL AND NOT EXISTS(SELECT FROM public.finance_reserved_funds p WHERE p.owner_id=c.owner_id AND p.workspace_id=c.workspace_id AND p.id=c.reserved_fund_id AND p.deleted_at IS NULL)
)
SELECT jsonb_pretty(jsonb_build_object(
 'usuarios',(SELECT count(*) FROM auth.users),
 'usuarios_confirmados',(SELECT count(*) FROM auth.users WHERE email_confirmed_at IS NOT NULL),
 'ultimo_acceso',(SELECT to_char(max(last_sign_in_at) AT TIME ZONE 'Europe/Madrid','YYYY-MM-DD HH24:MI:SS') FROM auth.users),
 'espacios',(SELECT coalesce(jsonb_agg(jsonb_build_object('tipo',w.kind,'revision',w.revision,
    'ultima_escritura',to_char(w.updated_at AT TIME ZONE 'Europe/Madrid','YYYY-MM-DD HH24:MI:SS'),
    'cuentas',(SELECT count(*) FROM public.finance_accounts a WHERE a.owner_id=w.owner_id AND a.workspace_id=w.id AND a.deleted_at IS NULL),
    'movimientos',(SELECT count(*) FROM public.finance_transactions t WHERE t.owner_id=w.owner_id AND t.workspace_id=w.id AND t.deleted_at IS NULL))), '[]'::jsonb)
    FROM public.finance_workspaces w WHERE w.deleted_at IS NULL),
 'tablas',(SELECT jsonb_agg(jsonb_build_object('entidad',entidad,'activos',activos,'eliminados',eliminados,'ultima_escritura',to_char(ultima_escritura AT TIME ZONE 'Europe/Madrid','YYYY-MM-DD HH24:MI:SS')) ORDER BY entidad) FROM counts),
 'relaciones_activas_ausentes',(SELECT sum(n) FROM missing_links),
 'reservas_incoherentes',(SELECT count(*) FROM public.finance_reserved_funds r WHERE r.deleted_at IS NULL AND
    coalesce((SELECT sum(t.reserved_amount_minor) FROM public.finance_transactions t WHERE t.owner_id=r.owner_id AND t.workspace_id=r.workspace_id AND t.reserved_fund_id=r.id AND t.deleted_at IS NULL),0)>r.amount_minor),
 'pagos_reservados_en_otra_cuenta',(SELECT count(*) FROM public.finance_transactions t JOIN public.finance_reserved_funds r ON r.owner_id=t.owner_id AND r.workspace_id=t.workspace_id AND r.id=t.reserved_fund_id WHERE t.deleted_at IS NULL AND t.source_account_id IS DISTINCT FROM r.account_id),
 'identificadores_bancarios_duplicados',(SELECT count(*) FROM (SELECT 1 FROM public.finance_transactions WHERE deleted_at IS NULL AND external_id IS NOT NULL GROUP BY owner_id,workspace_id,source_account_id,external_id HAVING count(*)>1) d),
 'ejecuciones_periodicas_repetidas',(SELECT count(*) FROM (SELECT 1 FROM public.finance_transactions WHERE deleted_at IS NULL AND recurring_movement_id IS NOT NULL GROUP BY owner_id,workspace_id,recurring_movement_id,(date AT TIME ZONE 'UTC')::date HAVING count(*)>1) d),
 'rls_habilitado_y_forzado',(SELECT bool_and(relrowsecurity AND relforcerowsecurity) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname LIKE 'finance_%' AND relkind='r'),
 'funciones_sync_sin_elevacion',(SELECT count(*)=2 AND bool_and(NOT prosecdef) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('finance_snapshot','finance_save_snapshot'))
)) AS informe;
