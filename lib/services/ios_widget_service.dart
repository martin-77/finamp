import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/services/favorite_provider.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/user_rating_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Synchronizes Finamp's current media state with the iOS WidgetKit extension
/// and dispatches widget actions back through the existing Finamp services.
///
/// The widget extension only receives presentation state. Jellyfin credentials
/// and network access remain in the main Finamp process.
class IosWidgetService {
  IosWidgetService._();

  static final instance = IosWidgetService._();

  static const _channel = MethodChannel('finamp/ios_widget');
  final _log = Logger('IosWidgetService');

  StreamSubscription<MediaItem?>? _mediaItemSubscription;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  StreamSubscription<FinampQueueItem?>? _currentTrackSubscription;
  ProviderSubscription<bool>? _showRatingsSubscription;
  ProviderSubscription<bool>? _favoriteSubscription;
  ProviderSubscription<double?>? _ratingSubscription;
  ProviderSubscription<AlbumImageInfo>? _artworkSubscription;

  AudioHandler? _audioHandler;
  MediaItem? _mediaItem;
  PlaybackState? _playbackState;
  BaseItemDto? _currentItem;
  Uri? _artUri;

  Future<void> _syncTail = Future<void>.value();
  bool _initialized = false;

  Future<void> initialize({required AudioHandler audioHandler}) async {
    if (!Platform.isIOS || _initialized) return;

    _initialized = true;
    _audioHandler = audioHandler;
    _channel.setMethodCallHandler(_handleNativeCall);

    _mediaItemSubscription = audioHandler.mediaItem.listen((mediaItem) {
      _mediaItem = mediaItem;
      unawaited(syncNow());
    });

    _playbackStateSubscription = audioHandler.playbackState.listen((state) {
      _playbackState = state;
      unawaited(syncNow());
    });

    _currentTrackSubscription = GetIt.instance<QueueService>()
        .getCurrentTrackStream()
        .listen((queueItem) {
          _currentItem = queueItem?.baseItem;
          _bindItemProviders();
          unawaited(syncNow());
        });

    final container = GetIt.instance<ProviderContainer>();
    _showRatingsSubscription = container.listen<bool>(
      finampSettingsProvider.showStarRatings,
      (_, __) => unawaited(syncNow()),
      fireImmediately: true,
    );
  }

  void _bindItemProviders() {
    _favoriteSubscription?.close();
    _favoriteSubscription = null;
    _ratingSubscription?.close();
    _ratingSubscription = null;
    _artworkSubscription?.close();
    _artworkSubscription = null;
    _artUri = null;

    final item = _currentItem;
    if (item == null) return;

    final container = GetIt.instance<ProviderContainer>();

    _favoriteSubscription = container.listen<bool>(
      isFavoriteProvider(item),
      (_, __) => unawaited(syncNow()),
      fireImmediately: true,
    );

    _ratingSubscription = container.listen<double?>(
      userRatingProvider(item),
      (_, __) => unawaited(syncNow()),
      fireImmediately: true,
    );

    // Mirror the player artwork path exactly. AlbumImageProvider lets Jellyfin
    // resolve track/parent/album artwork through item.imageId, downloads the
    // full-quality image with Finamp's cache manager, and then publishes the
    // resulting local file URI. The native bridge only needs to copy that file.
    _artworkSubscription = container.listen<AlbumImageInfo>(
      albumImageProvider(AlbumImageRequest(item: item)),
      (_, latest) {
        _artUri = latest.uri;
        unawaited(syncNow());
      },
      fireImmediately: true,
    );
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'performAction') {
      throw MissingPluginException('Unknown iOS widget method: ${call.method}');
    }

    final arguments = Map<String, dynamic>.from(
      (call.arguments as Map?) ?? const <String, dynamic>{},
    );
    final action = arguments['action'] as String?;
    final handler = _audioHandler;

    if (handler == null || action == null) {
      throw StateError('iOS widget bridge is not initialized');
    }

