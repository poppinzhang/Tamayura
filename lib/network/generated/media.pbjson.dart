// This is a generated file - do not edit.
//
// Generated from media.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use emptyDescriptor instead')
const Empty$json = {
  '1': 'Empty',
};

/// Descriptor for `Empty`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List emptyDescriptor =
    $convert.base64Decode('CgVFbXB0eQ==');

@$core.Deprecated('Use deviceIdentityDescriptor instead')
const DeviceIdentity$json = {
  '1': 'DeviceIdentity',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'protocol_version', '3': 3, '4': 1, '5': 13, '10': 'protocolVersion'},
  ],
};

/// Descriptor for `DeviceIdentity`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deviceIdentityDescriptor = $convert.base64Decode(
    'Cg5EZXZpY2VJZGVudGl0eRIOCgJpZBgBIAEoCVICaWQSEgoEbmFtZRgCIAEoCVIEbmFtZRIpCh'
    'Bwcm90b2NvbF92ZXJzaW9uGAMgASgNUg9wcm90b2NvbFZlcnNpb24=');

@$core.Deprecated('Use mediaEntryDescriptor instead')
const MediaEntry$json = {
  '1': 'MediaEntry',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'mime_type', '3': 3, '4': 1, '5': 9, '10': 'mimeType'},
    {'1': 'size', '3': 4, '4': 1, '5': 3, '10': 'size'},
    {'1': 'modified_ms', '3': 5, '4': 1, '5': 3, '10': 'modifiedMs'},
    {'1': 'shared_folder_id', '3': 7, '4': 1, '5': 9, '10': 'sharedFolderId'},
    {
      '1': 'shared_folder_name',
      '3': 8,
      '4': 1,
      '5': 9,
      '10': 'sharedFolderName'
    },
    {'1': 'relative_path', '3': 9, '4': 1, '5': 9, '10': 'relativePath'},
  ],
  '9': [
    {'1': 6, '2': 7},
  ],
};

/// Descriptor for `MediaEntry`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mediaEntryDescriptor = $convert.base64Decode(
    'CgpNZWRpYUVudHJ5Eg4KAmlkGAEgASgJUgJpZBISCgRuYW1lGAIgASgJUgRuYW1lEhsKCW1pbW'
    'VfdHlwZRgDIAEoCVIIbWltZVR5cGUSEgoEc2l6ZRgEIAEoA1IEc2l6ZRIfCgttb2RpZmllZF9t'
    'cxgFIAEoA1IKbW9kaWZpZWRNcxIoChBzaGFyZWRfZm9sZGVyX2lkGAcgASgJUg5zaGFyZWRGb2'
    'xkZXJJZBIsChJzaGFyZWRfZm9sZGVyX25hbWUYCCABKAlSEHNoYXJlZEZvbGRlck5hbWUSIwoN'
    'cmVsYXRpdmVfcGF0aBgJIAEoCVIMcmVsYXRpdmVQYXRoSgQIBhAH');

@$core.Deprecated('Use catalogRequestDescriptor instead')
const CatalogRequest$json = {
  '1': 'CatalogRequest',
  '2': [
    {'1': 'revision', '3': 1, '4': 1, '5': 9, '10': 'revision'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'page_size', '3': 3, '4': 1, '5': 13, '10': 'pageSize'},
    {'1': 'known_revision', '3': 4, '4': 1, '5': 9, '10': 'knownRevision'},
  ],
};

/// Descriptor for `CatalogRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List catalogRequestDescriptor = $convert.base64Decode(
    'Cg5DYXRhbG9nUmVxdWVzdBIaCghyZXZpc2lvbhgBIAEoCVIIcmV2aXNpb24SHQoKcGFnZV90b2'
    'tlbhgCIAEoCVIJcGFnZVRva2VuEhsKCXBhZ2Vfc2l6ZRgDIAEoDVIIcGFnZVNpemUSJQoOa25v'
    'd25fcmV2aXNpb24YBCABKAlSDWtub3duUmV2aXNpb24=');

