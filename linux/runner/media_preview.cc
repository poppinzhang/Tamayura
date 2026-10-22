#include "media_preview.h"

#include <fcntl.h>
#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>

namespace tamayura {
namespace {

// libjpeg decodes at a reduced scale; other formats decode at full size
// before they are scaled, so they get a smaller pixel budget.
constexpr uint64_t kMaxScaledDecodePixels = 600ull * 1000 * 1000;
constexpr uint64_t kMaxFullDecodePixels = 64ull * 1000 * 1000;
// Bound the channel payload even for a particularly noisy image.
constexpr size_t kMaxPreviewBytes = 8 * 1024 * 1024;
constexpr uint64_t kMaxEmbeddedJpegBytes = 64ull * 1024 * 1024;
constexpr int64_t kMaxCachedThumbnailBytes = 16 * 1024 * 1024;

class Semaphore {
 public:
  explicit Semaphore(unsigned count) : count_(count) {}
  void Acquire() {
    std::unique_lock<std::mutex> lock(mutex_);
    ready_.wait(lock, [this] { return count_ > 0; });
    --count_;
  }
  void Release() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      ++count_;
    }
    ready_.notify_one();
  }

 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  unsigned count_;
};

class Permit {
 public:
  explicit Permit(Semaphore& semaphore) : semaphore_(semaphore) {
    semaphore_.Acquire();
  }
  ~Permit() { semaphore_.Release(); }
  Permit(const Permit&) = delete;
  Permit& operator=(const Permit&) = delete;

 private:
  Semaphore& semaphore_;
};

// Bounds peak memory from concurrent decodes and the number of thumbnailer
// processes started for one large folder of videos.
Semaphore& DecodeSlots() {
  static Semaphore slots(4);
  return slots;
}

Semaphore& ThumbnailerSlots() {
  static Semaphore slots(2);
  return slots;
}

struct PixbufDeleter {
  void operator()(GdkPixbuf* pixbuf) const {
    if (pixbuf) g_object_unref(pixbuf);
  }
};
using Pixbuf = std::unique_ptr<GdkPixbuf, PixbufDeleter>;

[[noreturn]] void Undecodable() {
  throw StorageError("PREVIEW_FAILED", TextId::kCannotDecode);
}

// Exhausted memory may recover later; anything else the decoder reports is a
// property of this file.
[[noreturn]] void DecodeFailure(const GError* error) {
  if (error && error->domain == GDK_PIXBUF_ERROR &&
      error->code == GDK_PIXBUF_ERROR_INSUFFICIENT_MEMORY) {
    throw StorageError("RESOURCE_EXHAUSTED", TextId::kResourcesExhausted);
  }
  Undecodable();
}

Pixbuf Allocated(GdkPixbuf* pixbuf) {
  if (!pixbuf) {
    throw StorageError("RESOURCE_EXHAUSTED", TextId::kResourcesExhausted);
  }
  return Pixbuf(pixbuf);
}

struct DecodeState {
  unsigned maximum;  // 0 keeps the decoded size.
  bool rejected = false;
};

void OnSizePrepared(GdkPixbufLoader* loader, gint width, gint height,
                    gpointer data) {
  auto* state = static_cast<DecodeState*>(data);
  GdkPixbufFormat* format = gdk_pixbuf_loader_get_format(loader);
  gchar* format_name = format ? gdk_pixbuf_format_get_name(format) : nullptr;
  const bool scaled_decode = g_strcmp0(format_name, "jpeg") == 0;
  g_free(format_name);
  const uint64_t pixels = width > 0 && height > 0
                              ? static_cast<uint64_t>(width) *
                                    static_cast<uint64_t>(height)
                              : 0;
  if (!pixels ||
      pixels > (scaled_decode ? kMaxScaledDecodePixels : kMaxFullDecodePixels)) {
    state->rejected = true;
    // A zero size stops the loader before it allocates the image, as
    // gdk_pixbuf_get_file_info() does.
    gdk_pixbuf_loader_set_size(loader, 0, 0);
    return;
  }
  const auto longest = static_cast<unsigned>(std::max(width, height));
  if (state->maximum && longest > state->maximum) {
    const double ratio = static_cast<double>(state->maximum) / longest;
    gdk_pixbuf_loader_set_size(loader,
                               std::max(1, static_cast<int>(width * ratio + 0.5)),
                               std::max(1, static_cast<int>(height * ratio + 0.5)));
  }
}

bool HasLoaderFor(const std::string& mime_type) {
  GSList* formats = gdk_pixbuf_get_formats();
  bool found = false;
  for (GSList* item = formats; item && !found; item = item->next) {
    auto* format = static_cast<GdkPixbufFormat*>(item->data);
    if (gdk_pixbuf_format_is_disabled(format)) continue;
    gchar** types = gdk_pixbuf_format_get_mime_types(format);
    for (gchar** type = types; type && *type && !found; ++type) {
      found = mime_type == *type;
    }
    g_strfreev(types);
  }
  g_slist_free(formats);
  return found;
}

