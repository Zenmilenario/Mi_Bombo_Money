-- Isolated sync roundtrip test. Only fixed fictitious owners are written.
-- Existing users/data remain untouched. Every test write is rolled back.
-- Two logical clients are represented by stored JSON/revisions, not iOS devices.
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
DECLARE original jsonb; saved jsonb; device_a jsonb; device_b jsonb; document_b jsonb; category jsonb;
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
    -- A and B start with the same revision. B must not overwrite A with a stale snapshot.
    device_a := public.finance_snapshot('11111111-1111-4111-8111-111111111101');
    device_b := device_a;
    device_a := jsonb_set(device_a,'{document,accounts,0,name}','"Cuenta ficticia editada por A"'::jsonb);
    saved := public.finance_save_snapshot((device_a->>'workspace_id')::uuid,
        (device_a->>'revision')::bigint,device_a->'document','Europe/Madrid');
    BEGIN
        PERFORM public.finance_save_snapshot((device_b->>'workspace_id')::uuid,
            (device_b->>'revision')::bigint,device_b->'document','Europe/Madrid');
        RAISE EXCEPTION 'Device B overwrote a newer revision';
    EXCEPTION WHEN serialization_failure THEN NULL; END;
    -- B reloads, retains A's edit and adds a distinct record.
    device_b := public.finance_snapshot((saved->>'workspace_id')::uuid);
    category := jsonb_build_object('id','11111111-1111-4111-8111-111111111103',
        'name','Categoria ficticia B','kindRaw','expense','systemImage','tag','colorHex','#176B87',
        'isArchived',false,'isSystem',false,'sortOrder',0,
        'createdAt',extract(epoch FROM now())-978307200,'updatedAt',extract(epoch FROM now())-978307200);
    document_b := jsonb_set(device_b->'document','{categories}',jsonb_build_array(category));
    saved := public.finance_save_snapshot((device_b->>'workspace_id')::uuid,
        (device_b->>'revision')::bigint,document_b,'Europe/Madrid');
    device_a := public.finance_snapshot((saved->>'workspace_id')::uuid);
    IF device_a->'document'->'accounts'->0->>'name' <> 'Cuenta ficticia editada por A'
       OR device_a->'document'->'categories'->0->>'name' <> 'Categoria ficticia B' THEN
        RAISE EXCEPTION 'Reload did not preserve both clients edits';
    END IF;
    -- A retains B's offline deletion; a later read must not resurrect it.
    document_b := jsonb_set(device_a->'document','{categories}','[]'::jsonb);
    saved := public.finance_save_snapshot((device_a->>'workspace_id')::uuid,
        (device_a->>'revision')::bigint,document_b,'Europe/Madrid');
    device_a := public.finance_snapshot((saved->>'workspace_id')::uuid);
    IF jsonb_array_length(device_a->'document'->'categories')<>0 OR NOT EXISTS(
        SELECT FROM public.finance_categories WHERE id='11111111-1111-4111-8111-111111111103'
          AND owner_id='11111111-1111-4111-8111-111111111111' AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Deletion was not propagated as a tombstone';
    END IF;
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
SELECT 'OK: dos clientes simulados, relectura, revision obsoleta rechazada, cambios distintos conservados y borrado propagado. Datos ficticios revertidos.' AS resultado;
