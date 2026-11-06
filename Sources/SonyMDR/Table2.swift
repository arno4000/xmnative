import Foundation
import HeadphoneKit

/// Command table 2 of table-set-1 devices (DataType 0x0E, ...mdr.v1.table2 in the app).
/// Only voice guidance on/off is used so far. The parser in the app checks exact lengths.
public enum SonyV1Table2 {
    enum Cmd {
        static let vgGetParam: UInt8 = 0x46, vgRetParam: UInt8 = 0x47, vgSetParam: UInt8 = 0x48, vgNtfyParam: UInt8 = 0x49
    }

    public static func getVoiceGuidance() -> [UInt8] { [Cmd.vgGetParam, 0x01, 0x01] }
    /// 48 01 01 v (v: 00 off, 01 on – not inverted)
    public static func setVoiceGuidance(_ on: Bool) -> [UInt8] { [Cmd.vgSetParam, 0x01, 0x01, on ? 0x01 : 0x00] }

    public static func parse(_ p: [UInt8]) -> [SonyUpdate] {
        guard p.count >= 4, p[1] == 0x01, p[2] == 0x01 else { return [] }
        switch p[0] {
        case Cmd.vgRetParam, Cmd.vgNtfyParam: return [.voiceGuidance(p[3] == 0x01)]
        default: return []
        }
    }
}