// Decodes `length` bytes at `offset` with the loader for the gdk-pixbuf
// format `type`, or else for `mime_type`; there is no generic sniffing. All
// bytes come from the already validated descriptor.
Pixbuf Decode(const SafeFile& file, uint64_t offset, uint64_t length,
              const char* type, const std::string& mime_type,
              unsigned maximum) {
  Permit permit(DecodeSlots());
  GdkPixbufLoader* loader =
      type ? gdk_pixbuf_loader_new_with_type(type, nullptr)
      : mime_type.empty()
          ? nullptr
          : gdk_pixbuf_loader_new_with_mime_type(mime_type.c_str(), nullptr);
  if (!loader) Undecodable();
  DecodeState state{maximum};
  g_signal_connect(loader, "size-prepared", G_CALLBACK(OnSizePrepared), &state);
  g_autoptr(GError) error = nullptr;
  bool failed = false;
  try {
    std::vector<uint8_t> buffer(256 * 1024);
    uint64_t done = 0;
    while (done < length && !state.rejected) {
      const auto request =
          static_cast<size_t>(std::min<uint64_t>(buffer.size(), length - done));
      const size_t read = file.ReadAt(static_cast<int64_t>(offset + done),
                                      buffer.data(), request);
      if (read == 0) throw StorageError("FILE_CHANGED", TextId::kFileEnded);
      if (!gdk_pixbuf_loader_write(loader, buffer.data(), read, &error)) {
        failed = true;
        break;
      }
      done += read;
    }
  } catch (...) {
    gdk_pixbuf_loader_close(loader, nullptr);
    g_object_unref(loader);
    throw;
  }
  g_autoptr(GError) close_error = nullptr;
  const gboolean closed =
      gdk_pixbuf_loader_close(loader, failed ? nullptr : &close_error);
  GdkPixbuf* decoded = gdk_pixbuf_loader_get_pixbuf(loader);
  Pixbuf result(decoded && !failed && closed && !state.rejected
                    ? GDK_PIXBUF(g_object_ref(decoded))
                    : nullptr);
  g_object_unref(loader);
  if (!result) DecodeFailure(error ? error : close_error);
  return result;
}

// Returns null when this decoder cannot read the bytes; retryable failures
// still throw.
Pixbuf TryDecode(const SafeFile& file, uint64_t offset, uint64_t length,
                 const char* type, const std::string& mime_type,
                 unsigned maximum) {
  try {
    return Decode(file, offset, length, type, mime_type, maximum);
  } catch (const StorageError& error) {
    if (error.code != "PREVIEW_FAILED") throw;
    return nullptr;
  }
}

bool HasBrand(const uint8_t* head, size_t size, std::initializer_list<const char*> brands) {
  // ISO base media "ftyp": major brand at 8, compatible brands from 16.
  const size_t box = static_cast<size_t>(head[0]) << 24 | head[1] << 16 | head[2] << 8 | head[3];
  const size_t end = std::min(size, std::max<size_t>(box, 16));
  for (size_t position = 8; position + 4 <= end; position += position == 8 ? 8 : 4) {
    for (const char* brand : brands) {
      if (std::memcmp(head + position, brand, 4) == 0) return true;
    }
  }
  return false;
}

// Media formats are identified by their content, as on the other platforms,
// and only these loaders are used. Icon, legacy and vector loaders never
// see media, including files received from other devices.
Pixbuf TryDecodeMedia(const SafeFile& file, uint64_t offset, uint64_t length,
                      unsigned maximum) {
  uint8_t head[64] = {};
  const size_t size =
      file.ReadAt(static_cast<int64_t>(offset), head, std::min<uint64_t>(sizeof(head), length));
  const char* type = nullptr;
  const char* mime_type = nullptr;
  if (size >= 3 && head[0] == 0xff && head[1] == 0xd8 && head[2] == 0xff) {
    type = "jpeg";
  } else if (size >= 8 && std::memcmp(head, "\x89PNG\r\n\x1a\n", 8) == 0) {
    type = "png";
  } else if (size >= 6 &&
             (std::memcmp(head, "GIF87a", 6) == 0 || std::memcmp(head, "GIF89a", 6) == 0)) {
    type = "gif";
  } else if (size >= 2 && head[0] == 'B' && head[1] == 'M') {
    type = "bmp";
  } else if (size >= 4 && (std::memcmp(head, "II*\0", 4) == 0 ||
                           std::memcmp(head, "MM\0*", 4) == 0)) {
    type = "tiff";
  } else if (size >= 12 && std::memcmp(head, "RIFF", 4) == 0 &&
             std::memcmp(head + 8, "WEBP", 4) == 0) {
    type = "webp";
  } else if (size >= 16 && std::memcmp(head + 4, "ftyp", 4) == 0) {
    if (HasBrand(head, size, {"avif", "avis"})) {
      mime_type = "image/avif";
    } else if (HasBrand(head, size, {"heic", "heix", "heim", "heis", "hevc", "hevx",
                                     "hevm", "hevs", "mif1", "msf1"})) {
      mime_type = "image/heif";
    }
  }
  if (!type && !mime_type) return nullptr;
  if (mime_type && !HasLoaderFor(mime_type)) return nullptr;
  return TryDecode(file, offset, length, type, mime_type ? mime_type : "", maximum);
}

