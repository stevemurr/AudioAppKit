import AudioAppKit
import AudioAppTesting
import Foundation
import Synchronization
import Testing

/// Reports its own destruction, to show where a state is freed.
private final class Token: Sendable {
    let id: Int
    let destroyed: Counter
    init(_ id: Int, _ destroyed: Counter) { self.id = id; self.destroyed = destroyed }
    deinit { destroyed.bump() }
}

@Suite struct RealtimeTests {
    @Test func queueKeepsOrderAndRefusesWhenFull() {
        let queue = SPSCQueue<Int>(capacity: 4)
        for value in 0..<4 { #expect(queue.push(value)) }
        #expect(!queue.push(99))
        #expect(queue.isFull)
        #expect((0..<4).map { _ in queue.pop() } == [0, 1, 2, 3])
        #expect(queue.pop() == nil)
    }

    @Test func queueDeliversEverythingAcrossThreads() {
        let queue = SPSCQueue<Int>(capacity: 64)
        let total = 200_000
        let writer = Thread {
            var next = 0
            while next < total { if queue.push(next) { next += 1 } }
        }
        writer.start()
        var expected = 0
        var inOrder = true
        while expected < total {
            if let value = queue.pop() {
                inOrder = inOrder && value == expected
                expected += 1
            }
        }
        #expect(inOrder)
    }

    @Test func queuePushAndPopStayOffTheHeap() {
        let queue = SPSCQueue<Int>(capacity: 16)
        let report = RealtimeProbe.measure {
            var value = 0
            while value < 1_000 {
                queue.push(value)
                _ = queue.pop()
                value += 1
            }
        }
        #expect(report.isClean, "\(report)")
    }

    @Test func ringWrapsAroundItsEnd() {
        let ring = AudioRing(channelCount: 2, frameCapacity: 8)
        var written = 0, read = 0
        var correct = true
        for _ in 0..<50 {
            let start = written
            written += ring.write(frames: 5) { channel, frame in Float((start + frame) * 2 + channel) }
            let from = read
            read += ring.read(frames: 3) { channel, frame, sample in
                correct = correct && sample == Float((from + frame) * 2 + channel)
            }
        }
        #expect(correct)
        #expect(ring.availableFrames == written - read)
        #expect(ring.availableFrames <= 8)
        ring.drain()
        #expect(ring.availableFrames == 0)
    }

    @Test func latestValueNeverShowsAHalfStoredValue() {
        struct Pair { var a: Int; var b: Int }
        let latest = LatestValue(Pair(a: 0, b: 0))
        let stop = Atomic<Bool>(false)
        let torn = Counter(), seen = Counter()
        let reader = Thread {
            while !stop.load(ordering: .relaxed) {
                if let matched = latest.read({ $0.a == $0.b }) {
                    seen.bump()
                    if !matched { torn.bump() }
                }
            }
        }
        reader.start()
        // Keep publishing until the reader has had a real chance to collide with a write.
        var last = 0
        while last < 20_000 || seen.value < 1_000 {
            last += 1
            latest.publish(Pair(a: last, b: last))
        }
        stop.store(true, ordering: .relaxed)
        while !reader.isFinished { usleep(1_000) }
        #expect(torn.value == 0)
        #expect(seen.value > 0)
        #expect(latest.read { $0.a } == last)
        #expect(latest.publishCount == last)
    }

    @Test func swappedStateIsFreedByTheControlThreadOnly() {
        let destroyed = Counter()
        let swapped = Swapped(Token(0, destroyed))
        let reader = swapped.reader
        #expect(reader.current().pointee.id == 0)

        swapped.publish(Token(1, destroyed))
        // The audio thread adopts the new state without freeing the old one.
        let report = RealtimeProbe.measure { _ = reader.current() }
        #expect(report.isClean, "\(report)")
        #expect(reader.current().pointee.id == 1)
        #expect(destroyed.value == 0)
        #expect(swapped.retiredCount == 1)

        swapped.collect()
        #expect(destroyed.value == 1)
    }

    @Test func aStateTheAudioThreadNeverSawIsFreedAtOnce() {
        let destroyed = Counter()
        let swapped = Swapped(Token(0, destroyed))
        swapped.publish(Token(1, destroyed))
        swapped.publish(Token(2, destroyed))
        #expect(destroyed.value == 1)
        #expect(swapped.reader.current().pointee.id == 2)
    }

    @Test func everythingIsFreedWhenSwappedGoesAway() {
        let destroyed = Counter()
        do {
            let swapped = Swapped(Token(0, destroyed))
            swapped.publish(Token(1, destroyed))
            _ = swapped.reader.current()
            swapped.publish(Token(2, destroyed))
        }
        #expect(destroyed.value == 3)
    }

    @Test func probeCatchesAnAllocationAndPassesArithmetic() {
        let dirty = RealtimeProbe.measure {
            let scratch = [Float](repeating: 0, count: 4_096)
            withExtendedLifetime(scratch) {}
        }
        #expect(dirty.allocations >= 1)
        #expect(dirty.deallocations >= 1)

        var total = 0
        let clean = RealtimeProbe.measure {
            var value = 0
            while value < 10_000 { total &+= value; value += 1 }
        }
        #expect(clean.isClean, "\(clean)")
        #expect(total == 49_995_000)
    }

    @Test func probeIgnoresOtherThreads() {
        let stop = Atomic<Bool>(false)
        let noisy = Thread {
            while !stop.load(ordering: .relaxed) {
                let scratch = [Int](repeating: 1, count: 256)
                withExtendedLifetime(scratch) {}
            }
        }
        noisy.start()
        var total = 0
        let report = RealtimeProbe.measure {
            var value = 0
            while value < 2_000_000 { total &+= value; value += 1 }
        }
        stop.store(true, ordering: .relaxed)
        #expect(report.isClean, "\(report)")
    }
}
