import Foundation
import ObjectiveC

/// Loads SourceModel.framework at runtime and exposes typed entry points onto
/// its private classes. Not Sendable: instances must be owned by a single actor.
nonisolated final class SourceModelClient {

    enum LoadError: Error, CustomStringConvertible {
        case bundleNotFound(URL)
        case loadFailed(URL, underlying: any Error)
        case classMissing(String)
        case selectorMissing(className: String, selector: String)

        var description: String {
            switch self {
            case .bundleNotFound(let url): "no framework bundle at \(url.path)"
            case .loadFailed(let url, let error): "failed to load \(url.path): \(error)"
            case .classMissing(let name): "class \(name) not found after load"
            case .selectorMissing(let className, let selector): "\(className) does not respond to \(selector)"
            }
        }
    }

    private let languageClass: any XCQLSourceCodeLanguageClass
    private let modelClass: any XCQLSourceModelClass
    private let nodeTypesClass: any XCQLSourceNodeTypesClass

    init(frameworkURL: URL) throws {
        guard let bundle = Bundle(url: frameworkURL) else {
            throw LoadError.bundleNotFound(frameworkURL)
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            throw LoadError.loadFailed(frameworkURL, underlying: error)
        }

        // Capability probe: any drift in the private API fails here, cleanly,
        // instead of crashing in a message send later.
        func probedClass(
            _ name: String,
            classSelectors: [String] = [],
            instanceSelectors: [String] = []
        ) throws -> AnyClass {
            guard let cls: AnyClass = NSClassFromString(name) else {
                throw LoadError.classMissing(name)
            }
            for selector in classSelectors {
                guard let meta = object_getClass(cls),
                      class_getInstanceMethod(meta, NSSelectorFromString(selector)) != nil else {
                    throw LoadError.selectorMissing(className: name, selector: "+\(selector)")
                }
            }
            for selector in instanceSelectors {
                guard class_getInstanceMethod(cls, NSSelectorFromString(selector)) != nil else {
                    throw LoadError.selectorMissing(className: name, selector: "-\(selector)")
                }
            }
            return cls
        }

        // Probe only selectors this client actually sends; every extra probed
        // selector is another way to falsely decline on future Xcode drift.
        let language: AnyClass = try probedClass(
            "SMSourceCodeLanguage",
            classSelectors: [
                "loadAndCacheDefaultSourceCodeLanguages",
                "sourceCodeLanguageForFileExtension:",
                "sourceCodeLanguageForFileDataTypeIdentifier:",
                "sourceCodeLanguageWithIdentifier:",
            ]
        )
        let model: AnyClass = try probedClass(
            "SMSourceModel",
            instanceSelectors: [
                "initWithSourceBufferProvider:", "setDirtyRange:", "parse", "_topLevelSourceItem",
            ]
        )
        let item: AnyClass = try probedClass(
            "SMSourceModelItem",
            instanceSelectors: ["range", "nodeType", "children"]
        )
        _ = item
        let nodeTypes: AnyClass = try probedClass(
            "SMSourceNodeTypes",
            classSelectors: ["nodeTypeNameForId:"]
        )

        // The `as AnyObject` coercion is load-bearing: it unwraps the Swift
        // ObjCClassWrapper metadata into the actual class object. Bitcasting
        // the AnyClass value directly crashes the first retain.
        languageClass = unsafeBitCast(language as AnyObject, to: (any XCQLSourceCodeLanguageClass).self)
        modelClass = unsafeBitCast(model as AnyObject, to: (any XCQLSourceModelClass).self)
        nodeTypesClass = unsafeBitCast(nodeTypes as AnyObject, to: (any XCQLSourceNodeTypesClass).self)

        languageClass.loadAndCacheDefaultSourceCodeLanguages()
    }

    // MARK: Language lookup

    func language(forUTI identifier: String) -> AnyObject? {
        languageClass.sourceCodeLanguage(forFileDataTypeIdentifier: identifier) as AnyObject?
    }

    func language(forExtension fileExtension: String) -> AnyObject? {
        languageClass.sourceCodeLanguage(forFileExtension: fileExtension) as AnyObject?
    }

    func language(forIdentifier identifier: String) -> AnyObject? {
        languageClass.sourceCodeLanguage(withIdentifier: identifier) as AnyObject?
    }

    // MARK: Parsing

    func nodeTypeName(forId id: Int16) -> String? {
        nodeTypesClass.nodeTypeName(forId: id)
    }

    /// Parses `text` as `language` and returns the root item of the source model
    /// tree, plus the objects that must stay alive while the tree is walked.
    func parse(text: NSString, language: AnyObject) -> (root: any XCQLSourceModelItem, retained: [AnyObject])? {
        let provider = SourceBufferProvider(text: text, language: language)
        let raw = modelClass.alloc() as AnyObject
        let model = unsafeBitCast(raw, to: (any XCQLSourceModel).self)
        guard let initialized = model.initialized(provider: provider) else { return nil }
        let live = unsafeBitCast(initialized as AnyObject, to: (any XCQLSourceModel).self)
        live.setDirtyRange(NSRange(location: 0, length: text.length))
        live.parse()
        guard let root = live._topLevelSourceItem() else { return nil }
        return (unsafeBitCast(root as AnyObject, to: (any XCQLSourceModelItem).self),
                [initialized as AnyObject, provider])
    }

    func item(_ object: AnyObject) -> any XCQLSourceModelItem {
        unsafeBitCast(object, to: (any XCQLSourceModelItem).self)
    }
}
