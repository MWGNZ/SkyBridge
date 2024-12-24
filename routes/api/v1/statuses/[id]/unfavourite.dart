import 'dart:io';

import 'package:bluesky/bluesky.dart' as bsky;
import 'package:atproto_core/atproto_core.dart' as core;
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_bridge/auth.dart';
import 'package:sky_bridge/database.dart';
import 'package:sky_bridge/models/mastodon/mastodon_post.dart';
import 'package:sky_bridge/src/generated/prisma/prisma_client.dart';
import 'package:sky_bridge/util.dart';

/// Undo a like for a post.
/// POST /api/v1/statuses/:id/unfavourite HTTP/1.1
/// See: https://docs.joinmastodon.org/methods/statuses/#unfavourite
Future<Response> onRequest<T>(RequestContext context, String id) async {
  // Only allow POST requests.
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // If the id is not a number we return 404 for now.
  if (int.tryParse(id) == null) {
    return Response(statusCode: HttpStatus.notFound);
  }

  // Construct bluesky connection.
  // Get a bluesky connection/session from the a provided bearer token.
  // If the token is invalid, bail out and return an error.
  final bluesky = await blueskyFromContext(context);
  if (bluesky == null) return authError();

  // Get the post from the database.
  // If the post is not in the database we return 404.
  final idNumber = BigInt.parse(id);
  final postRecord = await db.postRecord.findUnique(
    where: PostRecordWhereUniqueInput(id: idNumber),
  );
  if (postRecord == null) Response(statusCode: HttpStatus.notFound);

  // Get the post from bluesky, we assume we already know the post exists
  // and don't bother adding to the database or anything.
  final uri = core.AtUri.parse(postRecord!.uri);
  final response = await bluesky.feed.getPosts(uris: [uri]);
  final post = response.data.posts.first;

  // Get the user who posted this from the database.
  final did = post.author.did;
  final user = await db.userRecord.findUnique(
    where: UserRecordWhereUniqueInput(did: did),
  );
  if (user == null) {
    throw Exception('User not found, this should not happen!: $did');
  }

  final mastodonPost = await databaseTransaction(
    () => MastodonPost.fromBlueSkyPost(post),
  );

  if (post.viewer.like != null) {
    // Unlike the post now that we have everything in order.
    await bluesky.atproto.repo.deleteRecord(uri: post.viewer.like!);
    mastodonPost
      ..favourited = false
      ..favouritesCount -= 1;
  }

  // Return the post that we just liked.
  return threadedJsonResponse(
    body: mastodonPost,
  );
}
