import 'dart:async';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/star_rating_settings.dart';
import 'package:finamp/services/user_rating_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrackRating extends ConsumerStatefulWidget {
  const TrackRating({super.key, required this.baseItem});

  final BaseItemDto baseItem;

  @override
  ConsumerState<TrackRating> createState() => _TrackRatingState();
}

class _TrackRatingState extends ConsumerState<TrackRating> {
  static const _starWidth = 34.0;
  static const _starCount = 5;

  double? _dragRating;

  double _ratingForPosition(double dx, {required bool allowHalfStars}) {
    if (dx <= 0) return 0;

    final raw = (dx / (_starWidth * _starCount) * _starCount).clamp(0.0, _starCount.toDouble());
    final steps = allowHalfStars ? 2.0 : 1.0;
    return ((raw * steps).ceil() / steps).clamp(allowHalfStars ? 0.5 : 1.0, _starCount.toDouble());
  }

  void _updateDrag(Offset localPosition, {required bool allowHalfStars}) {
    setState(() {
      _dragRating = _ratingForPosition(localPosition.dx, allowHalfStars: allowHalfStars);
    });
  }

  void _finishDrag() {
    final rating = _dragRating;
    if (rating == null) return;

    setState(() => _dragRating = null);
    unawaited(setUserRating(ref, widget.baseItem, rating == 0 ? null : rating));
  }

  @override
  Widget build(BuildContext context) {
    final ratingProvider = userRatingProvider(widget.baseItem);
    final rating = ref.watch(ratingProvider);
    final isUpdating = ref.watch(userRatingUpdatingProvider(widget.baseItem.id));
    final halfStarSetting = ref.watch(allowHalfStarRatingsProvider);
    final allowHalfStars = halfStarSetting.valueOrNull ?? false;
    final storedStars = ratingToStarValue(rating);
    final selectedStars = _dragRating ?? (allowHalfStars ? storedStars : storedStars.roundToDouble());
    final ratingLabel = selectedStars == 0
        ? 'Not rated'
        : '${selectedStars % 1 == 0 ? selectedStars.toInt() : selectedStars} of 5 stars';

    return Semantics(
      container: true,
      label: ratingLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: isUpdating
            ? null
            : (details) => _updateDrag(details.localPosition, allowHalfStars: allowHalfStars),
        onHorizontalDragUpdate: isUpdating
            ? null
            : (details) => _updateDrag(details.localPosition, allowHalfStars: allowHalfStars),
        onHorizontalDragEnd: isUpdating ? null : (_) => _finishDrag(),
        onHorizontalDragCancel: isUpdating ? null : _finishDrag,
        child: SizedBox(
          width: _starWidth * _starCount,
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_starCount, (index) {
              final stars = index + 1;
              final remaining = selectedStars - index;
              final icon = remaining >= 1
                  ? Icons.star_rounded
                  : remaining >= 0.5
                  ? Icons.star_half_rounded
                  : Icons.star_border_rounded;
              final clearsRating = selectedStars == stars;

              return Semantics(
                button: true,
                enabled: !isUpdating,
                label: '$stars of 5 stars',
                selected: clearsRating,
                excludeSemantics: true,
                child: SizedBox(
                  width: _starWidth,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: clearsRating ? 'Clear rating' : '$stars/5',
                    iconSize: 22,
                    onPressed: isUpdating
                        ? null
                        : () => unawaited(setUserRating(ref, widget.baseItem, clearsRating ? null : stars)),
                    icon: Icon(icon),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
