import Darwin
import Foundation

/// A cheap fingerprint of "did any config file change": the modification time, size and inode of
/// `config`, every file it was read from, and the `~/.ssh` and `config.d` directories (which
/// change when a file is added or removed). It only calls `lstat`, never opens or parses
/// anything, so it can run every few seconds; a changed signature is the cue to scan properly.
package enum ConfigStatSignature {
    package static func make(rootURL: URL, sources: [URL]) -> [String] {
        let ssh = rootURL.deletingLastPathComponent()
        let managed = ssh.appendingPathComponent("config.d")
        var paths: Set<String> = [rootURL.path, ssh.path, managed.path]
        for source in sources { paths.insert(source.standardizedFileURL.path) }
        if let groups = try? FileManager.default.contentsOfDirectory(atPath: managed.path) {
            for name in groups {
                let child = managed.appendingPathComponent(name).path
                var info = stat()
                if lstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { paths.insert(child) }
            }
        }
        return paths.sorted().map { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return "\(path)|missing" }
            return "\(path)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_size)|\(info.st_ino)"
        }
    }
}
