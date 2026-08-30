import AppKit
import CoreGraphics
import Foundation

enum ClipboardImageCodec {
    private static let headerSize = 124
    private static let biRGB: UInt32 = 0
    private static let bitFields: UInt32 = 3
    private static let redMask: UInt32 = 0x00FF0000
    private static let greenMask: UInt32 = 0x0000FF00
    private static let blueMask: UInt32 = 0x000000FF
    private static let alphaMask: UInt32 = 0xFF000000
    private static let maximumDimension = 16_384
    private static let maximumPixelBytes = ClipboardWire.maximumPDUSize - headerSize

    static func encodeDIBV5(tiff: Data) -> [UInt8]? {
        guard let representation = NSBitmapImageRep(data: tiff) else { return nil }
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension else {
            return nil
        }

        guard let image = representation.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rowBytes = width * 4
        let pixelBytes = rowBytes * height
        guard pixelBytes <= maximumPixelBytes else { return nil }
        var pixels = [UInt8](repeating: 0, count: pixelBytes)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            let red = pixels[offset]
            pixels[offset] = pixels[offset + 2]
            pixels[offset + 2] = red
            if alpha > 0, alpha < 255 {
                pixels[offset] = unpremultiply(pixels[offset], by: alpha)
                pixels[offset + 1] = unpremultiply(pixels[offset + 1], by: alpha)
                pixels[offset + 2] = unpremultiply(pixels[offset + 2], by: alpha)
            }
        }

        // DIBV5 rows are bottom-up; the bitmap context stores them top-down.
        for row in 0..<(height / 2) {
            let oppositeRow = height - 1 - row
            for byte in 0..<rowBytes {
                pixels.swapAt(row * rowBytes + byte, oppositeRow * rowBytes + byte)
            }
        }

        var dib: [UInt8] = []
        dib.reserveCapacity(headerSize + pixels.count)
        dib.appendU32LE(UInt32(headerSize))
        dib.appendU32LE(UInt32(width))
        dib.appendU32LE(UInt32(height))
        dib.appendU16LE(1)
        dib.appendU16LE(32)
        dib.appendU32LE(bitFields)
        dib.appendU32LE(UInt32(pixels.count))
        dib.appendU32LE(0)
        dib.appendU32LE(0)
        dib.appendU32LE(0)
        dib.appendU32LE(0)
        dib.appendU32LE(redMask)
        dib.appendU32LE(greenMask)
        dib.appendU32LE(blueMask)
        dib.appendU32LE(alphaMask)
        dib.appendU32LE(0x73524742)
        for _ in 0..<16 {
            dib.appendU32LE(0)
        }
        dib.append(contentsOf: pixels)
        return dib
    }

    static func decodeDIBV5(_ data: [UInt8]) -> NSImage? {
        guard data.count >= headerSize,
              readU32LE(data, 0) == headerSize,
              readU16LE(data, 12) == 1,
              readU16LE(data, 14) == 32 else {
            return nil
        }

        let widthValue = Int32(bitPattern: readU32LE(data, 4))
        let heightValue = Int32(bitPattern: readU32LE(data, 8))
        guard widthValue > 0, heightValue != 0, heightValue != Int32.min else { return nil }

        let compression = readU32LE(data, 16)
        guard compression == biRGB || compression == bitFields else { return nil }
        if compression == bitFields {
            guard readU32LE(data, 40) == redMask,
                  readU32LE(data, 44) == greenMask,
                  readU32LE(data, 48) == blueMask,
                  readU32LE(data, 52) == 0 || readU32LE(data, 52) == alphaMask else {
                return nil
            }
        }

        let width = Int(widthValue)
        let height = abs(Int(heightValue))
        guard width <= maximumDimension, height <= maximumDimension else { return nil }

        let rowBytes = width * 4
        let pixelBytes = rowBytes * height
        guard pixelBytes <= maximumPixelBytes,
              readU32LE(data, 20) == 0 || readU32LE(data, 20) >= UInt32(pixelBytes),
              data.count >= headerSize + pixelBytes else { return nil }

        let hasAlpha = compression == bitFields && readU32LE(data, 52) == alphaMask

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.thirtyTwoBitLittleEndian, .alphaNonpremultiplied],
            bytesPerRow: rowBytes,
            bitsPerPixel: 32
        ) else {
            return nil
        }
        guard let bitmap = representation.bitmapData else { return nil }

        for storedRow in 0..<height {
            let destinationY = heightValue > 0 ? height - 1 - storedRow : storedRow
            for x in 0..<width {
                let offset = headerSize + storedRow * rowBytes + x * 4
                let destination = destinationY * rowBytes + x * 4
                bitmap[destination] = data[offset + 2]
                bitmap[destination + 1] = data[offset + 1]
                bitmap[destination + 2] = data[offset]
                bitmap[destination + 3] = hasAlpha ? data[offset + 3] : 255
            }
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(representation)
        return image
    }

    private static func unpremultiply(_ value: UInt8, by alpha: UInt8) -> UInt8 {
        UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
    }

    private static func readU16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readU32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

private extension Array where Element == UInt8 {
    mutating func appendU16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendU32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
