#ifndef TAMAYURA_MEDIA_PREVIEW_H_
#define TAMAYURA_MEDIA_PREVIEW_H_

#include <gdk-pixbuf/gdk-pixbuf.h>

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "storage_core.h"

namespace tamayura {

struct PreviewOptions {
  // Look up the freedesktop thumbnail cache and run installed thumbnailers
  // when the image decoders cannot read the media. Used only for the user's
  // own shared files; received files are decoded in process.
  bool system_thumbnailers = false;
  // Private folder for thumbnailer output.
  std::string work_directory;
  // The shared thumbnail cache, normally $XDG_CACHE_HOME/thumbnails.
  std::string thumbnail_cache_directory;
  // Data directories searched for "thumbnailers/*.thumbnailer".
  std::vector<std::string> thumbnailer_roots;
  int timeout_seconds = 20;

  static PreviewOptions ForSharedMedia();
};

// A JPEG no larger than `maximum` pixels on its long side, with EXIF
// orientation applied. Throws PREVIEW_FAILED when no available decoder can
// read the media; file access, memory and I/O failures keep their own codes
// so that they can be retried.
Bytes JpegPreview(const SafeFile& file, unsigned maximum,
                  const std::string& mime_type, const PreviewOptions& options);

// The following are exposed for native tests.
struct EmbeddedJpeg {
  uint64_t offset = 0;
  uint64_t length = 0;
  unsigned width = 0;
  unsigned height = 0;
};
struct RawLayout {
  // The RAW's own orientation from its first image directory.
  std::optional<unsigned> orientation;
  std::vector<EmbeddedJpeg> previews;
};
// Finds JPEG previews in TIFF-based RAW files (DNG, CR2, NEF and ARW)
// without reading the sensor data.
RawLayout ReadRawLayout(const SafeFile& file);
std::optional<std::pair<unsigned, unsigned>> JpegDimensions(const uint8_t* data,
                                                            size_t size);
// Returns a new reference with an EXIF orientation (1-8) applied.
GdkPixbuf* ApplyOrientation(GdkPixbuf* source, unsigned orientation);
// Clears the cached thumbnailer list after tests change the search roots.
void ResetThumbnailers();
// Stops running thumbnailers within 100 ms and starts no new ones, so that
// quitting never waits for a slow video decoder.
void CancelThumbnailers();

}  // namespace tamayura

#endif  // TAMAYURA_MEDIA_PREVIEW_H_
