import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/finamp_models.dart';
import 'android_auto_helper.dart';
import 'audio_service_helper.dart';
import 'queue_service.dart';
import 'user_rating_provider.dart';
import 'user_rating_service.dart';

/// iOS-specific helpers for playback state sync, system ratings, and Siri media intents.

final _logger = Logger('IosHelpers');

/// Syncs playback state to iOS's MPNowPlayingInfoCenter.
///
/// TODO: This is a workaround because audio_service doesn't set
/// MPNowPlayingInfoCenter.playbackState on iOS (only on macOS).
/// This causes CarPlay's Now Playing screen to not reflect the correct
/// play/pause state when playback is started from the phone.
/// Consider contributing a fix upstream to audio_service.
class IosPlaybackStateSync {
  static const _channel = MethodChannel('com.unicornsonlsd.finamp-ios/playback_state');

  /// Sets the playback state on iOS's MPNowPlayingInfoCenter.
  /// This is needed for CarPlay to show the correct play/pause state.
  static Future<void> setPlaybackState({required bool isPlaying}) async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('setPlaybackState', {'isPlaying': isPlaying});
      _logger.fine('Set iOS playback state to ${isPlaying ? "playing" : "paused"}');
    } catch (e) {
      _logger.warning('Failed to set iOS playback state: $e');
    }
  }
}

/// Bridges Jellyfin's personal rating to iOS system media controls.
class IosRatingHandler {
  static const _channel = MethodChannel('com.unicornsonlsd.finamp-ios/rating');
  static StreamSubscription<FinampQueueItem?>? _trackSubscription;
  static bool _initialized = false;

  static Future<void> setup() async {
    if (!Platform.isIOS || _initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'ratingChanged') {
        _logger.warning('Unknown iOS rating method: ${call.method}');
        return;
      }

      final arguments = call.arguments as Map<dynamic, dynamic>?;
      final value = (arguments?['rating'] as num?)?.toDouble();
      if (value == null) return;
      await _handleRatingChanged(value);
    });

    final preferences = await SharedPreferences.getInstance();
    final enabled = preferences.getBool('showStarRatings') ?? false;
    await setEnabled(enabled);

    _trackSubscription = GetIt.instance<QueueService>().getCurrentTrackStream().listen((track) {
      final rating = ratingToStarValue(track?.baseItem.userData?.rating);
      unawaited(setCurrentRating(rating));
    });
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (error) {
      _logger.warning('Failed to set iOS rating command state: $error');
    }
  }

  static Future<void> setCurrentRating(double rating) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('setCurrentRating', {'rating': rating});
    } catch (error) {
      _logger.warning('Failed to set current iOS rating: $error');
    }
  }

  static Future<void> _handleRatingChanged(double rating) async {
    final item = GetIt.instance<QueueService>().getCurrentTrack()?.baseItem;
    if (item == null) {
      _logger.warning('Ignoring iOS rating because no track is active');
      return;
    }

    try {
      final preferences = await SharedPreferences.getInstance();
      final allowHalfStars = preferences.getBool('allowHalfStarRatings') ?? false;
      final normalizedStars = rating <= 0
          ? 0.0
          : allowHalfStars
          ? (rating * 2).round() / 2.0
          : rating.roundToDouble();

      final service = UserRatingService();
      final userData = normalizedStars <= 0
          ? await service.clearRating(item.id)
          : await service.setRating(item.id, starsToRating(normalizedStars));

      if (GetIt.instance.isRegistered<ProviderContainer>()) {
        final container = GetIt.instance<ProviderContainer>();
        container.read(userRatingProvider(item).notifier).state = userData.rating;
      }

      await setCurrentRating(ratingToStarValue(userData.rating));
      _logger.fine('Updated rating from iOS system controls to $normalizedStars stars');
    } catch (error, stackTrace) {
      _logger.warning('Failed to update rating from iOS system controls', error, stackTrace);
    }
  }
}

/// Handles Siri media intent commands from iOS.
///
/// This enables voice commands like "Hey Siri, play [track/artist] on Finamp"
/// from anywhere on iOS (phone, CarPlay, AirPods, etc.).
class IosSiriHandler {
  static const _siriIntentChannel = MethodChannel('com.unicornsonlsd.finamp-ios/siri_intent');

  /// Sets up the method channel handler for Siri media intents.
  /// Should be called once during app initialization.
  static void setup() {
    if (!Platform.isIOS) return;

    _siriIntentChannel.setMethodCallHandler((call) async {
      _logger.info("Received Siri intent: ${call.method}");

      switch (call.method) {
        case 'playFromSearch':
          await _handlePlayFromSearch(call.arguments as Map<dynamic, dynamic>?);
          break;
        case 'searchMedia':
          await _handleSearchMedia(call.arguments as Map<dynamic, dynamic>?);
          break;
        default:
          _logger.warning("Unknown Siri intent method: ${call.method}");
      }
    });

    _logger.info("Siri intent handler set up");
  }

