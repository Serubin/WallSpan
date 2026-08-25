// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageLoadError: Error, CustomStringConvertible {
    case cannotOpen(URL)
    case noDimensions(URL)
    case decodeFailed(URL)

    public var description: String {
        switch self {
        case .cannotOpen(let u): return "cannot open image: \(u.path)"
        case .noDimensions(let u): return "image has no readable dimensions: \(u.path)"
        case .decodeFailed(let u): return "failed to decode image: \(u.path)"
        }
    }
}

public struct SourceImage {
    public let image: CGImage
    /// Pixel dimensions on disk, after EXIF orientation is accounted for.
    public let nativeSize: CGSize
    /// What we actually decoded. Smaller than `nativeSize` when downsampled.
    public var decodedSize: CGSize { CGSize(width: image.width, height: image.height) }
    public var wasDownsampled: Bool { decodedSize.width < nativeSize.width }
}

public enum ImageLoader {
    /// True if ImageIO can decode this file. UTType conformance, not an extension
    /// allowlist, so HEIC/AVIF/TIFF/etc. work without maintaining a list.
    public static func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        guard type.conforms(to: .image) else { return false }
        let decodable = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return decodable.contains { type.conforms(to: UTType($0) ?? .data) }
    }

    /// Loads `url` at the smallest resolution that still fully covers `target`.
    ///
    /// Dimensions come from metadata (no decode) so ImageIO can downsample *during*
    /// decode: a 191 MP source is ~765 MB as RGBA8, ~95% of it discarded by the crop.
    public static func load(_ url: URL, covering target: CGSize) throws -> SourceImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoadError.cannotOpen(url)
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int,
              rawW > 0, rawH > 0
        else {
            throw ImageLoadError.noDimensions(url)
        }

        // EXIF orientations 5-8 transpose the image. Aspect math must use post-transform
        // dimensions or a rotated photo gets cropped along the wrong axis.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let transposed = orientation >= 5 && orientation <= 8
        let nativeW = transposed ? rawH : rawW
        let nativeH = transposed ? rawW : rawH

        // Aspect-FILL: scale so the source covers the target in both axes.
        let fillScale = max(target.width / CGFloat(nativeW), target.height / CGFloat(nativeH))
        let needed = Int((CGFloat(max(nativeW, nativeH)) * fillScale).rounded(.up))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // applies EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            // Asking for more than native does not upscale; ImageIO just returns native.
            kCGImageSourceThumbnailMaxPixelSize: max(1, needed),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ImageLoadError.decodeFailed(url)
        }
        return SourceImage(image: cg, nativeSize: CGSize(width: nativeW, height: nativeH))
    }
}
