#include "image_preview.h"

#include <wrl/client.h>
#include <wrl/implements.h>

#include <array>
#include <cmath>
#include <filesystem>
#include <functional>
#include <iostream>

namespace {
using namespace tamayura;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;

void Expect(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

void Check(HRESULT value) {
  Expect(SUCCEEDED(value), "Synthetic WIC fixture failed");
}

class Metadata final : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                          IWICMetadataQueryReader> {
 public:
  explicit Metadata(unsigned orientation) : orientation_(orientation) {}
  HRESULT STDMETHODCALLTYPE GetContainerFormat(GUID* format) override {
    *format = GUID_ContainerFormatJpeg; return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetLocation(UINT, WCHAR*, UINT*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetMetadataByName(LPCWSTR name, PROPVARIANT* result) override {
    if (wcscmp(name, L"System.Photo.Orientation") != 0) return WINCODEC_ERR_PROPERTYNOTFOUND;
    PropVariantInit(result);
    result->vt = VT_UI2;
    result->uiVal = static_cast<USHORT>(orientation_);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetEnumerator(IEnumString**) override { return E_NOTIMPL; }
 private:
  unsigned orientation_;
};

// The pixels pass through Windows' real scaler/orienter/JPEG codec. The small
// wrappers control only optional codec features and late CopyPixels failures.
class Frame final : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                       IWICBitmapFrameDecode> {
 public:
  explicit Frame(IWICBitmapSource* source, std::optional<unsigned> orientation = std::nullopt)
      : source_(source) {
    if (orientation) metadata_ = Make<Metadata>(*orientation);
  }
  bool corrupt = false;
  bool empty_size = false;
  bool record_reads = false;
  HRESULT size_status = S_OK;
  HRESULT pixels_status = S_OK;
  HRESULT metadata_status = S_OK;
  HRESULT thumbnail_status = S_OK;
  unsigned copies = 0;
  unsigned thumbnails = 0;
  std::vector<WICRect> reads;
  ComPtr<IWICBitmapSource> thumbnail;
  HRESULT STDMETHODCALLTYPE GetSize(UINT* width, UINT* height) override {
    if (FAILED(size_status)) return size_status;
    if (empty_size) { *width = 0; *height = 0; return S_OK; }
    return source_->GetSize(width, height);
  }
  HRESULT STDMETHODCALLTYPE GetPixelFormat(WICPixelFormatGUID* format) override {
    return source_->GetPixelFormat(format);
  }
  HRESULT STDMETHODCALLTYPE GetResolution(double* x, double* y) override {
    return source_->GetResolution(x, y);
  }
  HRESULT STDMETHODCALLTYPE CopyPalette(IWICPalette* palette) override {
    return source_->CopyPalette(palette);
  }
  HRESULT STDMETHODCALLTYPE CopyPixels(const WICRect* rect, UINT stride,
                                       UINT size, BYTE* pixels) override {
    ++copies;
    if (record_reads) {
      UINT width = 0, height = 0;
      source_->GetSize(&width, &height);
      reads.push_back(rect ? *rect : WICRect{0, 0, static_cast<INT>(width), static_cast<INT>(height)});
    }
    if (FAILED(pixels_status)) return pixels_status;
    if (corrupt) return WINCODEC_ERR_BADIMAGE;
    return source_->CopyPixels(rect, stride, size, pixels);
  }
  HRESULT STDMETHODCALLTYPE GetMetadataQueryReader(IWICMetadataQueryReader** metadata) override {
    *metadata = nullptr;
    if (FAILED(metadata_status)) return metadata_status;
    return metadata_ ? metadata_.CopyTo(metadata) : WINCODEC_ERR_UNSUPPORTEDOPERATION;
  }
  HRESULT STDMETHODCALLTYPE GetColorContexts(UINT, IWICColorContext**, UINT*) override {
    return WINCODEC_ERR_UNSUPPORTEDOPERATION;
  }
  HRESULT STDMETHODCALLTYPE GetThumbnail(IWICBitmapSource** source) override {
    ++thumbnails;
    *source = nullptr;
    if (FAILED(thumbnail_status)) return thumbnail_status;
    return thumbnail ? thumbnail.CopyTo(source) : WINCODEC_ERR_CODECNOTHUMBNAIL;
  }
 private:
  ComPtr<IWICBitmapSource> source_;
  ComPtr<IWICMetadataQueryReader> metadata_;
};

class Decoder final : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                         IWICBitmapDecoder> {
 public:
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICBitmapSource> thumbnail;
  ComPtr<IWICBitmapSource> preview;
  ComPtr<IWICMetadataQueryReader> metadata;
  unsigned thumbnails = 0;
  unsigned previews = 0;
  HRESULT thumbnail_status = S_OK;
  HRESULT preview_status = S_OK;
  HRESULT STDMETHODCALLTYPE QueryCapability(IStream*, DWORD*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE Initialize(IStream*, WICDecodeOptions) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetContainerFormat(GUID* format) override {
    *format = GUID_ContainerFormatTiff; return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDecoderInfo(IWICBitmapDecoderInfo**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE CopyPalette(IWICPalette*) override { return WINCODEC_ERR_PALETTEUNAVAILABLE; }
  HRESULT STDMETHODCALLTYPE GetMetadataQueryReader(IWICMetadataQueryReader** result) override {
    *result = nullptr;
    return metadata ? metadata.CopyTo(result) : WINCODEC_ERR_UNSUPPORTEDOPERATION;
  }
  HRESULT STDMETHODCALLTYPE GetPreview(IWICBitmapSource** result) override {
    ++previews;
    *result = nullptr;
    if (FAILED(preview_status)) return preview_status;
    return preview ? preview.CopyTo(result) : WINCODEC_ERR_UNSUPPORTEDOPERATION;
  }
  HRESULT STDMETHODCALLTYPE GetColorContexts(UINT, IWICColorContext**, UINT*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetThumbnail(IWICBitmapSource** result) override {
    ++thumbnails;
    *result = nullptr;
    if (FAILED(thumbnail_status)) return thumbnail_status;
    return thumbnail ? thumbnail.CopyTo(result) : WINCODEC_ERR_CODECNOTHUMBNAIL;
  }
  HRESULT STDMETHODCALLTYPE GetFrameCount(UINT* count) override { *count = 1; return S_OK; }
  HRESULT STDMETHODCALLTYPE GetFrame(UINT index, IWICBitmapFrameDecode** result) override {
    *result = nullptr;
    return index == 0 && frame ? frame.CopyTo(result) : WINCODEC_ERR_FRAMEMISSING;
  }
};

using Color = std::array<BYTE, 3>;
const std::array<Color, 4> kColors = {{{0, 0, 255}, {0, 255, 0},
                                     {255, 0, 0}, {0, 255, 255}}};

ComPtr<IWICBitmap> Pattern(IWICImagingFactory* factory, UINT width, UINT height) {
  Bytes pixels(width * height * 3);
  for (UINT y = 0; y < height; ++y) {
    for (UINT x = 0; x < width; ++x) {
      const auto& color = kColors[(x >= width / 2 ? 1 : 0) + (y >= height / 2 ? 2 : 0)];
      const auto offset = (y * width + x) * 3;
      for (unsigned c = 0; c < 3; ++c) pixels[offset + c] = color[c];
    }
  }
  ComPtr<IWICBitmap> bitmap;
  Check(factory->CreateBitmapFromMemory(width, height, GUID_WICPixelFormat24bppBGR,
      width * 3, static_cast<UINT>(pixels.size()), pixels.data(), &bitmap));
  return bitmap;
}

Bytes JpegWithThumbnail(IWICImagingFactory* factory) {
  const auto image = Pattern(factory, 192, 128);
  const auto thumbnail_bitmap = Pattern(factory, 96, 48);
  auto main = Make<Decoder>(); main->frame = Make<Frame>(image.Get());
  auto thumb = Make<Decoder>(); thumb->frame = Make<Frame>(thumbnail_bitmap.Get());
  const auto jpeg = WicJpegPreview(factory, main.Get(), 192, false);
  const auto thumbnail = WicJpegPreview(factory, thumb.Get(), 96, false);
  // Empty IFD0 followed by IFD1 with JPEG compression, offset and byte count.
  // This exercises real WIC embedded extraction without a private RAW fixture.
  Bytes tiff = {'I', 'I', 42, 0, 8, 0, 0, 0, 0, 0, 14, 0, 0, 0,
      3, 0, 0x03, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0,
      0x01, 0x02, 4, 0, 1, 0, 0, 0, 56, 0, 0, 0,
      0x02, 0x02, 4, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  const auto size = static_cast<uint32_t>(thumbnail.size());
  for (unsigned byte = 0; byte < 4; ++byte) {
    tiff[48 + byte] = static_cast<BYTE>((size >> (8 * byte)) & 255);
  }
  tiff.insert(tiff.end(), thumbnail.begin(), thumbnail.end());
  const auto length = tiff.size() + 8;
  Expect(length <= 65535, "Embedded JPEG fixture is too large");
  Bytes result = {0xff, 0xd8, 0xff, 0xe1, static_cast<BYTE>(length >> 8),
      static_cast<BYTE>(length & 255), 'E', 'x', 'i', 'f', 0, 0};
  result.insert(result.end(), tiff.begin(), tiff.end());
  result.insert(result.end(), jpeg.begin() + 2, jpeg.end());
  return result;
}

void ExpectJpeg(IWICImagingFactory* factory, const Bytes& bytes, UINT width, UINT height,
                const std::array<unsigned, 4>& corners = {0, 1, 2, 3}) {
  Expect(bytes.size() > 2 && bytes[0] == 0xff && bytes[1] == 0xd8, "Expected JPEG bytes");
  ComPtr<IWICStream> stream;
  Check(factory->CreateStream(&stream));
  Check(stream->InitializeFromMemory(const_cast<BYTE*>(bytes.data()), static_cast<DWORD>(bytes.size())));
  ComPtr<IWICBitmapDecoder> decoder;
  Check(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder));
  ComPtr<IWICBitmapFrameDecode> frame;
  Check(decoder->GetFrame(0, &frame));
  UINT actual_width = 0, actual_height = 0;
  Check(frame->GetSize(&actual_width, &actual_height));
  Expect(actual_width == width && actual_height == height, "Incorrect bounded JPEG dimensions");
  ComPtr<IWICFormatConverter> converter;
  Check(factory->CreateFormatConverter(&converter));
  Check(converter->Initialize(frame.Get(), GUID_WICPixelFormat24bppBGR,
      WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom));
  Bytes pixels(width * height * 3);
  Check(converter->CopyPixels(nullptr, width * 3, static_cast<UINT>(pixels.size()), pixels.data()));
  for (unsigned corner = 0; corner < 4; ++corner) {
    const UINT x = width * (corner % 2 == 0 ? 1 : 3) / 4;
    const UINT y = height * (corner < 2 ? 1 : 3) / 4;
    const auto offset = (y * width + x) * 3;
    for (unsigned c = 0; c < 3; ++c) {
      Expect(std::abs(static_cast<int>(pixels[offset + c]) - kColors[corners[corner]][c]) < 40,
             "Incorrect JPEG orientation or reflection");
    }
  }
}

}  // namespace

int main() {
  const auto com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) { std::cerr << "COM initialization failed\n"; return 1; }
  struct ComGuard { ~ComGuard() { CoUninitialize(); } } com_guard;
  unsigned passed = 0;
  auto test = [&](const char* name, const std::function<void()>& body) {
    body(); ++passed; std::cout << "PASS " << name << '\n';
  };
  try {
    ComPtr<IWICImagingFactory> factory;
    Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                           IID_PPV_ARGS(&factory)));
    const auto image = Pattern(factory.Get(), 96, 64);
    const auto large = Pattern(factory.Get(), 192, 128);
    test("each embedded provider succeeds without reading RAW pixels", [&] {
      for (unsigned provider = 0; provider < 3; ++provider) {
        auto full = Make<Frame>(large.Get());
        full->corrupt = true;
        auto embedded = Make<Frame>(image.Get());
        auto decoder = Make<Decoder>();
        decoder->frame = full;
        if (provider == 0) decoder->thumbnail = embedded;
        if (provider == 1) full->thumbnail = embedded;
        if (provider == 2) decoder->preview = embedded;
        ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true), 96, 64);
        Expect(full->copies == 0 && embedded->copies > 0, "RAW pixels must not be read");
        Expect(decoder->previews == (provider == 2 ? 1u : 0u), "Do not load larger previews unnecessarily");
      }
    });
    test("a standalone embedded preview survives an unavailable full frame", [&] {
      auto decoder = Make<Decoder>(); decoder->preview = Make<Frame>(image.Get(), 1);
      ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true), 96, 64);
    });
    test("embedded pixels use one sequential pass before portrait rotation", [&] {
      const std::array<std::array<unsigned, 4>, 4> corners = {{{0, 1, 2, 3},
          {2, 0, 3, 1}, {1, 3, 0, 2}, {0, 2, 1, 3}}};
      const std::array<unsigned, 4> orientations = {1, 6, 8, 5};
      for (unsigned maximum : {48u, 96u}) {
        for (size_t index = 0; index < orientations.size(); ++index) {
          auto full = Make<Frame>(large.Get(), orientations[index]); full->corrupt = true;
          auto embedded = Make<Frame>(image.Get()); embedded->record_reads = true;
          auto decoder = Make<Decoder>(); decoder->frame = full; decoder->thumbnail = embedded;
          const UINT short_edge = maximum * 2 / 3;
          const bool portrait = orientations[index] != 1;
          ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), maximum, true),
                     portrait ? short_edge : maximum, portrait ? maximum : short_edge, corners[index]);
          // WIC may request one rectangle or split scaling into scanlines.
          // Require a single complete, sequential pass over full-width rows:
          // no repeated pixels, backwards seeks or rotated column reads that
          // can make a lazy RAW provider decode the embedded JPEG repeatedly.
          INT next_row = 0;
          for (const auto& rect : embedded->reads) {
            Expect(rect.X == 0 && rect.Width == 96 && rect.Y == next_row &&
                       rect.Height > 0 && rect.Height <= 64 - next_row,
                   "Embedded pixels must be read once in forward row order before rotation");
            next_row += rect.Height;
          }
          Expect(next_row == 64 && full->copies == 0,
                 "Materialization must read all embedded pixels once and never decode the full RAW");
        }
      }
    });
    test("a corrupt optional thumbnail falls through to the next embedded source", [&] {
      auto full = Make<Frame>(large.Get()); full->corrupt = true;
      auto bad = Make<Frame>(image.Get()); bad->corrupt = true;
      auto good = Make<Frame>(image.Get());
      auto decoder = Make<Decoder>();
      decoder->frame = full; decoder->thumbnail = bad; decoder->preview = good;
      ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true), 96, 64);
      Expect(bad->copies > 0 && good->copies > 0 && full->copies == 0,
             "A lazy decoding failure must not discard other embedded previews");
    });
    test("resource, permission and I/O failures stay retryable at every codec probe", [&] {
      const std::array<std::pair<HRESULT, const char*>, 10> failures = {{{E_OUTOFMEMORY, "RESOURCE_EXHAUSTED"},
          {E_ACCESSDENIED, "PERMISSION_LOST"}, {HRESULT_FROM_WIN32(ERROR_READ_FAULT), "IO_ERROR"},
          {STG_E_READFAULT, "IO_ERROR"}, {HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION), "PERMISSION_LOST"},
          {WINCODEC_ERR_STREAMREAD, "IO_ERROR"}, {WINCODEC_ERR_STREAMWRITE, "IO_ERROR"},
          {WINCODEC_ERR_STREAMNOTAVAILABLE, "IO_ERROR"}, {WINCODEC_ERR_WIN32ERROR, "IO_ERROR"},
          {WINCODEC_ERR_ALREADYLOCKED, "IO_ERROR"}}};
      for (const auto& failure : failures) {
        for (unsigned stage = 0; stage < 6; ++stage) {
          auto full = Make<Frame>(large.Get());
          auto optional = Make<Frame>(image.Get());
          auto decoder = Make<Decoder>(); decoder->frame = full;
          if (stage < 2) decoder->thumbnail = optional;
          if (stage == 0) optional->pixels_status = failure.first;
          if (stage == 1) optional->size_status = failure.first;
          if (stage == 2) decoder->thumbnail_status = failure.first;
          if (stage == 3) full->thumbnail_status = failure.first;
          if (stage == 4) decoder->preview_status = failure.first;
          if (stage == 5) full->metadata_status = failure.first;
          bool rejected = false;
          try { WicJpegPreview(factory.Get(), decoder.Get(), 96, true); }
          catch (const StorageError& error) { rejected = error.code == failure.second; }
          Expect(rejected && full->copies == 0, "Transient codec failure must escape and avoid a cached placeholder");
        }
      }
    });
    test("absent, corrupt, undersized and empty embedded images fall back to full frame", [&] {
      for (unsigned reason = 0; reason < 4; ++reason) {
        auto full = Make<Frame>(large.Get());
        auto embedded = Make<Frame>(image.Get());
        auto decoder = Make<Decoder>(); decoder->frame = full;
        if (reason != 0) decoder->thumbnail = embedded;
        if (reason == 1) embedded->corrupt = true;
        if (reason == 3) embedded->empty_size = true;
        const UINT maximum = reason == 2 ? 192 : 96;
        ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), maximum, true),
                   maximum, maximum * 2 / 3);
        Expect(full->copies > 0, "Unusable embedded image must read the full frame");
      }
    });
    test("non-RAW images keep full-frame rendering", [&] {
      auto full = Make<Frame>(large.Get());
      auto decoder = Make<Decoder>(); decoder->frame = full; decoder->thumbnail = image;
      ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, false), 96, 64);
      Expect(full->copies > 0 && decoder->thumbnails == 0 && decoder->previews == 0,
             "Ordinary photos must not switch to embedded thumbnails");
    });
    test("all supported RAW extensions enable real WIC embedded extraction", [&] {
      wchar_t temporary[MAX_PATH + 1]{};
      Expect(GetTempPathW(MAX_PATH, temporary) != 0, "Temporary folder unavailable");
      const auto directory = JoinPath(temporary, L"tamayura-preview-test-" +
          std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
      std::filesystem::create_directory(directory);
      struct Cleanup {
        std::wstring path;
        ~Cleanup() { std::error_code ignored; std::filesystem::remove_all(path, ignored); }
      } cleanup{directory};
      const auto fixture = JpegWithThumbnail(factory.Get());
      unsigned fixture_index = 0;
      for (const auto extension : {L".dng", L".cr2", L".nef", L".arw", L".ARW", L".jpg"}) {
        const auto path = JoinPath(directory, L"synthetic-" +
            std::to_wstring(fixture_index++) + extension);
        {
          Handle output(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
          Expect(output.get() != INVALID_HANDLE_VALUE, "Cannot create synthetic image");
          DWORD written = 0;
          Expect(WriteFile(output.get(), fixture.data(), static_cast<DWORD>(fixture.size()),
                           &written, nullptr) && written == fixture.size(), "Cannot write synthetic image");
        }
        const auto file = SafeFile::Open(path);
        ExpectJpeg(factory.Get(), JpegPreview(file, 96, false), 96,
                   std::wstring(extension) == L".jpg" ? 64 : 48);
      }
    });
    test("all EXIF rotations and mirrors apply once to embedded pixels", [&] {
      const std::array<std::array<unsigned, 4>, 8> corners = {{{0, 1, 2, 3}, {1, 0, 3, 2},
          {3, 2, 1, 0}, {2, 3, 0, 1}, {0, 2, 1, 3}, {2, 0, 3, 1}, {3, 1, 2, 0}, {1, 3, 0, 2}}};
      for (unsigned orientation = 1; orientation <= 8; ++orientation) {
        auto full = Make<Frame>(large.Get(), orientation); full->corrupt = true;
        auto embedded = Make<Frame>(image.Get(), orientation);
        auto decoder = Make<Decoder>(); decoder->frame = full; decoder->thumbnail = embedded;
        const bool swap = orientation >= 5;
        ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true),
                   swap ? 64 : 96, swap ? 96 : 64, corners[orientation - 1]);
        Expect(full->copies == 0, "Orientation metadata must not trigger RAW decoding");
      }
    });
    test("RAW orientation overrides an embedded JPEG's conflicting orientation 1", [&] {
      auto full = Make<Frame>(large.Get(), 6); full->corrupt = true;
      auto embedded = Make<Frame>(image.Get(), 1);
      auto decoder = Make<Decoder>(); decoder->frame = full; decoder->preview = embedded;
      ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true),
                 64, 96, {2, 0, 3, 1});
    });
    test("embedded orientation is used when the RAW has no orientation metadata", [&] {
      auto full = Make<Frame>(large.Get()); full->corrupt = true;
      auto embedded = Make<Frame>(image.Get(), 6);
      auto decoder = Make<Decoder>(); decoder->frame = full; decoder->preview = embedded;
      ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true),
                 64, 96, {2, 0, 3, 1});
    });
    test("missing embedded metadata uses parent or container orientation", [&] {
      for (bool container : {false, true}) {
        auto full = Make<Frame>(large.Get(), container ? std::nullopt : std::optional<unsigned>(6));
        full->corrupt = true;
        auto decoder = Make<Decoder>(); decoder->frame = full; decoder->thumbnail = image;
        if (container) decoder->metadata = Make<Metadata>(6);
        ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 96, true),
                   64, 96, {2, 0, 3, 1});
      }
    });
    test("preview bounds reject invalid requests and never upscale full frames", [&] {
      auto full = Make<Frame>(image.Get());
      auto decoder = Make<Decoder>(); decoder->frame = full;
      ExpectJpeg(factory.Get(), WicJpegPreview(factory.Get(), decoder.Get(), 2560, true), 96, 64);
      for (unsigned maximum : {0u, 2561u}) {
        bool rejected = false;
        try { WicJpegPreview(factory.Get(), decoder.Get(), maximum, true); }
        catch (const StorageError& error) { rejected = error.code == "INVALID_ARGUMENT"; }
        Expect(rejected, "Invalid preview bound must be rejected");
      }
    });
    test("a full-frame decoding failure still reports PREVIEW_FAILED", [&] {
      auto full = Make<Frame>(large.Get()); full->corrupt = true;
      auto decoder = Make<Decoder>(); decoder->frame = full;
      bool rejected = false;
      try { WicJpegPreview(factory.Get(), decoder.Get(), 96, true); }
      catch (const StorageError& error) { rejected = error.code == "PREVIEW_FAILED"; }
      Expect(rejected && full->copies > 0, "Full-frame errors must retain the existing failure contract");
    });
    std::cout << passed << " preview tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