Pixbuf ScaleToFit(Pixbuf image, unsigned maximum) {
  const int width = gdk_pixbuf_get_width(image.get());
  const int height = gdk_pixbuf_get_height(image.get());
  const auto longest = static_cast<unsigned>(std::max(width, height));
  if (longest <= maximum) return image;
  const double ratio = static_cast<double>(maximum) / longest;
  return Allocated(gdk_pixbuf_scale_simple(
      image.get(), std::max(1, static_cast<int>(width * ratio + 0.5)),
      std::max(1, static_cast<int>(height * ratio + 0.5)),
      GDK_INTERP_BILINEAR));
}

// JPEG has no alpha; transparent pixels would otherwise become black.
Pixbuf Opaque(Pixbuf image) {
  if (!gdk_pixbuf_get_has_alpha(image.get())) return image;
  const int width = gdk_pixbuf_get_width(image.get());
  const int height = gdk_pixbuf_get_height(image.get());
  auto background =
      Allocated(gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, width, height));
  gdk_pixbuf_fill(background.get(), 0xffffffff);
  gdk_pixbuf_composite(image.get(), background.get(), 0, 0, width, height, 0,
                       0, 1, 1, GDK_INTERP_NEAREST, 255);
  return background;
}

Bytes EncodeJpeg(Pixbuf image, unsigned maximum) {
  image = Opaque(ScaleToFit(std::move(image), maximum));
  const char* quality = maximum <= 256 ? "80" : "88";
  for (;;) {
    gchar* buffer = nullptr;
    gsize size = 0;
    g_autoptr(GError) error = nullptr;
    if (!gdk_pixbuf_save_to_buffer(image.get(), &buffer, &size, "jpeg", &error,
                                   "quality", quality, nullptr)) {
      if (error && error->domain == GDK_PIXBUF_ERROR &&
          error->code == GDK_PIXBUF_ERROR_INSUFFICIENT_MEMORY) {
        throw StorageError("RESOURCE_EXHAUSTED", TextId::kResourcesExhausted);
      }
      throw StorageError("PREVIEW_FAILED", TextId::kCannotEncodePreview);
    }
    std::unique_ptr<gchar, decltype(&g_free)> owned(buffer, g_free);
    if (!size) throw StorageError("PREVIEW_FAILED", TextId::kCannotEncodePreview);
    if (size <= kMaxPreviewBytes) {
      const auto* bytes = reinterpret_cast<const uint8_t*>(buffer);
      return Bytes(bytes, bytes + size);
    }
    const int width = gdk_pixbuf_get_width(image.get());
    const int height = gdk_pixbuf_get_height(image.get());
    if (width <= 1 && height <= 1) {
      throw StorageError("PREVIEW_FAILED", TextId::kCannotEncodePreview);
    }
    image = Allocated(gdk_pixbuf_scale_simple(image.get(), std::max(1, width / 2),
                                              std::max(1, height / 2),
                                              GDK_INTERP_BILINEAR));
  }
}

Pixbuf EmbeddedOrientation(Pixbuf image) {
  return Allocated(gdk_pixbuf_apply_embedded_orientation(image.get()));
}

class Tiff {
 public:
  Tiff(const SafeFile& file, int64_t size, bool little)
      : file_(file), size_(static_cast<uint64_t>(size)), little_(little) {}

  uint16_t U16(const uint8_t* bytes) const {
    return little_ ? static_cast<uint16_t>(bytes[0] | bytes[1] << 8)
                   : static_cast<uint16_t>(bytes[0] << 8 | bytes[1]);
  }
  uint32_t U32(const uint8_t* bytes) const {
    return little_ ? static_cast<uint32_t>(bytes[0]) |
                         static_cast<uint32_t>(bytes[1]) << 8 |
                         static_cast<uint32_t>(bytes[2]) << 16 |
                         static_cast<uint32_t>(bytes[3]) << 24
                   : static_cast<uint32_t>(bytes[0]) << 24 |
                         static_cast<uint32_t>(bytes[1]) << 16 |
                         static_cast<uint32_t>(bytes[2]) << 8 |
                         static_cast<uint32_t>(bytes[3]);
  }
  bool Read(uint64_t offset, uint8_t* buffer, size_t length) const {
    return offset <= size_ && length <= size_ - offset &&
           file_.ReadAt(static_cast<int64_t>(offset), buffer, length) == length;
  }

