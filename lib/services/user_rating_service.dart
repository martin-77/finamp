import 'package:chopper/chopper.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:get_it/get_it.dart';

class UserRatingService {
  UserRatingService({JellyfinApiHelper? jellyfinApiHelper})
    : _jellyfinApiHelper =
          jellyfinApiHelper ?? GetIt.instance<JellyfinApiHelper>();

  final JellyfinApiHelper _jellyfinApiHelper;

  Future<UserItemDataDto> setRating(BaseItemId itemId, double rating) async {
    final response = await _send(
      method: 'POST',
      path: '/UserItems/${itemId.raw}/UserData',
      body: <String, dynamic>{'Rating': rating},
    );
    return _parseUserData(response);
  }

  Future<UserItemDataDto> clearRating(BaseItemId itemId) async {
    final response = await _send(
      method: 'DELETE',
      path: '/UserItems/${itemId.raw}/Rating',
    );
    return _parseUserData(response);
  }

  Future<Response<dynamic>> _send({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) {
    final client = _jellyfinApiHelper.jellyfinApi.client;
    final request = Request(
      method,
      Uri.parse(path),
      client.baseUrl,
      body: body,
    );

    return client.send<dynamic, dynamic>(
      request,
      requestConverter: JsonConverter.requestFactory,
      responseConverter: JsonConverter.responseFactory,
    );
  }

  UserItemDataDto _parseUserData(Response<dynamic> response) {
    final body = response.bodyOrThrow;
    if (body is! Map) {
      throw StateError('Unexpected response while updating user rating');
    }

    return UserItemDataDto.fromJson(Map<String, dynamic>.from(body));
  }
}
