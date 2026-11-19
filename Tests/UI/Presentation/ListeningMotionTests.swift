import CoreGraphics
import Foundation
import Testing

@testable import UI

@Test func listeningEveryGenerationReplaysFromSharedMonotonicEpoch() {
    var motion = ListeningMotion()
    let first = UUID().uuidString
    motion.update(active: true, generation: first, reduceMotion: false, at: 10)
    #expect(motion.activatedAt == 10 && motion.elapsed(at: 10) == 0)
    #expect(motion.opacity(at: 10) == 0.85)
    #expect(abs(motion.opacity(at: 10.16) - 0.98125) < 0.0001)
    #expect(motion.opacity(at: 11) == 1)
    motion.update(active: false, generation: nil, reduceMotion: false, at: 12)
    #expect(motion.opacity(at: 12) == 1 && motion.opacity(at: 12.5) == 0)
    #expect(!motion.needsFrame(at: 12.5))
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 13)
    #expect(motion.elapsed(at: 13) == 0 && motion.opacity(at: 13) == 0.85)
    #expect(motion.isEntering(at: 13))
    // Coalesced UI off/on still resets when the enabled generation changes.
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 14)
    #expect(motion.activatedAt == 14 && motion.elapsed(at: 14) == 0)
    motion.update(active: true, generation: motion.generation, reduceMotion: false, at: 14.2)
    #expect(motion.activatedAt == 14)
}

@Test func listeningRapidReversalPreservesFadeContinuityAndReducedMotionSettles() {
    var motion = ListeningMotion()
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 1)
    let partial = motion.opacity(at: 1.12)
    motion.update(active: false, generation: nil, reduceMotion: false, at: 1.12)
    #expect(motion.opacity(at: 1.12) == partial)
    let fading = motion.opacity(at: 1.2)
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: true, at: 1.2)
    #expect(motion.opacity(at: 1.2) == fading)
    #expect(motion.elapsed(at: 1.2) == 2 && !motion.isEntering(at: 1.2))
    #expect(!motion.needsFrame(at: 1.5))
    motion.update(active: false, generation: nil, reduceMotion: true, at: 2)
    #expect(motion.needsFrame(at: 2.1) && !motion.needsFrame(at: 2.3))
}

@Test func everyEyeExpressionHasMatchingCubicTopologyAndFiniteCoordinates() {
    let rect = CGRect(x: 0, y: 0, width: 82, height: 98)
    var reference: [CGPathElementType]?
    for expression in EyeExpression.allCases {
        let pair = EyePose.pair(for: expression)
        for pose in [pair.0, pair.1] {
            let path = EyeContour(smile: pose.smile, slant: pose.slant, heart: pose.heart, closure: pose.closure).path(
                in: rect)
            var types: [CGPathElementType] = []
            path.applyWithBlock { element in
                types.append(element.pointee.type)
                let count = element.pointee.type == .addCurveToPoint ? 3 : element.pointee.type == .closeSubpath ? 0 : 1
                for index in 0..<count {
                    #expect(element.pointee.points[index].x.isFinite && element.pointee.points[index].y.isFinite)
                }
            }
            if let reference { #expect(types == reference) } else { reference = types }
            #expect(
                types == [
                    .moveToPoint, .addCurveToPoint, .addCurveToPoint, .addCurveToPoint, .addCurveToPoint,
                    .addCurveToPoint, .addCurveToPoint, .addCurveToPoint, .addCurveToPoint, .closeSubpath,
                ])
        }
    }
    let open = EyeContour(smile: 0, slant: 0, heart: 0, closure: 0).path(in: rect)
    let closed = EyeContour(smile: 0, slant: 0, heart: 0, closure: 1).path(in: rect)
    #expect(open.boundingBox.height > closed.boundingBox.height * 3)
}

