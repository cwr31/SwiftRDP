import Foundation

/// Single owner for “how are we sending the desktop right now?”
/// Replaces ad-hoc combinations of `gfxReady` / `everOpened` / wait timers.
enum GraphicsPathState: Equatable {
    /// Display Mode is Bitmap, or GFX was never enabled for this client.
    case bitmapOnly
    /// GFX enabled; waiting for Graphics DVC CREATE.
    case awaitingGraphicsDVC
    /// Graphics DVC is up; CAPS / surfaces not ready yet — do not send frames.
    case negotiatingSurfaces
    /// CAPS + surfaces ready — encode via H.264 / RemoteFX.
    case encodingGFX
    /// Channel was open then closed; recreate in flight — never fall back to bitmap.
    case recovering
}

enum GraphicsCreateReason: String {
    case capsExchanged = "CAPS exchanged"
    case channelClosed = "channel CLOSED"
}
