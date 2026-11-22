import AudioAppKit
import AudioAppTesting
import Foundation
import Synchronization
import Testing

@Suite struct TaggedSlotTests {
    @Test func aSlotAnswersOnlyToTheTagItHolds() {
        let slot = TaggedSlot<[Float]>([])
        #expect(!slot.read(0) { _ in })
        slot.publish(7, value: [1, 2, 3])
        var seen: [Float] = []
        #expect(slot.read(7) { seen = copy $0 })
        #expect(seen == [1, 2, 3])
        #expect(!slot.read(6) { _ in })
        slot.publish(8, value: [4])
        #expect(!slot.read(7) { _ in })
        #expect(slot.tag == 8)
        slot.clear()
        #expect(!slot.read(8) { _ in })
    }

    @Test func readingStaysOffTheHeap() {
        let slot = TaggedSlot<[Float]>([])
        slot.publish(3, value: [Float](repeating: 0.5, count: 512))
        let target = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { target.deallocate() }
        let report = RealtimeProbe.measure {
            var turn = 0
            while turn < 100 {
                slot.read(3) { value in value.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: 512) } }
                turn += 1
            }
        }
        #expect(report.isClean, "\(report)")
        #expect(target[511] == 0.5)
    }

    @Test func aReaderNeverSeesAValueUnderTheWrongTag() {
        // Each published array is filled with its own tag, so a mismatch is a torn read.
        let slot = TaggedSlot<[Int]>([])
        let stop = Atomic<Bool>(false)
        let wrong = Counter(), seen = Counter()
        let latest = Atomic<Int>(0)
        let reader = Thread {
            while !stop.load(ordering: .relaxed) {
                let tag = latest.load(ordering: .relaxed)
                if slot.read(tag, { value in if value.contains(where: { $0 != tag }) { wrong.bump() } }) { seen.bump() }
            }
        }
        reader.start()
        var tag = 0
        while tag < 20_000 || seen.value < 1_000 {
            tag += 1
            slot.publish(tag, value: [Int](repeating: tag, count: 64))
            latest.store(tag, ordering: .relaxed)
        }
        stop.store(true, ordering: .relaxed)
        while !reader.isFinished { usleep(1_000) }
        #expect(wrong.value == 0)
        #expect(seen.value > 0)
    }
}
