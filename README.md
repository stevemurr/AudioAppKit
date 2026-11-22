# AudioAppKit

Building blocks for audio apps in Swift on Apple platforms: the role JUCE plays for C++.

The code that runs on the audio thread must never allocate memory, take a lock or wait. Most audio
libraries leave that rule to convention. Here it is checked twice: by the compiler, and by a test probe.

**Status: first milestone.** The foundations, the processing contract, a runtime graph and the test tools
are built and tested. Device and file I/O, metering, controls and plug-in export are not built yet; see
[Roadmap](#roadmap).

Requires Swift 6 and macOS 15 or iOS 18.

## A first look

```swift
import AudioAppKit

// 1. Declare the processors your app uses. The set is closed, so the compiler can check all of it.
enum Node: Processor, ~Copyable {
    case filter(Biquad)
    case gain(Gain)

    mutating func prepare(_ format: Format, maxFrames: Int) {
        switch consume self {
        case .filter(var node): node.prepare(format, maxFrames: maxFrames); self = .filter(node)
        case .gain(var node): node.prepare(format, maxFrames: maxFrames); self = .gain(node)
        }
    }

    @_noAllocation @_noLocks
    mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
        switch consume self {
        case .filter(var node): node.process(&io, context); self = .filter(node)
        case .gain(var node): node.process(&io, context); self = .gain(node)
        }
    }
}

// 2. Build the signal path while the app runs.
let level = Parameter(id: "level", default: 0, in: -60...12, unit: .decibels)
let graph = Graph<Node>(format: Format(sampleRate: 48_000, layout: .stereo), maxFrames: 512)
let filter = graph.add(.filter(Biquad(.highPass, frequency: 80)))
let gain = graph.add(.gain(Gain(level: level)))
try graph.connect(.input, to: .node(filter))
try graph.connect(.node(filter), to: .node(gain))
try graph.connect(.node(gain), to: .output)
try graph.commit()

// 3. Render from the audio callback. This function is where the compiler checks the whole path.
@_noAllocation @_noLocks
func render(_ renderer: borrowing GraphRenderer<Node>, input: AudioBlock, output: AudioBlock, context: RenderContext) {
    renderer.render(input: input, output: output, context: context)
}

// 4. Move a fader from any thread.
level.value = -6
```

Rewire at any time: add or remove nodes, change connections, then `commit()`. The audio thread picks the
new routing up at its next block, never sees a half-made change, and never frees anything itself.

## What is built

| Module | Types |
|---|---|
| `AudioAppCore` | `SampleRate`, `FramePosition`, `Decibels`, `ChannelLayout`, `Format`, `Taper`, `AudioBlock`, `AudioBuffer`, `Transport`, `RenderContext` |
| `AudioAppRealtime` | `SPSCQueue`, `AudioRing`, `LatestValue`, `Swapped` and `SwappedReader`, `RealtimeMath`, `RealtimeThread` |
| `AudioAppProcessing` | `Processor`, `Chain`, `Parameter`, `Smoothed`, `Graph`, `GraphRenderer`, `NodeID`, `Endpoint` |
| `AudioAppDSP` | `Gain`, `Biquad`, `BiquadCoefficients`, `FilterResponse` |
| `AudioAppTesting` | `RealtimeProbe`, `ProcessorHarness`, `TestSignal`, `Measure` |

`import AudioAppKit` brings in the first four. `AudioAppTesting` is a separate product for test targets.

Audio is planar 32-bit float at any sample rate and channel count. Filters keep their state in double
precision.

## How the real-time rule is enforced

**The compiler.** Swift's `@_noAllocation` and `@_noLocks` attributes make it a build error for a function,
or anything it calls, to allocate, lock or count references. Every `process` in this library carries them.
Put them on your own audio callback, as in step 3 above, and the check runs through the graph and into
every processor in your node enum. The check runs in debug and release builds alike.

**The probe.** `RealtimeProbe.measure { ... }` counts every allocation and free the enclosed code makes on
its thread. The library's tests run every processor and the graph under it, including the block where a
rewired graph is picked up and the block where a fader moves.

```swift
var filter = Biquad(.peak, frequency: 1_000, gain: 6)
filter.prepare(format, maxFrames: 512)
#expect(ProcessorHarness.heapActivity(&filter, sampleRate: 48_000).isClean)
```

**What that does and does not promise.** The attributes are underscored, meaning Swift may change them. The
probe sees heap activity but not locks. Neither can see into a system call you make yourself. So the
guarantee is "checked by two independent tools", not "proven".

### Rules for writing a processor

These come from what the compiler accepted and rejected while building the library.

1. **Make it a non-copyable struct** (`struct Foo: Processor, ~Copyable`). A copyable struct that holds a
   `Parameter` gets a reference count on every read, which the compiler rejects.
2. **Reserve all memory in `prepare`.** Free it in `deinit`.
3. **Mark `process` with `@_noAllocation @_noLocks`,** and make it `@inlinable` if it lives in a library.
4. **Use `RealtimeMath` for `sqrt`, `tan` and `pow`.** `exp`, `log`, `sin` and `cos` pass the check as
   they are; the others call the system math library, which the check cannot see into.
5. **Read parameters once per block,** not per sample.

### Debug builds

In a debug build, an ordinary `for` loop over a range performs a runtime type lookup that allocates.
Functions carrying the attributes are compiled without it, which is why the library's hot paths carry them
directly. When you repeat a call inside `RealtimeProbe.measure`, use a `while` loop.

## The graph

Each node has one input and one output in the graph's channel layout. A node's input is the sum of
everything connected to it, each connection with its own gain, so a connection is also a send.

Not built yet: side-chain inputs, per-node channel layouts, latency compensation between parallel paths,
and events (MIDI, sample-accurate parameter changes).

## Roadmap

| Module | Will hold |
|---|---|
| Processing | A macro to write the node enum's forwarding; events; latency compensation; side-chains; `Bypassable`, `DryWet`, `Oversampled`, `STFTHost`; parameter undo and control attachment |
| DSP | State-variable filter, delay line, envelope follower, FFT, filter bank, dynamics core, limiter, feedback delay network, resampler |
| RenderAhead | Running DSP that cannot be real-time-safe (machine-learning models, large solvers) ahead of the callback |
| IO | Devices, the audio engine, file reading and writing, offline render, waveform overviews |
| Metering | Peak, true peak, loudness, spectrum, correlation |
| Controls | Fader, knob, slider, level meter, waveform view |
| Plugin | Audio Unit (AUv3) export |

## Building and testing

```
swift build
swift test
swift test -c release
```
