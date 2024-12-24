import 'dart:io';

import 'package:bluesky/bluesky.dart' as bsky;
import 'package:atproto/atproto.dart' as at;
import 'package:atproto_core/atproto_core.dart' as core;
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_bridge/auth.dart';
import 'package:sky_bridge/database.dart';
import 'package:sky_bridge/models/forms/new_post_form.dart';
import 'package:sky_bridge/models/mastodon/mastodon_post.dart';
import 'package:sky_bridge/src/generated/prisma/prisma_client.dart';
import 'package:sky_bridge/util.dart';

/// Publish a new post with the given parameters.
/// POST /api/v1/statuses HTTP/1.1
/// See: https://docs.joinmastodon.org/methods/statuses/#create
Future<Response> onRequest<T>(RequestContext context) async {
  // Only allow POST requests.
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // Get a bluesky connection/session from the a provided bearer token.
  // If the token is invalid, bail out and return an error.
  final bluesky = await blueskyFromContext(context);
  if (bluesky == null) return authError();

  // Determine if the request is a JSON request or a form request.
  final request = context.request;
  final type = context.request.headers[HttpHeaders.contentTypeHeader] ?? '';
  Map<String, dynamic> body;
  if (type.contains('application/json')) {
    body = await request.json() as Map<String, dynamic>;
  } else {
    body = await request.formData();
  }

  final form = NewPostForm.fromJson(body);
  var facets = <Map<String, dynamic>>[];

  // If the post is a reply, we need to get the parent post and root post.
  bsky.ReplyRef? postReplyRef;
  final replyId = form.inReplyToId;
  if (replyId != null) {
    final record = await db.postRecord.findUnique(
      where: PostRecordWhereUniqueInput(id: BigInt.from(replyId)),
    );

    // The post we're trying to reply to doesn't exist in the database.
    if (record == null) return Response(statusCode: HttpStatus.notFound);

    final uri = core.AtUri.parse(record.uri);
    final post = (await bluesky.feed.getPosts(uris: [uri])).data.posts.first;

    final parentRef = at.StrongRef(
      cid: post.cid,
      uri: post.uri,
    );

    // If the post we're replying to is itself a reply we need to grab the root
    // from it. Otherwise the root is the post we're replying to.
    final reply = post.record.reply;
    postReplyRef = bsky.ReplyRef(
      root: reply != null ? reply.root : parentRef,
      parent: parentRef,
    );
  }

  // Find any linked entities like mentions or links.
  final status = form.status;
  if (status != null) {
    facets = await status.entities.toFacets();
  }

  // Get any images we need to attach if necessary.
  final mediaIds = form.mediaIds;
  final images = <bsky.Image>[];
  if (mediaIds != null) {
    for (final idString in mediaIds) {
      // Get the media record from the database.
      final id = BigInt.parse(idString);
      final record = await db.mediaRecord.findUnique(
        where: MediaRecordWhereUniqueInput(id: id),
      );
      if (record == null) continue;

      // Construct an embed attachment and add it to the list of images.
      final blob = record.toBlob();
      final image = bsky.Image(
        alt: record.description,
        image: blob,
      );

      images.add(image);
    }
  }

  // Construct an embed if we have any images to attach.
  final embed = images.isEmpty
      ? null
      : bsky.Embed.images(
          data: bsky.EmbedImages(
            images: images,
          ),
        );

  // Create a new post with attached entities.
  final newPost = await bluesky.feed.post(
    text: form.status?.value ?? '',
    facets: facets.map(bsky.Facet.fromJson).toList(),
    reply: postReplyRef,
    embed: embed,
    languageTags: form.language != null ? [form.language!] : null,
  );

  // Get our newly created post.
  // If it fails, we try again three times before bailing out.
  bsky.Post? postData;
  for (var i = 0; i < 3; i++) {
    try {
      final response = await bluesky.feed.getPosts(uris: [newPost.data.uri]);
      postData = response.data.posts.first;
      break;
    } catch (_) {
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  // If we still don't have a post, bail out with a 500 error.
  if (postData == null) {
    return Response(statusCode: HttpStatus.internalServerError);
  }

  // Construct and return the new post as a [MastodonPost].
  final mastodonPost = await databaseTransaction(
    () => MastodonPost.fromBlueSkyPost(postData!),
  );

  return threadedJsonResponse(
    body: mastodonPost,
  );
}