@$core.Deprecated('Use catalogResponseDescriptor instead')
const CatalogResponse$json = {
  '1': 'CatalogResponse',
  '2': [
    {'1': 'revision', '3': 1, '4': 1, '5': 9, '10': 'revision'},
    {
      '1': 'items',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.tamayura.v1.MediaEntry',
      '10': 'items'
    },
    {'1': 'next_page_token', '3': 3, '4': 1, '5': 9, '10': 'nextPageToken'},
    {'1': 'total_count', '3': 4, '4': 1, '5': 13, '10': 'totalCount'},
    {'1': 'not_modified', '3': 5, '4': 1, '5': 8, '10': 'notModified'},
  ],
};

/// Descriptor for `CatalogResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List catalogResponseDescriptor = $convert.base64Decode(
    'Cg9DYXRhbG9nUmVzcG9uc2USGgoIcmV2aXNpb24YASABKAlSCHJldmlzaW9uEi0KBWl0ZW1zGA'
    'IgAygLMhcudGFtYXl1cmEudjEuTWVkaWFFbnRyeVIFaXRlbXMSJgoPbmV4dF9wYWdlX3Rva2Vu'
    'GAMgASgJUg1uZXh0UGFnZVRva2VuEh8KC3RvdGFsX2NvdW50GAQgASgNUgp0b3RhbENvdW50Ei'
    'EKDG5vdF9tb2RpZmllZBgFIAEoCFILbm90TW9kaWZpZWQ=');

@$core.Deprecated('Use thumbnailRequestDescriptor instead')
const ThumbnailRequest$json = {
  '1': 'ThumbnailRequest',
  '2': [
    {'1': 'revision', '3': 1, '4': 1, '5': 9, '10': 'revision'},
    {'1': 'id', '3': 2, '4': 1, '5': 9, '10': 'id'},
  ],
};

/// Descriptor for `ThumbnailRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List thumbnailRequestDescriptor = $convert.base64Decode(
    'ChBUaHVtYm5haWxSZXF1ZXN0EhoKCHJldmlzaW9uGAEgASgJUghyZXZpc2lvbhIOCgJpZBgCIA'
    'EoCVICaWQ=');

@$core.Deprecated('Use thumbnailResponseDescriptor instead')
const ThumbnailResponse$json = {
  '1': 'ThumbnailResponse',
  '2': [
    {'1': 'revision', '3': 1, '4': 1, '5': 9, '10': 'revision'},
    {'1': 'id', '3': 2, '4': 1, '5': 9, '10': 'id'},
    {'1': 'data', '3': 3, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `ThumbnailResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List thumbnailResponseDescriptor = $convert.base64Decode(
    'ChFUaHVtYm5haWxSZXNwb25zZRIaCghyZXZpc2lvbhgBIAEoCVIIcmV2aXNpb24SDgoCaWQYAi'
    'ABKAlSAmlkEhIKBGRhdGEYAyABKAxSBGRhdGE=');

@$core.Deprecated('Use readRequestDescriptor instead')
const ReadRequest$json = {
  '1': 'ReadRequest',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'offset', '3': 2, '4': 1, '5': 3, '10': 'offset'},
    {'1': 'length', '3': 3, '4': 1, '5': 3, '10': 'length'},
  ],
};

/// Descriptor for `ReadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List readRequestDescriptor = $convert.base64Decode(
    'CgtSZWFkUmVxdWVzdBIOCgJpZBgBIAEoCVICaWQSFgoGb2Zmc2V0GAIgASgDUgZvZmZzZXQSFg'
    'oGbGVuZ3RoGAMgASgDUgZsZW5ndGg=');

@$core.Deprecated('Use fileChunkDescriptor instead')
const FileChunk$json = {
  '1': 'FileChunk',
  '2': [
    {'1': 'offset', '3': 1, '4': 1, '5': 3, '10': 'offset'},
    {'1': 'data', '3': 2, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `FileChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileChunkDescriptor = $convert.base64Decode(
    'CglGaWxlQ2h1bmsSFgoGb2Zmc2V0GAEgASgDUgZvZmZzZXQSEgoEZGF0YRgCIAEoDFIEZGF0YQ'
    '==');
