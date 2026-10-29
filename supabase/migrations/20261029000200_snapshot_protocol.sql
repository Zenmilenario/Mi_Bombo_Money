-- Atomic snapshot protocol over the normalized tables. Uses Supabase Auth and RLS.
-- The model contract is versioned in CloudBackend/backup-contract.json.
-- These UUIDs are provenance, not live SwiftData relationships: deleting a rule or
-- import log must preserve its posted transactions, including on a first upload.
DO $$ DECLARE item record;
BEGIN
    FOR item IN SELECT DISTINCT c.conname FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey)
        WHERE c.conrelid='public.finance_transactions'::regclass AND c.contype='f'
          AND a.attname IN ('import_batch_id','recurring_movement_id')
    LOOP EXECUTE format('ALTER TABLE public.finance_transactions DROP CONSTRAINT %I',item.conname); END LOOP;
END $$;
CREATE FUNCTION finance_private.backup_contract() RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = '' AS $contract$ SELECT '[{"key": "institutions", "table": "finance_institutions", "fields": {"id": "id", "name": "name", "colorHex": "color_hex", "notes": "notes", "createdAt": "created_at", "updatedAt": "updated_at"}, "dates": ["createdAt", "updatedAt"], "months": []}, {"key": "accounts", "table": "finance_accounts", "fields": {"id": "id", "name": "name", "typeRaw": "type", "currencyCode": "currency_code", "openingBalanceMinor": "opening_balance_minor", "openingDate": "opening_date", "annualInterestRate": "annual_interest_rate", "targetBalanceMinor": "target_balance_minor", "creditLimitMinor": "credit_limit_minor", "includeInNetWorth": "include_in_net_worth", "isArchived": "is_archived", "sortOrder": "sort_order", "notes": "notes", "lastUpdatedAt": "last_updated_at", "createdAt": "created_at", "updatedAt": "updated_at", "institutionID": "institution_id"}, "dates": ["openingDate", "lastUpdatedAt", "createdAt", "updatedAt"], "months": []}, {"key": "categories", "table": "finance_categories", "fields": {"id": "id", "name": "name", "kindRaw": "kind", "systemImage": "system_image", "colorHex": "color_hex", "isArchived": "is_archived", "isSystem": "is_system", "sortOrder": "sort_order", "createdAt": "created_at", "updatedAt": "updated_at"}, "dates": ["createdAt", "updatedAt"], "months": []}, {"key": "cards", "table": "finance_cards", "fields": {"id": "id", "name": "name", "typeRaw": "type", "lastFour": "last_four", "limitMinor": "limit_minor", "limitKindRaw": "limit_kind", "onlinePurchasesEnabled": "online_purchases_enabled", "contactlessEnabled": "contactless_enabled", "atmWithdrawalsEnabled": "atm_withdrawals_enabled", "internationalPaymentsEnabled": "international_payments_enabled", "cashbackEnabled": "cashback_enabled", "cashbackPercent": "cashback_percent", "roundUpEnabled": "round_up_enabled", "isArchived": "is_archived", "notes": "notes", "createdAt": "created_at", "updatedAt": "updated_at", "institutionID": "institution_id", "linkedAccountID": "linked_account_id"}, "dates": ["createdAt", "updatedAt"], "months": []}, {"key": "reservedFunds", "table": "finance_reserved_funds", "fields": {"id": "id", "name": "name", "amountMinor": "amount_minor", "notes": "notes", "createdAt": "created_at", "updatedAt": "updated_at", "accountID": "account_id"}, "dates": ["createdAt", "updatedAt"], "months": []}, {"key": "categoryRules", "table": "finance_category_rules", "fields": {"id": "id", "phrase": "phrase", "transactionTypeRaw": "transaction_type", "isActive": "is_active", "createdAt": "created_at", "updatedAt": "updated_at", "categoryID": "category_id"}, "dates": ["createdAt", "updatedAt"], "months": []}, {"key": "recurringBudgets", "table": "finance_recurring_budgets", "fields": {"id": "id", "startMonth": "start_month", "endMonth": "end_month", "baseLimitMinor": "base_limit_minor", "remainderChoiceRaw": "remainder_choice", "createdAt": "created_at", "updatedAt": "updated_at", "categoryID": "category_id"}, "dates": ["startMonth", "endMonth", "createdAt", "updatedAt"], "months": ["startMonth", "endMonth"]}, {"key": "budgets", "table": "finance_monthly_budgets", "fields": {"id": "id", "monthStart": "month_start", "limitMinor": "limit_minor", "notes": "notes", "createdAt": "created_at", "updatedAt": "updated_at", "categoryID": "category_id"}, "dates": ["monthStart", "createdAt", "updatedAt"], "months": ["monthStart"]}, {"key": "goals", "table": "finance_savings_goals", "fields": {"id": "id", "name": "name", "targetAmountMinor": "target_amount_minor", "currentAmountMinor": "current_amount_minor", "targetDate": "target_date", "colorHex": "color_hex", "notes": "notes", "isCompleted": "is_completed", "createdAt": "created_at", "updatedAt": "updated_at", "linkedAccountID": "linked_account_id"}, "dates": ["targetDate", "createdAt", "updatedAt"], "months": []}, {"key": "recurringMovements", "table": "finance_recurring_movements", "fields": {"id": "id", "name": "name", "typeRaw": "type", "amountMinor": "amount_minor", "descriptionText": "description_text", "notes": "notes", "frequencyRaw": "frequency", "interval": "interval", "nextDueDate": "next_due_date", "endDate": "end_date", "isActive": "is_active", "isSubscription": "is_subscription", "postsAutomatically": "posts_automatically", "createdAt": "created_at", "updatedAt": "updated_at", "sourceAccountID": "source_account_id", "destinationAccountID": "destination_account_id", "categoryID": "category_id"}, "dates": ["nextDueDate", "endDate", "createdAt", "updatedAt"], "months": []}, {"key": "importBatches", "table": "finance_import_batches", "fields": {"id": "id", "fileName": "file_name", "sourceRaw": "source", "institutionName": "institution_name", "importedAt": "imported_at", "importedRows": "imported_rows", "skippedDuplicates": "skipped_duplicates", "possibleDuplicates": "possible_duplicates", "checksum": "checksum", "notes": "notes"}, "dates": ["importedAt"], "months": []}, {"key": "snapshots", "table": "finance_balance_snapshots", "fields": {"id": "id", "date": "date", "balanceMinor": "balance_minor", "sourceRaw": "source", "notes": "notes", "createdAt": "created_at", "accountID": "account_id"}, "dates": ["date", "createdAt"], "months": []}, {"key": "transactions", "table": "finance_transactions", "fields": {"id": "id", "date": "date", "typeRaw": "type", "amountMinor": "amount_minor", "descriptionText": "description_text", "notes": "notes", "isReconciled": "is_reconciled", "fingerprint": "fingerprint", "duplicateStateRaw": "duplicate_state", "externalID": "external_id", "importBatchID": "import_batch_id", "recurringMovementID": "recurring_movement_id", "reservedFundID": "reserved_fund_id", "reservedAmountMinor": "reserved_amount_minor", "createdAt": "created_at", "updatedAt": "updated_at", "sourceAccountID": "source_account_id", "destinationAccountID": "destination_account_id", "categoryID": "category_id"}, "dates": ["date", "createdAt", "updatedAt"], "months": []}]'::jsonb $contract$;
GRANT USAGE ON SCHEMA finance_private TO authenticated;
REVOKE ALL ON FUNCTION finance_private.backup_contract() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION finance_private.backup_contract() TO authenticated;