@Test func listeningOriginIsFiniteAndLatchedUntilNextActivation() {
    #expect(ListeningLightOrigin(x: -.infinity, y: .nan) == ListeningLightOrigin(x: 0.5, y: 0.4))
    #expect(ListeningLightOrigin(x: -1, y: 2) == ListeningLightOrigin(x: 0, y: 1))
    var motion = ListeningMotion()
    let generation = UUID().uuidString
    let first = ListeningLightOrigin(x: 0.2, y: 0.3)
    let second = ListeningLightOrigin(x: 0.8, y: 0.6)
    motion.update(active: true, generation: generation, reduceMotion: false, origin: first, at: 1)
    motion.update(active: true, generation: generation, reduceMotion: false, origin: second, at: 1.1)
    #expect(motion.origin == first && motion.activatedAt == 1)
    motion.update(active: false, generation: nil, reduceMotion: false, origin: second, at: 1.2)
    #expect(motion.origin == first)
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, origin: second, at: 1.3)
    #expect(motion.origin == second && motion.elapsed(at: 1.3) == 0)
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 1.4)
    #expect(motion.origin == ListeningLightOrigin(x: 0.5, y: 0.4))
}

@Test func listeningExitKeepsExistingSmoothFadeAtEverySample() {
    var motion = ListeningMotion()
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 0)
    #expect(motion.opacity(at: 0) == 0.85)
    motion.update(active: false, generation: nil, reduceMotion: false, at: 2)
    for step in 0...16 {
        let fraction = Double(step) / 16
        let expected = 1 - fraction * fraction * (3 - 2 * fraction)
        #expect(abs(motion.opacity(at: 2 + 0.32 * fraction) - expected) < 0.000001)
    }
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 3)
    #expect(motion.opacity(at: 3) == 0.85)
}

@Test func decorativeLightUsesConfiguredSourceAndPreservesExitFade() {
    var motion = ListeningMotion()
    let origin = ListeningLightOrigin(x: 0.1, y: 0.8)
    motion.update(
        active: true, generation: UUID().uuidString, reduceMotion: false, origin: origin,
        initialOpacity: 0.95, intensity: 0.6,
        at: 1)
    #expect(motion.origin == origin && motion.opacity(at: 1) == 0.95 && motion.intensity == 0.6)
    motion.update(active: false, generation: nil, reduceMotion: false, at: 2)
    #expect(motion.intensity == 0.6 && abs(motion.opacity(at: 2.16) - 0.5) < 0.000001)
    #expect(!motion.needsFrame(at: 2.5))
}

@Test func clearingDecorationRestoresListeningWithoutAnotherWakeFlash() {
    var motion = ListeningMotion()
    motion.update(active: true, generation: UUID().uuidString, reduceMotion: false, at: 1)
    motion.update(
        active: true, generation: UUID().uuidString, reduceMotion: false, replayEntry: false, at: 2)
    #expect(motion.elapsed(at: 2) == 2 && !motion.isEntering(at: 2))
    #expect(motion.opacity(at: 2) == 1)
}

@Test func haloFailureLatchesAndIdenticalSnapshotsDoNotWake() {
    var state = HaloRenderState()
    var motion = ListeningMotion()
    motion.update(active: true, generation: "one", reduceMotion: false, at: 1)
    let size = CGSize(width: 390, height: 844)
    let initial = state.update(motion: motion, size: size, visible: true, maximumFPS: 120)
    #expect(initial)
    for _ in 0..<300 {
        let repeated = state.update(motion: motion, size: size, visible: true, maximumFPS: 120)
        #expect(!repeated)
    }
    let hidden = state.update(motion: motion, size: size, visible: false, maximumFPS: 120)
    let failure = state.fail()
    let repeatedFailure = state.fail()
    let repeatedStop = state.stop()
    let late = state.update(motion: motion, size: size, visible: true, maximumFPS: 60)
    #expect(hidden && failure && !repeatedFailure && !repeatedStop && !late)
    var replacement = HaloRenderState()
    let restarted = replacement.update(motion: motion, size: size, visible: true, maximumFPS: 60)
    let stopped = replacement.stop()
    // A real in-flight GPU failure may still be reported once during explicit teardown.
    let stoppingFailure = replacement.fail()
    let duplicateFailure = replacement.fail()
    #expect(restarted && stopped && stoppingFailure && !duplicateFailure)
}
