import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'banking.dart';
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
}

/// Downloads and saves the person's finances with the same functions the iPhone uses to sync.
class FinanceRepository extends ChangeNotifier {
  Finances? finances;
  CloudCopy? copy;
  String? error;
  bool loading = false;
  DateTime? loadedAt;

  Future<CloudCopy> _fetch() async => CloudCopy.parse(await Supabase.instance.client.rpc('finance_snapshot'));

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      _adopt(await _fetch());
    } on AuthException {
      error = 'Tu sesión ha caducado. Vuelve a entrar.';
    } catch (_) {
      error = 'No se han podido cargar tus finanzas. Comprueba la conexión y vuelve a intentarlo.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _adopt(CloudCopy value) {
    copy = value;
    finances = Finances.fromDocument(value.document);
    loadedAt = DateTime.now();
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
        _adopt(CloudCopy.parse(saved));
        notifyListeners();
        return result;
      } on PostgrestException catch (error) {
        if (error.code == '40001' || error.message.contains('cloud_revision_conflict')) continue;
        rethrow;
      }
    }
    throw BankingError('cloud_conflict');
  }

  void clear() {
    finances = null;
    copy = null;
    error = null;
    loadedAt = null;
    notifyListeners();
  }
}
