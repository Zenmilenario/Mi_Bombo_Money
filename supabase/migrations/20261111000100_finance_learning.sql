-- What the person has taught the app's models (categories confirmed, operations identified, corrections),
-- shared by their devices. It is not financial data and is kept apart from the finance snapshot: that
-- protocol replaces whole tables and would drop unknown fields. The contract is
-- CloudBackend/learning-contract.md. One document per personal workspace, saved with a revision check.
CREATE TABLE public.finance_learning (
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    document jsonb NOT NULL CHECK (jsonb_typeof(document) = 'object' AND document->>'version' = '1'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_id, workspace_id),
    FOREIGN KEY (owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id) ON DELETE CASCADE
);
ALTER TABLE public.finance_learning ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_learning FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_learning FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_learning TO authenticated;
GRANT ALL ON public.finance_learning TO service_role;
CREATE POLICY owner_select ON public.finance_learning FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_learning FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_learning FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);

-- The learning of the person's personal workspace: revision 0 and an empty document until the first save.
CREATE FUNCTION public.finance_learning_snapshot() RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE owner uuid := auth.uid(); ws public.finance_workspaces; saved public.finance_learning;
BEGIN
    IF owner IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    SELECT * INTO ws FROM public.finance_workspaces WHERE owner_id=owner AND kind='personal' AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    SELECT * INTO saved FROM public.finance_learning WHERE owner_id=owner AND workspace_id=ws.id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('workspace_id',ws.id,'revision',0,'document',jsonb_build_object('version',1));
    END IF;
    RETURN jsonb_build_object('workspace_id',ws.id,'revision',saved.revision,'document',saved.document);
END $$;
REVOKE ALL ON FUNCTION public.finance_learning_snapshot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finance_learning_snapshot() TO authenticated;

-- Saves the merged learning if nobody saved since `p_expected_revision` (0 = never saved); otherwise the
-- device reads it again, merges and retries (40001), as with the finance snapshot.
CREATE FUNCTION public.finance_learning_save(p_workspace uuid, p_expected_revision bigint, p_document jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE owner uuid := auth.uid(); ws public.finance_workspaces; saved public.finance_learning;
BEGIN
    IF owner IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    -- Its own lock key: saving the learning never waits for a finance snapshot.
    PERFORM pg_advisory_xact_lock(hashtextextended(owner::text,1));
    SELECT * INTO ws FROM public.finance_workspaces WHERE owner_id=owner AND id=p_workspace AND kind='personal' AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    IF p_document IS NULL OR jsonb_typeof(p_document)<>'object' OR p_document->>'version' IS DISTINCT FROM '1'
       OR octet_length(p_document::text)>5000000 THEN
        RAISE EXCEPTION 'Invalid learning format or size' USING ERRCODE='22023';
    END IF;
    SELECT * INTO saved FROM public.finance_learning WHERE owner_id=owner AND workspace_id=p_workspace FOR UPDATE;
    IF NOT FOUND THEN
        IF p_expected_revision IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'cloud_revision_conflict' USING ERRCODE='40001'; END IF;
        INSERT INTO public.finance_learning(owner_id,workspace_id,revision,document) VALUES(owner,p_workspace,1,p_document)
            RETURNING * INTO saved;
    ELSE
        IF p_expected_revision IS DISTINCT FROM saved.revision THEN RAISE EXCEPTION 'cloud_revision_conflict' USING ERRCODE='40001'; END IF;
        UPDATE public.finance_learning SET document=p_document, revision=saved.revision+1, updated_at=clock_timestamp()
            WHERE owner_id=owner AND workspace_id=p_workspace RETURNING * INTO saved;
    END IF;
    RETURN jsonb_build_object('workspace_id',p_workspace,'revision',saved.revision,'document',saved.document);
END $$;
REVOKE ALL ON FUNCTION public.finance_learning_save(uuid,bigint,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finance_learning_save(uuid,bigint,jsonb) TO authenticated;
