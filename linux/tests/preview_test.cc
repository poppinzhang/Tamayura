#include "media_preview.h"

#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <chrono>

#include "test_support.h"

namespace {
using namespace tamayura;
using namespace tamayura_test;

struct PixbufHandle {
  GdkPixbuf* value;
  explicit PixbufHandle(GdkPixbuf* pixbuf) : value(pixbuf) {
    Expect(value != nullptr, "Cannot create a test image");
  }
  ~PixbufHandle() { g_object_unref(value); }
  PixbufHandle(const PixbufHandle&) = delete;
  PixbufHandle& operator=(const PixbufHandle&) = delete;
};

// Fills each quadrant with its own colour so orientation is observable.
GdkPixbuf* Quadrants(int width, int height, bool alpha = false) {
  GdkPixbuf* image = gdk_pixbuf_new(GDK_COLORSPACE_RGB, alpha, 8, width, height);
  Expect(image != nullptr, "Cannot allocate a test image");
  const int channels = gdk_pixbuf_get_n_channels(image);
  const int stride = gdk_pixbuf_get_rowstride(image);
  guchar* pixels = gdk_pixbuf_get_pixels(image);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      guchar* pixel = pixels + y * stride + x * channels;
      const bool right = x >= width / 2, bottom = y >= height / 2;
      pixel[0] = right ? 0 : 255;
      pixel[1] = bottom ? 255 : 0;
      pixel[2] = right && bottom ? 255 : 0;
      if (alpha) pixel[3] = 255;
    }
  }
  return image;
}

Bytes Save(GdkPixbuf* image, const char* type, const std::vector<std::string>& options = {}) {
  std::vector<char*> keys, values;
  for (size_t index = 0; index + 1 < options.size(); index += 2) {
    keys.push_back(const_cast<char*>(options[index].c_str()));
    values.push_back(const_cast<char*>(options[index + 1].c_str()));
  }
  keys.push_back(nullptr);
  values.push_back(nullptr);
  gchar* buffer = nullptr;
  gsize size = 0;
  Expect(gdk_pixbuf_save_to_bufferv(image, &buffer, &size, type, keys.data(), values.data(),
                                    nullptr),
         std::string("Cannot encode a test ") + type);
  Bytes bytes(reinterpret_cast<uint8_t*>(buffer), reinterpret_cast<uint8_t*>(buffer) + size);
  g_free(buffer);
  return bytes;
}

Bytes Jpeg(int width, int height) {
  PixbufHandle image(Quadrants(width, height));
  return Save(image.value, "jpeg", {"quality", "95"});
}

// Inserts an EXIF APP1 segment holding only an orientation tag.
Bytes WithOrientation(Bytes jpeg, uint16_t orientation) {
  const uint8_t tiff[] = {'I', 'I', 0x2a, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0,
                          static_cast<uint8_t>(orientation), 0, 0, 0, 0, 0, 0, 0};
  Bytes segment = {0xff, 0xe1, 0, 0, 'E', 'x', 'i', 'f', 0, 0};
  segment.insert(segment.end(), std::begin(tiff), std::end(tiff));
  const size_t length = segment.size() - 2;
  segment[2] = static_cast<uint8_t>(length >> 8);
  segment[3] = static_cast<uint8_t>(length & 0xff);
  jpeg.insert(jpeg.begin() + 2, segment.begin(), segment.end());
  return jpeg;
}

struct Decoded {
  int width = 0;
  int height = 0;
  std::vector<std::array<int, 3>> corners;  // top-left, top-right, bottom-left, bottom-right
};

Decoded DecodeJpeg(const Bytes& bytes) {
  Expect(bytes.size() > 2 && bytes[0] == 0xff && bytes[1] == 0xd8, "Expected JPEG data");
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new_with_type("jpeg", nullptr);
  Expect(loader && gdk_pixbuf_loader_write(loader, bytes.data(), bytes.size(), nullptr) &&
             gdk_pixbuf_loader_close(loader, nullptr),
         "Cannot decode the preview");
  GdkPixbuf* image = gdk_pixbuf_loader_get_pixbuf(loader);
  Decoded result{gdk_pixbuf_get_width(image), gdk_pixbuf_get_height(image), {}};
  const int channels = gdk_pixbuf_get_n_channels(image);
  const int stride = gdk_pixbuf_get_rowstride(image);
  const guchar* pixels = gdk_pixbuf_get_pixels(image);
  const int inset_x = std::max(1, result.width / 8), inset_y = std::max(1, result.height / 8);
  for (const auto& [x, y] : {std::pair<int, int>{inset_x, inset_y},
                             {result.width - 1 - inset_x, inset_y},
                             {inset_x, result.height - 1 - inset_y},
                             {result.width - 1 - inset_x, result.height - 1 - inset_y}}) {
    const guchar* pixel = pixels + y * stride + x * channels;
    result.corners.push_back({pixel[0], pixel[1], pixel[2]});
  }
  g_object_unref(loader);
  return result;
}