  /// Handles Siri "Play X on Finamp" voice commands by delegating to
  /// Android Auto's search engine, which has sophisticated metadata-driven
  /// type detection, multi-type ranking, playlist preference, and artist filtering.
  ///
  /// Siri metadata is translated into Android Auto's extras format so that
  /// AA's decision tree can determine the best search strategy.
  static Future<void> _handlePlayFromSearch(Map<dynamic, dynamic>? arguments) async {
    if (arguments == null) {
      _logger.warning("Siri playFromSearch called with null arguments");
      return;
    }

    final query = arguments['query'] as String?;
    final artist = arguments['artist'] as String?;
    final album = arguments['album'] as String?;
    final genre = arguments['genre'] as String?;
    final shuffle = arguments['shuffle'] as bool? ?? false;
    final mediaType = arguments['mediaType'] as String?;

    _logger.info(
      "Siri playFromSearch - query: $query, artist: $artist, album: $album, genre: $genre, mediaType: $mediaType, shuffle: $shuffle",
    );

    // Shuffle with no specific query
    if (shuffle && query == null && artist == null && album == null) {
      await _shuffleAll();
      return;
    }

    // Build search query for Android Auto's search engine
    final rawQuery = query ?? artist ?? album ?? genre ?? '';
    if (rawQuery.isEmpty) {
      await _shuffleAll();
      return;
    }

    final extras = _buildExtrasFromSiriData(
      query: query,
      artist: artist,
      album: album,
      genre: genre,
      mediaType: mediaType,
    );

    _logger.info("Siri delegating to AA search - rawQuery: $rawQuery, extras: $extras");
    final androidAutoHelper = GetIt.instance<AndroidAutoHelper>();
    await androidAutoHelper.playFromSearch(AndroidAutoSearchQuery(rawQuery, extras));
  }

  /// Translates Siri metadata fields into Android Auto intent extras format.
  ///
  /// This mapping allows AA's decision tree to correctly identify the search type:
  /// - artist + query → track search filtered by artist
  /// - album + query → track search
  /// - artist only → artist search (instant mix)
  /// - mediaType hint on bare query → maps query to the appropriate extra
  /// - bare query with no hints → null extras (AA does generic: playlists first, then tracks)
  static Map<String, dynamic>? _buildExtrasFromSiriData({
    String? query,
    String? artist,
    String? album,
    String? genre,
    String? mediaType,
  }) {
    final extras = <String, dynamic>{};

    // Direct fields from Siri (compound queries like "Play X by Y")
    if (artist != null) extras['android.intent.extra.artist'] = artist;
    if (album != null) extras['android.intent.extra.album'] = album;
    if (query != null && (artist != null || album != null)) {
      extras['android.intent.extra.title'] = query;
    }
    if (genre != null) extras['android.intent.extra.genre'] = genre;

    // Use Siri's mediaType hint for bare queries (no artist/album fields)
    // e.g. "Play the artist Taylor Swift" → mediaType='artist', query='Taylor Swift'
    if (artist == null && album == null && query != null && mediaType != null) {
      switch (mediaType) {
        case 'artist':
          extras['android.intent.extra.artist'] = query;
        case 'album':
          extras['android.intent.extra.album'] = query;
        case 'song':
          extras['android.intent.extra.title'] = query;
        case 'playlist':
          extras['android.intent.extra.playlist'] = query;
        case 'genre':
          extras['android.intent.extra.genre'] = query;
      }
    }

    return extras.isEmpty ? null : extras;
  }

  /// Shuffles all tracks using the shared shuffle handler.
  static Future<void> _shuffleAll() async {
    final audioServiceHelper = GetIt.instance<AudioServiceHelper>();
    await audioServiceHelper.shuffleAll(onlyShowFavorites: false, itemCount: DefaultSettings.quickShuffleItemCount);
  }

  /// Handles Siri "Search for X on Finamp" voice commands
  static Future<void> _handleSearchMedia(Map<dynamic, dynamic>? arguments) async {
    if (arguments == null) {
      _logger.warning("Siri searchMedia called with null arguments");
      return;
    }

    final query = arguments['query'] as String?;
    _logger.info("Siri searchMedia - query: $query");

    // TODO: Navigate to a search results screen instead of playing immediately.
    // This would require a Flutter method channel callback to trigger navigation.
    await _handlePlayFromSearch(arguments);
  }
}