CREATE FUNCTION finance_private.lock_workspace() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF (auth.uid() IS NOT NULL AND NEW.owner_id <> auth.uid()) OR (current_user = 'authenticated' AND auth.uid() IS NULL) THEN
        RAISE EXCEPTION 'Owner mismatch' USING ERRCODE='42501';
    END IF;
    PERFORM id FROM public.finance_workspaces
        WHERE owner_id=NEW.owner_id AND id=NEW.workspace_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='23503'; END IF;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION finance_private.lock_workspace() FROM PUBLIC, anon, authenticated;
CREATE FUNCTION finance_private.touch_workspace() RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    UPDATE public.finance_workspaces SET updated_at=clock_timestamp() WHERE owner_id=NEW.owner_id AND id=NEW.workspace_id;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION finance_private.touch_workspace() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_institutions FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_institutions FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_accounts FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_accounts FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_categories FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_categories FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_cards FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_cards FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_reserved_funds FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_reserved_funds FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_category_rules FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_category_rules FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_recurring_budgets FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_recurring_budgets FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_monthly_budgets FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_monthly_budgets FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_savings_goals FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_savings_goals FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_recurring_movements FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_recurring_movements FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_import_batches FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_import_batches FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_balance_snapshots FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_balance_snapshots FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();
CREATE TRIGGER a_workspace_lock BEFORE INSERT OR UPDATE ON public.finance_transactions FOR EACH ROW EXECUTE FUNCTION finance_private.lock_workspace();
CREATE TRIGGER z_workspace_revision AFTER INSERT OR UPDATE ON public.finance_transactions FOR EACH ROW EXECUTE FUNCTION finance_private.touch_workspace();

