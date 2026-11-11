-- `public.rls_auto_enable()` is the event-trigger function of the project's «ensure_rls» trigger, which turns on
-- row-level security in every new table. It belongs to postgres and is not meant to be called through the API,
-- but it was executable by anyone (Supabase advisor 0028/0029). The event trigger keeps working without these
-- grants: event triggers do not check EXECUTE. Only where the function exists (it is not in local test databases).
DO $$
BEGIN
    IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN
        REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;
    END IF;
END $$;