// The quadrant colours of Quadrants(), named as in the source image.
enum Corner { kTopLeft, kTopRight, kBottomLeft, kBottomRight };
const std::array<std::array<int, 3>, 4> kColors = {{
    {255, 0, 0}, {0, 0, 0}, {255, 255, 0}, {0, 255, 255}}};

bool Near(const std::array<int, 3>& actual, const std::array<int, 3>& expected) {
  for (int channel = 0; channel < 3; ++channel) {
    if (std::abs(actual[channel] - expected[channel]) > 60) return false;
  }
  return true;
}

void ExpectCorners(const Decoded& image, std::array<Corner, 4> expected, const std::string& what) {
  for (size_t index = 0; index < 4; ++index) {
    Expect(Near(image.corners[index], kColors[expected[index]]),
           what + ": unexpected colour in corner " + std::to_string(index));
  }
}

Bytes PreviewOf(const std::string& path, unsigned maximum, const std::string& mime,
                const PreviewOptions& options = {}) {
  const auto file = SafeFile::Open(path);
  return JpegPreview(file, maximum, mime, options);
}

uint32_t Crc32(const uint8_t* data, size_t size) {
  uint32_t crc = 0xffffffff;
  for (size_t index = 0; index < size; ++index) {
    crc ^= data[index];
    for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
  }
  return ~crc;
}

void AppendChunk(Bytes& png, const char* type, const Bytes& data) {
  const auto size = static_cast<uint32_t>(data.size());
  for (int shift = 24; shift >= 0; shift -= 8) png.push_back(static_cast<uint8_t>(size >> shift));
  Bytes typed(type, type + 4);
  typed.insert(typed.end(), data.begin(), data.end());
  png.insert(png.end(), typed.begin(), typed.end());
  const uint32_t crc = Crc32(typed.data(), typed.size());
  for (int shift = 24; shift >= 0; shift -= 8) png.push_back(static_cast<uint8_t>(crc >> shift));
}

// A valid PNG header claiming a huge image, without pixel data.
Bytes HugePngHeader(uint32_t width, uint32_t height) {
  Bytes png = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  Bytes header;
  for (const uint32_t value : {width, height}) {
    for (int shift = 24; shift >= 0; shift -= 8) header.push_back(static_cast<uint8_t>(value >> shift));
  }
  header.insert(header.end(), {8, 6, 0, 0, 0});
  AppendChunk(png, "IHDR", header);
  AppendChunk(png, "IEND", {});
  return png;
}

// Minimal little-endian TIFF containers shaped like camera RAW files.
class RawBuilder {
 public:
  struct Entry {
    uint16_t tag;
    uint16_t type;
    uint32_t value;
    int blob_offset = -1;  // value is the offset of this blob
    int blob_length = -1;  // value is the length of this blob
    int ifd = -1;          // value is the offset of this IFD
  };
  int Blob(Bytes data) {
    blobs_.push_back(std::move(data));
    return static_cast<int>(blobs_.size() - 1);
  }
  int Ifd(std::vector<Entry> entries, int next = -1) {
    ifds_.push_back({std::move(entries), next});
    return static_cast<int>(ifds_.size() - 1);
  }
  Bytes Build() const {
    std::vector<uint32_t> ifd_offsets, blob_offsets;
    uint32_t cursor = 8;
    for (const auto& ifd : ifds_) {
      ifd_offsets.push_back(cursor);
      cursor += 2 + 12 * static_cast<uint32_t>(ifd.entries.size()) + 4;
    }
    for (const auto& blob : blobs_) {
      blob_offsets.push_back(cursor);
      cursor += static_cast<uint32_t>(blob.size());
    }
    Bytes out = {'I', 'I', 0x2a, 0};
    Put32(out, ifd_offsets.at(0));
    for (const auto& ifd : ifds_) {
      Put16(out, static_cast<uint16_t>(ifd.entries.size()));
      for (const auto& entry : ifd.entries) {
        Put16(out, entry.tag);
        Put16(out, entry.type);
        Put32(out, 1);
        const uint32_t value = entry.blob_offset >= 0 ? blob_offsets.at(entry.blob_offset)
                               : entry.blob_length >= 0
                                   ? static_cast<uint32_t>(blobs_.at(entry.blob_length).size())
                               : entry.ifd >= 0 ? ifd_offsets.at(entry.ifd)
                                                : entry.value;
        if (entry.type == 3) {
          Put16(out, static_cast<uint16_t>(value));
          Put16(out, 0);
        } else {
          Put32(out, value);
        }
      }
      Put32(out, ifd.next >= 0 ? ifd_offsets.at(ifd.next) : 0);
    }
    for (const auto& blob : blobs_) out.insert(out.end(), blob.begin(), blob.end());
    return out;
  }

