import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:hive_ce/hive.dart';

/// Persistent cache for paged Jellyfin library responses.
///
/// This intentionally caches the server response pages rather than trying to
/// mirror the full Jellyfin object graph. It gives the online library a fast
/// warm start while the separate local library index can be built and updated
/// independently.
class LibraryPageCache {
  static const boxName = "LibraryPageCache";
  static const defaultMaxAge = Duration(minutes: 15);

  LibraryPageCache._(this._box);

  final Box<String> _box;

  static LibraryPageCache fromOpenBox() => LibraryPageCache._(Hive.box<String>(boxName));

  LibraryPageCacheEntry? get(String signature) {
    final encoded = _box.get(_keyFor(signature));
    if (encoded == null) return null;

    try {
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final entry = LibraryPageCacheEntry.fromJson(decoded);
      // Guard the compact hash key against collisions.
      return entry.signature == signature ? entry : null;
    } on Object {
      return null;
    }
  }

  Future<void> put(String signature, List<BaseItemDto> items) async {
    final entry = LibraryPageCacheEntry(
      signature: signature,
      updatedAt: DateTime.now().toUtc(),
      items: items,
    );
    await _box.put(_keyFor(signature), jsonEncode(entry.toJson()));
  }

  Future<void> remove(String signature) => _box.delete(_keyFor(signature));

  Future<void> clear() => _box.clear();

  /// Stable FNV-1a key. The full signature is stored in the value as a
  /// collision check, so this is only used to keep Hive keys compact.
  static String _keyFor(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, "0");
  }
}

class LibraryPageCacheEntry {
  const LibraryPageCacheEntry({
    required this.signature,
    required this.updatedAt,
    required this.items,
  });

  final String signature;
  final DateTime updatedAt;
  final List<BaseItemDto> items;

  bool isFresh([Duration maxAge = LibraryPageCache.defaultMaxAge]) =>
      DateTime.now().toUtc().difference(updatedAt) <= maxAge;

  factory LibraryPageCacheEntry.fromJson(Map<String, dynamic> json) {
    return LibraryPageCacheEntry(
      signature: json["signature"] as String,
      updatedAt: DateTime.parse(json["updatedAt"] as String),
      items: (json["items"] as List<dynamic>)
          .map((item) => BaseItemDto.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    "signature": signature,
    "updatedAt": updatedAt.toIso8601String(),
    "items": items.map((item) => item.toJson()).toList(),
  };
}

/// Builds a deterministic signature from the effective server query. Keeping
/// this independent from Riverpod/provider identity makes cache entries stable
/// across process restarts.
String libraryPageCacheSignature({
  required String serverId,
  required String userId,
  required String? libraryId,
  required String contentType,
  required String sortBy,
  required String sortOrder,
  required Iterable<String> filters,
  required int startIndex,
  required int limit,
}) {
  final sortedFilters = filters.toList()..sort();
  return jsonEncode({
    "serverId": serverId,
    "userId": userId,
    "libraryId": libraryId,
    "contentType": contentType,
    "sortBy": sortBy,
    "sortOrder": sortOrder,
    "filters": sortedFilters,
    "startIndex": startIndex,
    "limit": limit,
  });
}
