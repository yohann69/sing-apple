import Foundation

final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [Child] = []
    weak var parent: XMLNode?

    enum Child {
        case element(XMLNode)
        case text(String)
    }

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

    func attr(_ local: String) -> String? {
        if let v = attributes[local] { return v }
        return attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value
    }

    var elements: [XMLNode] {
        children.compactMap { if case .element(let e) = $0 { e } else { nil } }
    }

    func first(_ local: String) -> XMLNode? {
        for e in elements {
            if e.localName == local { return e }
            if let found = e.first(local) { return found }
        }
        return nil
    }

    func all(_ local: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for e in elements {
            if e.localName == local { out.append(e) }
            out.append(contentsOf: e.all(local))
        }
        return out
    }

    var textContent: String {
        children.map {
            switch $0 {
            case .text(let t): t
            case .element(let e): e.textContent
            }
        }.joined()
    }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private(set) var root: XMLNode?
    private var error: Error?

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw builder.error ?? parser.parserError ?? LyricsParseError.malformed("XML")
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            node.parent = parent
            parent.children.append(.element(node))
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = stack.last else { return }
        if case .text(let previous) = current.children.last {
            current.children[current.children.count - 1] = .text(previous + string)
        } else {
            current.children.append(.text(string))
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
