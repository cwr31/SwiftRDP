import Foundation

/// X.224 Connection Request / Confirm and Data TPDUs (MS-RDPBCGR §2.2.1.1–1.2).
public enum X224 {
    public static let crCode: UInt8 = 0xE0
    public static let ccCode: UInt8 = 0xD0
    public static let dtCode: UInt8 = 0xF0
    public static let drCode: UInt8 = 0x80

    // RDP Negotiation
    public static let typeRDPNegReq: UInt8 = 0x01
    public static let typeRDPNegRsp: UInt8 = 0x02
    public static let typeRDPNegFailure: UInt8 = 0x03

    public static let protocolRDP: UInt32 = 0x0000_0000
    public static let protocolSSL: UInt32 = 0x0000_0001
    public static let protocolHybrid: UInt32 = 0x0000_0002
    public static let protocolRDSTLS: UInt32 = 0x0000_0004
    public static let protocolHybridEx: UInt32 = 0x0000_0008

    /// RDP_NEG_RSP flags (MS-RDPBCGR 2.2.1.2.1).
    /// Without EXTENDED_CLIENT_DATA_SUPPORTED, mstsc MUST NOT send CS_MCS_MSGCHANNEL.
    public static let negFlagExtendedClientDataSupported: UInt8 = 0x01
    public static let negFlagDynvcGfxProtocolSupported: UInt8 = 0x02
    /// Typical modern RDP server negotiation flags.
    public static let negFlagsDefault: UInt8 =
        negFlagExtendedClientDataSupported | negFlagDynvcGfxProtocolSupported

    /// RDP_NEG_FAILURE::failureCode — server requires CredSSP/NLA.
    public static let failureHybridRequiredByServer: UInt32 = 0x0000_0005
    /// RDP_NEG_FAILURE::failureCode — server requires TLS.
    public static let failureSSLRequiredByServer: UInt32 = 0x0000_0001

    public struct ConnectionRequest {
        public var cookie: String?
        public var requestedProtocols: UInt32
        public var srcRef: UInt16
        public var rawRoutingToken: [UInt8]?
    }

    public struct ConnectionConfirm {
        public var selectedProtocol: UInt32
        public var flags: UInt8
    }

    public static func parseConnectionRequest(_ tpdu: [UInt8]) -> ConnectionRequest? {
        guard tpdu.count >= 7 else { return nil }
        let li = Int(tpdu[0])
        guard tpdu.count >= 1 + li else { return nil }
        guard (tpdu[1] & 0xF0) == crCode else { return nil }

        // Variable part after fixed: LI(1) + CR(6 fixed fields min)...
        // Structure: LI | 0xE0 | DST-REF(2) | SRC-REF(2) | CLASS(1) | [variable]
        let srcRef = UInt16(tpdu[4]) << 8 | UInt16(tpdu[5])
        let idx = 7
        var cookie: String?
        var requested: UInt32 = protocolRDP
        if idx < tpdu.count {
            let variable = Array(tpdu[idx...])
            // Cookie ends with \r\n
            if let crlf = variable.firstRange(of: [0x0D, 0x0A]) {
                let cookieBytes = variable[..<crlf.lowerBound]
                cookie = String(bytes: cookieBytes, encoding: .ascii)
                let after = Array(variable[crlf.upperBound...])
                if after.count >= 8, after[0] == typeRDPNegReq {
                    requested = UInt32(after[4])
                        | UInt32(after[5]) << 8
                        | UInt32(after[6]) << 16
                        | UInt32(after[7]) << 24
                }
            } else if variable.count >= 8, variable[0] == typeRDPNegReq {
                requested = UInt32(variable[4])
                    | UInt32(variable[5]) << 8
                    | UInt32(variable[6]) << 16
                    | UInt32(variable[7]) << 24
            }
        }
        return ConnectionRequest(
            cookie: cookie,
            requestedProtocols: requested,
            srcRef: srcRef,
            rawRoutingToken: nil
        )
    }

    public static func buildConnectionConfirm(
        selectedProtocol: UInt32,
        flags: UInt8 = negFlagsDefault,
        srcRef: UInt16 = 0
    ) -> [UInt8] {
        // RDP_NEG_RSP
        var neg: [UInt8] = []
        neg.append(typeRDPNegRsp)
        neg.append(flags)
        neg.appendU16(8) // length
        neg.appendU32(selectedProtocol)
        return wrapConnectionConfirm(negotiation: neg, srcRef: srcRef)
    }

    /// RDP_NEG_FAILURE inside X.224 Connection Confirm (MS-RDPBCGR 2.2.1.2.2).
    public static func buildNegotiationFailure(failureCode: UInt32, srcRef: UInt16 = 0) -> [UInt8] {
        var neg: [UInt8] = []
        neg.append(typeRDPNegFailure)
        neg.append(0) // flags
        neg.appendU16(8)
        neg.appendU32(failureCode)
        return wrapConnectionConfirm(negotiation: neg, srcRef: srcRef)
    }

    private static func wrapConnectionConfirm(negotiation neg: [UInt8], srcRef: UInt16) -> [UInt8] {
        // X.224 CC: LI | 0xD0 | DST-REF | SRC-REF | CLASS | RDP_NEG_*
        // SRC-REF is the client's CR SRC-REF (echoed).
        var tpdu: [UInt8] = []
        let fixedWithoutLI: [UInt8] = [
            ccCode, 0x00, 0x00, // DST-REF
            UInt8((srcRef >> 8) & 0xFF), UInt8(srcRef & 0xFF),
            0x00,               // CLASS 0
        ]
        let li = fixedWithoutLI.count + neg.count
        tpdu.append(UInt8(li))
        tpdu.append(contentsOf: fixedWithoutLI)
        tpdu.append(contentsOf: neg)
        return TPKT.wrap(tpdu)
    }

    public static func buildData(_ userData: [UInt8]) -> [UInt8] {
        // X.224 DT TPDU: LI=2 | 0xF0 | 0x80 (EOT) | user data
        var tpdu: [UInt8] = [0x02, dtCode, 0x80]
        tpdu.append(contentsOf: userData)
        return TPKT.wrap(tpdu)
    }

    public static func parseData(_ tpdu: [UInt8]) -> [UInt8]? {
        guard tpdu.count >= 3 else { return nil }
        let li = Int(tpdu[0])
        guard tpdu.count >= 1 + li else { return nil }
        guard (tpdu[1] & 0xF0) == dtCode else { return nil }
        // User data starts after LI + header (LI bytes following first byte… standard: DT has LI=2 meaning 2 header bytes after LI)
        let headerLen = 1 + li
        guard tpdu.count >= headerLen else { return nil }
        return Array(tpdu[headerLen...])
    }
}
