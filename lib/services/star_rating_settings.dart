import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _showStarRatingsPreferenceKey = 'showStarRatings';

final showStarRatingsProvider = FutureProvider<bool>((ref) async {
  final preferences = await SharedPreferences.getInstance();
  return preferences.getBool(_showStarRatingsPreferenceKey) ?? false;
});

Future<void> setShowStarRatings(WidgetRef ref, bool enabled) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(_showStarRatingsPreferenceKey, enabled);
  ref.invalidate(showStarRatingsProvider);
}
