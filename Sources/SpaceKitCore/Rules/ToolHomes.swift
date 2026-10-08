import Foundation

/// Folders in the home directory where developer and AI tools keep their own data: package caches, toolchains,
/// container disks, model stores. Storage categories count them as developer or AI data, and pattern rules never
/// search them, because a `node_modules` or `build` folder in there belongs to the tool, not to a project.
public enum ToolHomes {
    public static let developer: [String] = [
        "~/.npm", "~/.pnpm-store", "~/.nvm", "~/.volta", "~/.fnm", "~/.bun", "~/.deno", "~/.yarn",
        "~/.cargo", "~/.rustup", "~/go", "~/.gradle", "~/.m2", "~/.sdkman", "~/.android",
        "~/.pyenv", "~/.rbenv", "~/.gem", "~/.docker", "~/.orbstack",
        "~/miniconda3", "~/anaconda3", "~/miniforge3", "~/.conda", "~/.mamba", "~/.pub-cache", "~/fvm", "~/.cocoapods",
    ]

    public static let ai: [String] = ["~/.ollama", "~/.lmstudio", "~/jan"]
}