  struct Entry {
    uint16_t type = 0;
    uint32_t count = 0;
    uint8_t value[4] = {};
  };

  // A single SHORT or LONG value.
  std::optional<uint32_t> Scalar(const Entry& entry) const {
    if (entry.count != 1) return std::nullopt;
    if (entry.type == 3) return U16(entry.value);
    if (entry.type == 4 || entry.type == 13) return U32(entry.value);
    return std::nullopt;
  }

  // LONG or IFD offsets, stored inline when there is only one.
  std::vector<uint32_t> Offsets(const Entry& entry, uint32_t limit) const {
    if ((entry.type != 4 && entry.type != 13) || entry.count == 0 ||
        entry.count > limit) {
      return {};
    }
    if (entry.count == 1) return {U32(entry.value)};
    std::vector<uint8_t> bytes(static_cast<size_t>(entry.count) * 4);
    if (!Read(U32(entry.value), bytes.data(), bytes.size())) return {};
    std::vector<uint32_t> values;
    for (uint32_t index = 0; index < entry.count; ++index) {
      values.push_back(U32(&bytes[static_cast<size_t>(index) * 4]));
    }
    return values;
  }

 private:
  const SafeFile& file_;
  uint64_t size_;
  bool little_;
};

std::optional<Bytes> RawPreview(const SafeFile& file, const FileInfo& info,
                                const std::string& mime_type,
                                unsigned maximum) {
  const auto layout = ReadRawLayout(file);
  auto previews = layout.previews;
  std::sort(previews.begin(), previews.end(),
            [](const EmbeddedJpeg& left, const EmbeddedJpeg& right) {
              return std::max(left.width, left.height) <
                     std::max(right.width, right.height);
            });
  auto finish = [&](Pixbuf image) {
    // The RAW's orientation wins and is applied once; some cameras mark an
    // embedded JPEG as upright even though its pixels keep the RAW layout.
    if (layout.orientation) {
      image = Pixbuf(ApplyOrientation(image.get(), *layout.orientation));
    } else {
      image = EmbeddedOrientation(std::move(image));
    }
    return EncodeJpeg(std::move(image), maximum);
  };
  // Prefer the smallest embedded preview that covers the request. Reading
  // its bytes never touches the sensor data.
  std::set<size_t> tried;
  for (size_t index = 0; index < previews.size(); ++index) {
    const auto& preview = previews[index];
    if (std::max(preview.width, preview.height) < maximum) continue;
    tried.insert(index);
    if (auto image = TryDecode(file, preview.offset, preview.length, "jpeg", "",
                               maximum)) {
      return finish(std::move(image));
    }
  }
  // An installed gdk-pixbuf RAW loader can render the full image.
  if (HasLoaderFor(mime_type)) {
    if (auto image = TryDecode(file, 0, static_cast<uint64_t>(info.size),
                               nullptr, mime_type, maximum)) {
      return EncodeJpeg(EmbeddedOrientation(std::move(image)), maximum);
    }
  }
  // Otherwise a smaller embedded preview is better than none.
  for (size_t index = previews.size(); index-- > 0;) {
    if (tried.count(index)) continue;
    const auto& preview = previews[index];
    if (auto image = TryDecode(file, preview.offset, preview.length, "jpeg", "",
                               maximum)) {
      return finish(std::move(image));
    }
  }
  return std::nullopt;
}

// The freedesktop thumbnail cache, valid only for the same URI and
// modification time. File managers fill it for videos and other media that
// gdk-pixbuf cannot decode.
Pixbuf CachedSystemThumbnail(const SafeFile& file, const FileInfo& info,
                             const PreviewOptions& options) {
  if (options.thumbnail_cache_directory.empty()) return nullptr;
  g_autofree gchar* uri = g_filename_to_uri(file.path().c_str(), nullptr, nullptr);
  if (!uri) return nullptr;
  g_autofree gchar* digest = g_compute_checksum_for_string(G_CHECKSUM_MD5, uri, -1);
  if (!digest) return nullptr;
  const std::string modified = std::to_string(info.modified_seconds);
  for (const char* folder : {"large", "x-large", "xx-large", "normal"}) {
    const auto path = options.thumbnail_cache_directory + "/" + folder + "/" +
                      digest + ".png";
    try {
      const auto cached = SafeFile::Open(path);
      const auto size = cached.info().size;
      if (size <= 0 || size > kMaxCachedThumbnailBytes) continue;
      // Decode at its own size so that the PNG text options are kept.
      auto image = TryDecode(cached, 0, static_cast<uint64_t>(size), "png", "", 0);
      if (!image) continue;
      if (g_strcmp0(gdk_pixbuf_get_option(image.get(), "tEXt::Thumb::URI"), uri) == 0 &&
          g_strcmp0(gdk_pixbuf_get_option(image.get(), "tEXt::Thumb::MTime"),
                    modified.c_str()) == 0) {
        return image;
      }
    } catch (const StorageError& error) {
      if (error.code == "RESOURCE_EXHAUSTED") throw;
    }
  }
  return nullptr;
}