    switch (action) {
      case 'togglePlayback':
        if (_playbackState?.playing ?? false) {
          await handler.pause();
        } else {
          await handler.play();
        }
      case 'previous':
        await handler.skipToPrevious();
      case 'next':
        await handler.skipToNext();
      case 'toggleFavorite':
        await _toggleFavorite();
      case 'setRating':
        final stars = (arguments['rating'] as num?)?.toDouble();
        if (stars == null || stars < 1 || stars > 5) {
          throw ArgumentError.value(
            stars,
            'rating',
            'Widget rating must be between 1 and 5 stars',
          );
        }
        await _writeRating(stars);
      case 'clearRating':
        await _writeRating(null);
      default:
        throw ArgumentError.value(
          action,
          'action',
          'Unknown iOS widget action',
        );
    }

    await syncNow();
  }

  Future<void> _toggleFavorite() async {
    final item = _currentItem;
    if (item == null) return;

    final container = GetIt.instance<ProviderContainer>();
    final provider = isFavoriteProvider(item);
    final isFavorite = container.read(provider);

    await container.read(provider.notifier).updateFavorite(!isFavorite);
  }

  Future<void> _writeRating(double? stars) async {
    final item = _currentItem;
    if (item == null) return;

    if (FinampSettingsHelper.finampSettings.isOffline) {
      throw StateError('Ratings cannot be changed while Finamp is offline');
    }

    final container = GetIt.instance<ProviderContainer>();
    final provider = userRatingProvider(item);
    final previous = container.read(provider);
    final api = GetIt.instance<JellyfinApiHelper>();

    try {
      final userData = stars == null
          ? await api.clearUserRating(item.id)
          : await api.setUserRating(item.id, starsToRating(stars));
      container.read(provider.notifier).state = userData.rating;
    } catch (_) {
      container.read(provider.notifier).state = previous;
      rethrow;
    }
  }

  Future<void> syncNow() {
    if (!Platform.isIOS) return Future<void>.value();

    final sync = _syncTail.then((_) => _syncNow());
    _syncTail = sync.catchError((Object error, StackTrace stackTrace) {
      _log.warning(
        'Failed to synchronize iOS widget state',
        error,
        stackTrace,
      );
    });
    return sync;
  }

  Future<void> _syncNow() async {
    final item = _currentItem;
    final container = GetIt.instance<ProviderContainer>();

    final isFavorite = item == null
        ? false
        : container.read(isFavoriteProvider(item));
    final jellyfinRating = item == null
        ? null
        : container.read(userRatingProvider(item));

    final state = <String, Object?>{
      'itemID': item?.id,
      'title': _mediaItem?.title ?? 'Finamp',
      'artist': _mediaItem?.artist ?? '',
      'album': _mediaItem?.album ?? '',
      'isPlaying': _playbackState?.playing ?? false,
      'showStarRatings': FinampSettingsHelper.finampSettings.showStarRatings,
      'isFavorite': isFavorite,
      'starRating': jellyfinRating == null
          ? null
          : ratingToStarValue(jellyfinRating),
      'artURI': _artUri?.toString(),
    };

    try {
      await _channel.invokeMethod<void>('updateState', state);
    } on PlatformException catch (error, stackTrace) {
      _log.warning(
        'Failed to update iOS widget state',
        error,
        stackTrace,
      );
    }
  }

  Future<void> dispose() async {
    if (!_initialized) return;

    _initialized = false;
    _channel.setMethodCallHandler(null);
    await _mediaItemSubscription?.cancel();
    await _playbackStateSubscription?.cancel();
    await _currentTrackSubscription?.cancel();
    _showRatingsSubscription?.close();
    _favoriteSubscription?.close();
    _ratingSubscription?.close();
    _artworkSubscription?.close();

    _audioHandler = null;
    _mediaItem = null;
    _playbackState = null;
    _currentItem = null;
    _artUri = null;
  }
}
