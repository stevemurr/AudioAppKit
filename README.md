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
//    The macro writes the forwarding code and a checked `Node.render` for your audio callback.
@ProcessorSet enum Node: ~Copyable {
    case filter(Biquad)
    case gain(Gain)
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

// 3. Render from the audio callback. `Node.render` carries the compiler's real-time checks.
Node.render(graph.renderer, input: input, output: output, context: context)

// 4. Move a fader from any thread.
level.value = -6
```

Rewire at any time: add or remove nodes, change connections, then `commit()`. The audio thread picks the
new routing up at its next block, never sees a half-made change, and never frees anything itself.

## What is built

| Module | Types |
|---|---|
| `AudioAppCore` | `SampleRate`, `FramePosition`, `Decibels`, `ChannelLayout`, `Format`, `Taper`, `AudioBlock`, `SampleBuffer`, `Transport`, `RenderContext`, `Event`, `EventList`, `EventBuffer` |
| `AudioAppRealtime` | `SPSCQueue`, `AudioRing`, `LatestValue`, `Swapped` and `SwappedReader`, `RealtimeMath`, `RealtimeThread` |
| `AudioAppProcessing` | `Processor`, `@ProcessorSet`, `Parameter`, `Smoothed`, `Graph`, `GraphRenderer`, `Chain`, `DryWet`, `Bypassable`, `MidSide`, `PerChannel`, `ScratchBuffer`, `LatencyDelay` |
| `AudioAppDSP` | `Gain`, `Biquad`, `BiquadCoefficients`, `FilterResponse` |
| `AudioAppTesting` | `RealtimeProbe`, `ProcessorHarness`, `TestSignal`, `Measure` |

`import AudioAppKit` brings in the first four. `AudioAppTesting` is a separate product for test targets.

Audio is planar 32-bit float at any sample rate and channel count. Filters keep their state in double
precision.

## How the real-time rule is enforced

**The compiler.** Swift's `@_noAllocation` and `@_noLocks` attributes make it a build error for a function,
or anything it calls, to allocate, lock or count references. Every `process` in this library carries them.
`@ProcessorSet` writes a `render` function that carries them too, so calling it, as in step 3 above, runs
the check through the graph and into every processor in your node enum. The check runs in debug and
release builds alike.

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

Two things differ in a debug build.

- **Unchecked code allocates.** An ordinary `for` loop over a range, or generic code that has not been
  specialised, performs runtime type lookups that allocate. Code reached from a function carrying the
  attributes is compiled without them. So always render through a checked function such as `Node.render`,
  and when you repeat a call inside `RealtimeProbe.measure`, use a `while` loop.
- **The check sees one file at a time.** A debug build compiles each file alone, and the check can only
  see through generic code (the graph, a wrapper, a default implementation) to a processor whose
  conformance is in the file being compiled. Keep a `@ProcessorSet` enum in the same file as any of your
  own processors it holds, and put a checked call through `DryWet<YourProcessor>` in the file that
  declares `YourProcessor`. Release builds compile the module whole and have no such limit.

## The graph

- **Inputs.** Each node has a main input and an output in the graph's channel layout. An input is the sum
  of everything connected to it, each connection with its own gain, so a connection is also a send.
- **Side-chains.** A node may also have a side-chain input (`connect(_:to:input: .sidechain)`), handed to
  the processor's `process(_:sidechain:_:)`.
- **Latency.** When paths of different latency meet, the earlier ones are delayed so they arrive together.
  `graph.latencyFrames` is how late the output is as a whole. The aligning delays start empty after each
  `commit`, so rewiring a path that needs alignment drops that many frames of its audio once.
- **Events.** `RenderContext.events` carries MIDI, parameter changes and custom events timed to the frame.
  They reach every node, and stay on their frame when a long block is rendered in pieces.

Not built yet: per-node channel layouts.

## Wrapping a processor

| Wrapper | Does |
|---|---|
| `Chain` | Runs two processors in series as one |
| `DryWet` | Blends processed with untouched, holding the dry signal back by the processor's latency |
| `Bypassable` | Switches a processor out with a short crossfade and no jump in timing |
| `MidSide` | Runs a processor on what the two channels share and how they differ |
| `PerChannel` | Runs a separate copy of a processor on each channel |

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
