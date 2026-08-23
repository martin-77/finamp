import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/gen/assets.gen.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
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
  static const _intentStateTimeout = Duration(seconds: 2);
  final _log = Logger('IosWidgetService');

  StreamSubscription<MediaItem?>? _mediaItemSubscription;
  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  StreamSubscription<FinampQueueItem?>? _currentTrackSubscription;
  ProviderSubscription<bool>? _showRatingsSubscription;
  ProviderSubscription<bool>? _favoriteSubscription;
  ProviderSubscription<double?>? _ratingSubscription;

  AudioHandler? _audioHandler;

  Future<void> _syncTail = Future<void>.value();
  int _widgetActionDepth = 0;
  bool _queueServiceBound = false;
  bool _initialized = false;

  bool get _isHandlingWidgetAction => _widgetActionDepth > 0;

  Future<void> initialize({required AudioHandler audioHandler}) async {
    if (!Platform.isIOS || _initialized) return;

    _audioHandler = audioHandler;
    _channel.setMethodCallHandler(_handleNativeCall);

    _mediaItemSubscription = audioHandler.mediaItem.listen((mediaItem) {
      _bindQueueServiceIfAvailable();
      _log.info(
        '[WIDGET-DIAG] mediaItem title=${mediaItem?.title} '
        'id=${mediaItem?.id} artUri=${mediaItem?.artUri}',
      );
      unawaited(_handleMediaItemUpdate(mediaItem));
    });

    // PlaybackState is Finamp's published playback truth. It is only used as
    // an event source here; snapshots read its current value directly.
    _playbackStateSubscription = audioHandler.playbackState.listen((state) {
      _bindQueueServiceIfAvailable();
      _log.info(
        '[WIDGET-DIAG] playbackState playing=${state.playing} '
        'queueIndex=${state.queueIndex}',
      );
      unawaited(syncNow());
    });

    final container = GetIt.instance<ProviderContainer>();
    _showRatingsSubscription = container.listen<bool>(
      finampSettingsProvider.showStarRatings,
      (_, __) => unawaited(syncNow()),
      fireImmediately: true,
    );

    // MusicPlayerBackgroundTask is constructed inside AudioService.init().
    // QueueService is registered only after AudioService.init() completes, so
    // bind it lazily as soon as Finamp makes it available.
    _bindQueueServiceIfAvailable();
    _initialized = true;
    _log.info('[WIDGET-DIAG] initialized');
  }

  void _bindQueueServiceIfAvailable() {
    if (_queueServiceBound || !GetIt.instance.isRegistered<QueueService>()) {
      return;
    }

    final queueService = GetIt.instance<QueueService>();
    _queueServiceBound = true;
    _bindItemProviders(queueService.getCurrentTrack()?.baseItem);

    _currentTrackSubscription = queueService.getCurrentTrackStream().listen((queueItem) {
      _log.info(
        '[WIDGET-DIAG] currentTrack id=${queueItem?.baseItem.id.raw} '
        'title=${queueItem?.item.title}',
      );
      _bindItemProviders(queueItem?.baseItem);
      unawaited(syncNow());
    });
  }

  Future<void> _handleMediaItemUpdate(MediaItem? mediaItem) async {
    _bindQueueServiceIfAvailable();

    // QueueService in redesign deliberately publishes the MediaItem more than
    // once for the same track: metadata may be updated independently, and the
    // full-quality albumImageProvider later replaces placeholder artwork with
    // a local cached file. Persist the current track state before artwork so
    // the native writer can validate the matching item ID.
    await syncNow();

    if (mediaItem == null) {
      _log.info('[WIDGET-DIAG] artwork skip reason=null-media-item');
      return;
    }

    // Artwork ownership is defined by this MediaItem snapshot itself. A newer
    // MediaItem for the same track does not make a valid local artwork file
    // stale; only a real track change does. This matters for cold image-cache
    // loads where Finamp may publish several same-track MediaItems while the
    // full-quality image is being prepared.
    final item = _itemFromMediaItem(mediaItem);
    final artUri = mediaItem.artUri;
    _log.info(
      '[WIDGET-DIAG] artwork candidate item=${item?.id.raw} '
      'title=${mediaItem.title} artUri=$artUri',
    );
    if (item == null) {
      _log.info('[WIDGET-DIAG] artwork skip reason=no-item');
      return;
    }
    if (artUri == null) {
      _log.info('[WIDGET-DIAG] artwork skip item=${item.id.raw} reason=no-art-uri');
      return;
    }
    if (!artUri.isScheme('file')) {
      _log.info(
        '[WIDGET-DIAG] artwork skip item=${item.id.raw} '
        'reason=non-file-uri uri=$artUri',
      );
      return;
    }

    if (_isPlaceholderArtwork(artUri)) {
      _log.info(
        '[WIDGET-DIAG] artwork skip item=${item.id.raw} reason=placeholder',
      );
      return;
    }

    final liveItem = _liveCurrentQueueItem()?.baseItem;
    if (liveItem != null && liveItem.id != item.id) {
      _log.info(
        '[WIDGET-DIAG] artwork skip item=${item.id.raw} '
        'reason=track-mismatch live=${liveItem.id.raw}',
      );
      return;
    }

    try {
      final bytes = await File.fromUri(artUri).readAsBytes();
      if (bytes.isEmpty) {
        _log.info(
          '[WIDGET-DIAG] artwork skip item=${item.id.raw} reason=empty-file',
        );
        return;
      }

      // File I/O is asynchronous. Re-check only track identity afterwards;
      // another MediaItem event for the same track is harmless and must not
      // cancel this valid artwork publication.
      final currentItem = _liveCurrentQueueItem()?.baseItem;
      if (currentItem != null && currentItem.id != item.id) {
        _log.info(
          '[WIDGET-DIAG] artwork skip item=${item.id.raw} '
          'reason=track-changed-after-read live=${currentItem.id.raw}',
        );
        return;
      }

      _log.info(
        '[WIDGET-DIAG] artwork send item=${item.id.raw} bytes=${bytes.length} '
        'reload=${!_isHandlingWidgetAction}',
      );
      await _channel.invokeMethod<void>('updateArtwork', <String, Object>{
        'itemID': item.id.raw,
        'bytes': bytes,
        'reload': !_isHandlingWidgetAction,
      });
      _log.info('[WIDGET-DIAG] artwork sent item=${item.id.raw}');
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to publish iOS widget artwork from $artUri',
        error,
        stackTrace,
      );
    }
  }

  BaseItemDto? _itemFromMediaItem(MediaItem? mediaItem) {
    final itemJson = mediaItem?.extras?['itemJson'];
    if (itemJson is! Map) return null;

    try {
      return BaseItemDto.fromJson(Map<String, dynamic>.from(itemJson));
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to decode iOS widget item from MediaItem extras',
        error,
        stackTrace,
      );
      return null;
    }
  }

  FinampQueueItem? _liveCurrentQueueItem() {
    _bindQueueServiceIfAvailable();
    if (!GetIt.instance.isRegistered<QueueService>()) return null;
    return GetIt.instance<QueueService>().getCurrentTrack();
  }

  bool _isPlaceholderArtwork(Uri artUri) {
    final placeholderPath = Assets.images.albumWhite.path;
    return artUri.path == placeholderPath ||
        artUri.path.endsWith('/$placeholderPath');
  }

  void _bindItemProviders(BaseItemDto? item) {
    _favoriteSubscription?.close();
    _favoriteSubscription = null;
    _ratingSubscription?.close();
    _ratingSubscription = null;

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
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'performAction') {
      throw MissingPluginException('Unknown iOS widget method: ${call.method}');
    }

    _bindQueueServiceIfAvailable();

    final arguments = Map<String, dynamic>.from(
      (call.arguments as Map?) ?? const <String, dynamic>{},
    );
    final action = arguments['action'] as String?;
    final handler = _audioHandler;

    if (handler == null || action == null) {
      throw StateError('iOS widget bridge is not initialized');
    }

    _log.info(
      '[WIDGET-DIAG] action start action=$action '
      'playing=${handler.playbackState.value.playing} '
      'item=${_liveCurrentQueueItem()?.baseItem.id.raw}',
    );
    _widgetActionDepth++;
    try {
      switch (action) {
        case 'togglePlayback':
          final expectedPlaying = !handler.playbackState.value.playing;
          final confirmation = _waitForPlaybackState(expectedPlaying);
          if (expectedPlaying) {
            await handler.play();
          } else {
            await handler.pause();
          }
          await confirmation;
        case 'previous':
          final previousItemID = _liveCurrentQueueItem()?.baseItem.id.raw;
          final confirmation = _waitForTrackChange(previousItemID);
          await handler.skipToPrevious();
          final confirmedItem = await confirmation;
          if (confirmedItem != null) {
            _bindItemProviders(confirmedItem.baseItem);
          }
        case 'next':
          final previousItemID = _liveCurrentQueueItem()?.baseItem.id.raw;
          final confirmation = _waitForTrackChange(previousItemID);
          await handler.skipToNext();
          final confirmedItem = await confirmation;
          if (confirmedItem != null) {
            _bindItemProviders(confirmedItem.baseItem);
          }
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

      // Stream callbacks triggered by the action are allowed to persist state
      // (and artwork) while the intent is running, but they are serialized and
      // suppress WidgetCenter reloads. Wait for all already-enqueued writes,
      // then return one final coherent snapshot to Swift. Swift persists that
      // snapshot before AppIntent.perform() returns; WidgetKit performs the
      // single timeline reload afterwards.
      await _syncTail;
      final state = _buildState();
      _log.info(
        '[WIDGET-DIAG] action final action=$action '
        'item=${state['itemID']} title=${state['title']} '
        'playing=${state['isPlaying']}',
      );
      return state;
    } finally {
      _widgetActionDepth--;
    }
  }

  Future<PlaybackState?> _waitForPlaybackState(bool expectedPlaying) async {
    final handler = _audioHandler;
    if (handler == null) return null;
    if (handler.playbackState.value.playing == expectedPlaying) {
      return handler.playbackState.value;
    }

    try {
      return await handler.playbackState
          .firstWhere((state) => state.playing == expectedPlaying)
          .timeout(_intentStateTimeout);
    } on TimeoutException {
      _log.warning(
        'Timed out waiting for iOS widget playback state: '
        'playing=$expectedPlaying',
      );
      return null;
    }
  }

  Future<FinampQueueItem?> _waitForTrackChange(String? previousItemID) async {
    if (previousItemID == null || !GetIt.instance.isRegistered<QueueService>()) {
      return null;
    }

    try {
      return await GetIt.instance<QueueService>()
          .getCurrentTrackStream()
          .firstWhere((queueItem) {
            final itemID = queueItem?.baseItem.id.raw;
            return itemID != null && itemID != previousItemID;
          })
          .timeout(_intentStateTimeout);
    } on TimeoutException {
      // Previous may intentionally seek to the beginning of the current track
      // instead of changing tracks, and next may stay put at the end of a queue.
      return GetIt.instance<QueueService>().getCurrentTrack();
    }
  }

  Future<void> _toggleFavorite() async {
    final item = _liveCurrentQueueItem()?.baseItem;
    if (item == null) return;

    final container = GetIt.instance<ProviderContainer>();
    final provider = isFavoriteProvider(item);
    final isFavorite = container.read(provider);

    await container.read(provider.notifier).updateFavorite(!isFavorite);
  }

  Future<void> _writeRating(double? stars) async {
    final item = _liveCurrentQueueItem()?.baseItem;
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

  Future<void> syncNow({bool? reload}) {
    if (!Platform.isIOS) return Future<void>.value();

    final shouldReload = reload ?? !_isHandlingWidgetAction;
    final sync = _syncTail.then((_) => _syncNow(reload: shouldReload));
    _syncTail = sync.catchError((Object error, StackTrace stackTrace) {
      _log.warning(
        'Failed to synchronize iOS widget state',
        error,
        stackTrace,
      );
    });
    return sync;
  }

  Map<String, Object?> _buildState() {
    final queueItem = _liveCurrentQueueItem();
    final item = queueItem?.baseItem;
    final currentMediaItem = queueItem?.item;
    final handler = _audioHandler;
    final container = GetIt.instance<ProviderContainer>();

    final isFavorite = item == null
        ? false
        : container.read(isFavoriteProvider(item));
    final jellyfinRating = item == null
        ? null
        : container.read(userRatingProvider(item));

    return <String, Object?>{
      'itemID': item?.id.raw,
      'title': currentMediaItem?.title ?? 'Finamp',
      'artist': currentMediaItem?.artist ?? '',
      'album': currentMediaItem?.album ?? '',
      'isPlaying': handler?.playbackState.value.playing ?? false,
      'showStarRatings': FinampSettingsHelper.finampSettings.showStarRatings,
      'isFavorite': isFavorite,
      'starRating': jellyfinRating == null
          ? null
          : ratingToStarValue(jellyfinRating),
    };
  }

  Future<void> _syncNow({required bool reload}) async {
    final state = _buildState();
    _log.info(
      '[WIDGET-DIAG] state send item=${state['itemID']} '
      'title=${state['title']} playing=${state['isPlaying']} reload=$reload',
    );

    try {
      await _channel.invokeMethod<void>('updateState', <String, Object?>{
        ...state,
        'reload': reload,
      });
      _log.info(
        '[WIDGET-DIAG] state sent item=${state['itemID']} '
        'title=${state['title']} playing=${state['isPlaying']} reload=$reload',
      );
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

    _audioHandler = null;
    _queueServiceBound = false;
    _widgetActionDepth = 0;
  }
}
