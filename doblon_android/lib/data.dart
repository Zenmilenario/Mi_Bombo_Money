import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' hide Category;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'bank_activity.dart';
import 'banking.dart';
import 'edits.dart';
import 'learning.dart';
import 'models.dart';

/// Same cloud project and public key as the iPhone app (`CloudConfiguration.json`). The publishable key
/// is public by design: every table is protected per user by row-level security.
const supabaseUrl = 'https://coeicjffmpclqowsqeys.supabase.co';
const supabasePublishableKey = 'sb_publishable_ybkbyweHXrOHRUugSwpBgw_J4Wcfq5U';

/// The cloud copy as `finance_snapshot` returns it: the raw document is kept so that saving back never
/// drops a field the iPhone stores.
class CloudCopy {
  CloudCopy(this.workspaceId, this.revision, this.document);
  final String workspaceId;
  final int revision;
  final Map<String, dynamic> document;

  static CloudCopy parse(dynamic response) {
    final map = Map<String, dynamic>.from(response as Map);
    return CloudCopy('${map['workspace_id']}', (map['revision'] as num).toInt(), Map<String, dynamic>.from(map['document'] as Map));
  }

  Map<String, dynamic> toJson() => {'workspace_id': workspaceId, 'revision': revision, 'document': document};
}

/// Keeps the last cloud copy and the changes not yet uploaded on this device, per user, in the app's private
/// storage. With it the app opens and works without connection; changes are uploaded when it returns.
class LocalStore {
  LocalStore(this.directory);
  final Directory directory;

  File _file(String user, String name) => File('${directory.path}${Platform.pathSeparator}$name-$user.json');

