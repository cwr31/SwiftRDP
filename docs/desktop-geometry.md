# Desktop Geometry

The negotiated RDP desktop is the coordinate space for graphics and input. A
physical panel's framebuffer size is a capture-source property, not permission
to replace that desktop. Valid Display Control requests resize the session
desktop without changing a mirrored physical monitor's resolution.

## Invariants

- Demand Active, Monitor Layout, GFX RESET/CREATE and capture output describe the
  same even-sized desktop. Explicit server width/height settings still apply.
- `DisplayContentLayout` defines one aspect-preserving content rectangle. Small
  aspect differences are not classified with a percentage tolerance.
- ScreenCaptureKit outputs full-range BT.709 NV12 directly at the desktop size.
  Its `destinationRect`, `preservesAspectRatio` and opaque black background define
  the image placement. H.264 submits that buffer directly. All codecs reject
  stale-sized frames instead of keeping a second scaler in the encode path.
- Only the resolved capture layout updates input mapping on the session event
  loop. There is no session-side predicted layout or separate physical sizing
  plan. Live FPS/audio updates retain that same rectangle.
- `DesktopInputMapping` is the shared immutable inverse for mouse, touch and pen.
  It accounts for letterbox offsets, Quartz bounds and nonzero display origins.
  Relative Y follows the protocol direction; it is not flipped. Bounds remain
  half-open so input cannot land on an adjacent display's first coordinate.
- Unchanged desktop requests do not restart capture. A generation-scoped resize
  suspends video submission until the new capture is ready and starts fresh GFX
  surfaces/reference pictures. Pointer history stays in host space across
  geometry changes. All display changes use the same rebind path.
- A missing selected source is an error, not a request to capture another
  display. Native callback discovery and first-frame readiness share one
  cancellable result primitive; timeouts never wait for an unresponsive API.

## Physical Mirror Versus Virtual Desktop

A physical mirror preserves the source monitor's aspect ratio, so a wide phone
viewport can have side bars. Removing those bars by stretching is not a correct
fit. A virtual desktop can instead use a source geometry matching the client;
its logical/HiDPI mode controls UI size independently of the wire desktop.

For a 3024x1964 panel and a 1424x700 client, the session/capture/encoded desktop is
1424x700. The image is 1078x700 at offset (173, 0), and every input type uses that
same rectangle to map back into the panel's Quartz coordinate space.

## Contracts

- [MS-RDPEDISP: processing a monitor layout](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/32525e02-fc5c-4b82-ae87-88a458444902)
- [MS-RDPEGFX: RESET_GRAPHICS output dimensions](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/60c8841c-3288-473b-82c3-340e24f51f98)
- [MS-RDPBCGR: relative pointer axis directions](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/9af47964-8bfc-4f43-8a15-4339a89833fa)
- [Apple: SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration)

`MobileDesktopGeometryTests` covers negotiation, resize/no-op behavior, native
capture configuration, inverse input mapping, relative movement and display
boundaries. Graphics, capture-lifecycle and the full package suites must pass
before installing a new signed app. A real phone reconnect is still required to
verify client-side presentation and touch behavior end to end.