struct Thumbnailer {
  std::vector<std::string> arguments;
  std::vector<std::string> mime_types;
};

std::mutex thumbnailer_mutex;
std::map<std::vector<std::string>, std::vector<Thumbnailer>> thumbnailer_cache;

bool Executable(const std::string& program) {
  if (program.empty()) return false;
  if (program[0] == '/') return g_file_test(program.c_str(), G_FILE_TEST_IS_EXECUTABLE);
  g_autofree gchar* found = g_find_program_in_path(program.c_str());
  return found != nullptr;
}

// Reads "[Thumbnailer Entry]" files as specified by freedesktop.org. A file
// in an earlier data directory overrides one with the same name later.
std::vector<Thumbnailer> LoadThumbnailers(const std::vector<std::string>& roots) {
  std::vector<Thumbnailer> result;
  std::set<std::string> names;
  for (const auto& root : roots) {
    const auto directory = root + "/thumbnailers";
    GDir* listing = g_dir_open(directory.c_str(), 0, nullptr);
    if (!listing) continue;
    std::vector<std::string> files;
    while (const gchar* name = g_dir_read_name(listing)) {
      if (g_str_has_suffix(name, ".thumbnailer")) files.emplace_back(name);
    }
    g_dir_close(listing);
    std::sort(files.begin(), files.end());
    for (const auto& name : files) {
      if (!names.insert(name).second) continue;
      g_autoptr(GKeyFile) entry = g_key_file_new();
      const auto path = directory + "/" + name;
      if (!g_key_file_load_from_file(entry, path.c_str(), G_KEY_FILE_NONE, nullptr)) {
        continue;
      }
      constexpr char kGroup[] = "Thumbnailer Entry";
      g_autofree gchar* try_exec = g_key_file_get_string(entry, kGroup, "TryExec", nullptr);
      if (try_exec && !Executable(try_exec)) continue;
      g_autofree gchar* exec = g_key_file_get_string(entry, kGroup, "Exec", nullptr);
      gchar** argv = nullptr;
      if (!exec || !g_shell_parse_argv(exec, nullptr, &argv, nullptr)) continue;
      Thumbnailer thumbnailer;
      for (gchar** argument = argv; *argument; ++argument) {
        thumbnailer.arguments.emplace_back(*argument);
      }
      g_strfreev(argv);
      if (thumbnailer.arguments.empty() || !Executable(thumbnailer.arguments[0])) {
        continue;
      }
      gchar** types = g_key_file_get_string_list(entry, kGroup, "MimeType", nullptr, nullptr);
      for (gchar** type = types; type && *type; ++type) {
        if (**type) thumbnailer.mime_types.emplace_back(*type);
      }
      g_strfreev(types);
      if (!thumbnailer.mime_types.empty()) result.push_back(std::move(thumbnailer));
    }
  }
  return result;
}

std::optional<Thumbnailer> FindThumbnailer(const std::string& mime_type,
                                           const std::vector<std::string>& roots) {
  std::lock_guard<std::mutex> lock(thumbnailer_mutex);
  auto found = thumbnailer_cache.find(roots);
  if (found == thumbnailer_cache.end()) {
    found = thumbnailer_cache.emplace(roots, LoadThumbnailers(roots)).first;
  }
  for (const auto& thumbnailer : found->second) {
    for (const auto& type : thumbnailer.mime_types) {
      // Content types on Linux are MIME types, including aliases and
      // subclasses known to shared-mime-info.
      if (type == mime_type || g_content_type_is_a(mime_type.c_str(), type.c_str())) {
        return thumbnailer;
      }
    }
  }
  return std::nullopt;
}

std::string Expand(const std::string& token, const std::string& input,
                   const std::string& input_uri, const std::string& output,
                   const std::string& size) {
  std::string result;
  for (size_t index = 0; index < token.size(); ++index) {
    if (token[index] != '%' || index + 1 == token.size()) {
      result.push_back(token[index]);
      continue;
    }
    switch (token[++index]) {
      case 'i': result += input; break;
      case 'u': result += input_uri; break;
      case 'o': result += output; break;
      case 's': result += size; break;
      case '%': result.push_back('%'); break;
      default:
        result.push_back('%');
        result.push_back(token[index]);
    }
  }
  return result;
}

