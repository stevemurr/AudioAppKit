/// Makes an enum of processors into a processor, for use as a graph's node type.
///
/// Give the enum one case per kind of processor your app uses, each holding one processor:
///
///     @ProcessorSet enum Node: ~Copyable {
///         case filter(Biquad)
///         case gain(Gain)
///     }
///
/// The macro writes the `Processor` conformance, forwarding each call to whichever processor
/// the enum holds, and a `Node.render(_:input:output:context:)` for your audio callback to
/// call. That function is where the compiler checks the whole audio path.
@attached(extension, conformances: Processor, names: named(prepare), named(process), named(reset), named(latencyFrames), named(render))
public macro ProcessorSet() = #externalMacro(module: "AudioAppMacros", type: "ProcessorSetMacro")
