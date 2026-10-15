import Foundation

/// Catalog fallback for a file name's extension. Shared by the file browser (`FilesSheet`)
/// and source control so a `.swift` file looks the same everywhere. Folders are handled by callers.
func fileTypeIcon(_ name: String) -> AppIconName {
    switch (name as NSString).pathExtension.lowercased() {
    case "swift": return .fileCode
    case "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "py", "rb", "go", "rs", "java", "c", "cpp", "h":
        return .code
    case "md", "markdown", "txt", "rtf", "log": return .fileText
    case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "ico": return .filePicture
    case "pdf": return .fileText
    case "zip", "tar", "gz", "tgz", "rar", "7z": return .fileArchive
    case "sh", "bash", "zsh", "fish": return .terminal
    case "yml", "yaml", "toml", "ini", "conf", "env", "plist": return .settings
    case "lock": return .lock
    case "css", "scss", "html", "htm": return .code
    default: return .file
    }
}