void RemoveScratch(const std::string& directory) {
  if (GDir* listing = g_dir_open(directory.c_str(), 0, nullptr)) {
    while (const gchar* name = g_dir_read_name(listing)) {
      const auto path = directory + "/" + name;
      g_unlink(path.c_str());
    }
    g_dir_close(listing);
  }
  g_rmdir(directory.c_str());
}

std::atomic<bool> thumbnailers_cancelled{false};

struct WaitState {
  bool done = false;
  bool timed_out = false;
  std::chrono::steady_clock::time_point deadline;
};

void OnWaited(GObject* source, GAsyncResult* result, gpointer data) {
  g_subprocess_wait_finish(G_SUBPROCESS(source), result, nullptr);
  static_cast<WaitState*>(data)->done = true;
}

gboolean OnTick(gpointer data) {
  auto* state = static_cast<WaitState*>(data);
  if (thumbnailers_cancelled.load() || std::chrono::steady_clock::now() >= state->deadline) {
    state->timed_out = true;
  }
  return G_SOURCE_CONTINUE;
}

// Runs an installed thumbnailer for the user's own shared file. The child
// receives the validated descriptor as fd 3 and reads it through
// /proc/self/fd/3, never through the original, replaceable path.
Pixbuf RunThumbnailer(const SafeFile& file, const std::string& mime_type,
                      unsigned maximum, const PreviewOptions& options) {
  if (options.work_directory.empty() || thumbnailers_cancelled.load()) return nullptr;
  const auto thumbnailer = FindThumbnailer(mime_type, options.thumbnailer_roots);
  if (!thumbnailer) return nullptr;
  Permit permit(ThumbnailerSlots());
  if (thumbnailers_cancelled.load()) return nullptr;
  std::string scratch = options.work_directory + "/run-XXXXXX";
  if (!g_mkdtemp_full(scratch.data(), 0700)) {
    ThrowSystemError(TextId::kPrivateDirectoryUnavailable, errno);
  }
  struct Cleanup {
    std::string directory;
    ~Cleanup() { RemoveScratch(directory); }
  } cleanup{scratch};
  const std::string input = "/proc/self/fd/3";
  const std::string output = scratch + "/thumbnail.png";
  g_autofree gchar* input_uri = g_filename_to_uri(input.c_str(), nullptr, nullptr);
  std::vector<std::string> arguments;
  for (const auto& token : thumbnailer->arguments) {
    arguments.push_back(Expand(token, input, input_uri ? input_uri : "", output,
                               std::to_string(maximum)));
  }
  std::vector<char*> argv;
  for (auto& argument : arguments) argv.push_back(argument.data());
  argv.push_back(nullptr);

  // Never already 3, so the child's dup2 always clears close-on-exec.
  const int child_input = fcntl(file.fd(), F_DUPFD_CLOEXEC, 10);
  if (child_input < 0) ThrowSystemError(TextId::kCannotAccess, errno);
  GSubprocessLauncher* launcher = g_subprocess_launcher_new(
      static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
                                    G_SUBPROCESS_FLAGS_STDERR_SILENCE));
  g_subprocess_launcher_take_fd(launcher, child_input, 3);
  g_subprocess_launcher_set_cwd(launcher, scratch.c_str());

  // Completion is delivered to this worker's own context, never the UI loop.
  GMainContext* context = g_main_context_new();
  g_main_context_push_thread_default(context);
  GSubprocess* process = g_subprocess_launcher_spawnv(launcher, argv.data(), nullptr);
  WaitState state;
  state.deadline = std::chrono::steady_clock::now() +
                   std::chrono::seconds(std::max(1, options.timeout_seconds));
  bool succeeded = false;
  if (process) {
    g_subprocess_wait_async(process, nullptr, OnWaited, &state);
    GSource* timer = g_timeout_source_new(100);
    g_source_set_callback(timer, OnTick, &state, nullptr);
    g_source_attach(timer, context);
    bool killed = false;
    while (!state.done) {
      g_main_context_iteration(context, TRUE);
      if (state.timed_out && !killed) {
        g_subprocess_force_exit(process);
        killed = true;
      }
    }
    g_source_destroy(timer);
    g_source_unref(timer);
    succeeded = !state.timed_out && g_subprocess_get_if_exited(process) &&
                g_subprocess_get_exit_status(process) == 0;
    g_object_unref(process);
  }
  g_main_context_pop_thread_default(context);
  g_main_context_unref(context);
  g_object_unref(launcher);
  if (state.timed_out) {
    throw StorageError("PREVIEW_FAILED", TextId::kThumbnailTimeout);
  }
  if (!succeeded) return nullptr;
  try {
    const auto produced = SafeFile::Open(output);
    const auto size = produced.info().size;
    if (size <= 0 || size > kMaxCachedThumbnailBytes) return nullptr;
    return TryDecodeMedia(produced, 0, static_cast<uint64_t>(size), maximum);
  } catch (const StorageError& error) {
    if (error.code == "RESOURCE_EXHAUSTED") throw;
    return nullptr;
  }
}

}  // namespace

