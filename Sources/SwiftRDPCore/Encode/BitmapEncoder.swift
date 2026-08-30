import Foundation
import CoreGraphics

/// Dirty-region helpers (`DirtyTile` / `DirtyInfo`).
public struct DirtyTile: Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var data: [UInt8]

    public init(x: Int, y: Int, width: Int, height: Int, data: [UInt8]) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.data = data
    }
}

public struct DirtyInfo: Sendable {
    public var rects: [CGRect]
    public var tiles: [DirtyTile]
    /// Approximate dirty coverage percent of the frame (log: ` / dirty avg %.0f%%`).
    public var averagePercent: Double

    public init(rects: [CGRect] = [], tiles: [DirtyTile] = [], averagePercent: Double = 0) {
        self.rects = rects
        self.tiles = tiles
        self.averagePercent = averagePercent
    }

    public static func from(frame: CapturedFrame, maxTile: Int = 64) -> DirtyInfo {
        let rects = frame.dirtyRects ?? []
        guard !rects.isEmpty else {
            return DirtyInfo(rects: [], tiles: [], averagePercent: 100)
        }
        let raw = BitmapEncoder.tiles(frame: frame, dirtyRects: rects, maxTile: maxTile)
        let tiles = raw.map {
            DirtyTile(x: $0.x, y: $0.y, width: $0.w, height: $0.h, data: $0.data)
        }
        let dirtyPixels = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        let total = Double(max(frame.width * frame.height, 1))
        let pct = min(100.0, dirtyPixels / total * 100.0)
        return DirtyInfo(rects: rects, tiles: tiles, averagePercent: pct)
    }
}

/// Bitmap encoder (enum style).
public enum BitmapEncoder {
    /// Full-frame tiling.
    public static func tiles(frame: CapturedFrame, maxTile: Int = 64) -> [(x: Int, y: Int, w: Int, h: Int, data: [UInt8])] {
        tiles(frame: frame, region: CGRect(x: 0, y: 0, width: frame.width, height: frame.height), maxTile: maxTile)
    }

    /// Dirty-rect aware tiling (dirty-tile path).
    public static func tiles(
        frame: CapturedFrame,
        dirtyRects: [CGRect],
        maxTile: Int = 64
    ) -> [(x: Int, y: Int, w: Int, h: Int, data: [UInt8])] {
        guard !dirtyRects.isEmpty else {
            return tiles(frame: frame, maxTile: maxTile)
        }
        var out: [(Int, Int, Int, Int, [UInt8])] = []
        for rect in dirtyRects {
            let r = rect.integral
            let x0 = max(0, Int(r.minX))
            let y0 = max(0, Int(r.minY))
            let x1 = min(frame.width, Int(r.maxX))
            let y1 = min(frame.height, Int(r.maxY))
            guard x1 > x0, y1 > y0 else { continue }
            out += tiles(
                frame: frame,
                region: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                maxTile: maxTile
            )
        }
        return out
    }

    private static func tiles(
        frame: CapturedFrame,
        region: CGRect,
        maxTile: Int
    ) -> [(x: Int, y: Int, w: Int, h: Int, data: [UInt8])] {
        var tiles: [(Int, Int, Int, Int, [UInt8])] = []
        // `frame.bgrBottomUp` is full-frame DIB bottom-up (row 0 = screen bottom).
        let rowSize = (frame.width * 3 + 3) & ~3
        let originX = Int(region.minX)
        let originY = Int(region.minY)
        let regionW = Int(region.width)
        let regionH = Int(region.height)
        var y = 0
        while y < regionH {
            let th = min(maxTile, regionH - y)
            var x = 0
            while x < regionW {
                let tw = min(maxTile, regionW - x)
                let tileRowSize = (tw * 3 + 3) & ~3
                var data = [UInt8](repeating: 0, count: tileRowSize * th)
                // RDP rectangle payload is also bottom-up: wire row 0 = bottom of dest rect.
                for row in 0..<th {
                    let screenY = originY + y + (th - 1 - row)
                    let bufY = frame.height - 1 - screenY
                    guard bufY >= 0, bufY < frame.height else { continue }
                    let srcOff = bufY * rowSize + (originX + x) * 3
                    let dstOff = row * tileRowSize
                    for col in 0..<tw {
                        let si = srcOff + col * 3
                        guard si + 2 < frame.bgrBottomUp.count else { break }
                        data[dstOff + col * 3] = frame.bgrBottomUp[si]
                        data[dstOff + col * 3 + 1] = frame.bgrBottomUp[si + 1]
                        data[dstOff + col * 3 + 2] = frame.bgrBottomUp[si + 2]
                    }
                }
                tiles.append((originX + x, originY + y, tw, th, data))
                x += tw
            }
            y += th
        }
        return tiles
    }
}
