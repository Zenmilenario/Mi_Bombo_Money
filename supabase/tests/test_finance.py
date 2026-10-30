"""Real PostgreSQL tests. Runs only in a newly created ephemeral LOCAL database.
Auth JWT validation is supplied by Supabase, not emulated here; this suite verifies
SQL grants, RLS, foreign keys, revisions and money invariants under real low-privilege roles.
"""
import os
from pathlib import Path
import re
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Event
import time
from uuid import uuid4
import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg.types.json import Jsonb
import json

ROOT = Path(__file__).resolve().parents[2]
A, B = '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002'
WA, WB = '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000012'
TABLES = ['workspaces', 'institutions', 'accounts', 'categories', 'cards', 'reserved_funds', 'category_rules',
          'monthly_budgets', 'recurring_budgets', 'savings_goals', 'recurring_movements', 'import_batches',
          'balance_snapshots', 'transactions']
# Thirteen existing SwiftData entities plus a cloud workspace boundary (14 tables).
DSN = ''

class CloudStorageTests(unittest.TestCase):
    def setUp(self):
        self.db = psycopg.connect(DSN)
        self.ids = {owner: {name: str(uuid4()) for name in TABLES} for owner in [A, B]}
        for owner, workspace in [(A, WA), (B, WB)]:
            self.db.execute('INSERT INTO auth.users(id) VALUES (%s)', (owner,))
            self.insert('workspaces', dict(id=workspace, owner_id=owner, kind='personal', name='Personal'))
            for name in TABLES[1:]:
                self.insert(name, self.record(name, owner, workspace))
        self.as_user(A)

    def tearDown(self):
        self.db.rollback()
        self.db.close()

    def as_user(self, owner, role='authenticated'):
        self.db.execute('RESET ROLE')
        self.db.execute(sql.SQL('SET LOCAL ROLE {}').format(sql.Identifier(role)))
        self.db.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (owner or '',))

    def insert(self, name, record):
        keys = list(record)
        return self.db.execute(sql.SQL('INSERT INTO public.{} ({}) VALUES ({}) RETURNING id, revision').format(
            sql.Identifier('finance_' + name), sql.SQL(',').join(map(sql.Identifier, keys)),
            sql.SQL(',').join(sql.Placeholder() for _ in keys)), list(record.values())).fetchone()

    def record(self, name, owner=A, workspace=WA, new=False):
        ids = self.ids[owner]
        row = dict(id=str(uuid4()) if new else ids[name], owner_id=owner, workspace_id=workspace)
        fields = {
            'institutions': dict(name='Entidad ficticia'),
            'accounts': dict(name='Corriente ficticia', type='checking', opening_date='2026-01-01T12:00:00Z', institution_id=ids['institutions']),
            'categories': dict(name='Formación', kind='expense'),
            'cards': dict(name='Débito de prueba', type='debit', linked_account_id=ids['accounts']),
            'reserved_funds': dict(name='Objetivo', amount_minor=5000, account_id=ids['accounts']),
            'category_rules': dict(phrase='Escuela', transaction_type='expense', category_id=ids['categories']),
            'monthly_budgets': dict(month_start='2026-02-01' if new else '2026-01-01', limit_minor=10000, category_id=ids['categories']),
            'recurring_budgets': dict(start_month='2026-01-01', base_limit_minor=10000, remainder_choice='carryForward', category_id=ids['categories']),
            'savings_goals': dict(name='Objetivo ficticio', target_amount_minor=20000, linked_account_id=ids['accounts']),
            'recurring_movements': dict(name='Suscripción', type='expense', amount_minor=1000, description_text='Suscripción', frequency='monthly', next_due_date='2026-11-01T12:00:00Z', source_account_id=ids['accounts']),
            'import_batches': dict(file_name='ficticio.csv', source='csv', imported_at='2026-01-01T12:00:00Z'),
            'balance_snapshots': dict(date='2026-01-01T12:00:00Z', balance_minor=20000, source='manual', account_id=ids['accounts']),
            'transactions': dict(date='2026-01-05T12:00:00Z', type='expense', amount_minor=1000, description_text='Pago de prueba', reserved_fund_id=ids['reserved_funds'], reserved_amount_minor=500, source_account_id=ids['accounts'], category_id=ids['categories']),
        }
        row.update(fields[name])
        return row

    def expect_sqlstate(self, state, operation):
        with self.assertRaises(psycopg.Error) as caught:
            with self.db.transaction():
                operation()
        self.assertEqual(caught.exception.sqlstate, state)

    def test_every_table_has_rls_and_no_anonymous_or_destructive_grants(self):
        for name in TABLES:
            with self.subTest(table=name):
                table = 'public.finance_' + name
                row = self.db.execute('SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid=%s::regclass', (table,)).fetchone()
                self.assertEqual(row, (True, True))
                for role, privilege in [('anon','SELECT'),('anon','INSERT'),('anon','UPDATE'),('anon','DELETE'),('authenticated','DELETE'),('authenticated','TRUNCATE')]:
                    self.assertFalse(self.db.execute('SELECT has_table_privilege(%s,%s,%s)', (role,table,privilege)).fetchone()[0])

    def test_banking_links_are_unique_per_workspace_and_survive_snapshot_roundtrip(self):
        key = 'enable:' + 'a' * 64
        self.db.execute('UPDATE public.finance_accounts SET bank_identity_key=%s WHERE id=%s', (key, self.ids[A]['accounts']))
        self.db.execute('UPDATE public.finance_transactions SET bank_entry_key=%s WHERE id=%s', ('enable-entry:fixture', self.ids[A]['transactions']))
        document = self.db.execute('SELECT public.finance_snapshot(%s)', (WA,)).fetchone()[0]
        self.assertEqual(document['document']['accounts'][0]['bankIdentityKey'], key)
        self.assertEqual(document['document']['transactions'][0]['bankEntryKey'], 'enable-entry:fixture')
        saved = self.db.execute('SELECT public.finance_save_snapshot(%s,%s,%s)', (WA, document['revision'], Jsonb(document['document']))).fetchone()[0]
        self.assertEqual(saved['document']['accounts'][0]['bankIdentityKey'], key)
        self.expect_sqlstate('23505', lambda: self.insert('accounts', dict(self.record('accounts', new=True), bank_identity_key=key)))
        self.expect_sqlstate('23505', lambda: self.insert('transactions', dict(self.record('transactions', new=True), bank_entry_key='enable-entry:fixture')))
        self.expect_sqlstate('23514', lambda: self.db.execute('UPDATE public.finance_accounts SET bank_identity_key=%s WHERE id=%s', ('raw-iban-not-allowed', self.ids[A]['accounts'])))

    def test_user_sees_only_own_rows_in_every_table(self):
        for owner in [A,B]:
            self.as_user(owner)
            for name in TABLES:
                with self.subTest(user=owner,table=name):
                    rows=self.db.execute(sql.SQL('SELECT owner_id FROM public.{}').format(sql.Identifier('finance_'+name))).fetchall()
                    self.assertEqual([str(row[0]) for row in rows], [owner])

    def test_anonymous_reads_and_writes_are_denied_in_every_table(self):
        self.as_user(None,'anon')
        for name in TABLES:
            with self.subTest(table=name):
                table=sql.Identifier('finance_'+name)
                for statement in [sql.SQL('SELECT * FROM public.{}').format(table), sql.SQL('UPDATE public.{} SET deleted_at=now()').format(table),sql.SQL('DELETE FROM public.{}').format(table)]:
                    self.expect_sqlstate('42501', lambda s=statement: self.db.execute(s))
                row=dict(kind='sandbox',name='Prueba',owner_id=A) if name=='workspaces' else self.record(name,new=True)
                self.expect_sqlstate('42501',lambda n=name,r=row:self.insert(n,r))

    def test_authenticated_user_can_insert_update_and_soft_delete_own_rows(self):
        for name in TABLES:
            with self.subTest(table=name):
                record=dict(kind='sandbox',name='Prueba',owner_id=A) if name=='workspaces' else self.record(name,new=True)
                inserted=self.insert(name,record)
                table=sql.Identifier('finance_'+name)
                result=self.db.execute(sql.SQL('UPDATE public.{} SET deleted_at=now(),revision=999 WHERE id=%s RETURNING revision,deleted_at').format(table),(inserted[0],)).fetchone()
                self.assertEqual(result[0],2)
                self.assertIsNotNone(result[1])
                self.expect_sqlstate('42501',lambda t=table:self.db.execute(sql.SQL('DELETE FROM public.{} WHERE owner_id=%s').format(t),(A,)))

    def test_spoofed_owner_and_cross_user_updates_denied(self):
        for name in TABLES:
            with self.subTest(table=name):
                row=dict(kind='sandbox',name='Spoofed',owner_id=B) if name=='workspaces' else self.record(name,B,WB,new=True)
                self.expect_sqlstate('42501',lambda n=name,r=row:self.insert(n,r))
                result=self.db.execute(sql.SQL('UPDATE public.{} SET deleted_at=now() WHERE owner_id=%s').format(sql.Identifier('finance_'+name)),(B,))
                self.assertEqual(result.rowcount,0)

    def test_authenticated_without_subject_sees_nothing(self):
        self.as_user(None)
        for name in TABLES:
            self.assertEqual(self.db.execute(sql.SQL('SELECT count(*) FROM public.{}').format(sql.Identifier('finance_'+name))).fetchone()[0],0)
        self.expect_sqlstate('42501',lambda:self.insert('workspaces',dict(owner_id=A,kind='personal',name='Forbidden')))

    def test_relations_cannot_point_to_other_owner_or_workspace(self):
        row=self.record('accounts',new=True); row['institution_id']=self.ids[B]['institutions']
        self.expect_sqlstate('23503',lambda:self.insert('accounts',row))
        row=self.record('transactions',new=True); row['workspace_id']=WB
        self.expect_sqlstate('23503',lambda:self.insert('transactions',row))
        test_ws=self.insert('workspaces',dict(kind='sandbox',name='Sandbox',owner_id=A))[0]
        row=self.record('transactions',new=True); row['workspace_id']=test_ws
        self.expect_sqlstate('23503',lambda:self.insert('transactions',row))

    def test_identity_and_workspace_kind_are_immutable(self):
        self.expect_sqlstate('42501',lambda:self.db.execute('UPDATE public.finance_accounts SET owner_id=%s WHERE owner_id=%s',(B,A)))
        self.expect_sqlstate('23514',lambda:self.db.execute("UPDATE public.finance_workspaces SET kind='sandbox' WHERE id=%s",(WA,)))
        self.expect_sqlstate('23514',lambda:self.db.execute('UPDATE public.finance_accounts SET id=%s WHERE owner_id=%s',(uuid4(),A)))

    def test_reserved_payment_requires_its_own_account(self):
        account=self.insert('accounts',self.record('accounts',new=True))[0]
        row=self.record('transactions',new=True);row['source_account_id']=account
        self.expect_sqlstate('23503',lambda:self.insert('transactions',row))

    def test_reserved_money_cannot_be_overspent_even_by_future_payments(self):
        row=self.record('transactions',new=True);row.update(amount_minor=6000,reserved_amount_minor=5000,date='2030-01-01T00:00:00Z')
        self.expect_sqlstate('23514',lambda:self.insert('transactions',row))
        self.expect_sqlstate('23514',lambda:self.db.execute('UPDATE public.finance_reserved_funds SET amount_minor=499 WHERE owner_id=%s',(A,)))

    def test_edit_delete_and_restore_release_and_recommit_reserved_money(self):
        row=self.record('transactions',new=True);row.update(amount_minor=4500,reserved_amount_minor=4500)
        other=self.insert('transactions',row)[0]
        self.db.execute('UPDATE public.finance_transactions SET deleted_at=now() WHERE id=%s',(other,))
        replacement=self.insert('transactions',self.record('transactions',new=True))[0]
        self.expect_sqlstate('23514',lambda:self.db.execute('UPDATE public.finance_transactions SET deleted_at=NULL WHERE id=%s',(other,)))
        self.db.execute('UPDATE public.finance_transactions SET deleted_at=now() WHERE id=%s',(replacement,))
        self.db.execute('UPDATE public.finance_transactions SET deleted_at=NULL WHERE id=%s',(other,))

    def test_invalid_amounts_and_funding_shapes_are_rejected(self):
        for changes in [dict(amount_minor=0),dict(amount_minor=-1),dict(reserved_amount_minor=1001),dict(reserved_amount_minor=None),dict(type='income'),dict(reserved_fund_id=None)]:
            with self.subTest(changes=changes):
                row=self.record('transactions',new=True);row.update(changes)
                self.expect_sqlstate('23514',lambda r=row:self.insert('transactions',r))
        row=self.record('cards',new=True);row['last_four']='1234567890123456'
        self.expect_sqlstate('23514',lambda:self.insert('cards',row))

    def test_provider_identifier_is_deduplicated_per_account(self):
        row=self.record('transactions',new=True);row['external_id']='fictitious-reference'
        self.insert('transactions',row)
        row['id']=str(uuid4())
        self.expect_sqlstate('23505',lambda:self.insert('transactions',row))

    def test_optimistic_revision_filter_rejects_stale_write(self):
        item=self.ids[A]['accounts']
        first=self.db.execute('UPDATE public.finance_accounts SET notes=%s WHERE id=%s AND revision=1 RETURNING revision',('New',item)).fetchone()
        self.assertEqual(first[0],2)
        stale=self.db.execute('UPDATE public.finance_accounts SET notes=%s WHERE id=%s AND revision=1 RETURNING revision',('Stale',item)).fetchone()
        self.assertIsNone(stale)
        self.assertEqual(self.db.execute('SELECT notes FROM public.finance_accounts WHERE id=%s',(item,)).fetchone()[0],'New')

    def snapshot(self, workspace=WA):
        return self.db.execute('SELECT public.finance_snapshot(%s)',(workspace,)).fetchone()[0]

    def save_snapshot(self, snapshot):
        return self.db.execute('SELECT public.finance_save_snapshot(%s,%s,%s,%s)',
            (snapshot['workspace_id'],snapshot['revision'],Jsonb(snapshot['document']),'Europe/Madrid')).fetchone()[0]

    def test_snapshot_roundtrip_covers_all_entities_and_reserved_money(self):
        before=self.snapshot()
        self.assertEqual(len(before['document']['transactions']),1)
        self.assertEqual(before['document']['transactions'][0]['reservedAmountMinor'],500)
        after=self.save_snapshot(before)
        self.assertGreater(after['revision'],before['revision'])
        for key in ['institutions','accounts','categories','cards','reservedFunds','categoryRules','budgets','recurringBudgets','goals','recurringMovements','snapshots','importBatches','transactions']:
            self.assertEqual(len(after['document'][key]),1,key)
            for field,value in before['document'][key][0].items():
                if field not in ['updatedAt','monthStart','startMonth','endMonth']:
                    self.assertEqual(after['document'][key][0][field],value,(key,field))

    def test_snapshot_rejects_stale_revisions_and_cross_owner_workspace(self):
        before=self.snapshot()
        after=self.save_snapshot(before)
        self.expect_sqlstate('40001',lambda:self.save_snapshot(before))
        self.expect_sqlstate('42501',lambda:self.snapshot(WB))
        after['workspace_id']=WB
        self.expect_sqlstate('42501',lambda:self.save_snapshot(after))

    def test_snapshot_invalid_payload_is_atomic(self):
        before=self.snapshot()
        broken=json.loads(json.dumps(before))
        broken['document']['transactions'][0]['reservedAmountMinor']=999999
        self.expect_sqlstate('23514',lambda:self.save_snapshot(broken))
        after=self.snapshot()
        self.assertEqual(before['document'],after['document'])
        self.assertEqual(before['revision'],after['revision'])
        del broken['document']['accounts']
        self.expect_sqlstate('22023',lambda:self.save_snapshot(broken))

    def test_snapshot_deletions_create_tombstones_and_release_reserves(self):
        before=self.snapshot()
        original=before['document']['transactions'][0]['id']
        before['document']['transactions']=[]
        after=self.save_snapshot(before)
        self.assertEqual(after['document']['transactions'],[])
        self.assertIsNotNone(self.db.execute('SELECT deleted_at FROM public.finance_transactions WHERE id=%s',(original,)).fetchone()[0])
        after['document']['reservedFunds'][0]['amountMinor']=1
        self.save_snapshot(after)

    def test_snapshot_default_workspace_and_anonymous_rejection(self):
        self.assertEqual(self.db.execute('SELECT public.finance_snapshot(NULL)').fetchone()[0]['workspace_id'],WA)
        self.as_user(None,'anon')
        self.expect_sqlstate('42501',lambda:self.db.execute('SELECT public.finance_snapshot(NULL)'))

    def test_snapshot_preserves_posted_history_after_rule_and_import_log_removed(self):
        before=self.snapshot()
        transaction=before['document']['transactions'][0]
        transaction['recurringMovementID']=str(uuid4())
        transaction['importBatchID']=str(uuid4())
        before['document']['recurringMovements']=[]
        before['document']['importBatches']=[]
        after=self.save_snapshot(before)
        self.assertEqual(after['document']['transactions'][0]['recurringMovementID'],transaction['recurringMovementID'])
        self.assertEqual(after['document']['transactions'][0]['importBatchID'],transaction['importBatchID'])
        self.assertEqual(after['document']['transactions'][0]['amountMinor'],transaction['amountMinor'])

    def test_snapshot_payload_cannot_override_server_ownership(self):
        before=self.snapshot()
        before['document']['accounts'][0]['owner_id']=B
        before['document']['accounts'][0]['workspace_id']=WB
        self.save_snapshot(before)
        self.assertEqual(str(self.db.execute('SELECT owner_id FROM public.finance_accounts').fetchone()[0]),A)

    def test_concurrent_payments_cannot_double_spend_a_reserve(self):
        owner, workspace, account, fund = (uuid4() for _ in range(4))
        with psycopg.connect(DSN, autocommit=True) as admin:
            admin.execute('INSERT INTO auth.users(id) VALUES (%s)', (owner,))
            admin.execute("INSERT INTO public.finance_workspaces(owner_id,id,kind,name) VALUES (%s,%s,'personal','Concurrency test')", (owner,workspace))
            admin.execute("INSERT INTO public.finance_accounts(owner_id,workspace_id,id,name,type,opening_date) VALUES (%s,%s,%s,'Account','checking',now())",(owner,workspace,account))
            admin.execute("INSERT INTO public.finance_reserved_funds(owner_id,workspace_id,id,name,amount_minor,account_id) VALUES (%s,%s,%s,'Fund',5000,%s)",(owner,workspace,fund,account))
        first_inserted, second_started, allow_commit = Event(), Event(), Event()
        statement = """INSERT INTO public.finance_transactions(owner_id,workspace_id,date,type,amount_minor,
            description_text,source_account_id,reserved_fund_id,reserved_amount_minor)
            VALUES (%s,%s,now(),'expense',4000,'Concurrent payment',%s,%s,4000)"""
        def pay(first):
            try:
                with psycopg.connect(DSN) as connection:
                    connection.execute('SET LOCAL ROLE authenticated')
                    connection.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(str(owner),))
                    connection.execute("SET LOCAL statement_timeout = '5s'")
                    if not first:
                        if not first_inserted.wait(3): raise RuntimeError('First payment did not start')
                        second_started.set()
                    connection.execute(statement,(owner,workspace,account,fund))
                    if first:
                        first_inserted.set()
                        if not allow_commit.wait(3): raise RuntimeError('Commit was not released')
                return 'committed'
            except psycopg.Error as error:
                return error.sqlstate
        with ThreadPoolExecutor(max_workers=2) as pool:
            first, second = pool.submit(pay,True), pool.submit(pay,False)
            try:
                self.assertTrue(second_started.wait(3))
                deadline=time.monotonic()+2
                blocked=False
                with psycopg.connect(DSN,autocommit=True) as observer:
                    while time.monotonic()<deadline:
                        blocked=observer.execute("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock')").fetchone()[0]
                        if blocked: break
                        time.sleep(0.01)
                self.assertTrue(blocked, 'Second writer must wait for the reserve lock')
            finally:
                allow_commit.set()
            self.assertEqual(first.result(timeout=6),'committed')
            self.assertEqual(second.result(timeout=6),'23514')
        with psycopg.connect(DSN,autocommit=True) as admin:
            self.assertEqual(admin.execute('SELECT sum(reserved_amount_minor) FROM public.finance_transactions WHERE owner_id=%s',(owner,)).fetchone()[0],4000)
            admin.execute('DELETE FROM auth.users WHERE id=%s',(owner,))


def main():
    global DSN
    admin_dsn=os.environ.get('CLOUD_TEST_ADMIN_DSN','dbname=postgres user=postgres')
    parts=conninfo_to_dict(admin_dsn)
    if parts.get('host','') not in ['', 'localhost','127.0.0.1','::1','/var/run/postgresql']:
        raise SystemExit('Refusing to create test databases on a non-local host.')
    database='mibombo_'+uuid4().hex+'_cloud_test'
    assert re.fullmatch(r'mibombo_[a-f0-9]{32}_cloud_test',database)
    with psycopg.connect(admin_dsn,autocommit=True) as admin:
        admin.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(database)))
        try:
            DSN=make_conninfo(admin_dsn,dbname=database)
            with psycopg.connect(DSN) as setup:
                setup.execute((ROOT/'supabase/tests/bootstrap_local.sql').read_text(encoding='utf-8-sig'))
                for migration in sorted((ROOT/'supabase/migrations').glob('*.sql')):
                    setup.execute(migration.read_text(encoding='utf-8'))
            result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CloudStorageTests))
        finally:
            admin.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(database)))
    raise SystemExit(0 if result.wasSuccessful() else 1)

if __name__=='__main__': main()
