-- Smoke test for the NEW development project only. Everything is rolled back.
BEGIN;
INSERT INTO auth.users(id) VALUES ('11111111-1111-4111-8111-111111111111'), ('22222222-2222-4222-8222-222222222222');
INSERT INTO public.finance_workspaces(owner_id,id,kind,name) VALUES
('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111101','personal','Prueba A'),
('22222222-2222-4222-8222-222222222222','22222222-2222-4222-8222-222222222202','personal','Prueba B');
INSERT INTO public.finance_accounts(owner_id,workspace_id,id,name,type,opening_date) VALUES
('11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111101','11111111-1111-4111-8111-111111111102','Cuenta A','checking',now()),
('22222222-2222-4222-8222-222222222222','22222222-2222-4222-8222-222222222202','22222222-2222-4222-8222-222222222203','Cuenta B','checking',now());
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
DO $$
DECLARE original jsonb; saved jsonb;
BEGIN
    IF (SELECT count(*) FROM public.finance_accounts) <> 1 THEN RAISE EXCEPTION 'Owner isolation failed'; END IF;
    IF EXISTS(SELECT FROM public.finance_accounts WHERE name='Cuenta B') THEN RAISE EXCEPTION 'Other user is visible'; END IF;
    UPDATE public.finance_accounts SET notes='Verified' WHERE owner_id='11111111-1111-4111-8111-111111111111';
    IF NOT FOUND THEN RAISE EXCEPTION 'Own update failed'; END IF;
    UPDATE public.finance_accounts SET notes='Forbidden' WHERE owner_id='22222222-2222-4222-8222-222222222222';
    IF FOUND THEN RAISE EXCEPTION 'Other user update succeeded'; END IF;
    BEGIN
        INSERT INTO public.finance_workspaces(owner_id,kind,name) VALUES ('22222222-2222-4222-8222-222222222222','sandbox','Forbidden');
        RAISE EXCEPTION 'Spoofed owner was accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    original := public.finance_snapshot('11111111-1111-4111-8111-111111111101');
    IF jsonb_array_length(original->'document'->'accounts') <> 1 THEN RAISE EXCEPTION 'Snapshot isolation failed'; END IF;
    saved := public.finance_save_snapshot((original->>'workspace_id')::uuid,
        (original->>'revision')::bigint,original->'document','Europe/Madrid');
    IF (saved->>'revision')::bigint <= (original->>'revision')::bigint THEN RAISE EXCEPTION 'Snapshot revision not advanced'; END IF;
    BEGIN
        PERFORM public.finance_save_snapshot((original->>'workspace_id')::uuid,
            (original->>'revision')::bigint,original->'document','Europe/Madrid');
        RAISE EXCEPTION 'Stale revision was accepted';
    EXCEPTION WHEN serialization_failure THEN NULL; END;
    BEGIN
        PERFORM public.finance_snapshot('22222222-2222-4222-8222-222222222202');
        RAISE EXCEPTION 'Cross owner snapshot was accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN
        DELETE FROM public.finance_accounts;
        RAISE EXCEPTION 'Physical delete was accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET LOCAL ROLE anon;
DO $$ BEGIN
    BEGIN
        PERFORM * FROM public.finance_accounts;
        RAISE EXCEPTION 'Anonymous access was accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
SELECT 'OK: RLS, aislamiento, lectura y escritura cloud, revisiones obsoletas rechazadas. Datos ficticios revertidos.' AS resultado;
