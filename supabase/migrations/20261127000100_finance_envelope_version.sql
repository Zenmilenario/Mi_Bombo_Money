-- Compatibility of encrypted finance documents across app versions (27 November 2026).
--
-- The server cannot read an encrypted document, so it cannot tell whether a client dropped data it does not know
-- (an older iPhone app rebuilds the document with the lists it knows and leaves out the instalment plans). The
-- version of the envelope says it instead: clients that know every list of the current contract seal the finance
-- document as version 2. A version 1 save over a version 2 document is refused with `client_outdated`, so an older
-- client can never overwrite a newer copy; its changes stay on its device until it is updated. Learning documents
-- stay version 1. Nothing stored is changed by this migration.

CREATE OR REPLACE FUNCTION finance_private.check_envelope(value jsonb, max_bytes integer DEFAULT 15000000) RETURNS void
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
    IF value IS NULL OR jsonb_typeof(value)<>'object' OR coalesce(value->>'v','') NOT IN ('1','2')
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

CREATE OR REPLACE FUNCTION public.finance_encrypted_save(p_workspace uuid,p_kind text,p_expected_revision bigint,p_envelope jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE saved public.finance_sealed_documents; check_value jsonb;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    PERFORM finance_private.check_envelope(p_envelope,CASE WHEN p_kind='learning' THEN 7500000 ELSE 15000000 END);
    -- Only finance documents have a version 2.
    IF p_kind<>'finance' AND p_envelope->>'v'<>'1' THEN RAISE EXCEPTION 'Invalid encrypted envelope' USING ERRCODE='22023'; END IF;
    SELECT key_check INTO check_value FROM public.finance_encryption_keys WHERE owner_id=auth.uid() AND workspace_id=p_workspace;
    IF check_value IS NULL OR p_envelope->>'key_id' IS DISTINCT FROM check_value->>'key_id' THEN
        RAISE EXCEPTION 'Key mismatch' USING ERRCODE='42501';
    END IF;
    SELECT d.* INTO saved FROM public.finance_sealed_documents d JOIN public.finance_workspaces w ON (w.owner_id,w.id)=(d.owner_id,d.workspace_id)
        WHERE d.owner_id=auth.uid() AND d.workspace_id=p_workspace AND d.kind=p_kind AND w.deleted_at IS NULL FOR UPDATE OF d;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    IF saved.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'cloud_revision_conflict' USING ERRCODE='40001'; END IF;
    -- An older client cannot write over a document written by a newer one (it would drop what it does not know).
    IF (saved.envelope->>'v')::int > (p_envelope->>'v')::int THEN
        RAISE EXCEPTION 'client_outdated' USING ERRCODE='22023', HINT='Update the app: the stored document has a newer format.';
    END IF;
    UPDATE public.finance_sealed_documents SET envelope=p_envelope,revision=saved.revision+1,updated_at=clock_timestamp()
        WHERE owner_id=auth.uid() AND workspace_id=p_workspace AND kind=p_kind;
    RETURN public.finance_encrypted_snapshot(p_kind);
END $$;
REVOKE ALL ON FUNCTION public.finance_encrypted_save(uuid,text,bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finance_encrypted_save(uuid,text,bigint,jsonb) TO authenticated;
