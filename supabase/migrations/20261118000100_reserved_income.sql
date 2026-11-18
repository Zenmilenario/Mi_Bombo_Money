-- Income set aside for a reserve (Doblón 0.28.0, 18 November 2026). NOT APPLIED until the owner confirms it.
--
-- An income or interest may name a reserve and the part set aside for it:
--   * dated after the reserve was created, that part adds to the reserve in the income's account (for example,
--     interest the person decides to keep in it);
--   * dated before, it is where the reserve's starting amount came from: already counted, never added again.
-- Payments and moves keep their rules. The app leaves that part out of everyday income in both cases.

ALTER TABLE public.finance_transactions DROP CONSTRAINT finance_reserved_allocation_check;
ALTER TABLE public.finance_transactions
    ADD CONSTRAINT finance_reserved_allocation_check CHECK (
        (reserved_fund_id IS NULL AND reserved_amount_minor IS NULL) OR
        (reserved_fund_id IS NOT NULL AND reserved_amount_minor IS NOT NULL
         AND reserved_amount_minor > 0 AND reserved_amount_minor <= amount_minor
         AND type IN ('expense','fee','transfer','income','interest')));

-- Payments of a reserve may not exceed what it was given: its starting amount plus income added after it existed.
CREATE OR REPLACE FUNCTION finance_private.check_reserved_payments() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE fund_ids uuid[]; fund_total bigint; fund_deleted timestamptz; fund_created timestamptz; fund_key uuid; allocated numeric; added numeric;
BEGIN
    IF TG_TABLE_NAME = 'finance_transactions' THEN
        IF TG_OP = 'UPDATE' THEN fund_ids := ARRAY[OLD.reserved_fund_id, NEW.reserved_fund_id];
        ELSE fund_ids := ARRAY[NEW.reserved_fund_id]; END IF;
        PERFORM id FROM public.finance_reserved_funds
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id AND id = ANY(fund_ids)
            ORDER BY id FOR UPDATE;
        IF NEW.reserved_fund_id IS NULL OR NEW.deleted_at IS NOT NULL THEN RETURN NEW; END IF;
        SELECT amount_minor, deleted_at, created_at INTO fund_total, fund_deleted, fund_created FROM public.finance_reserved_funds
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id AND id = NEW.reserved_fund_id;
        IF NOT FOUND OR fund_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'Reserved fund is unavailable' USING ERRCODE = '23514';
        END IF;
        fund_key := NEW.reserved_fund_id;
    ELSE
        fund_total := NEW.amount_minor; fund_created := NEW.created_at; fund_key := NEW.id;
    END IF;
    SELECT coalesce(sum(reserved_amount_minor) FILTER (WHERE type IN ('expense','fee')), 0),
           coalesce(sum(reserved_amount_minor) FILTER (WHERE type IN ('income','interest') AND date > fund_created), 0)
        INTO allocated, added FROM public.finance_transactions
        WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id AND reserved_fund_id = fund_key AND deleted_at IS NULL;
    IF allocated > fund_total + added THEN
        RAISE EXCEPTION 'Reserved payments exceed the funded amount' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;

-- Where each reserve's money is, instant by instant: income added first, then moves, then payments.
CREATE OR REPLACE FUNCTION finance_private.check_reserved_locations() RETURNS trigger
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
            FOR movement IN SELECT * FROM public.finance_transactions
                WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
                  AND reserved_fund_id = fund_id AND deleted_at IS NULL AND date = instant
                  AND type IN ('income','interest') AND date > fund.created_at LOOP
                balances := jsonb_set(balances, ARRAY[movement.source_account_id::text],
                    to_jsonb(coalesce((balances->>movement.source_account_id::text)::numeric,0) + movement.reserved_amount_minor));
            END LOOP;
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
