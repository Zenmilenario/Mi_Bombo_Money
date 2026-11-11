-- Applied to the live project on 11 November 2026, in one transaction with the developer's exemption (the id is
-- inserted by an administrator and is not stored in the repository).
-- Default: encrypted. Only an administrator can exempt the developer's own identity.
CREATE TABLE finance_private.developer_plaintext_users (
    owner_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE
);
REVOKE ALL ON finance_private.developer_plaintext_users FROM PUBLIC, anon, authenticated;
-- No policies on purpose: only SECURITY DEFINER code (plaintext_allowed) and administrators read it.
ALTER TABLE finance_private.developer_plaintext_users ENABLE ROW LEVEL SECURITY;
GRANT ALL ON finance_private.developer_plaintext_users TO service_role;

CREATE FUNCTION finance_private.plaintext_allowed() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
    SELECT auth.uid() IS NOT NULL AND EXISTS (
        SELECT FROM finance_private.developer_plaintext_users WHERE owner_id=auth.uid()
    )
$$;
REVOKE ALL ON FUNCTION finance_private.plaintext_allowed() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION finance_private.plaintext_allowed() TO authenticated;

CREATE TABLE public.finance_encryption_keys (
    owner_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    key_check jsonb NOT NULL,
    FOREIGN KEY(owner_id,workspace_id) REFERENCES public.finance_workspaces(owner_id,id) ON DELETE CASCADE
);
CREATE TABLE public.finance_sealed_documents (
    owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    kind text NOT NULL CHECK(kind IN ('finance','learning')),
    revision bigint NOT NULL CHECK(revision>0),
    envelope jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(owner_id,workspace_id,kind),
    FOREIGN KEY(owner_id,workspace_id) REFERENCES public.finance_workspaces(owner_id,id) ON DELETE CASCADE
);
ALTER TABLE public.finance_encryption_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_encryption_keys FORCE ROW LEVEL SECURITY;
ALTER TABLE public.finance_sealed_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_sealed_documents FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_encryption_keys, public.finance_sealed_documents FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.finance_encryption_keys, public.finance_sealed_documents TO authenticated;
GRANT ALL ON public.finance_encryption_keys, public.finance_sealed_documents TO service_role;
CREATE POLICY own_keys ON public.finance_encryption_keys FOR SELECT TO authenticated USING(owner_id=(SELECT auth.uid()));
CREATE POLICY own_ciphertext ON public.finance_sealed_documents FOR SELECT TO authenticated USING(owner_id=(SELECT auth.uid()));

-- Old versions and direct REST requests cannot write plaintext for guests. SELECT is also restricted;
-- the one-time, scoped migration RPC below is the only path for reading their legacy copy.
DO $$ DECLARE item record;
BEGIN
    FOR item IN SELECT tablename FROM pg_tables WHERE schemaname='public'
        AND tablename LIKE 'finance_%' AND tablename NOT IN ('finance_workspaces','finance_encryption_keys','finance_sealed_documents')
    LOOP
        EXECUTE format('CREATE POLICY encrypted_users_no_plaintext ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT finance_private.plaintext_allowed())) WITH CHECK ((SELECT finance_private.plaintext_allowed()))',item.tablename);
    END LOOP;
    CREATE POLICY encrypted_users_no_workspace_writes ON public.finance_workspaces AS RESTRICTIVE FOR INSERT TO authenticated
        WITH CHECK ((SELECT finance_private.plaintext_allowed()));
    CREATE POLICY encrypted_users_no_workspace_updates ON public.finance_workspaces AS RESTRICTIVE FOR UPDATE TO authenticated
        USING ((SELECT finance_private.plaintext_allowed())) WITH CHECK ((SELECT finance_private.plaintext_allowed()));
END $$;

