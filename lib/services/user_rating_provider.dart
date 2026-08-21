import 'package:chopper/chopper.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

final userRatingProvider = StateProvider.autoDispose.family<double?, BaseItemDto>(
  (ref, item) => item.userData?.rating,
);

int ratingToStars(double? rating) {
  if (rating == null) return 0;
  return (rating / 2).round().clamp(0, 5).toInt();
}

double starsToRating(int stars) => stars.clamp(1, 5).toDouble() * 2.0;

Future<void> updateUserRating(
  WidgetRef ref,
  BaseItemDto item,
  int stars,
) async {
  if (FinampSettingsHelper.finampSettings.isOffline) {
    FeedbackHelper.feedback(FeedbackType.error);
    GlobalSnackbar.message(
      (context) => AppLocalizations.of(context)!.notAvailableInOfflineMode,
    );
    return;
  }

  final provider = userRatingProvider(item);
  final oldRating = ref.read(provider);
  final newRating = starsToRating(stars);

  ref.read(provider.notifier).state = newRating;

  try {
    final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
    final client = jellyfinApiHelper.jellyfinApi.client;
    final request = Request(
      'POST',
      Uri.parse('/UserItems/${item.id.raw}/UserData'),
      client.baseUrl,
      body: <String, dynamic>{'Rating': newRating},
    );

    final response = await client.send<dynamic, dynamic>(
      request,
      requestConverter: JsonConverter.requestFactory,
      responseConverter: JsonConverter.responseFactory,
    );
    final body = response.bodyOrThrow;

    if (body is! Map) {
      throw StateError('Unexpected response while updating user rating');
    }

    final userData = UserItemDataDto.fromJson(Map<String, dynamic>.from(body));
    ref.read(provider.notifier).state = userData.rating ?? newRating;
    FeedbackHelper.feedback(FeedbackType.selection);
  } catch (error) {
    ref.read(provider.notifier).state = oldRating;
    FeedbackHelper.feedback(FeedbackType.error);
    GlobalSnackbar.error(error);
  }
}