 private:
  static void Put16(Bytes& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xff));
    out.push_back(static_cast<uint8_t>(value >> 8));
  }
  static void Put32(Bytes& out, uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) out.push_back(static_cast<uint8_t>(value >> shift));
  }
  struct Directory {
    std::vector<Entry> entries;
    int next;
  };
  std::vector<Directory> ifds_;
  std::vector<Bytes> blobs_;
};

constexpr uint16_t kShort = 3, kLong = 4;

PreviewOptions ThumbnailerOptions(const TempDirectory& temp, int timeout = 10) {
  PreviewOptions options;
  options.system_thumbnailers = true;
  options.work_directory = temp / "work";
  options.thumbnail_cache_directory = temp / "cache";
  options.thumbnailer_roots = {temp / "data"};
  options.timeout_seconds = timeout;
  MakeDirectory(options.work_directory, 0700);
  MakeDirectory(temp / "data/thumbnailers");
  ResetThumbnailers();
  return options;
}

void InstallThumbnailer(const TempDirectory& temp, const std::string& script,
                        const std::string& mime_types) {
  WriteText(temp / "data/fake.sh", "#!/bin/sh\n" + script);
  chmod((temp / "data/fake.sh").c_str(), 0755);
  WriteText(temp / "data/thumbnailers/fake.thumbnailer",
            "[Thumbnailer Entry]\nTryExec=sh\nExec=sh " + (temp / "data/fake.sh") +
                " %i %o %s\nMimeType=" + mime_types + "\n");
  ResetThumbnailers();
}

void TestJpegThumbnails() {
  TempDirectory temp;
  WriteFile(temp / "a.jpg", Jpeg(800, 400));
  auto image = DecodeJpeg(PreviewOf(temp / "a.jpg", 256, "image/jpeg"));
  Expect(image.width == 256 && image.height == 128, "aspect ratio kept: " +
                                                        std::to_string(image.width) + "x" +
                                                        std::to_string(image.height));
  ExpectCorners(image, {kTopLeft, kTopRight, kBottomLeft, kBottomRight}, "unrotated");
  WriteFile(temp / "small.jpg", Jpeg(100, 50));
  image = DecodeJpeg(PreviewOf(temp / "small.jpg", 256, "image/jpeg"));
  Expect(image.width == 100 && image.height == 50, "small images are not enlarged");
  WriteFile(temp / "large.jpg", Jpeg(3000, 2000));
  image = DecodeJpeg(PreviewOf(temp / "large.jpg", 2560, "image/jpeg"));
  Expect(image.width == 2560 && image.height == 1707, "large preview fits 2560");
  Reject("INVALID_ARGUMENT", [&] { PreviewOf(temp / "a.jpg", 0, "image/jpeg"); });
  Reject("INVALID_ARGUMENT", [&] { PreviewOf(temp / "a.jpg", 2561, "image/jpeg"); });
}

