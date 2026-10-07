import CoreMedia
import Foundation
import VideoToolbox

/// Whether this Mac has hardware H.264 and HEVC encoders, for the tests that need one: the recording writer requires
/// hardware encoding, as the app does (`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`), and its
/// failure tests rely on the hardware H.264 encoder refusing a side over 4096 pixels. Every Apple Silicon Mac has both,
/// and so does GitHub's hosted xcode-27 runner, a virtual Mac (the tests ran and passed there). On a Mac without them,
/// those tests are skipped:
///
///     @Test(.enabled(if: HardwareEncoders.available, "needs a hardware video encoder"))
///
/// Everything else in the media tests (software encodes, decoding, ProRes, audio) runs on any Mac.
public enum HardwareEncoders {
    /// Both codecs have an encoder VideoToolbox lists as hardware accelerated, and a session that requires hardware
    /// opens for each. Checked once per test process.
    public static let available: Bool = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].allSatisfy { codec in
        listed(codec) && opens(codec)
    }

    /// Whether VideoToolbox lists a hardware-accelerated encoder for `codec`. Software encoders leave the key out.
    static func listed(_ codec: CMVideoCodecType) -> Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains { encoder in
            (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec
                && (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }

    /// Whether a small compression session for `codec` that requires hardware opens: what the recording writer asks for.
    static func opens(_ codec: CMVideoCodecType) -> Bool {
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 320, height: 180, codecType: codec,
                                                encoderSpecification: specification as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return false }
        VTCompressionSessionInvalidate(session)
        return status == noErr
    }
}
