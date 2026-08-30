import Foundation

/// Stable hardware identity used for every SwiftRDP virtual display lifecycle.
enum VirtualDisplayIdentity {
    static let displayName = "SwiftRDP Virtual Display"
    static let vendorID: UInt32 = 0x0472
    static let productID: UInt32 = 0x0001
    static let serialNumber: UInt32 = 0x4D485244 // "MHRD"
}
