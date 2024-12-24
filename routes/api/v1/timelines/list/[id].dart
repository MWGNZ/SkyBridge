import 'dart:io';

import 'package:bluesky/bluesky.dart' as bsky;
import 'package:atproto_core/atproto_core.dart' as core;
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_bridge/auth.dart';
import 'package:sky_bridge/database.dart';
import 'package:sky_bridge/models/mastodon/mastodon_post.dart';
import 'package:sky_bridge/models/params/timeline_params.dart';
import 'package:sky_bridge/src/generated/prisma/prisma_client.dart';
import 'package:sky_bridge/util.dart';

/// View posts in the given list timeline.
/// GET /api/v1/timelines/list/:list_id HTTP/1.1
/// See: https://docs.joinmastodon.org/methods/timelines/#list
Future<Response> onRequest<T>(RequestContext context, String id) async {
  // Only allow GET requests.
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // If the id is not a number we return 404 for now.
  if (int.tryParse(id) == null) {
    return Response(statusCode: HttpStatus.notFound);
  }

  // Get the next cursor from the request parameters.
  final params = context.request.uri.queryParameters;
  final encodedParams = TimelineParams.fromJson(params);
  final nextCursor = encodedParams.cursor;

  // Construct bluesky connection.
  // Get a bluesky connection/session from the a provided bearer token.
  // If the token is invalid, bail out and return an error.
  final bluesky = await blueskyFromContext(context);
  if (bluesky == null) return authError();

  // Get the media attachment from the database.
  final idNumber = BigInt.parse(id);
  final record = await db.feedRecord.findUnique(
    where: FeedRecordWhereUniqueInput(id: idNumber),
  );
  if (record == null) return Response(statusCode: HttpStatus.notFound);

  final feed = await bluesky.feed.getFeed(
    generatorUri: core.AtUri.parse(record.uri),
  );

  // Take all the posts and convert them to Mastodon ones
  // Await all the futures, getting any necessary data from the database.
  final posts = await databaseTransaction(() async {
    final futures = feed.data.feed.map(MastodonPost.fromFeedView).toList();
    return Future.wait(futures);
  });

  // Get the parent posts for each post.
  final processedPosts = await processParentPosts(bluesky, posts);

  var headers = <String, String>{};
  if (processedPosts.isNotEmpty) {
    headers = generatePaginationHeaders(
      items: processedPosts,
      requestUri: context.request.uri,
      nextCursor: nextCursor ?? '',
      getId: (post) => BigInt.parse(post.id),
    );
  }

  return threadedJsonResponse(
    body: processedPosts,
    headers: headers,
  );
}
