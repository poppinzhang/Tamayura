import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

// Decode directly from an already validated descriptor, keeping the directory
// security scope and descriptor alive until ImageIO / AVFoundation finishes.
enum MediaPreview {
  static func jpeg(file: SafeFile, video: Bool, maximum: Int, mimeType: String = "video/quicktime") throws -> Data {
    guard (1...2560).contains(maximum) else {
      throw PlatformFailure.invalid(.previewRange)
    }
    let url = URL(fileURLWithPath: "/dev/fd/\(file.fd)")
    var image: CGImage
    if video {
      let loader = try DescriptorVideoLoader(file: file, mimeType: mimeType)
      let asset = AVURLAsset(url: URL(string: "tamayura-media://local/video")!)
      asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "dev.tamayura.video-preview"))
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: maximum, height: maximum)
      let complete = DispatchSemaphore(value: 0)
      let frame = GeneratedFrame()
      generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
        frame.set(image: image, error: error)
        complete.signal()
      }
      image = try withExtendedLifetime(loader) {
        if complete.wait(timeout: .now() + 20) != .success {
          generator.cancelAllCGImageGeneration()
          throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", .videoThumbnailTimeout)
        }
        return try frame.get()
      }
    } else {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maximum,
              kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else {
        throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", .cannotDecode)
      }
      image = decoded
    }
    // Bound the channel payload even for a particularly noisy image.
    while true {
      let bytes = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", .cannotCreatePreview)
      }
      CGImageDestinationAddImage(destination, image,
        [kCGImageDestinationLossyCompressionQuality: maximum <= 256 ? 0.8 : 0.88] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", .cannotEncodePreview)
      }
      if bytes.length <= 8 * 1024 * 1024 { return bytes as Data }
      let width = max(1, image.width / 2), height = max(1, image.height / 2)
      guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", .cannotScalePreview)
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let reduced = context.makeImage() else { throw PlatformFailure.invalid(.previewTooLarge) }
      image = reduced
    }
  }
}

/// AVFoundation does not consistently support /dev/fd URLs. Supply random-access
/// bytes from the validated descriptor instead of reopening a mutable file path.
private final class DescriptorVideoLoader: NSObject, AVAssetResourceLoaderDelegate {
  private let file: SafeFile
  private let size: Int64
  private let contentType: String
  init(file: SafeFile, mimeType: String) throws {
    self.file = file
    size = try file.info().st_size
    contentType = UTType(mimeType: mimeType)?.identifier ?? UTType.movie.identifier
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
    do {
      if let info = request.contentInformationRequest {
        info.contentType = contentType
        info.contentLength = size
        info.isByteRangeAccessSupported = true
      }
      if let data = request.dataRequest {
        var offset = max(data.requestedOffset, data.currentOffset)
        guard offset >= 0, offset <= size else { throw PlatformFailure.invalid(.invalidVideoRange) }
        let available = size - data.requestedOffset
        let count = data.requestsAllDataToEndOfResource ? available : min(Int64(data.requestedLength), available)
        let end = data.requestedOffset + count
        while offset < end && !request.isCancelled {
          let bytes = try file.read(offset: offset, length: Int(min(256 * 1024, end - offset)), expectedSize: size)
          data.respond(with: bytes)
          offset += Int64(bytes.count)
        }
      }
      if !request.isCancelled { request.finishLoading() }
    } catch { request.finishLoading(with: error) }
    return true
  }
}

private final class GeneratedFrame: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<CGImage, Error>?
  func set(image: CGImage?, error: Error?) {
    lock.lock(); defer { lock.unlock() }
    if let image { value = .success(image) }
    else { value = .failure(error ?? PlatformFailure(code: "PREVIEW_UNAVAILABLE", .videoThumbnailUnreadable)) }
  }
  func get() throws -> CGImage {
    lock.lock(); defer { lock.unlock() }
    guard let value else { throw PlatformFailure(code: "PREVIEW_UNAVAILABLE", .videoThumbnailTimeout) }
    return try value.get()
  }
}