void TestExifOrientation() {
  TempDirectory temp;
  WriteFile(temp / "rotated.jpg", WithOrientation(Jpeg(800, 400), 6));
  auto image = DecodeJpeg(PreviewOf(temp / "rotated.jpg", 256, "image/jpeg"));
  Expect(image.width == 128 && image.height == 256, "orientation 6 swaps axes");
  ExpectCorners(image, {kBottomLeft, kTopLeft, kBottomRight, kTopRight}, "rotate clockwise");
  WriteFile(temp / "flipped.jpg", WithOrientation(Jpeg(800, 400), 3));
  image = DecodeJpeg(PreviewOf(temp / "flipped.jpg", 256, "image/jpeg"));
  Expect(image.width == 256 && image.height == 128, "orientation 3 keeps axes");
  ExpectCorners(image, {kBottomRight, kBottomLeft, kTopRight, kTopLeft}, "rotate 180");
}

void TestApplyOrientationTable() {
  PixbufHandle source(Quadrants(30, 20));
  const std::array<std::array<Corner, 4>, 9> expected = {{
      {kTopLeft, kTopRight, kBottomLeft, kBottomRight},
      {kTopLeft, kTopRight, kBottomLeft, kBottomRight},
      {kTopRight, kTopLeft, kBottomRight, kBottomLeft},
      {kBottomRight, kBottomLeft, kTopRight, kTopLeft},
      {kBottomLeft, kBottomRight, kTopLeft, kTopRight},
      {kTopLeft, kBottomLeft, kTopRight, kBottomRight},
      {kBottomLeft, kTopLeft, kBottomRight, kTopRight},
      {kBottomRight, kTopRight, kBottomLeft, kTopLeft},
      {kTopRight, kBottomRight, kTopLeft, kBottomLeft},
  }};
  for (unsigned orientation = 1; orientation <= 8; ++orientation) {
    PixbufHandle oriented(ApplyOrientation(source.value, orientation));
    const bool swapped = orientation >= 5;
    Expect(gdk_pixbuf_get_width(oriented.value) == (swapped ? 20 : 30) &&
               gdk_pixbuf_get_height(oriented.value) == (swapped ? 30 : 20),
           "orientation dimensions");
    ExpectCorners(DecodeJpeg(Save(oriented.value, "jpeg", {"quality", "95"})),
                  expected[orientation], "orientation " + std::to_string(orientation));
  }
}

void TestTransparencyAndFormats() {
  TempDirectory temp;
  GdkPixbuf* clear = gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, 200, 100);
  gdk_pixbuf_fill(clear, 0x00000000);
  WriteFile(temp / "clear.png", Save(clear, "png"));
  g_object_unref(clear);
  const auto image = DecodeJpeg(PreviewOf(temp / "clear.png", 256, "image/png"));
  Expect(image.width == 200 && image.height == 100, "PNG size");
  for (const auto& corner : image.corners) {
    Expect(corner[0] > 235 && corner[1] > 235 && corner[2] > 235,
           "transparent pixels become white");
  }
  PixbufHandle opaque(Quadrants(64, 32));
  WriteFile(temp / "image.bmp", Save(opaque.value, "bmp"));
  Expect(DecodeJpeg(PreviewOf(temp / "image.bmp", 256, "image/bmp")).width == 64, "BMP");
  // A content type that does not match the extension is still sniffed.
  WriteFile(temp / "misnamed.png", Jpeg(40, 20));
  Expect(DecodeJpeg(PreviewOf(temp / "misnamed.png", 256, "image/png")).width == 40,
         "sniffed when the extension is wrong");
}

void TestUndecodableImages() {
  TempDirectory temp;
  WriteText(temp / "noise.jpg", std::string(4096, 'x'));
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "noise.jpg", 256, "image/jpeg"); });
  auto truncated = Jpeg(800, 400);
  truncated.resize(64);
  WriteFile(temp / "truncated.jpg", truncated);
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "truncated.jpg", 256, "image/jpeg"); });
  // Only the listed media formats are decoded, whatever the extension says.
  WriteText(temp / "icon.jpg",
            "/* XPM */\nstatic char * icon[] = {\"1 1 1 1\", \"a c #FF0000\", \"a\"};\n");
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "icon.jpg", 256, "image/jpeg"); });
  PixbufHandle tiny(Quadrants(16, 16, true));
  WriteFile(temp / "icon.png", Save(tiny.value, "ico"));
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "icon.png", 256, "image/png"); });
  WriteFile(temp / "empty.jpg", {});
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "empty.jpg", 256, "image/jpeg"); });
  WriteText(temp / "clip.mp4", "not a video");
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "clip.mp4", 256, "video/mp4"); });
}

