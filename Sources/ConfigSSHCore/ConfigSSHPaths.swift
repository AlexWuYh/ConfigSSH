import Darwin
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

    fileprivate static var previewRootURL: URL? {
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

extension ConfigSSHPaths {
    /// Local snapshot folder; in Debug preview mode it sits next to the `/tmp` fixture.
    package static var localSnapshotFolder: URL {
        #if DEBUG
        if let previewRootURL {
            // Snapshot folders refuse symlinked components and /tmp → /private/tmp is one; realpath
            // keeps the /private prefix, unlike Foundation's resolvingSymlinksInPath.
            let fixture = previewRootURL.deletingLastPathComponent().deletingLastPathComponent()
            let resolved = realpath(fixture.path, nil).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? fixture.path
            return URL(fileURLWithPath: resolved).appendingPathComponent("Snapshots")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ConfigSSH/Snapshots")
    }
}
