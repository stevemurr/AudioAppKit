import AudioAppCore

/// The parameters of a processor or an app, in a fixed order, optionally arranged in named
/// groups. It is what a preset saves, what a plug-in host is shown, and where a control looks
/// a parameter up by id.
///
/// The tree only holds references. The processors that read the parameters keep their own
/// references to the same objects, so nothing is looked up while audio runs.
public final class ParameterTree: Sendable {
    public enum Node: Sendable {
        case parameter(Parameter)
        case group(Group)
    }

    /// A named set of parameters and further groups.
    public struct Group: Sendable {
        public let id: String
        public let name: String
        public let children: [Node]

        public init(id: String, name: String? = nil, _ children: [Node]) {
            self.id = id
            self.name = name ?? id
            self.children = children
        }

        public init(id: String, name: String? = nil, _ parameters: [Parameter]) {
            self.init(id: id, name: name, parameters.map(Node.parameter))
        }
    }

    public let children: [Node]
    /// Every parameter, in the order the tree lists them.
    public let parameters: [Parameter]
    private let byID: [String: Parameter]

    /// - Precondition: every parameter id is different.
    public init(_ children: [Node]) {
        self.children = children
        var flat: [Parameter] = []
        func gather(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .parameter(let parameter): flat.append(parameter)
                case .group(let group): gather(group.children)
                }
            }
        }
        gather(children)
        parameters = flat
        var index: [String: Parameter] = [:]
        for parameter in flat {
            precondition(index[parameter.id] == nil, "Two parameters share the id \(parameter.id)")
            index[parameter.id] = parameter
        }
        byID = index
    }

    public convenience init(_ parameters: [Parameter]) {
        self.init(parameters.map(Node.parameter))
    }

    public subscript(id: String) -> Parameter? { byID[id] }

    /// The current value of every parameter.
    public func snapshot() -> ParameterSnapshot {
        ParameterSnapshot(values: Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.value) }))
    }

    /// Sets every parameter the snapshot names. Ids the tree does not have are ignored, and
    /// parameters the snapshot does not name keep their values, so presets survive a
    /// processor gaining or losing a parameter.
    public func restore(_ snapshot: ParameterSnapshot) {
        for (id, value) in snapshot.values { byID[id]?.value = value }
    }

    public func resetToDefaults() {
        for parameter in parameters { parameter.resetToDefault() }
    }
}

/// Parameter values by id: a preset, or a plug-in's saved state.
public struct ParameterSnapshot: Codable, Equatable, Sendable {
    public var values: [String: Float]

    public init(values: [String: Float] = [:]) { self.values = values }
}
