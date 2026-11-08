//
//  VideoMessageType.swift
//  ShootKit
//
//  Created by Michael Forrest on 02/06/2023.
//

import Foundation
import CoreMedia

enum VideoMessageType: UInt32 {
    case invalid = 0
    case videoFrame = 2
    case hevcParameterSet = 3
    case requestVideoStream = 4
    case cancelVideoStream = 5
    case cameraAvailable = 6
    case handshake = 7
    case clock = 8
    case control = 9
//    case version = 10
    case beatSheetAvailable = 11
    case streamDeckAvailable = 12
    case videoFrameWithHeader = 17 // 4-byte header length, JSON VideoFrameHeader, then the compressed frame
    case capabilities = 18 // JSON PeerCapabilities, sent by both ends after the existing handshake
}

/// What this end of the connection is able to receive.
/// Every field is optional so that more can be added later without breaking older peers.
struct PeerCapabilities: Codable {
    /// True if this peer can decode `videoFrameWithHeader` messages.
    var acceptsVideoFrameHeaders: Bool?
}

struct VideoFrameHeader: Codable {
    let presentationTimeStamp: CMTime
    let decodeTimeStamp: CMTime?
    let duration: CMTime?

    // Ecamm: Validate peer-controlled JSON before it reaches Core Media or clock arithmetic.
    // Keep this separate from the wire representation; optional fields remain upstream-compatible.
    enum ParseError: Error { case invalid }

    static func parse(_ payload: Data) throws -> (VideoFrameHeader, Data) {
        guard payload.count > 4, payload.count <= VideoProtocol.maximumMessageLength else { throw ParseError.invalid }
        // Byte-wise reads also work on unaligned network buffers and macOS 12.
        let length = payload.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard length > 0, length <= 64 * 1024, length < payload.count - 4 else { throw ParseError.invalid }
        let header = try JSONDecoder().decode(Self.self, from: Data(payload.dropFirst(4).prefix(length)))
        guard validTime(header.presentationTimeStamp),
              header.decodeTimeStamp.map(validTime) ?? true,
              header.duration.map({ validTime($0) && $0.seconds >= 0 && $0.seconds <= 10 }) ?? true else {
            throw ParseError.invalid
        }
        return (header, Data(payload.dropFirst(4 + length)))
    }

    private static func validTime(_ time: CMTime) -> Bool {
        // This bound allows 31 years of host uptime without risking overflow in time conversion.
        time.isNumeric && time.timescale > 0 && time.epoch == 0 && abs(time.seconds) < 1_000_000_000
    }

    /// Builds a videoFrameWithHeader message body: header length, JSON header, compressed frame.
    static func payload(compressedVideoFrame: Data, presentationTimeStamp: CMTime) throws -> Data {
        let header = VideoFrameHeader(presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: nil, duration: nil)
        let headerData = try JSONEncoder().encode(header)
        var headerLength = UInt32(headerData.count).littleEndian
        var payload = Data(capacity: MemoryLayout<UInt32>.size + headerData.count + compressedVideoFrame.count)
        withUnsafeBytes(of: &headerLength) { payload.append(contentsOf: $0) }
        payload.append(headerData)
        payload.append(compressedVideoFrame)
        return payload
    }
}

struct H265ParameterSet:Codable{
    let parameters: [Data]
}