// gdk-pixbuf decodes JPEG progressively: once the frame header is complete,
// missing scan data leaves the rest of the image grey, as in image viewers.
// A file still being copied changes size, so its preview is requested again.
void TestTruncatedScan() {
  TempDirectory temp;
  auto truncated = Jpeg(800, 400);
  truncated.resize(truncated.size() * 2 / 3);
  WriteFile(temp / "partial.jpg", truncated);
  const auto image = DecodeJpeg(PreviewOf(temp / "partial.jpg", 256, "image/jpeg"));
  Expect(image.width == 256 && image.height == 128, "partial image keeps its frame size");
}

void TestPixelBudget() {
  TempDirectory temp;
  WriteFile(temp / "huge.png", HugePngHeader(9000, 9000));
  const auto started = std::chrono::steady_clock::now();
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "huge.png", 256, "image/png"); });
  Expect(std::chrono::steady_clock::now() - started < std::chrono::seconds(5),
         "huge images are rejected before decoding");
  // A JPEG frame header claiming 65000 x 65000 pixels.
  auto jpeg = Jpeg(64, 32);
  for (size_t index = 2; index + 9 < jpeg.size(); ++index) {
    if (jpeg[index] == 0xff && jpeg[index + 1] == 0xc0) {
      jpeg[index + 5] = 0xfd;
      jpeg[index + 6] = 0xe8;
      jpeg[index + 7] = 0xfd;
      jpeg[index + 8] = 0xe8;
      break;
    }
  }
  WriteFile(temp / "huge.jpg", jpeg);
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "huge.jpg", 256, "image/jpeg"); });
}

void TestJpegDimensions() {
  const auto jpeg = Jpeg(321, 123);
  const auto size = JpegDimensions(jpeg.data(), jpeg.size());
  Expect(size && size->first == 321 && size->second == 123, "baseline frame size");
  const Bytes progressive = {0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xff, 0xc2,
                             0x00, 0x0b, 0x08, 0x01, 0x00, 0x02, 0x00, 0x01, 0x01, 0x11, 0x00};
  const auto frame = JpegDimensions(progressive.data(), progressive.size());
  Expect(frame && frame->first == 512 && frame->second == 256, "progressive frame size");
  const Bytes scan_first = {0xff, 0xd8, 0xff, 0xda, 0x00, 0x02};
  Expect(!JpegDimensions(scan_first.data(), scan_first.size()), "no frame before scan");
  Expect(!JpegDimensions(progressive.data(), 12), "truncated header");
  const Bytes png = {0x89, 'P', 'N', 'G'};
  Expect(!JpegDimensions(png.data(), png.size()), "not a JPEG");
}

void TestRawEmbeddedPreview() {
  TempDirectory temp;
  {
    // The RAW orientation wins over the embedded JPEG's own tag.
    RawBuilder raw;
    const int preview = raw.Blob(WithOrientation(Jpeg(1024, 512), 3));
    raw.Ifd({{256, kLong, 6000}, {257, kLong, 4000}, {274, kShort, 6},
             {513, kLong, 0, preview}, {514, kLong, 0, -1, preview}});
    WriteFile(temp / "a.ARW", raw.Build());
    const auto layout = ReadRawLayout(SafeFile::Open(temp / "a.ARW"));
    Expect(layout.orientation && *layout.orientation == 6 && layout.previews.size() == 1 &&
               layout.previews[0].width == 1024 && layout.previews[0].height == 512,
           "RAW layout");
    const auto image = DecodeJpeg(PreviewOf(temp / "a.ARW", 256, "image/x-sony-arw"));
    Expect(image.width == 128 && image.height == 256, "RAW orientation applied once");
    ExpectCorners(image, {kBottomLeft, kTopLeft, kBottomRight, kTopRight}, "RAW rotation");
  }
  {
    // Without a RAW orientation, the embedded JPEG's tag is used.
    RawBuilder raw;
    const int preview = raw.Blob(WithOrientation(Jpeg(1024, 512), 6));
    raw.Ifd({{513, kLong, 0, preview}, {514, kLong, 0, -1, preview}});
    WriteFile(temp / "b.NEF", raw.Build());
    const auto image = DecodeJpeg(PreviewOf(temp / "b.NEF", 256, "image/x-nikon-nef"));
    Expect(image.width == 128 && image.height == 256, "embedded orientation used");
  }
}

