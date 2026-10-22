#include <gdk-pixbuf/gdk-pixbuf.h>

#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void Expect(bool value, const std::string& message) {
  if (!value) throw std::runtime_error(message);
}

std::vector<guchar> ReadIcon(const std::string& variant, int size) {
  const std::string path = std::string(TAMAYURA_TRAY_RESOURCE_DIR) + "/hibiki-" + variant +
                           "-" + std::to_string(size) + ".png";
  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkPixbuf) image = gdk_pixbuf_new_from_file(path.c_str(), &error);
  Expect(image != nullptr, "tray artwork decodes: " + variant + " " + std::to_string(size));
  Expect(gdk_pixbuf_get_width(image) == size && gdk_pixbuf_get_height(image) == size,
         "tray artwork has the requested native dimensions");
  Expect(gdk_pixbuf_get_has_alpha(image) && gdk_pixbuf_get_n_channels(image) == 4,
         "tray artwork retains SVG transparency");
  std::vector<guchar> rgba;
  const guchar* pixels = gdk_pixbuf_get_pixels(image);
  const int stride = gdk_pixbuf_get_rowstride(image);
  for (int y = 0; y < size; ++y) {
    rgba.insert(rgba.end(), pixels + y * stride, pixels + y * stride + size * 4);
  }
  return rgba;
}

void Run() {
  for (const int size : {16, 20, 24, 32, 40, 48, 64}) {
    const auto black = ReadIcon("black", size);
    const auto white = ReadIcon("white", size);
    bool smooth_corner = false;
    bool lettering = false;
    for (int y = 0; y < size; ++y) {
      for (int x = 0; x < size; ++x) {
        const size_t offset = static_cast<size_t>(y * size + x) * 4;
        const guchar alpha = black[offset + 3];
        Expect(alpha == white[offset + 3], "theme variants have identical corner coverage");
        smooth_corner = smooth_corner || (alpha > 0 && alpha < 255);
        for (const auto* pixels : {&black, &white}) {
          Expect((*pixels)[offset] == (*pixels)[offset + 1] &&
                     (*pixels)[offset] == (*pixels)[offset + 2],
                 "SVG artwork remains monochrome");
        }
        if (alpha == 255) {
          Expect(std::abs(static_cast<int>(black[offset]) + white[offset] - 255) <= 1,
                 "both themes preserve the same reversed lettering");
          lettering = lettering || black[offset] > 192;
        }
      }
    }
    Expect(smooth_corner && lettering, "rounded edges and the supplied lettering remain visible");
    for (const int corner : {0, size - 1, size * (size - 1), size * size - 1}) {
      Expect(black[corner * 4 + 3] <= 1, "original outer corners retain transparent coverage");
    }
    const size_t top_middle = static_cast<size_t>(size / 2) * 4;
    Expect(black[top_middle] == 0 && white[top_middle] == 255 && black[top_middle + 3] == 255,
           "light desktops use black backgrounds; dark desktops use white backgrounds");
    if (size == 64) {
      // The supplied outlined glyph has three separated horizontal strokes in
      // its lower component. Check the actual artwork, not a synthetic square.
      for (const int y : {45, 49, 53}) {
        Expect(black[static_cast<size_t>(y * size + 32) * 4] == 255,
               "outlined glyph retains its lower horizontal strokes");
      }
      for (const int y : {47, 51}) {
        Expect(black[static_cast<size_t>(y * size + 32) * 4] < 32,
               "outlined glyph retains open counters between the strokes");
      }
    }
  }
  std::cout << "Linux tray SVG artwork tests passed\n";
}

}  // namespace

int main() {
  try {
    Run();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "[FAIL] tray icon: " << error.what() << '\n';
    return 1;
  }
}