CREATE FUNCTION public.finance_snapshot(p_workspace uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE owner uuid := auth.uid(); ws public.finance_workspaces; entity jsonb; field record;
    document jsonb := jsonb_build_object('formatVersion',2,'exportedAt',extract(epoch FROM now())-978307200);
    expression text; column_expr text; rows jsonb;
BEGIN
    IF owner IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(owner::text,0));
    IF p_workspace IS NULL THEN
        SELECT * INTO ws FROM public.finance_workspaces WHERE owner_id=owner AND kind='personal' AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN
            INSERT INTO public.finance_workspaces(owner_id,kind,name) VALUES(owner,'personal','Mis finanzas') RETURNING * INTO ws;
        END IF;
    ELSE
        SELECT * INTO ws FROM public.finance_workspaces WHERE owner_id=owner AND id=p_workspace AND kind='personal' AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    END IF;
    FOR entity IN SELECT value FROM jsonb_array_elements(finance_private.backup_contract()) LOOP
        expression := 'jsonb_build_object(';
        FOR field IN SELECT * FROM jsonb_each_text(entity->'fields') LOOP
            column_expr := format('to_jsonb(t.%I)',field.value);
            IF (entity->'months') ? field.key THEN
                column_expr := format('to_jsonb(extract(epoch FROM (t.%I + time ''12:00'') AT TIME ZONE ''UTC'')-978307200)',field.value);
            ELSIF (entity->'dates') ? field.key THEN
                column_expr := format('to_jsonb(extract(epoch FROM t.%I)-978307200)',field.value);
            END IF;
            expression := expression || format('%L,%s,',field.key,column_expr);
        END LOOP;
        expression := rtrim(expression,',') || ')';
        EXECUTE format('SELECT coalesce(jsonb_agg(%s ORDER BY t.id),''[]''::jsonb) FROM public.%I t WHERE owner_id=$1 AND workspace_id=$2 AND deleted_at IS NULL',expression,entity->>'table')
            INTO rows USING owner,ws.id;
        document := document || jsonb_build_object(entity->>'key',rows);
    END LOOP;
    RETURN jsonb_build_object('workspace_id',ws.id,'revision',ws.revision,'document',document);
