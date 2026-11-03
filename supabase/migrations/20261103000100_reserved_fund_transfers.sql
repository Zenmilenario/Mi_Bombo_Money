-- A reserved fund can follow an own-account transfer without becoming an expense.
-- Keep the owner/workspace foreign key; remove only the original-account restriction.
DO $$ DECLARE constraint_name text; BEGIN
    FOR constraint_name IN SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.finance_transactions'::regclass
          AND contype = 'f' AND confrelid = 'public.finance_reserved_funds'::regclass
    LOOP EXECUTE format('ALTER TABLE public.finance_transactions DROP CONSTRAINT %I', constraint_name); END LOOP;
    FOR constraint_name IN SELECT conname FROM pg_constraint
        WHERE conrelid = 'public.finance_transactions'::regclass AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%reserved_fund_id IS NULL%'
    LOOP EXECUTE format('ALTER TABLE public.finance_transactions DROP CONSTRAINT %I', constraint_name); END LOOP;
END $$;

ALTER TABLE public.finance_transactions
    ADD CONSTRAINT finance_reserved_fund_owner_fk FOREIGN KEY(owner_id, workspace_id, reserved_fund_id)
        REFERENCES public.finance_reserved_funds(owner_id, workspace_id, id),
    ADD CONSTRAINT finance_reserved_allocation_check CHECK (
        (reserved_fund_id IS NULL AND reserved_amount_minor IS NULL) OR
        (reserved_fund_id IS NOT NULL AND reserved_amount_minor IS NOT NULL
         AND reserved_amount_minor > 0 AND reserved_amount_minor <= amount_minor
         AND type IN ('expense','fee','transfer')));

-- Retain the immediate lock and total-spending protection. Transfers do not consume funding.
CREATE OR REPLACE FUNCTION finance_private.check_reserved_payments() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE fund_ids uuid[]; fund_total bigint; fund_deleted timestamptz; allocated numeric;
BEGIN
    IF TG_TABLE_NAME = 'finance_transactions' THEN
        IF TG_OP = 'UPDATE' THEN fund_ids := ARRAY[OLD.reserved_fund_id, NEW.reserved_fund_id];
        ELSE fund_ids := ARRAY[NEW.reserved_fund_id]; END IF;
        PERFORM id FROM public.finance_reserved_funds
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id AND id = ANY(fund_ids)
            ORDER BY id FOR UPDATE;
        IF NEW.reserved_fund_id IS NULL OR NEW.deleted_at IS NOT NULL THEN RETURN NEW; END IF;
        SELECT amount_minor, deleted_at INTO fund_total, fund_deleted FROM public.finance_reserved_funds
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id AND id = NEW.reserved_fund_id;
        IF NOT FOUND OR fund_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'Reserved fund is unavailable' USING ERRCODE = '23514';
        END IF;
        SELECT coalesce(sum(reserved_amount_minor), 0) INTO allocated FROM public.finance_transactions
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
              AND reserved_fund_id = NEW.reserved_fund_id AND deleted_at IS NULL AND type IN ('expense','fee');
    ELSE
        fund_total := NEW.amount_minor;
        SELECT coalesce(sum(reserved_amount_minor), 0) INTO allocated FROM public.finance_transactions
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
              AND reserved_fund_id = NEW.id AND deleted_at IS NULL AND type IN ('expense','fee');
    END IF;
    IF allocated > fund_total THEN
        RAISE EXCEPTION 'Reserved payments exceed the funded amount' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

-- Check the final graph, not intermediate snapshot replacement order. Existing workspace
-- locks serialize writers, including removal/editing of a transfer needed by a later payment.
CREATE FUNCTION finance_private.check_reserved_locations() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE fund_ids uuid[]; fund_id uuid; fund record; instant timestamptz; movement record;
        balances jsonb; done uuid[]; pending integer; progressed boolean; source_balance numeric;
