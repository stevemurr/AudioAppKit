import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Writes the `Processor` conformance of an enum whose cases each hold one processor: every
/// requirement forwards to whichever processor the enum currently holds.
public struct ProcessorSetMacro: ExtensionMacro {
    struct Problem: DiagnosticMessage {
        let message: String
        var diagnosticID: MessageID { MessageID(domain: "AudioAppKit", id: "ProcessorSet") }
        var severity: DiagnosticSeverity { .error }
    }

    public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax,
                                 providingExtensionsOf type: some TypeSyntaxProtocol,
                                 conformingTo protocols: [TypeSyntax],
                                 in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        guard let declared = declaration.as(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: Problem(message: "@ProcessorSet can only be attached to an enum")))
            return []
        }
        var cases: [String] = []
        for member in declared.memberBlock.members {
            guard let group = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in group.elements {
                guard let parameters = element.parameterClause?.parameters, parameters.count == 1 else {
                    context.diagnose(Diagnostic(node: element, message: Problem(
                        message: "each case of a @ProcessorSet enum must hold exactly one processor, as in 'case \(element.name.text)(SomeProcessor)'")))
                    return []
                }
                cases.append(element.name.text)
            }
        }
        guard !cases.isEmpty else {
            context.diagnose(Diagnostic(node: node, message: Problem(message: "a @ProcessorSet enum needs at least one case")))
            return []
        }

        let access = declared.modifiers.first { ["public", "package"].contains($0.name.text) }.map { "\($0.name.text) " } ?? ""
        // Take the processor out of the enum, run it, and put it back: the way to reach into
        // a non-copyable enum and change what it holds.
        func forward(_ call: String) -> String {
            cases.map { "        case .\($0)(var node): node.\(call); self = .\($0)(node)" }.joined(separator: "\n")
        }
        let latency = cases.map { "        case .\($0)(let node): node.latencyFrames" }.joined(separator: "\n")

        let source = """
        extension \(type.trimmed): Processor {
            \(access)mutating func prepare(_ format: Format, maxFrames: Int) {
                switch consume self {
        \(forward("prepare(format, maxFrames: maxFrames)"))
                }
            }

            @_noAllocation @_noLocks
            \(access)mutating func process(_ io: inout AudioBlock, _ context: borrowing RenderContext) {
                switch consume self {
        \(forward("process(&io, context)"))
                }
            }

            @_noAllocation @_noLocks
            \(access)mutating func process(_ io: inout AudioBlock, sidechain: AudioBlock, _ context: borrowing RenderContext) {
                switch consume self {
        \(forward("process(&io, sidechain: sidechain, context)"))
                }
            }

            \(access)mutating func reset() {
                switch consume self {
        \(forward("reset()"))
                }
            }

            \(access)var latencyFrames: Int {
                switch self {
        \(latency)
                }
            }

            /// Renders a graph of these nodes. The compiler checks that nothing on the way,
            /// through the graph and into every processor, can allocate or lock.
            @_noAllocation @_noLocks
            \(access)static func render(_ renderer: borrowing GraphRenderer<\(type.trimmed)>, input: AudioBlock?, output: AudioBlock, context: RenderContext) {
                renderer.render(input: input, output: output, context: context)
            }
        }
        """
        return [try ExtensionDeclSyntax(SyntaxNodeString(stringLiteral: source))]
    }
}

@main struct AudioAppMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ProcessorSetMacro.self]
}
