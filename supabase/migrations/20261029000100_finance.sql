-- Mi Bombo Money: normalized finance storage. No passwords or bank access tokens.
-- Apply with Supabase migrations to a dedicated development project.
CREATE SCHEMA IF NOT EXISTS finance_private;
REVOKE ALL ON SCHEMA finance_private FROM PUBLIC, anon, authenticated;

CREATE TABLE public.finance_workspaces (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    kind text NOT NULL CHECK (kind IN ('personal','sandbox','demo')),
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    source_key text,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0), deleted_at timestamptz,
    PRIMARY KEY (owner_id, id)
);
CREATE UNIQUE INDEX finance_personal_workspace ON public.finance_workspaces(owner_id)
    WHERE kind = 'personal' AND deleted_at IS NULL;
CREATE UNIQUE INDEX finance_test_workspace ON public.finance_workspaces(owner_id, kind, source_key)
    WHERE kind <> 'personal' AND source_key IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE public.finance_institutions (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    color_hex text NOT NULL DEFAULT '#1F6B7A', notes text NOT NULL DEFAULT '',
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id)
);

CREATE TABLE public.finance_accounts (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    type text NOT NULL CHECK (type IN ('checking','savings','cash','creditCard','investment','other')),
    currency_code text NOT NULL DEFAULT 'EUR' CHECK (currency_code ~ '^[A-Z]{3}$'),
    opening_balance_minor bigint NOT NULL DEFAULT 0, opening_date timestamptz NOT NULL,
    annual_interest_rate numeric(18,8) NOT NULL DEFAULT 0,
    target_balance_minor bigint NOT NULL DEFAULT 0, credit_limit_minor bigint CHECK (credit_limit_minor >= 0),
    include_in_net_worth boolean NOT NULL DEFAULT true, is_archived boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0, notes text NOT NULL DEFAULT '', last_updated_at timestamptz NOT NULL DEFAULT now(),
    institution_id uuid,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, institution_id) REFERENCES public.finance_institutions(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_categories (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    kind text NOT NULL CHECK (kind IN ('income','expense','both','transfer')),
    system_image text NOT NULL DEFAULT 'tag', color_hex text NOT NULL DEFAULT '#4D7C8A',
    is_archived boolean NOT NULL DEFAULT false, is_system boolean NOT NULL DEFAULT false, sort_order integer NOT NULL DEFAULT 0,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id)
);

