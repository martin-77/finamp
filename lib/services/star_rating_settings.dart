import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _showStarRatingsPreferenceKey = 'showStarRatings';
const _allowHalfStarRatingsPreferenceKey = 'allowHalfStarRatings';

final ValueNotifier<bool> showStarRatingsNotifier = ValueNotifier(false);

bool _starRatingSettingsInitialized = false;

bool get showStarRatingsEnabled => showStarRatingsNotifier.value;

Future<void> initializeStarRatingSettings() async {
  if (_starRatingSettingsInitialized) return;

  final preferences = await SharedPreferences.getInstance();
  showStarRatingsNotifier.value = preferences.getBool(_showStarRatingsPreferenceKey) ?? false;

  _starRatingSettingsInitialized = true;
}

final showStarRatingsProvider = FutureProvider<bool>((ref) async {
  await initializeStarRatingSettings();
  return showStarRatingsEnabled;
});

final allowHalfStarRatingsProvider = FutureProvider<bool>((ref) async {
  final preferences = await SharedPreferences.getInstance();
  return preferences.getBool(_allowHalfStarRatingsPreferenceKey) ?? false;
});

Future<bool> getAllowHalfStarRatings() async {
  final preferences = await SharedPreferences.getInstance();
  return preferences.getBool(_allowHalfStarRatingsPreferenceKey) ?? false;
}

Future<void> setShowStarRatings(WidgetRef ref, bool enabled) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(_showStarRatingsPreferenceKey, enabled);

  _starRatingSettingsInitialized = true;
  showStarRatingsNotifier.value = enabled;
  ref.invalidate(showStarRatingsProvider);
}

Future<void> setAllowHalfStarRatings(WidgetRef ref, bool enabled) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(_allowHalfStarRatingsPreferenceKey, enabled);
  ref.invalidate(allowHalfStarRatingsProvider);
}