PreviewOptions PreviewOptions::ForSharedMedia() {
  PreviewOptions options;
  options.system_thumbnailers = true;
  try {
    options.work_directory = PrivateDirectory(PrivateArea::kThumbnails);
  } catch (const StorageError&) {
    // Without a private scratch folder, thumbnailers are skipped.
  }
  if (const char* cache = g_get_user_cache_dir(); cache && cache[0] == '/') {
    options.thumbnail_cache_directory = std::string(cache) + "/thumbnails";
  }
  if (const char* data = g_get_user_data_dir(); data && data[0] == '/') {
    options.thumbnailer_roots.emplace_back(data);
  }
  for (const gchar* const* directory = g_get_system_data_dirs();
       directory && *directory; ++directory) {
    if ((*directory)[0] == '/') options.thumbnailer_roots.emplace_back(*directory);
  }
  return options;
}

Bytes JpegPreview(const SafeFile& file, unsigned maximum,
                  const std::string& mime_type, const PreviewOptions& options) {
  if (maximum < 1 || maximum > 2560) {
    throw StorageError("INVALID_ARGUMENT", TextId::kPreviewRange);
  }
  const auto info = file.info();
  if (!IsVideoMime(mime_type)) {
    if (IsRawMime(mime_type)) {
      if (auto bytes = RawPreview(file, info, mime_type, maximum)) return *bytes;
    }
    // Content decides the format; a TIFF-based RAW may still provide its
    // first image this way.
    if (auto image = TryDecodeMedia(file, 0, static_cast<uint64_t>(info.size), maximum)) {
      return EncodeJpeg(EmbeddedOrientation(std::move(image)), maximum);
    }
  }
  if (options.system_thumbnailers) {
    if (auto image = CachedSystemThumbnail(file, info, options)) {
      return EncodeJpeg(std::move(image), maximum);
    }
    if (auto image = RunThumbnailer(file, mime_type, maximum, options)) {
      return EncodeJpeg(std::move(image), maximum);
    }
  }
  Undecodable();
}

RawLayout ReadRawLayout(const SafeFile& file) {
  RawLayout layout;
  const int64_t size = file.info().size;
  uint8_t header[8];
  if (size < 16 || file.ReadAt(0, header, sizeof(header)) != sizeof(header)) {
    return layout;
  }
  bool little;
  if (header[0] == 'I' && header[1] == 'I') {
    little = true;
  } else if (header[0] == 'M' && header[1] == 'M') {
    little = false;
  } else {
    return layout;
  }
  const Tiff tiff(file, size, little);
  if (tiff.U16(header + 2) != 42) return layout;

  struct Pending {
    uint32_t offset;
    unsigned depth;
    bool chain;  // Part of the IFD0 -> IFD1 ... list.
  };
  std::vector<Pending> pending{{tiff.U32(header + 4), 0, true}};
  std::set<uint32_t> seen;
  std::vector<std::pair<uint64_t, uint64_t>> candidates;
  bool first = true;
  for (size_t next_index = 0; next_index < pending.size() && seen.size() < 32;
       ++next_index) {
    const auto current = pending[next_index];
    if (current.offset < 8 || !seen.insert(current.offset).second) continue;
    uint8_t count_bytes[2];
    if (!tiff.Read(current.offset, count_bytes, sizeof(count_bytes))) continue;
    const uint16_t count = tiff.U16(count_bytes);
    if (count == 0 || count > 512) continue;
    std::vector<uint8_t> entries(static_cast<size_t>(count) * 12 + 4);
    const bool has_next = tiff.Read(current.offset + 2, entries.data(), entries.size());
    if (!has_next &&
        !tiff.Read(current.offset + 2, entries.data(), static_cast<size_t>(count) * 12)) {
      continue;
    }
    std::map<uint16_t, Tiff::Entry> tags;
    for (uint16_t index = 0; index < count; ++index) {
      const uint8_t* raw = &entries[static_cast<size_t>(index) * 12];
      Tiff::Entry entry;
      entry.type = tiff.U16(raw + 2);
      entry.count = tiff.U32(raw + 4);
      std::copy(raw + 8, raw + 12, entry.value);
      tags.emplace(tiff.U16(raw), entry);
    }
    auto scalar = [&](uint16_t tag) -> std::optional<uint32_t> {
      const auto found = tags.find(tag);
      return found == tags.end() ? std::nullopt : tiff.Scalar(found->second);
    };
    if (first) {
      first = false;
      const auto orientation = scalar(274);
      if (orientation && *orientation >= 1 && *orientation <= 8) {
        layout.orientation = *orientation;
      }
    }
    // JPEGInterchangeFormat / JPEGInterchangeFormatLength.
    const auto jpeg_offset = scalar(513);
    const auto jpeg_length = scalar(514);
    if (jpeg_offset && jpeg_length) candidates.emplace_back(*jpeg_offset, *jpeg_length);
    // A single-strip image with JPEG compression holds a complete JPEG.
    const auto compression = scalar(259);
    const auto strip_offset = scalar(273);
    const auto strip_length = scalar(279);
    if (compression && (*compression == 6 || *compression == 7) && strip_offset &&
        strip_length) {
      candidates.emplace_back(*strip_offset, *strip_length);
    }
    if (current.depth < 3) {
      const auto subdirectories = tags.find(330);
      if (subdirectories != tags.end()) {
        for (const auto offset : tiff.Offsets(subdirectories->second, 16)) {
          pending.push_back({offset, current.depth + 1, false});
        }
      }
    }
    if (current.chain && has_next) {
      const uint32_t next = tiff.U32(&entries[static_cast<size_t>(count) * 12]);
      if (next) pending.push_back({next, current.depth, true});
    }
  }
  std::set<std::pair<uint64_t, uint64_t>> unique;
  for (const auto& [offset, length] : candidates) {
    if (length < 128 || length > kMaxEmbeddedJpegBytes ||
        offset > static_cast<uint64_t>(size) ||
        length > static_cast<uint64_t>(size) - offset ||
        !unique.insert({offset, length}).second) {
      continue;
    }
    std::vector<uint8_t> head(static_cast<size_t>(std::min<uint64_t>(length, 256 * 1024)));
    if (file.ReadAt(static_cast<int64_t>(offset), head.data(), head.size()) != head.size()) {
      continue;
    }
    if (const auto dimensions = JpegDimensions(head.data(), head.size())) {
      layout.previews.push_back({offset, length, dimensions->first, dimensions->second});
    }
  }
  return layout;
}

