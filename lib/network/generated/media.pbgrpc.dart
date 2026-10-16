// This is a generated file - do not edit.
//
// Generated from media.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'media.pb.dart' as $0;

export 'media.pb.dart';

/// Protocol v3. Keep the service path so GetIdentity can reject older peers.
@$pb.GrpcServiceName('tamayura.v1.MediaLibrary')
class MediaLibraryClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  MediaLibraryClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.DeviceIdentity> getIdentity(
    $0.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getIdentity, request, options: options);
  }

  $grpc.ResponseFuture<$0.CatalogResponse> listMediaPage(
    $0.CatalogRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$listMediaPage, request, options: options);
  }

  $grpc.ResponseFuture<$0.ThumbnailResponse> getThumbnail(
    $0.ThumbnailRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getThumbnail, request, options: options);
  }

  $grpc.ResponseStream<$0.FileChunk> readFile(
    $0.ReadRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$readFile, $async.Stream.fromIterable([request]),
        options: options);
  }

  // method descriptors

  static final _$getIdentity = $grpc.ClientMethod<$0.Empty, $0.DeviceIdentity>(
      '/tamayura.v1.MediaLibrary/GetIdentity',
      ($0.Empty value) => value.writeToBuffer(),
      $0.DeviceIdentity.fromBuffer);
  static final _$listMediaPage =
      $grpc.ClientMethod<$0.CatalogRequest, $0.CatalogResponse>(
          '/tamayura.v1.MediaLibrary/ListMediaPage',
          ($0.CatalogRequest value) => value.writeToBuffer(),
          $0.CatalogResponse.fromBuffer);
  static final _$getThumbnail =
      $grpc.ClientMethod<$0.ThumbnailRequest, $0.ThumbnailResponse>(
          '/tamayura.v1.MediaLibrary/GetThumbnail',
          ($0.ThumbnailRequest value) => value.writeToBuffer(),
          $0.ThumbnailResponse.fromBuffer);
  static final _$readFile = $grpc.ClientMethod<$0.ReadRequest, $0.FileChunk>(
      '/tamayura.v1.MediaLibrary/ReadFile',
      ($0.ReadRequest value) => value.writeToBuffer(),
      $0.FileChunk.fromBuffer);
}

@$pb.GrpcServiceName('tamayura.v1.MediaLibrary')
abstract class MediaLibraryServiceBase extends $grpc.Service {
  $core.String get $name => 'tamayura.v1.MediaLibrary';

  MediaLibraryServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.DeviceIdentity>(
        'GetIdentity',
        getIdentity_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.DeviceIdentity value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.CatalogRequest, $0.CatalogResponse>(
        'ListMediaPage',
        listMediaPage_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.CatalogRequest.fromBuffer(value),
        ($0.CatalogResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ThumbnailRequest, $0.ThumbnailResponse>(
        'GetThumbnail',
        getThumbnail_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.ThumbnailRequest.fromBuffer(value),
        ($0.ThumbnailResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.ReadRequest, $0.FileChunk>(
        'ReadFile',
        readFile_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $0.ReadRequest.fromBuffer(value),
        ($0.FileChunk value) => value.writeToBuffer()));
  }

  $async.Future<$0.DeviceIdentity> getIdentity_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.Empty> $request) async {
    return getIdentity($call, await $request);
  }

  $async.Future<$0.DeviceIdentity> getIdentity(
      $grpc.ServiceCall call, $0.Empty request);

  $async.Future<$0.CatalogResponse> listMediaPage_Pre($grpc.ServiceCall $call,
      $async.Future<$0.CatalogRequest> $request) async {
    return listMediaPage($call, await $request);
  }

  $async.Future<$0.CatalogResponse> listMediaPage(
      $grpc.ServiceCall call, $0.CatalogRequest request);

  $async.Future<$0.ThumbnailResponse> getThumbnail_Pre($grpc.ServiceCall $call,
      $async.Future<$0.ThumbnailRequest> $request) async {
    return getThumbnail($call, await $request);
  }

  $async.Future<$0.ThumbnailResponse> getThumbnail(
      $grpc.ServiceCall call, $0.ThumbnailRequest request);

  $async.Stream<$0.FileChunk> readFile_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.ReadRequest> $request) async* {
    yield* readFile($call, await $request);
  }

  $async.Stream<$0.FileChunk> readFile(
      $grpc.ServiceCall call, $0.ReadRequest request);
}
