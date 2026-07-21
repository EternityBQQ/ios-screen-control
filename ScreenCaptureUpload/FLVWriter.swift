import Foundation
import CoreMedia

/// FLV 封装器 — 生成 FLV header + sequence header + video tags
final class FLVWriter {

    private var cachedSPS: Data?  // Sequence Parameter Set
    private var cachedPPS: Data?  // Picture Parameter Set

    // MARK: - FLV Header

    /// FLV 文件头: "FLV" + version + flags + headerSize
    func makeHeader() -> Data {
        var data = Data()
        data.append(contentsOf: [0x46, 0x4C, 0x56])  // "FLV"
        data.append(0x01)                              // version 1
        data.append(0x04)                              // TypeFlags: video only (0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x09]) // header size = 9
        // PreviousTagSize(0)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return data
    }

    // MARK: - Sequence Header

    /// AVCDecoderConfigurationRecord — 包含 SPS/PPS
    func makeSequenceHeader() -> Data? {
        guard let sps = cachedSPS, let pps = cachedPPS else { return nil }

        // AVCDecoderConfigurationRecord
        var record = Data()
        record.append(0x01)                   // configurationVersion
        record.append(sps[1])                 // AVCProfileIndication
        record.append(sps[2])                 // profile_compatibility
        record.append(sps[3])                 // AVCLevelIndication
        record.append(0xFF)                   // lengthSizeMinusOne (4 bytes) + reserved bits
        record.append(0xE1)                   // numOfSequenceParameterSets (1) + reserved

        // SPS
        var spsData = sps
        // Strip 4-byte start code (00 00 00 01) if present
        if spsData.prefix(4) == Data([0x00, 0x00, 0x00, 0x01]) {
            spsData = spsData.subdata(in: 4..<spsData.count)
        }
        record.append(contentsOf: [UInt8(spsData.count >> 8), UInt8(spsData.count & 0xFF)])
        record.append(spsData)

        // PPS
        record.append(0x01)                   // numOfPictureParameterSets
        var ppsData = pps
        if ppsData.prefix(4) == Data([0x00, 0x00, 0x00, 0x01]) {
            ppsData = ppsData.subdata(in: 4..<ppsData.count)
        }
        record.append(contentsOf: [UInt8(ppsData.count >> 8), UInt8(ppsData.count & 0xFF)])
        record.append(ppsData)

        return makeVideoTag(
            frameType: 1,     // keyframe
            codecId: 7,       // AVC
            avcPacketType: 0, // sequence header
            compositionTime: 0,
            data: record,
            timestamp: 0
        )
    }

    // MARK: - Video Tag

    /// FLV VideoTag (TagType=9)
    func makeVideoTag(
        nalUnits: [Data],
        timestamp: UInt32
    ) -> Data {
        var videoData = Data()

        // Is this a keyframe? Check first NALU type
        let naluType = nalUnits.first.map { $0[0] & 0x1F } ?? 0
        let isKeyframe = (naluType == 5 || naluType == 7) // IDR or SPS
        let isSPS = (naluType == 7)
        let isPPS = (naluType == 8)

        // Cache SPS/PPS
        if isSPS { cachedSPS = nalUnits.first }
        if isPPS { cachedPPS = nalUnits.first }

        // Skip SPS/PPS in regular frames (they go in sequence header)
        let dataNalus = nalUnits.filter { nu in
            let type = nu[0] & 0x1F
            return type != 7 && type != 8
        }
        guard !dataNalus.isEmpty else { return Data() }

        let frameType: UInt8 = isKeyframe ? 1 : 2
        let codecId: UInt8 = 7  // AVC

        videoData.append((frameType << 4) | codecId)  // FrameType|CodecID
        videoData.append(1)                             // AVCPacketType = NALU
        videoData.append(contentsOf: [0x00, 0x00, 0x00]) // CompositionTime = 0

        // AnnexB format NALUs
        for nalu in dataNalus {
            videoData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // start code
            videoData.append(nalu)
        }

        return flvTag(tagType: 9, timestamp: timestamp, data: videoData)
    }

    /// 内部使用：构建 video tag
    private func makeVideoTag(
        frameType: UInt8,
        codecId: UInt8,
        avcPacketType: UInt8,
        compositionTime: UInt32,
        data: Data,
        timestamp: UInt32
    ) -> Data {
        var videoData = Data()
        videoData.append((frameType << 4) | codecId)
        videoData.append(avcPacketType)
        videoData.append(contentsOf: [
            UInt8((compositionTime >> 16) & 0xFF),
            UInt8((compositionTime >> 8) & 0xFF),
            UInt8(compositionTime & 0xFF),
        ])
        videoData.append(data)
        return flvTag(tagType: 9, timestamp: timestamp, data: videoData)
    }

    /// 构建 FLV Tag
    private func flvTag(tagType: UInt8, timestamp: UInt32, data: Data) -> Data {
        var tag = Data()
        // PreviousTagSize (4 bytes, 0 for first tag)
        tag.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Tag Header (11 bytes)
        tag.append(tagType)
        tag.append(contentsOf: [
            UInt8((data.count >> 16) & 0xFF),
            UInt8((data.count >> 8) & 0xFF),
            UInt8(data.count & 0xFF),
        ]) // DataSize (3 bytes)
        tag.append(contentsOf: [
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF),
        ]) // Timestamp (3 bytes)
        tag.append(UInt8((timestamp >> 24) & 0xFF)) // TimestampExtended
        tag.append(contentsOf: [0x00, 0x00, 0x00])  // StreamID (always 0)

        // Tag Data
        tag.append(data)

        // Tag Size (4 bytes) = 11 + data.count
        let tagSize = UInt32(11 + data.count)
        tag.append(contentsOf: [
            UInt8((tagSize >> 24) & 0xFF),
            UInt8((tagSize >> 16) & 0xFF),
            UInt8((tagSize >> 8) & 0xFF),
            UInt8(tagSize & 0xFF),
        ])

        return tag
    }
}