BEGIN
    IF TG_TABLE_NAME = 'finance_transactions' THEN
        IF TG_OP = 'UPDATE' THEN fund_ids := ARRAY[OLD.reserved_fund_id, NEW.reserved_fund_id];
        ELSE fund_ids := ARRAY[NEW.reserved_fund_id]; END IF;
    ELSE fund_ids := ARRAY[NEW.id]; END IF;
    FOR fund_id IN SELECT DISTINCT value FROM unnest(fund_ids) value WHERE value IS NOT NULL LOOP
        SELECT * INTO fund FROM public.finance_reserved_funds
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id AND id = fund_id;
        IF NOT FOUND THEN CONTINUE; END IF;
        IF fund.deleted_at IS NOT NULL AND EXISTS (SELECT FROM public.finance_transactions
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
              AND reserved_fund_id = fund_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Reserved fund is unavailable' USING ERRCODE = '23514';
        END IF;
        balances := jsonb_build_object(fund.account_id::text, fund.amount_minor);
        FOR instant IN SELECT DISTINCT date FROM public.finance_transactions
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
              AND reserved_fund_id = fund_id AND deleted_at IS NULL ORDER BY date LOOP
            done := ARRAY[]::uuid[];
            LOOP
                pending := 0; progressed := false;
                FOR movement IN SELECT t.*, s.currency_code AS source_currency, d.currency_code AS destination_currency
                    FROM public.finance_transactions t
                    JOIN public.finance_accounts s ON (s.owner_id,s.workspace_id,s.id)=(t.owner_id,t.workspace_id,t.source_account_id)
                    JOIN public.finance_accounts d ON (d.owner_id,d.workspace_id,d.id)=(t.owner_id,t.workspace_id,t.destination_account_id)
                    WHERE t.owner_id = NEW.owner_id AND t.workspace_id = NEW.workspace_id
                      AND t.reserved_fund_id = fund_id AND t.deleted_at IS NULL AND t.date = instant
                      AND t.type = 'transfer' AND NOT(t.id = ANY(done)) ORDER BY t.id LOOP
                    IF movement.source_currency <> movement.destination_currency THEN
                        RAISE EXCEPTION 'Reserved transfer currencies differ' USING ERRCODE = '23514';
                    END IF;
                    source_balance := coalesce((balances->>movement.source_account_id::text)::numeric,0);
                    IF source_balance >= movement.reserved_amount_minor THEN
                        balances := jsonb_set(balances, ARRAY[movement.source_account_id::text], to_jsonb(source_balance - movement.reserved_amount_minor));
                        balances := jsonb_set(balances, ARRAY[movement.destination_account_id::text],
                            to_jsonb(coalesce((balances->>movement.destination_account_id::text)::numeric,0) + movement.reserved_amount_minor));
                        done := array_append(done,movement.id); progressed := true;
                    ELSE pending := pending + 1; END IF;
                END LOOP;
                EXIT WHEN pending = 0;
                IF NOT progressed THEN RAISE EXCEPTION 'Reserved transfer has no funding at its source' USING ERRCODE = '23514'; END IF;
            END LOOP;
            FOR movement IN SELECT * FROM public.finance_transactions
                WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
                  AND reserved_fund_id = fund_id AND deleted_at IS NULL AND date = instant AND type IN ('expense','fee') LOOP
                source_balance := coalesce((balances->>movement.source_account_id::text)::numeric,0);
                IF source_balance < movement.reserved_amount_minor THEN
                    RAISE EXCEPTION 'Reserved payment has no funding at its account and date' USING ERRCODE = '23514';
                END IF;
                balances := jsonb_set(balances, ARRAY[movement.source_account_id::text], to_jsonb(source_balance - movement.reserved_amount_minor));
            END LOOP;
        END LOOP;
    END LOOP;
    RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION finance_private.check_reserved_locations() FROM PUBLIC, anon, authenticated;
CREATE CONSTRAINT TRIGGER reserved_locations_guard AFTER INSERT OR UPDATE ON public.finance_transactions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION finance_private.check_reserved_locations();
CREATE CONSTRAINT TRIGGER reserved_locations_fund_guard AFTER INSERT OR UPDATE ON public.finance_reserved_funds
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION finance_private.check_reserved_locations();

COMMENT ON COLUMN public.finance_transactions.reserved_amount_minor IS
    'Expense/fee: consumes this portion of the reserve, excluded from monthly budget. Transfer: relocates this portion to destination without consuming the reserve.';
NOTIFY pgrst, 'reload schema';