-- Keep the established relational implementation for the explicitly exempt developer only.
ALTER FUNCTION public.finance_snapshot(uuid) SET SCHEMA finance_private;
ALTER FUNCTION finance_private.finance_snapshot(uuid) RENAME TO legacy_snapshot;
ALTER FUNCTION public.finance_save_snapshot(uuid,bigint,jsonb,text) SET SCHEMA finance_private;
ALTER FUNCTION finance_private.finance_save_snapshot(uuid,bigint,jsonb,text) RENAME TO legacy_save;
ALTER FUNCTION public.finance_learning_snapshot() SET SCHEMA finance_private;
ALTER FUNCTION finance_private.finance_learning_snapshot() RENAME TO legacy_learning_snapshot;
ALTER FUNCTION public.finance_learning_save(uuid,bigint,jsonb) SET SCHEMA finance_private;
ALTER FUNCTION finance_private.finance_learning_save(uuid,bigint,jsonb) RENAME TO legacy_learning_save;
REVOKE ALL ON FUNCTION finance_private.legacy_snapshot(uuid),finance_private.legacy_save(uuid,bigint,jsonb,text),
    finance_private.legacy_learning_snapshot(),finance_private.legacy_learning_save(uuid,bigint,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.finance_snapshot(p_workspace uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
    IF NOT finance_private.plaintext_allowed() THEN RAISE EXCEPTION 'client_encryption_required' USING ERRCODE='42501'; END IF;
    RETURN finance_private.legacy_snapshot(p_workspace);
END $$;
CREATE FUNCTION public.finance_save_snapshot(p_workspace uuid,p_expected_revision bigint,p_document jsonb,p_timezone text DEFAULT 'Europe/Madrid') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
    IF NOT finance_private.plaintext_allowed() THEN RAISE EXCEPTION 'client_encryption_required' USING ERRCODE='42501'; END IF;
    RETURN finance_private.legacy_save(p_workspace,p_expected_revision,p_document,p_timezone);
END $$;
CREATE FUNCTION public.finance_learning_snapshot() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
    IF NOT finance_private.plaintext_allowed() THEN RAISE EXCEPTION 'client_encryption_required' USING ERRCODE='42501'; END IF;
    RETURN finance_private.legacy_learning_snapshot();
END $$;
CREATE FUNCTION public.finance_learning_save(p_workspace uuid,p_expected_revision bigint,p_document jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
    IF NOT finance_private.plaintext_allowed() THEN RAISE EXCEPTION 'client_encryption_required' USING ERRCODE='42501'; END IF;
    RETURN finance_private.legacy_learning_save(p_workspace,p_expected_revision,p_document);
END $$;

CREATE FUNCTION public.finance_privacy_profile() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ws uuid; check_value jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
    SELECT id INTO ws FROM public.finance_workspaces WHERE owner_id=auth.uid() AND kind='personal' AND deleted_at IS NULL;
    IF ws IS NULL THEN
        INSERT INTO public.finance_workspaces(owner_id,kind,name) VALUES(auth.uid(),'personal','Mis finanzas') RETURNING id INTO ws;
    END IF;
    SELECT key_check INTO check_value FROM public.finance_encryption_keys WHERE owner_id=auth.uid() AND workspace_id=ws;
    RETURN jsonb_build_object('encryption_required',NOT finance_private.plaintext_allowed(),'workspace_id',ws,'key_check',check_value);
END $$;

CREATE FUNCTION finance_private.check_envelope(value jsonb, max_bytes integer DEFAULT 15000000) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
    IF value IS NULL OR jsonb_typeof(value)<>'object' OR value->>'v' IS DISTINCT FROM '1'
       OR value->>'alg' IS DISTINCT FROM 'A256GCM' OR octet_length(value::text)>max_bytes
       OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) IS DISTINCT FROM ARRAY['alg','ciphertext','key_id','nonce','tag','v']
       OR coalesce(value->>'key_id','') !~ '^[a-f0-9-]{36}$'
       OR octet_length(decode(value->>'nonce','base64')) IS DISTINCT FROM 12
       OR octet_length(decode(value->>'tag','base64')) IS DISTINCT FROM 16
       OR octet_length(decode(value->>'ciphertext','base64')) IS NULL THEN
        RAISE EXCEPTION 'Invalid encrypted envelope' USING ERRCODE='22023';
    END IF;
END $$;
REVOKE ALL ON FUNCTION finance_private.check_envelope(jsonb,integer) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.finance_encryption_source() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
    IF auth.uid() IS NULL OR finance_private.plaintext_allowed() OR EXISTS(SELECT FROM public.finance_encryption_keys WHERE owner_id=auth.uid()) THEN
        RAISE EXCEPTION 'Encryption enrollment unavailable' USING ERRCODE='42501';
    END IF;
    RETURN jsonb_build_object('finance',finance_private.legacy_snapshot(NULL),'learning',finance_private.legacy_learning_snapshot());
END $$;

CREATE FUNCTION public.finance_enable_encryption(p_workspace uuid,p_finance_revision bigint,p_learning_revision bigint,
    p_finance jsonb,p_learning jsonb,p_key_check jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE entity jsonb; ws public.finance_workspaces; learning_revision bigint;
BEGIN
    IF auth.uid() IS NULL OR finance_private.plaintext_allowed() THEN RAISE EXCEPTION 'Encryption unavailable' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
    PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text,1));
    SELECT * INTO ws FROM public.finance_workspaces WHERE owner_id=auth.uid() AND id=p_workspace AND kind='personal' AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    SELECT revision INTO learning_revision FROM public.finance_learning WHERE owner_id=auth.uid() AND workspace_id=p_workspace;
    IF ws.revision IS DISTINCT FROM p_finance_revision OR coalesce(learning_revision,0) IS DISTINCT FROM p_learning_revision
       OR EXISTS(SELECT FROM public.finance_encryption_keys WHERE owner_id=auth.uid()) THEN
        RAISE EXCEPTION 'cloud_revision_conflict' USING ERRCODE='40001';
    END IF;
    PERFORM finance_private.check_envelope(p_finance);
    PERFORM finance_private.check_envelope(p_learning,7500000);
    PERFORM finance_private.check_envelope(p_key_check,1024);
    IF p_finance->>'key_id' IS DISTINCT FROM p_key_check->>'key_id' OR p_learning->>'key_id' IS DISTINCT FROM p_key_check->>'key_id' THEN
        RAISE EXCEPTION 'Key mismatch' USING ERRCODE='22023';
    END IF;
    INSERT INTO public.finance_encryption_keys VALUES(auth.uid(),p_workspace,p_key_check);
    INSERT INTO public.finance_sealed_documents(owner_id,workspace_id,kind,revision,envelope)
        VALUES(auth.uid(),p_workspace,'finance',1,p_finance),(auth.uid(),p_workspace,'learning',1,p_learning);
    -- Remove live legacy rows (including tombstones) only after both ciphertexts were accepted atomically.
    FOR entity IN SELECT value FROM jsonb_array_elements(finance_private.backup_contract()) WITH ORDINALITY t(value,n) ORDER BY n DESC LOOP
        EXECUTE format('DELETE FROM public.%I WHERE owner_id=$1 AND workspace_id=$2',entity->>'table') USING auth.uid(),p_workspace;
    END LOOP;
    DELETE FROM public.finance_learning WHERE owner_id=auth.uid() AND workspace_id=p_workspace;
    UPDATE public.finance_workspaces SET name='Mis finanzas' WHERE owner_id=auth.uid() AND id=p_workspace;
END $$;

CREATE FUNCTION public.finance_encrypted_snapshot(p_kind text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE saved public.finance_sealed_documents;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    SELECT d.* INTO saved FROM public.finance_sealed_documents d JOIN public.finance_workspaces w
        ON (w.owner_id,w.id)=(d.owner_id,d.workspace_id) WHERE d.owner_id=auth.uid() AND d.kind=p_kind AND w.kind='personal' AND w.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'client_encryption_required' USING ERRCODE='42501'; END IF;
    RETURN jsonb_build_object('workspace_id',saved.workspace_id,'revision',saved.revision,'document',saved.envelope);
END $$;
CREATE FUNCTION public.finance_encrypted_save(p_workspace uuid,p_kind text,p_expected_revision bigint,p_envelope jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE saved public.finance_sealed_documents; check_value jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    PERFORM finance_private.check_envelope(p_envelope,CASE WHEN p_kind='learning' THEN 7500000 ELSE 15000000 END);
    SELECT key_check INTO check_value FROM public.finance_encryption_keys WHERE owner_id=auth.uid() AND workspace_id=p_workspace;
    IF check_value IS NULL OR p_envelope->>'key_id' IS DISTINCT FROM check_value->>'key_id' THEN
        RAISE EXCEPTION 'Key mismatch' USING ERRCODE='42501';
    END IF;
    SELECT d.* INTO saved FROM public.finance_sealed_documents d JOIN public.finance_workspaces w ON (w.owner_id,w.id)=(d.owner_id,d.workspace_id)
        WHERE d.owner_id=auth.uid() AND d.workspace_id=p_workspace AND d.kind=p_kind AND w.deleted_at IS NULL FOR UPDATE OF d;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    IF saved.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'cloud_revision_conflict' USING ERRCODE='40001'; END IF;
    UPDATE public.finance_sealed_documents SET envelope=p_envelope,revision=saved.revision+1,updated_at=clock_timestamp()
        WHERE owner_id=auth.uid() AND workspace_id=p_workspace AND kind=p_kind;
    RETURN public.finance_encrypted_snapshot(p_kind);
END $$;

REVOKE ALL ON FUNCTION public.finance_snapshot(uuid), public.finance_save_snapshot(uuid,bigint,jsonb,text),
    public.finance_learning_snapshot(),public.finance_learning_save(uuid,bigint,jsonb),public.finance_privacy_profile(),
    public.finance_encryption_source(),public.finance_enable_encryption(uuid,bigint,bigint,jsonb,jsonb,jsonb),
    public.finance_encrypted_snapshot(text),public.finance_encrypted_save(uuid,text,bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finance_snapshot(uuid), public.finance_save_snapshot(uuid,bigint,jsonb,text),
    public.finance_learning_snapshot(),public.finance_learning_save(uuid,bigint,jsonb),public.finance_privacy_profile(),
    public.finance_encryption_source(),public.finance_enable_encryption(uuid,bigint,bigint,jsonb,jsonb,jsonb),
    public.finance_encrypted_snapshot(text),public.finance_encrypted_save(uuid,text,bigint,jsonb) TO authenticated;