void TestRawPreviewSelection() {
  TempDirectory temp;
  // IFD0 -> SubIFD with a JPEG strip (as in DNG), IFD0 -> IFD1 with an
  // interchange-format thumbnail (as in CR2).
  RawBuilder raw;
  const int small = raw.Blob(Jpeg(160, 120));
  const int large = raw.Blob(Jpeg(1600, 1200));
  RawBuilder::Entry subdirectory{330, kLong, 0};
  subdirectory.ifd = 1;
  raw.Ifd({{256, kLong, 6000}, {257, kLong, 4000}, subdirectory}, 2);
  raw.Ifd({{254, kLong, 1}, {259, kShort, 7}, {273, kLong, 0, large},
           {279, kLong, 0, -1, large}});
  raw.Ifd({{513, kLong, 0, small}, {514, kLong, 0, -1, small}});
  WriteFile(temp / "c.DNG", raw.Build());
  const auto layout = ReadRawLayout(SafeFile::Open(temp / "c.DNG"));
  Expect(layout.previews.size() == 2 && !layout.orientation, "both previews found");
  auto image = DecodeJpeg(PreviewOf(temp / "c.DNG", 256, "image/x-adobe-dng"));
  Expect(image.width == 256 && image.height == 192, "smallest covering preview used");
  image = DecodeJpeg(PreviewOf(temp / "c.DNG", 2560, "image/x-adobe-dng"));
  Expect(image.width == 1600 && image.height == 1200, "largest preview when none covers");
  image = DecodeJpeg(PreviewOf(temp / "c.DNG", 100, "image/x-adobe-dng"));
  Expect(image.width == 100 && image.height == 75, "small request uses the thumbnail");
}

void TestDamagedRaw() {
  TempDirectory temp;
  const auto check = [&](const Bytes& bytes, const std::string& what) {
    WriteFile(temp / "damaged.CR2", bytes);
    (void)ReadRawLayout(SafeFile::Open(temp / "damaged.CR2"));
    Reject("PREVIEW_FAILED",
           [&] { PreviewOf(temp / "damaged.CR2", 256, "image/x-canon-cr2"); });
    (void)what;
  };
  check({'I', 'I', 0x2a, 0, 8, 0, 0, 0}, "header only");
  check({'M', 'M', 0, 0x2a, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0}, "offset past end");
  // IFD0 points to itself as the next directory.
  Bytes loop = {'I', 'I', 0x2a, 0, 8, 0, 0, 0, 1, 0, 0x01, 0x02, 4, 0, 1, 0, 0, 0,
                0xff, 0xff, 0, 0, 8, 0, 0, 0};
  check(loop, "directory loop");
  RawBuilder raw;
  const int preview = raw.Blob(Jpeg(1024, 512));
  raw.Ifd({{513, kLong, 0, preview}, {514, kLong, 0xffffff}});
  check(raw.Build(), "preview length past the end");
  RawBuilder garbage;
  const int noise = garbage.Blob(Bytes(4096, 0xff));
  garbage.Ifd({{513, kLong, 0, noise}, {514, kLong, 0, -1, noise}});
  check(garbage.Build(), "embedded data is not a JPEG");
}

void TestThumbnailers() {
  TempDirectory temp;
  auto options = ThumbnailerOptions(temp);
  PixbufHandle fixture(Quadrants(320, 180));
  WriteFile(temp / "data/fixture.png", Save(fixture.value, "png"));
  InstallThumbnailer(temp,
                     "[ \"$(head -c 4 \"$1\")\" = FAKE ] || exit 3\n"
                     "printf '%s %s' \"$1\" \"$3\" > " + (temp / "args") + "\n"
                     "cp " + (temp / "data/fixture.png") + " \"$2\"\n",
                     "video/mp4;video/quicktime;");
  WriteText(temp / "clip.mp4", "FAKE video bytes");
  const auto image = DecodeJpeg(PreviewOf(temp / "clip.mp4", 256, "video/mp4", options));
  Expect(image.width == 256 && image.height == 144, "thumbnailer output scaled");
  const auto args = ReadFile(temp / "args");
  Expect(std::string(args.begin(), args.end()) == "/proc/self/fd/3 256",
         "the child reads the validated descriptor");
  GDir* scratch = g_dir_open((temp / "work").c_str(), 0, nullptr);
  Expect(scratch && !g_dir_read_name(scratch), "scratch output removed");
  g_dir_close(scratch);
  // Received files and other callers never start external programs.
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "clip.mp4", 256, "video/mp4"); });
  WriteText(temp / "other.mp4", "something else");
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "other.mp4", 256, "video/mp4", options); });
  if (g_content_type_is_a("video/x-m4v", "video/mp4")) {
    WriteText(temp / "clip.m4v", "FAKE m4v");
    Expect(DecodeJpeg(PreviewOf(temp / "clip.m4v", 256, "video/x-m4v", options)).width == 256,
           "MIME subclasses match a thumbnailer");
  }
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "clip.mp4", 256, "video/webm", options); });
}