std::optional<std::pair<unsigned, unsigned>> JpegDimensions(const uint8_t* data,
                                                            size_t size) {
  if (size < 4 || data[0] != 0xff || data[1] != 0xd8) return std::nullopt;
  size_t position = 2;
  while (position + 4 <= size) {
    if (data[position] != 0xff) return std::nullopt;
    const uint8_t marker = data[position + 1];
    if (marker == 0xff) {
      ++position;  // Fill byte.
      continue;
    }
    position += 2;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
    if (marker == 0xd9 || marker == 0xda) return std::nullopt;
    const size_t length = static_cast<size_t>(data[position]) << 8 | data[position + 1];
    if (length < 2) return std::nullopt;
    const bool frame = marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 &&
                       marker != 0xc8 && marker != 0xcc;
    if (frame) {
      if (position + 7 > size) return std::nullopt;
      const unsigned height = static_cast<unsigned>(data[position + 3]) << 8 | data[position + 4];
      const unsigned width = static_cast<unsigned>(data[position + 5]) << 8 | data[position + 6];
      if (!width || !height) return std::nullopt;
      return std::make_pair(width, height);
    }
    position += length;
  }
  return std::nullopt;
}

GdkPixbuf* ApplyOrientation(GdkPixbuf* source, unsigned orientation) {
  GdkPixbuf* rotated = nullptr;
  GdkPixbuf* result = nullptr;
  switch (orientation) {
    case 2:
      result = gdk_pixbuf_flip(source, TRUE);
      break;
    case 3:
      result = gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_UPSIDEDOWN);
      break;
    case 4:
      result = gdk_pixbuf_flip(source, FALSE);
      break;
    case 5:
      rotated = gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_CLOCKWISE);
      if (rotated) result = gdk_pixbuf_flip(rotated, TRUE);
      break;
    case 6:
      result = gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_CLOCKWISE);
      break;
    case 7:
      rotated = gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_CLOCKWISE);
      if (rotated) result = gdk_pixbuf_flip(rotated, FALSE);
      break;
    case 8:
      result = gdk_pixbuf_rotate_simple(source, GDK_PIXBUF_ROTATE_COUNTERCLOCKWISE);
      break;
    default:
      result = GDK_PIXBUF(g_object_ref(source));
  }
  if (rotated) g_object_unref(rotated);
  if (!result) {
    throw StorageError("RESOURCE_EXHAUSTED", TextId::kResourcesExhausted);
  }
  return result;
}

void ResetThumbnailers() {
  std::lock_guard<std::mutex> lock(thumbnailer_mutex);
  thumbnailer_cache.clear();
}

void CancelThumbnailers() { thumbnailers_cancelled.store(true); }

}  // namespace tamayura
