//
//  RemoteClockMap.swift
//  ShootKit
//
//  Created by Michael Forrest / LLM on 10/10/2026.
//
import CoreMedia
final class RemoteClockMap {
    /// How long after its mapped capture time each frame is shown.
    /// Must exceed keyframe transit time plus network jitter.
    var playoutDelay: TimeInterval = 0.070

    /// Enough to span several keyframe intervals, so the window always contains some quick frames.
    private let clockOffsetMeasurementsToKeep = 120
    /// The first frame is a slow keyframe, so trust the newest minimum outright until this many frames have arrived.
    private let warmUpFrameCount = 30
    /// The estimate may fall this fast when a quicker frame shows the offset was overestimated.
    private let maximumDecreasePerFrame: TimeInterval = 0.0003
    /// The estimate may rise only as fast as real clock drift (about 150 ppm at 30 fps).
    /// A standing backlog must show up as late frames, not be absorbed as a new offset.
    private let maximumIncreasePerFrame: TimeInterval = 0.000005

    /// One measurement per recent frame of how far the receiver's clock is ahead of the sender's.
    /// Each is too large by however long that frame spent in transit, so the smallest is the most accurate.
    private var recentClockOffsetMeasurements: [TimeInterval] = []
    private var estimatedClockOffset: TimeInterval?
    // Ecamm: Mapping is confined to the decoder queue, including reset at stream boundaries.
    private var previousSenderTime: TimeInterval?
    private var previousArrivalTime: TimeInterval?
    private var previousDisplayTime: TimeInterval?

    func reset() {
        recentClockOffsetMeasurements.removeAll(keepingCapacity: true)
        estimatedClockOffset = nil
        previousSenderTime = nil
        previousArrivalTime = nil
        previousDisplayTime = nil
    }

    /// Returns the receiver host-clock time at which the frame should be displayed.
    func displayHostTime(forSenderPresentationTimeStamp senderPresentationTimeStamp: CMTime,
                         arrivalHostTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> CMTime {
        // Ecamm: Reject invalid arithmetic, and re-anchor after a peer clock reset or sleep.
        guard senderPresentationTimeStamp.isNumeric, arrivalHostTime.isNumeric else { return .invalid }
        if let sender = previousSenderTime, let arrival = previousArrivalTime,
           senderPresentationTimeStamp.seconds < sender ||
            abs((senderPresentationTimeStamp.seconds - sender) - (arrivalHostTime.seconds - arrival)) > 2 {
            reset()
        }
        previousSenderTime = senderPresentationTimeStamp.seconds
        previousArrivalTime = arrivalHostTime.seconds
        let clockOffsetMeasurement = arrivalHostTime.seconds - senderPresentationTimeStamp.seconds
        recentClockOffsetMeasurements.append(clockOffsetMeasurement)
        if recentClockOffsetMeasurements.count > clockOffsetMeasurementsToKeep {
            recentClockOffsetMeasurements.removeFirst()
        }

        // The smallest measurement came from the frame that spent least time in transit.
        let leastDelayedClockOffsetMeasurement = recentClockOffsetMeasurements.min()!

        let isWarmingUp = recentClockOffsetMeasurements.count < warmUpFrameCount
        let previousEstimate = estimatedClockOffset ?? leastDelayedClockOffsetMeasurement
        let updatedEstimate: TimeInterval
        if isWarmingUp {
            updatedEstimate = leastDelayedClockOffsetMeasurement
        } else {
            let desiredChange = leastDelayedClockOffsetMeasurement - previousEstimate
            let limitedChange = max(-maximumDecreasePerFrame,
                                           min(maximumIncreasePerFrame, desiredChange))
            updatedEstimate = previousEstimate + limitedChange
        }
        estimatedClockOffset = updatedEstimate

        // Ecamm: A quicker warm-up frame must not be scheduled before a frame already published.
        let displayTime = max(previousDisplayTime.map { $0 + 0.000001 } ?? -.infinity,
                              senderPresentationTimeStamp.seconds + updatedEstimate + playoutDelay)
        previousDisplayTime = displayTime
        return CMTime(seconds: displayTime, preferredTimescale: 1_000_000_000)
    }
}
