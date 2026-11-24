import 'package:flutter/widgets.dart';

/// Closes the screen [context] belongs to, once an asynchronous save has ended.
///
/// `Navigator.pop` closes whatever is on top, which is not always this screen: a category menu or a date picker
/// opened while it was saving. Popping that menu with this screen's result fails (the menu expects another type of
/// result) and, in a release build, leaves the menu painted over a navigator that keeps closing the screens below.
/// Here, what is still open above the screen is closed first as cancelled (it never chooses anything), and then the
/// screen itself, with [result]. If the screen is no longer there (the person went back), nothing is closed.
void closeOwnScreen<T extends Object?>(BuildContext context, [T? result]) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isActive) return;
  final navigator = Navigator.of(context);
  if (!route.isCurrent) navigator.popUntil((r) => r == route);
  navigator.pop<T>(result);
}
