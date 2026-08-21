import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _showStarRatingsPreferenceKey = 'showStarRatings';
const _allowHalfStarRatingsPreferenceKey = 'allowHalfStarRatings';

final showStarRatingsProvider = FutureProvider<bool>((ref) async {
  final preferences = await SharedPreferences.getInstance();
  return preferences.getBool(_showStarRatingsPreferenceKey) ?? false;
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
  ref.invalidate(showStarRatingsProvider);

  if (Platform.isIOS) {
    const channel = MethodChannel('com.unicornsonlsd.finamp-ios/rating');
    await channel.invokeMethod('setEnabled', {'enabled': enabled});
  }
}

Future<void> setAllowHalfStarRatings(WidgetRef ref, bool enabled) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(_allowHalfStarRatingsPreferenceKey, enabled);
  ref.invalidate(allowHalfStarRatingsProvider);
}
