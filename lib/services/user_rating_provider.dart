import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/user_rating_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final userRatingProvider = StateProvider.autoDispose.family<double?, BaseItemDto>((ref, item) => item.userData?.rating);

final userRatingUpdatingProvider = StateProvider.autoDispose.family<bool, BaseItemId>((ref, itemId) => false);

double ratingToStarValue(double? rating) {
  if (rating == null) return 0;
  return (rating / 2).clamp(0.0, 5.0);
}

int ratingToStars(double? rating) => ratingToStarValue(rating).round();

double starsToRating(num stars) => stars.clamp(0.5, 5.0).toDouble() * 2.0;

Future<void> setUserRating(WidgetRef ref, BaseItemDto item, num? stars) async {
  if (FinampSettingsHelper.finampSettings.isOffline) {
    FeedbackHelper.feedback(FeedbackType.error);
    GlobalSnackbar.message((context) => AppLocalizations.of(context)!.notAvailableInOfflineMode);
    return;
  }

  final updatingProvider = userRatingUpdatingProvider(item.id);
  if (ref.read(updatingProvider)) return;

  final provider = userRatingProvider(item);
  final oldRating = ref.read(provider);
  final newRating = stars == null || stars <= 0 ? null : starsToRating(stars);

  ref.read(updatingProvider.notifier).state = true;
  ref.read(provider.notifier).state = newRating;

  try {
    final service = UserRatingService();
    final userData = newRating == null
        ? await service.clearRating(item.id)
        : await service.setRating(item.id, newRating);

    ref.read(provider.notifier).state = userData.rating;
    FeedbackHelper.feedback(FeedbackType.selection);
  } catch (error) {
    ref.read(provider.notifier).state = oldRating;
    FeedbackHelper.feedback(FeedbackType.error);
    GlobalSnackbar.error(error);
  } finally {
    ref.read(updatingProvider.notifier).state = false;
  }
}
