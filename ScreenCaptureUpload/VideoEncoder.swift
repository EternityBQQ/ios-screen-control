import Foundation
import VideoToolbox
import CoreMedia

/// VideoToolbox H.264 硬件编码器
final class VideoEncoder {
    private var session: VTCompressionSession?
    private var callback: (([Data]) -> Void)?
    private let queue = DispatchQueue(label: "video.encoder")

    private let outputWidth = 1280
    private let outputHeight = 720
    private let bitrate = 2_000_000   // 2 Mbps
    private let keyframeInterval = 60 // 每 60 帧一个 I 帧
    private let fps = 30

    func configure(callback: @escaping ([Data]) -> Void) {
        self.callback = callback

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: outputWidth,
            height: outputHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("[VideoEncoder] Failed to create session: \(status)")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,         value: kCFBooleanTrue!)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,     value: kVTProfileLevel_H264_Baseline_3_1 as CFString)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,   value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,  value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse!)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func invalidate() {
        VTCompressionSessionInvalidate(session)
        session = nil
    }

    // MARK: - Callback

    private let compressionOutputCallback: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let refcon else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer else { return }
        let data = Data(bytes: ptr, count: length)

        // 解析 AVCC 格式的 NAL units
        let nalUnits = encoder.parseAVCCNalUnits(data)
        encoder.callback?(nalUnits)
    }

    /// 解析 AVCC 格式: [4-byte length][NAL payload]...
    private func parseAVCCNalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let nalSize = Int(data[offset]) << 24
                        | Int(data[offset + 1]) << 16
                        | Int(data[offset + 2]) << 8
                        | Int(data[offset + 3])
            offset += 4
            guard offset + nalSize <= data.count else { break }
            units.append(data.subdata(in: offset..<(offset + nalSize)))
            offset += nalSize
        }
        return units
    }
}
