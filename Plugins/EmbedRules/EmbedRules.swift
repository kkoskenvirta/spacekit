import Foundation
import PackagePlugin

/// Compiles the repository's `rules/**/*.yaml` into SpaceKitCore as Swift source, so the built-in rule library is a
/// fact of the build: no folder on disk can add, change or drop a built-in rule. Every rule file is an input of the
/// generating command, so editing one rebuilds the library; the plugin runs on every build, so it sees added and
/// removed files too.
@main
struct EmbedRules: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let rules = context.package.directoryURL.appending(path: "rules")
        let names = yamlFiles(in: rules)
        let files = names.map { rules.appending(path: $0) }
        let output = context.pluginWorkDirectoryURL.appending(path: "EmbeddedRuleFiles.swift")
        return [
            .buildCommand(
                displayName: "Embedding \(files.count) built-in rule files",
                executable: try context.tool(named: "RuleEmbedder").url,
                arguments: [rules.path(percentEncoded: false), output.path(percentEncoded: false)] + names,
                inputFiles: files,
                outputFiles: [output])
        ]
    }

    /// Rule files under `directory`, as paths relative to it, sorted so the generated source is stable.
    private func yamlFiles(in directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path(percentEncoded: false)) else { return [] }
        return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }.sorted()
    }
}