  Future<CloudCopy?> loadCopy(String user) async {
    try {
      return CloudCopy.parse(jsonDecode(await _file(user, 'cloud').readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<List<Operation>> loadPending(String user) async {
    try {
      final list = jsonDecode(await _file(user, 'pending').readAsString()) as List;
      return [for (final item in list) Operation.fromJson(Map<String, dynamic>.from(item as Map))];
    } catch (_) {
      return [];
    }
  }

  /// Written to a temporary file and renamed, so a crash never leaves half a file.
  Future<void> _write(File file, Object value) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> saveCopy(String user, CloudCopy copy) => _write(_file(user, 'cloud'), copy.toJson());
  Future<void> savePending(String user, List<Operation> pending) => _write(_file(user, 'pending'), [for (final op in pending) op.toJson()]);

  Future<void> clear(String user) async {
    for (final name in ['cloud', 'pending']) {
      final file = _file(user, name);
      if (await file.exists()) await file.delete();
    }
  }
}

/// Downloads and saves the person's finances with the same functions the iPhone uses to sync.
class FinanceRepository extends ChangeNotifier {
  FinanceRepository({LocalStore? store}) : _store = store;

  LocalStore? _store;
  Finances? finances;
  CloudCopy? copy;
  List<Operation> pending = [];
  String? error;
  bool loading = false;
  DateTime? loadedAt;
  bool _opened = false;

  String? get _user => Supabase.instance.client.auth.currentUser?.id;

  Future<LocalStore> _local() async => _store ??= LocalStore(await getApplicationSupportDirectory());

  Future<CloudCopy> _fetch() async => CloudCopy.parse(await Supabase.instance.client.rpc('finance_snapshot'));

  /// Shows the device copy at once, then uploads pending changes and downloads the latest cloud copy.
  Future<void> refresh() async {
    if (loading) return;
    final user = _user;
    if (user == null) return;
    if (!_opened) {
      _opened = true;
      final store = await _local();
      pending = await store.loadPending(user);
      final saved = await store.loadCopy(user);
      if (saved != null) _show(saved);
      learning = await Learning.open(store.directory, user);
      bankActivity = await BankActivityStore(store.directory).load(user);
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (pending.isNotEmpty) {
        await _upload();
      } else {
        await _adopt(await _fetch());
      }
    } on AuthException {
      error = 'Tu sesión ha caducado. Vuelve a entrar.';
    } catch (_) {
      error = copy == null
          ? 'No se han podido cargar tus finanzas. Comprueba la conexión y vuelve a intentarlo.'
          : 'Sin conexión: ves la última copia de este dispositivo.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// The cloud document with the pending changes applied: what the screens show and the forms edit.
  Map<String, dynamic>? document;

  void _show(CloudCopy value) {
    copy = value;
    document = withPending(value.document, pending);
    finances = Finances.fromDocument(document!);
  }

  Future<void> _adopt(CloudCopy value) async {
    _show(value);
    loadedAt = DateTime.now();
    final user = _user;
    if (user != null) await (await _local()).saveCopy(user, value);
  }

  /// Applies `change` to the latest cloud document and saves it with the expected revision. If another
  /// device saved in between, the cloud refuses (revision conflict): the change is applied again on the
  /// new document, up to three times, so nothing saved elsewhere is overwritten.
  Future<T> update<T>((Map<String, dynamic>, T) Function(Map<String, dynamic> document) change) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final current = await _fetch();
      final (document, result) = change(current.document);
      try {
        final saved = await Supabase.instance.client.rpc('finance_save_snapshot', params: {
          'p_workspace': current.workspaceId,
          'p_expected_revision': current.revision,
          'p_document': document,
          'p_timezone': 'Europe/Madrid',
        });
        await _adopt(CloudCopy.parse(saved));
        notifyListeners();
        return result;
      } on PostgrestException catch (error) {
        if (error.code == '40001' || error.message.contains('cloud_revision_conflict')) continue;
        rethrow;
      }
    }
    throw BankingError('cloud_conflict');
  }

  /// Records a change: it shows at once, is kept on the device and is uploaded as soon as possible.
  Future<void> apply(Operation op) async {
    final user = _user;
    if (user == null) return;
    pending = [...pending, op];
    await (await _local()).savePending(user, pending);
    if (copy != null) _show(copy!);
    notifyListeners();
    try {
      await _upload();
    } catch (_) {
      error = 'Guardado en este dispositivo. Se subirá a tu nube cuando haya conexión.';
      notifyListeners();
    }
  }

  bool _uploading = false;
  bool _again = false;

  /// One upload at a time; a change made during an upload is sent right after it.
  Future<void> _upload() async {
    final user = _user;
    if (user == null || pending.isEmpty) return;
    if (_uploading) {
      _again = true;
      return;
    }
    _uploading = true;
    try {
      do {
        _again = false;
        final sending = List<Operation>.from(pending);
        await update((document) => (withPending(document, sending), null));
        // Only what was sent is cleared: a change made meanwhile stays queued.
        pending = pending.sublist(sending.length);
        await (await _local()).savePending(user, pending);
        if (copy != null) _show(copy!);
        error = null;
        notifyListeners();
      } while (_again && pending.isNotEmpty);
    } finally {
      _uploading = false;
    }
  }

  String newId() => const Uuid().v4();

  /// What the person has taught the models on this device and profile (null until the first load).
  Learning? learning;

  /// The last bank report of each linked account (holds, balances, what it sent), by bank identity.
  Map<String, BankActivity> bankActivity = {};

  /// Keeps what each downloaded account reported, replacing that account's previous report.
  Future<void> recordBankActivity(List<AccountFeed> feeds, DateTime observedAt) async {
    final user = _user;
    if (user == null || feeds.isEmpty) return;
    bankActivity = {
      ...bankActivity,
      for (final feed in feeds) accountIdentity(feed.account.id): feed.activity(observedAt),
    };
    await BankActivityStore((await _local()).directory).save(user, bankActivity);
    notifyListeners();
  }

  /// Categorises movements and teaches the choice to the models (Swift `TransactionLearning.confirm`).
  Future<void> categorize(List<Transaction> rows, Category category) async {
    final op = categorizeOperation(rows, category, DateTime.now());
    final ids = {for (final id in op.data['ids'] as List) '$id'};
    await apply(op);
    final data = finances;
    if (data == null || learning == null) return;
    await learning!.confirmCategories(data.transactions.where((t) => ids.contains(t.id)).toList(), data);
    notifyListeners();
  }

  /// Tells the screens that something kept outside the document changed (what was learnt, bank reports).
  void changed() => notifyListeners();

  bool _correcting = false;

  /// Repeats the corrections the person taught on new bank movements, when the model has proved itself.
  Future<int> applyLearnedCorrections({Set<String>? only}) async {
    final data = finances;
    if (_correcting || data == null || learning == null || pending.isNotEmpty) return 0;
    _correcting = true;
    try {
      final op = await learning!.learnedCorrections(data, DateTime.now(), only: only);
      if (op == null) return 0;
      await apply(op);
      return (op.data['ops'] as List).length;
    } catch (_) {
      return 0;
    } finally {
      _correcting = false;
    }
  }

  Future<void> signOut() async {
    final user = _user;
    if (user != null) {
      final store = await _local();
      await store.clear(user);
      // Bank reports are not kept after signing out; what was taught to the models stays for this profile.
      await BankActivityStore(store.directory).clear(user);
    }
    bankActivity = {};
    learning = null;
    finances = null;
    copy = null;
    document = null;
    pending = [];
    error = null;
    loadedAt = null;
    _opened = false;
    notifyListeners();
  }
}
