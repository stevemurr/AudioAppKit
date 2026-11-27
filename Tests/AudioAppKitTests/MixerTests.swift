import AudioAppKit
import AudioAppTesting
import Foundation
import Testing

@Suite struct MixerTests {
    @Test func aFeedGathersItsSourcesAStretchAtATime() {
        let feed = StereoFeed(maxFrames: 8)
        let one: [Float] = [1, 2, 3, 4, 5, 6, 7, 8], two: [Float] = [10, 20, 30, 40]
        // Left over from the block before.
        feed.set(one, gain: 9, one, gain: 9, at: 0, frames: 8)
        feed.clear(frames: 8)
        // One source for the whole block, in two stretches; another that starts half-way through.
        feed.add(one, gain: 1, one, gain: -1, at: 0, frames: 3)
        one.withUnsafeBufferPointer { feed.add($0.baseAddress! + 3, gain: 1, $0.baseAddress! + 3, gain: -1, at: 3, frames: 5) }
        feed.add(two, gain: 0.5, two, gain: 0.25, at: 4, frames: 4)
        #expect((0..<8).map { feed.left[$0] } == [1, 2, 3, 4, 10, 16, 22, 28])
        #expect((0..<8).map { feed.right[$0] } == [-1, -2, -3, -4, -2.5, -1, 0.5, 2])
        feed.set(two, gain: 2, two, gain: 3, at: 2, frames: 2)
        #expect((0..<8).map { feed.left[$0] } == [1, 2, 20, 40, 10, 16, 22, 28])
        #expect(feed.right[2] == 30 && feed.right[3] == 60)
    }

    @Test func eachSourceOfASendArrivesAsLateAsItIsAsked() {
        let delays = SendDelays(sourceCount: 2, maxDelay: 100)
        #expect(delays.maxDelay == 127)
        let frames = 64, blocks = 6
        let first = TestSignal.noise(frames: frames * blocks, seed: 3), second = TestSignal.noise(frames: frames * blocks, seed: 4)
        var left = [Float](repeating: 0, count: frames * blocks), right = left
        for block in 0..<blocks {
            // Each block in two uneven stretches, as a mixer renders round a loop point.
            for (at, count) in [(0, 23), (23, frames - 23)] {
                let from = block * frames + at
                first.withUnsafeBufferPointer { a in
                    second.withUnsafeBufferPointer { b in
                        left.withUnsafeMutableBufferPointer { l in
                            right.withUnsafeMutableBufferPointer { r in
                                delays.send(0, a.baseAddress! + from, gain: 1, a.baseAddress! + from, gain: 0.5, delay: 0, send: 2,
                                            into: l.baseAddress! + from, r.baseAddress! + from, frames: count)
                                // The second source is only remembered until the fourth block, then sent 100 frames late.
                                delays.send(1, b.baseAddress! + from, gain: 1, b.baseAddress! + from, gain: 1, delay: 100, send: block >= 3 ? 1 : 0,
                                            into: l.baseAddress! + from, r.baseAddress! + from, frames: count)
                                // A source it has no line for is ignored.
                                delays.send(2, a.baseAddress! + from, gain: 1, a.baseAddress! + from, gain: 1, delay: 0, send: 1,
                                            into: l.baseAddress! + from, r.baseAddress! + from, frames: count)
                            }
                        }
                    }
                }
                delays.advance(frames: count)
            }
        }
        for index in 0..<(frames * blocks) {
            let late: Float = index >= 3 * frames ? second[index - 100] : 0
            #expect(left[index] == 2 * first[index] + late)
            #expect(right[index] == 2 * (0.5 * first[index]) + late)
        }
        // Forgotten, an open send finds nothing behind it.
        delays.reset()
        var after = [Float](repeating: 0, count: 8), other = after
        delays.send(1, [1, 1, 1, 1, 1, 1, 1, 1], gain: 1, [1, 1, 1, 1, 1, 1, 1, 1], gain: 1, delay: 4, send: 1, into: &after, &other, frames: 8)
        #expect(after == [0, 0, 0, 0, 1, 1, 1, 1])
    }

    @Test func aReturnFadesInAndOutAndSaysWhenItIsSilent() {
        var level = ReturnLevel()
        level.configure(sampleRate: 48_000, seconds: 0.01)
        #expect(!level.isSounding(wanting: 0))
        #expect(level.isSounding(wanting: 0.5))
        // Where playback starts it is simply there.
        level.start(wanting: 0.5, snaps: true)
        level.set(0.5)
        #expect(level.next() == 0.5 && !level.isRamping)
        // Switched off, it fades over the glide and is then silent.
        level.set(0)
        var last: Float = 1
        for _ in 0..<479 {
            let value = level.next()
            #expect(value < last && value > 0)
            last = value
            #expect(level.isSounding(wanting: 0))
        }
        #expect(level.next() == 0)
        #expect(!level.isSounding(wanting: 0))
        // Switched in while playing, it comes up from nothing.
        level.start(wanting: 0.5, snaps: false)
        level.set(0.5)
        #expect(level.current == 0 && level.isRamping)
        let first = level.next()
        #expect(first > 0 && first < 0.01)
        level.stop()
        #expect(level.current == 0 && !level.isRamping)
    }
}