void TestThumbnailerTimeout() {
  TempDirectory temp;
  auto options = ThumbnailerOptions(temp, 1);
  InstallThumbnailer(temp, "exec sleep 30\n", "video/mp4;");
  WriteText(temp / "slow.mp4", "FAKE");
  const auto started = std::chrono::steady_clock::now();
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "slow.mp4", 256, "video/mp4", options); });
  Expect(std::chrono::steady_clock::now() - started < std::chrono::seconds(10),
         "a hung thumbnailer is stopped");
  InstallThumbnailer(temp, "exit 1\n", "video/mp4;");
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "slow.mp4", 256, "video/mp4", options); });
  InstallThumbnailer(temp, "printf 'not png' > \"$2\"\n", "video/mp4;");
  Reject("PREVIEW_FAILED", [&] { PreviewOf(temp / "slow.mp4", 256, "video/mp4", options); });
}

void TestSystemThumbnailCache() {
  TempDirectory temp;
  auto options = ThumbnailerOptions(temp);
  const auto video = temp / "movie.mp4";
  WriteText(video, "cached video");
  struct stat info {};
  Expect(stat(video.c_str(), &info) == 0, "stat video");
  gchar* uri = g_filename_to_uri(video.c_str(), nullptr, nullptr);
  gchar* digest = g_compute_checksum_for_string(G_CHECKSUM_MD5, uri, -1);
  MakeDirectory(temp / "cache/large");
  const auto path = temp / ("cache/large/" + std::string(digest) + ".png");
  PixbufHandle thumbnail(Quadrants(256, 128));
  WriteFile(path, Save(thumbnail.value, "png",
                       {"tEXt::Thumb::URI", uri, "tEXt::Thumb::MTime",
                        std::to_string(info.st_mtim.tv_sec)}));
  const auto image = DecodeJpeg(PreviewOf(video, 256, "video/mp4", options));
  Expect(image.width == 256 && image.height == 128, "current cached thumbnail used");
  WriteFile(path, Save(thumbnail.value, "png",
                       {"tEXt::Thumb::URI", uri, "tEXt::Thumb::MTime", "1"}));
  Reject("PREVIEW_FAILED", [&] { PreviewOf(video, 256, "video/mp4", options); });
  WriteFile(path, Save(thumbnail.value, "png",
                       {"tEXt::Thumb::URI", "file:///elsewhere.mp4", "tEXt::Thumb::MTime",
                        std::to_string(info.st_mtim.tv_sec)}));
  Reject("PREVIEW_FAILED", [&] { PreviewOf(video, 256, "video/mp4", options); });
  g_free(digest);
  g_free(uri);
}

}  // namespace

int main() {
  return RunTests("preview", {
      {"JPEG thumbnails keep their aspect ratio and size limits", TestJpegThumbnails},
      {"EXIF orientation is applied", TestExifOrientation},
      {"orientation table matches EXIF", TestApplyOrientationTable},
      {"transparency and other formats", TestTransparencyAndFormats},
      {"undecodable images are preview failures", TestUndecodableImages},
      {"truncated scan data", TestTruncatedScan},
      {"huge images are rejected before allocation", TestPixelBudget},
      {"JPEG frame sizes", TestJpegDimensions},
      {"RAW embedded previews and orientation", TestRawEmbeddedPreview},
      {"RAW preview selection", TestRawPreviewSelection},
      {"damaged RAW containers fail safely", TestDamagedRaw},
      {"installed thumbnailers for shared videos", TestThumbnailers},
      {"thumbnailer failures and timeouts", TestThumbnailerTimeout},
      {"freedesktop thumbnail cache", TestSystemThumbnailCache},
  });
}
