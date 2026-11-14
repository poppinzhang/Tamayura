//go:build android

// The platform owns initialization and engine teardown atomically. Other
// control operations use Dart FFI; both enter the same serialized Go runtime.
// Byte arrays preserve UTF-8 without JNI's modified-UTF-8 conversion rules.
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "_cgo_export.h"

JNIEXPORT jbyteArray JNICALL
Java_dev_fluttertailscale_FlutterTailscalePlugin_requestNative(
    JNIEnv *env, jobject instance, jbyteArray input) {
  (void)instance;
  if (input == NULL) return NULL;
  jsize length = (*env)->GetArrayLength(env, input);
  if (length <= 0 || length > 1024 * 1024) return NULL;
  char *request = (char *)malloc((size_t)length + 1);
  if (request == NULL) return NULL;
  (*env)->GetByteArrayRegion(env, input, 0, length, (jbyte *)request);
  if ((*env)->ExceptionCheck(env)) { free(request); return NULL; }
  if (memchr(request, 0, (size_t)length) != NULL) { free(request); return NULL; }
  request[length] = 0;
  char *response = ft_request(request);
  free(request);
  if (response == NULL) return NULL;
  size_t responseLength = strlen(response);
  if (responseLength > 1024 * 1024) { ft_free(response); return NULL; }
  jbyteArray result = (*env)->NewByteArray(env, (jsize)responseLength);
  if (result != NULL) {
    (*env)->SetByteArrayRegion(env, result, 0, (jsize)responseLength,
                             (const jbyte *)response);
  }
  ft_free(response);
  return result;
}
