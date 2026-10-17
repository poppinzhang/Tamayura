#ifndef TAMAYURA_IMAGE_PREVIEW_H_
#define TAMAYURA_IMAGE_PREVIEW_H_

#include "storage_core.h"

#include <wincodec.h>

namespace tamayura {

// The decoder seam keeps optional RAW codec behavior testable with synthetic
// sources. The caller owns COM initialization, factory and decoder lifetimes.
Bytes WicJpegPreview(IWICImagingFactory* factory, IWICBitmapDecoder* decoder,
                     unsigned maximum, bool prefer_embedded);

}  // namespace tamayura

#endif  // TAMAYURA_IMAGE_PREVIEW_H_