CREATE TABLE public.finance_cards (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    type text NOT NULL CHECK (type IN ('debit','credit','prepaid','virtual')),
    last_four text NOT NULL DEFAULT '' CHECK (last_four ~ '^([0-9]{4})?$'),
    limit_minor bigint CHECK (limit_minor >= 0), limit_kind text CHECK (limit_kind IN ('perTransaction','daily','monthly','credit')),
    online_purchases_enabled boolean, contactless_enabled boolean, atm_withdrawals_enabled boolean,
    international_payments_enabled boolean, cashback_enabled boolean, cashback_percent numeric(7,4) CHECK (cashback_percent BETWEEN 0 AND 100),
    round_up_enabled boolean, is_archived boolean NOT NULL DEFAULT false, notes text NOT NULL DEFAULT '',
    institution_id uuid, linked_account_id uuid,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, institution_id) REFERENCES public.finance_institutions(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, linked_account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_reserved_funds (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    amount_minor bigint NOT NULL CHECK (amount_minor >= 0), notes text NOT NULL DEFAULT '', account_id uuid NOT NULL,
    UNIQUE(owner_id, workspace_id, id, account_id),
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_category_rules (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    phrase text NOT NULL CHECK (length(btrim(phrase)) >= 3),
    transaction_type text NOT NULL CHECK (transaction_type IN ('income','expense','interest','fee','transfer')),
    is_active boolean NOT NULL DEFAULT true, category_id uuid,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, category_id) REFERENCES public.finance_categories(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_monthly_budgets (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    month_start date NOT NULL CHECK (extract(day FROM month_start) = 1),
    limit_minor bigint NOT NULL CHECK (limit_minor >= 0), notes text NOT NULL DEFAULT '', category_id uuid NOT NULL,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, category_id) REFERENCES public.finance_categories(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_recurring_budgets (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    start_month date NOT NULL CHECK (extract(day FROM start_month) = 1),
    end_month date CHECK (extract(day FROM end_month) = 1 AND end_month > start_month),
    base_limit_minor bigint NOT NULL CHECK (base_limit_minor >= 0),
    remainder_choice text NOT NULL CHECK (remainder_choice IN ('save','carryForward')), category_id uuid NOT NULL,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, category_id) REFERENCES public.finance_categories(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_savings_goals (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    target_amount_minor bigint NOT NULL CHECK (target_amount_minor >= 0), current_amount_minor bigint NOT NULL DEFAULT 0 CHECK (current_amount_minor >= 0),
    target_date timestamptz, color_hex text NOT NULL DEFAULT '#2F7D66', notes text NOT NULL DEFAULT '',
    is_completed boolean NOT NULL DEFAULT false, linked_account_id uuid,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, linked_account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_recurring_movements (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    type text NOT NULL CHECK (type IN ('income','expense','interest','fee','transfer')),
    amount_minor bigint NOT NULL CHECK (amount_minor > 0), description_text text NOT NULL,
    notes text NOT NULL DEFAULT '', frequency text NOT NULL CHECK (frequency IN ('weekly','monthly','quarterly','yearly')),
    interval integer NOT NULL DEFAULT 1 CHECK (interval > 0), next_due_date timestamptz NOT NULL, end_date timestamptz,
    is_active boolean NOT NULL DEFAULT true, is_subscription boolean NOT NULL DEFAULT false, posts_automatically boolean,
    source_account_id uuid NOT NULL, destination_account_id uuid, category_id uuid,
    CHECK ((type = 'transfer' AND destination_account_id IS NOT NULL AND destination_account_id <> source_account_id)
    OR (type <> 'transfer' AND destination_account_id IS NULL)),
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, source_account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, destination_account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, category_id) REFERENCES public.finance_categories(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_import_batches (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    file_name text NOT NULL, source text NOT NULL CHECK (source IN ('csv','excel','bankAPI')),
    institution_name text NOT NULL DEFAULT '', imported_at timestamptz NOT NULL,
    imported_rows integer NOT NULL DEFAULT 0 CHECK (imported_rows >= 0), skipped_duplicates integer NOT NULL DEFAULT 0 CHECK (skipped_duplicates >= 0),
    possible_duplicates integer NOT NULL DEFAULT 0 CHECK (possible_duplicates >= 0), checksum text NOT NULL DEFAULT '', notes text NOT NULL DEFAULT '',
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id)
);

CREATE TABLE public.finance_balance_snapshots (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    date timestamptz NOT NULL, balance_minor bigint NOT NULL,
    source text NOT NULL CHECK (source IN ('manual','importFile','bankAPI')), notes text NOT NULL DEFAULT '', account_id uuid NOT NULL,
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id)
);

CREATE TABLE public.finance_transactions (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    deleted_at timestamptz,
    date timestamptz NOT NULL, type text NOT NULL CHECK (type IN ('income','expense','interest','fee','transfer')),
    amount_minor bigint NOT NULL CHECK (amount_minor > 0), description_text text NOT NULL CHECK (length(btrim(description_text)) > 0),
    notes text NOT NULL DEFAULT '', is_reconciled boolean NOT NULL DEFAULT false, fingerprint text NOT NULL DEFAULT '',
    duplicate_state text NOT NULL DEFAULT 'none' CHECK (duplicate_state IN ('none','possible','confirmed')),
    external_id text, import_batch_id uuid, recurring_movement_id uuid, reserved_fund_id uuid, reserved_amount_minor bigint,
    source_account_id uuid NOT NULL, destination_account_id uuid, category_id uuid,
    CHECK ((type = 'transfer' AND destination_account_id IS NOT NULL AND destination_account_id <> source_account_id)
    OR (type <> 'transfer' AND destination_account_id IS NULL)),
    CHECK ((reserved_fund_id IS NULL AND reserved_amount_minor IS NULL) OR
    (reserved_fund_id IS NOT NULL AND reserved_amount_minor IS NOT NULL AND reserved_amount_minor > 0
    AND reserved_amount_minor <= amount_minor AND type IN ('expense','fee'))),
    PRIMARY KEY(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id) REFERENCES public.finance_workspaces(owner_id, id),
    FOREIGN KEY(owner_id, workspace_id, source_account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, destination_account_id) REFERENCES public.finance_accounts(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, category_id) REFERENCES public.finance_categories(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, import_batch_id) REFERENCES public.finance_import_batches(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, recurring_movement_id) REFERENCES public.finance_recurring_movements(owner_id, workspace_id, id),
    FOREIGN KEY(owner_id, workspace_id, reserved_fund_id, source_account_id) REFERENCES public.finance_reserved_funds(owner_id, workspace_id, id, account_id)
);

CREATE UNIQUE INDEX finance_monthly_budget_identity ON public.finance_monthly_budgets(owner_id, workspace_id, category_id, month_start)
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX finance_external_movement_identity ON public.finance_transactions(owner_id, workspace_id, source_account_id, external_id)
    WHERE external_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX finance_transactions_month ON public.finance_transactions(owner_id, workspace_id, date);
CREATE INDEX finance_reserve_payments ON public.finance_transactions(owner_id, workspace_id, reserved_fund_id)
    WHERE reserved_fund_id IS NOT NULL AND deleted_at IS NULL;

CREATE FUNCTION finance_private.stamp_record() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.owner_id IS DISTINCT FROM OLD.owner_id OR NEW.id IS DISTINCT FROM OLD.id THEN
            RAISE EXCEPTION 'Record identity is immutable' USING ERRCODE = '23514';
        END IF;
        IF TG_TABLE_NAME <> 'finance_workspaces' THEN
            IF NEW.workspace_id IS DISTINCT FROM OLD.workspace_id THEN
                RAISE EXCEPTION 'Workspace is immutable' USING ERRCODE = '23514';
            END IF;
        ELSE
            IF NEW.kind IS DISTINCT FROM OLD.kind OR NEW.source_key IS DISTINCT FROM OLD.source_key THEN
                RAISE EXCEPTION 'Workspace source is immutable' USING ERRCODE = '23514';
            END IF;
        END IF;
        NEW.created_at := OLD.created_at;
        NEW.revision := OLD.revision + 1;
    ELSE
        NEW.revision := 1;
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION finance_private.stamp_record() FROM PUBLIC, anon, authenticated;

ALTER TABLE public.finance_workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_workspaces FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_workspaces FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_workspaces TO authenticated;
GRANT ALL ON public.finance_workspaces TO service_role;
CREATE POLICY owner_select ON public.finance_workspaces FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_workspaces FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_workspaces FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_workspaces
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_institutions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_institutions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_institutions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_institutions TO authenticated;
GRANT ALL ON public.finance_institutions TO service_role;
CREATE POLICY owner_select ON public.finance_institutions FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_institutions FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_institutions FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_institutions
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_accounts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_accounts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_accounts TO authenticated;
GRANT ALL ON public.finance_accounts TO service_role;
CREATE POLICY owner_select ON public.finance_accounts FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_accounts FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_accounts FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_accounts
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_categories FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_categories FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_categories TO authenticated;
GRANT ALL ON public.finance_categories TO service_role;
CREATE POLICY owner_select ON public.finance_categories FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_categories FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_categories FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_categories
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_cards FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_cards FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_cards TO authenticated;
GRANT ALL ON public.finance_cards TO service_role;
CREATE POLICY owner_select ON public.finance_cards FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_cards FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_cards FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_cards
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_reserved_funds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_reserved_funds FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_reserved_funds FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_reserved_funds TO authenticated;
GRANT ALL ON public.finance_reserved_funds TO service_role;
CREATE POLICY owner_select ON public.finance_reserved_funds FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_reserved_funds FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_reserved_funds FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_reserved_funds
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_category_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_category_rules FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_category_rules FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_category_rules TO authenticated;
GRANT ALL ON public.finance_category_rules TO service_role;
CREATE POLICY owner_select ON public.finance_category_rules FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_category_rules FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_category_rules FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_category_rules
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_monthly_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_monthly_budgets FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_monthly_budgets FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_monthly_budgets TO authenticated;
GRANT ALL ON public.finance_monthly_budgets TO service_role;
CREATE POLICY owner_select ON public.finance_monthly_budgets FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_monthly_budgets FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_monthly_budgets FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_monthly_budgets
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_recurring_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_recurring_budgets FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_recurring_budgets FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_recurring_budgets TO authenticated;
GRANT ALL ON public.finance_recurring_budgets TO service_role;
CREATE POLICY owner_select ON public.finance_recurring_budgets FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_recurring_budgets FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_recurring_budgets FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_recurring_budgets
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_savings_goals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_savings_goals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_savings_goals FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_savings_goals TO authenticated;
GRANT ALL ON public.finance_savings_goals TO service_role;
CREATE POLICY owner_select ON public.finance_savings_goals FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_savings_goals FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_savings_goals FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_savings_goals
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_recurring_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_recurring_movements FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_recurring_movements FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_recurring_movements TO authenticated;
GRANT ALL ON public.finance_recurring_movements TO service_role;
CREATE POLICY owner_select ON public.finance_recurring_movements FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_recurring_movements FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_recurring_movements FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_recurring_movements
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_import_batches FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_import_batches FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_import_batches TO authenticated;
GRANT ALL ON public.finance_import_batches TO service_role;
CREATE POLICY owner_select ON public.finance_import_batches FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_import_batches FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_import_batches FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_import_batches
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_balance_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_balance_snapshots FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_balance_snapshots FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_balance_snapshots TO authenticated;
GRANT ALL ON public.finance_balance_snapshots TO service_role;
CREATE POLICY owner_select ON public.finance_balance_snapshots FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_balance_snapshots FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_balance_snapshots FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_balance_snapshots
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

ALTER TABLE public.finance_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_transactions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_transactions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.finance_transactions TO authenticated;
GRANT ALL ON public.finance_transactions TO service_role;
CREATE POLICY owner_select ON public.finance_transactions FOR SELECT TO authenticated USING ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_insert ON public.finance_transactions FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE POLICY owner_update ON public.finance_transactions FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = owner_id) WITH CHECK ((SELECT auth.uid()) = owner_id);
CREATE TRIGGER stamp_record BEFORE INSERT OR UPDATE ON public.finance_transactions
    FOR EACH ROW EXECUTE FUNCTION finance_private.stamp_record();

-- Authenticated clients soft-delete via deleted_at. DELETE/TRUNCATE are deliberately not granted.
-- Retain tombstones and historical reserved funding until all devices acknowledge a later purge protocol.
CREATE FUNCTION finance_private.check_reserved_payments() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE fund_ids uuid[]; fund_total bigint; fund_deleted timestamptz; allocated numeric;
BEGIN
    IF TG_TABLE_NAME = 'finance_transactions' THEN
        IF TG_OP = 'UPDATE' THEN fund_ids := ARRAY[OLD.reserved_fund_id, NEW.reserved_fund_id];
        ELSE fund_ids := ARRAY[NEW.reserved_fund_id]; END IF;
        -- Consistent lock order serializes concurrent allocations and avoids double spending a reserve.
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
            AND reserved_fund_id = NEW.reserved_fund_id AND deleted_at IS NULL;
    ELSE
        fund_total := NEW.amount_minor;
        SELECT coalesce(sum(reserved_amount_minor), 0) INTO allocated FROM public.finance_transactions
            WHERE owner_id = NEW.owner_id AND workspace_id = NEW.workspace_id
            AND reserved_fund_id = NEW.id AND deleted_at IS NULL;
    END IF;
    IF allocated > fund_total THEN
        RAISE EXCEPTION 'Reserved payments exceed the funded amount' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION finance_private.check_reserved_payments() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER reserved_payment_guard AFTER INSERT OR UPDATE ON public.finance_transactions
    FOR EACH ROW EXECUTE FUNCTION finance_private.check_reserved_payments();
CREATE TRIGGER reserved_fund_guard AFTER UPDATE ON public.finance_reserved_funds
    FOR EACH ROW EXECUTE FUNCTION finance_private.check_reserved_payments();

COMMENT ON COLUMN public.finance_reserved_funds.amount_minor IS 'Total funding, including paid and committed allocations; not remaining balance.';
COMMENT ON COLUMN public.finance_transactions.reserved_amount_minor IS 'Immutable funding meaning: this portion of an expense is excluded from monthly budget, but is still an actual expense.';
