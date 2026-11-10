import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Same cloud project and public key as the iPhone app (`CloudConfiguration.json`). The publishable key
/// is public by design: every table is protected per user by row-level security.
const supabaseUrl = 'https://coeicjffmpclqowsqeys.supabase.co';
const supabasePublishableKey = 'sb_publishable_ybkbyweHXrOHRUugSwpBgw_J4Wcfq5U';

/// Downloads the person's finances with the same function the iPhone uses to sync (`finance_snapshot`).
class FinanceRepository extends ChangeNotifier {
  Finances? finances;
  String? error;
  bool loading = false;
  DateTime? loadedAt;

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final response = await Supabase.instance.client.rpc('finance_snapshot');
      final document = Map<String, dynamic>.from((response as Map)['document'] as Map);
      finances = Finances.fromDocument(document);
      loadedAt = DateTime.now();
    } on AuthException {
      error = 'Tu sesión ha caducado. Vuelve a entrar.';
    } catch (_) {
      error = 'No se han podido cargar tus finanzas. Comprueba la conexión y vuelve a intentarlo.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void clear() {
    finances = null;
    error = null;
    loadedAt = null;
    notifyListeners();
  }
}
