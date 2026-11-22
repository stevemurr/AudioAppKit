import AudioAppKit
import AudioAppPlugin
import AudioAppTesting
import AudioToolbox
import AVFoundation
import Foundation
import Testing

/// Writes the value of the latest parameter event to channel 0 and the note number of the
/// latest MIDI event to channel 1, from the frame each one arrives on.
private struct EventTap: Processor, ~Copyable {
    var value: Float = 0
    var note: Float = 0
    mutating func prepare(_ format: Format, maxFrames: Int) {}

    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        var next = 0, frame = 0
        while frame < io.frameCount {
            while next < context.events.count, context.events[next].offset <= frame {
                switch context.events[next].kind {
                case .parameter(_, let new): value = new
                case .midi(_, let number, _): note = Float(number)
                case .custom: break
                }
                next += 1
            }
            io[0][frame] = value
            io[1][frame] = note
            frame += 1
        }
    }
}

@Suite(.serialized) struct PluginEventTests {
    /// A host only sends MIDI to a unit that declares itself a music effect or instrument.
    @Test func hostEventsReachTheProcessorOnTheirFrame() throws {
        let description = PluginDescription(name: "Event Tap", manufacturerName: "AudioAppKit Tests",
                                            subtype: "tevt", manufacturer: "AAKt", version: 1,
                                            type: kAudioUnitType_MusicEffect)
        let amount = Parameter(id: "amount", default: 0, in: 0...10)
        let unit = try AudioUnitAdapter<EventTap>(description, instance: PluginInstance(processor: EventTap(), parameters: ParameterTree([.parameter(amount)])))
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }

        unit.scheduleParameterBlock(2, 0, 0, 7)
        let noteOn: [UInt8] = [0x90, 64, 100]
        noteOn.withUnsafeBufferPointer { unit.scheduleMIDIEventBlock?(5, 0, 3, $0.baseAddress!) }

        let output = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(output.unsafeMutablePointer) }
        let samples = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 8) }
        defer { samples.forEach { $0.deallocate() } }
        for channel in 0..<2 {
            output[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: UnsafeMutableRawPointer(samples[channel]))
        }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        let status = unit.renderBlock(&flags, &time, 8, 0, output.unsafeMutablePointer) { _, _, count, _, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) { memset(buffer.mData, 0, Int(count) * 4) }
            return noErr
        }
        #expect(status == noErr)
        #expect(Array(UnsafeBufferPointer(start: samples[0], count: 8)) == [0, 0, 7, 7, 7, 7, 7, 7])
        #expect(Array(UnsafeBufferPointer(start: samples[1], count: 8)) == [0, 0, 0, 0, 0, 64, 64, 64])
        #expect(amount.value == 7)
    }
}
