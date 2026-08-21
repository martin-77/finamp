import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/user_rating_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrackRating extends ConsumerWidget {
  const TrackRating({super.key, required this.baseItem});

  final BaseItemDto baseItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rating = ref.watch(userRatingProvider(baseItem));
    final selectedStars = ratingToStars(rating);

    return Semantics(
      container: true,
      label: selectedStars == 0 ? 'Not rated' : '$selectedStars of 5 stars',
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (index) {
            final stars = index + 1;
            final selected = stars <= selectedStars;
            final clearsRating = stars == selectedStars;

            return Semantics(
              button: true,
              label: '$stars of 5 stars',
              selected: clearsRating,
              excludeSemantics: true,
              child: SizedBox(
                width: 34,
                height: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  tooltip: clearsRating ? 'Clear rating' : '$stars/5',
                  iconSize: 22,
                  onPressed: () => setUserRating(
                    ref,
                    baseItem,
                    clearsRating ? null : stars,
                  ),
                  icon: Icon(
                    selected ? Icons.star_rounded : Icons.star_border_rounded,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
