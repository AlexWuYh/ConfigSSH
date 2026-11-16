import Foundation

package enum ConfigSSHPaths {
    package static var isPreviewMode: Bool { previewRootURL != nil }

    package static var rootURL: URL {
        previewRootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    package static var sshDirectory: URL {
        rootURL.deletingLastPathComponent()
    }

    package static var metadataURL: URL {
        if let previewRootURL {
            return previewRootURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("metadata.sqlite")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ConfigSSH/metadata.sqlite")
    }

    private static var previewRootURL: URL? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_ROOT"],
              raw.hasPrefix("/"), !raw.contains("..") else { return nil }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        let roots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
            .map { $0.resolvingSymlinksInPath().path }
        let resolvedPath = url.resolvingSymlinksInPath().path
        let allowed = roots.contains { resolvedPath.hasPrefix($0 + "/") }
        guard allowed, url.lastPathComponent == "config",
              url.deletingLastPathComponent().lastPathComponent == ".ssh" else { return nil }
        return url
        #else
        return nil
        #endif
    }
}