END $$;
REVOKE ALL ON FUNCTION public.finance_snapshot(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finance_snapshot(uuid) TO authenticated;

CREATE FUNCTION public.finance_save_snapshot(p_workspace uuid, p_expected_revision bigint, p_document jsonb, p_timezone text DEFAULT 'Europe/Madrid') RETURNS jsonb
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE owner uuid := auth.uid(); ws public.finance_workspaces; entity jsonb; field record; item jsonb;
    decoded jsonb; field_value jsonb; columns text; updates text; incoming_ids uuid[]; contract jsonb := finance_private.backup_contract();
BEGIN
    IF owner IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    -- Same lock order as finance_snapshot: no read/write advisory-vs-row inversion.
    PERFORM pg_advisory_xact_lock(hashtextextended(owner::text,0));
    SELECT * INTO ws FROM public.finance_workspaces WHERE owner_id=owner AND id=p_workspace AND kind='personal' AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Workspace unavailable' USING ERRCODE='42501'; END IF;
    IF p_expected_revision IS NULL OR ws.revision <> p_expected_revision THEN
        RAISE EXCEPTION 'cloud_revision_conflict' USING ERRCODE='40001';
    END IF;
    IF p_document IS NULL OR p_document->>'formatVersion' IS DISTINCT FROM '2' OR pg_column_size(p_document)>10000000 THEN
        RAISE EXCEPTION 'Invalid snapshot format or size' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS(SELECT FROM pg_timezone_names WHERE name=p_timezone) THEN
        RAISE EXCEPTION 'Invalid calendar timezone' USING ERRCODE='22023';
    END IF;
    FOR entity IN SELECT value FROM jsonb_array_elements(contract) LOOP
        IF jsonb_typeof(p_document->(entity->>'key')) IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'Missing entity array: %',entity->>'key' USING ERRCODE='22023';
        END IF;
        IF EXISTS(SELECT FROM jsonb_array_elements(p_document->(entity->>'key')) r WHERE jsonb_typeof(r)<>'object' OR r->>'id' IS NULL) THEN
            RAISE EXCEPTION 'Invalid record' USING ERRCODE='22023';
        END IF;
        IF (SELECT count(*) <> count(DISTINCT (r->>'id')::uuid) FROM jsonb_array_elements(p_document->(entity->>'key')) r) THEN
            RAISE EXCEPTION 'Duplicate record identity' USING ERRCODE='22023';
        END IF;
    END LOOP;
    -- Release old reserved allocations before replacing a complete, validated transaction set.
    UPDATE public.finance_transactions SET deleted_at=clock_timestamp()
        WHERE owner_id=owner AND workspace_id=p_workspace AND deleted_at IS NULL;
    FOR entity IN SELECT value FROM jsonb_array_elements(contract) LOOP
        SELECT coalesce(array_agg((r->>'id')::uuid),ARRAY[]::uuid[]) INTO incoming_ids
            FROM jsonb_array_elements(p_document->(entity->>'key')) r;
        EXECUTE format('UPDATE public.%I SET deleted_at=clock_timestamp() WHERE owner_id=$1 AND workspace_id=$2 AND deleted_at IS NULL AND NOT(id=ANY($3))',entity->>'table')
            USING owner,p_workspace,incoming_ids;
    END LOOP;
    FOR entity IN SELECT value FROM jsonb_array_elements(contract) LOOP
        FOR item IN SELECT value FROM jsonb_array_elements(p_document->(entity->>'key')) LOOP
            decoded := jsonb_build_object('owner_id',owner,'workspace_id',p_workspace,'created_at',now(),'updated_at',now(),'revision',1,'deleted_at',NULL);
            FOR field IN SELECT * FROM jsonb_each_text(entity->'fields') LOOP
                field_value := item->field.key;
                IF field_value IS NOT NULL AND field_value <> 'null'::jsonb AND (entity->'dates') ? field.key THEN
                    IF jsonb_typeof(field_value)<>'number' THEN RAISE EXCEPTION 'Invalid date' USING ERRCODE='22023'; END IF;
                    IF (entity->'months') ? field.key THEN
                        field_value := to_jsonb(to_char(to_timestamp((field_value::text)::double precision+978307200) AT TIME ZONE p_timezone,'YYYY-MM-01'));
                    ELSE
                        field_value := to_jsonb(to_timestamp((field_value::text)::double precision+978307200));
                    END IF;
                END IF;
                decoded := decoded || jsonb_build_object(field.value,field_value);
            END LOOP;
            SELECT string_agg(format('%I',key),',' ORDER BY key),
                string_agg(format('%I=excluded.%I',key,key),',' ORDER BY key) FILTER(WHERE key NOT IN ('owner_id','workspace_id','id','created_at','revision'))
                INTO columns,updates FROM jsonb_object_keys(decoded) AS k(key);
            EXECUTE format('INSERT INTO public.%1$I (%2$s) SELECT %2$s FROM jsonb_populate_record(NULL::public.%1$I,$1) ON CONFLICT(owner_id,workspace_id,id) DO UPDATE SET %3$s',entity->>'table',columns,updates)
                USING decoded;
        END LOOP;
    END LOOP;
    RETURN public.finance_snapshot(p_workspace);
END $$;
REVOKE ALL ON FUNCTION public.finance_save_snapshot(uuid,bigint,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finance_save_snapshot(uuid,bigint,jsonb,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
