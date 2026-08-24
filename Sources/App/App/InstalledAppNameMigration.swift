import Darwin
import Foundation

/// Renames the physical app bundle after the first cross-brand Sparkle update.
///
/// Sparkle 2.9.4 intentionally installs an update back to the current host path.
/// An OpenFire installation therefore receives ActionHalo's contents while its
/// outer directory remains `OpenFire.app`. This migration runs before
/// ActionHalo initializes its services, performs an atomic no-replace rename,
/// and lets a system helper reopen the app only after this process exits.
enum InstalledAppNameMigration {
    static let legacyBundleFileName = "OpenFire.app"
    static let currentBundleFileName = "ActionHalo.app"
    static let stableBundleIdentifier = "com.openfire.app"
    static let currentBundleName = "ActionHalo"
    static let currentExecutableName = "ActionHalo"
    static let applicationPackageType = "APPL"

    struct Plan: Equatable {
        let sourceURL: URL
        let destinationURL: URL
    }

    enum Assessment: Equatable {
        case notNeeded
        case destinationExists(URL)
        case ready(Plan)
    }

    struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        var shellValue: String {
            "\(device):\(inode)"
        }
    }

    static let relaunchHelperScript = """
    attempts=0
    while /bin/kill -0 "$1" 2>/dev/null; do
        if [ "$attempts" -ge 300 ]; then
            exit 75
        fi
        /bin/sleep 0.1
        attempts=$((attempts + 1))
    done

    destination_path="$2"
    bundle_identity="$3"
    launcher_path="$4"
    shift 4

    bundle_value() {
        /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
    }

    [ -d "$destination_path" ] || exit 66
    [ ! -L "$destination_path" ] || exit 66
    [ "$(/usr/bin/stat -f '%d:%i' "$destination_path" 2>/dev/null)" = "$bundle_identity" ] || exit 66
    [ "$(bundle_value "$destination_path" CFBundleIdentifier)" = "com.openfire.app" ] || exit 66
    [ "$(bundle_value "$destination_path" CFBundleName)" = "ActionHalo" ] || exit 66
    [ "$(bundle_value "$destination_path" CFBundlePackageType)" = "APPL" ] || exit 66
    [ "$(bundle_value "$destination_path" CFBundleExecutable)" = "ActionHalo" ] || exit 66

    launch_attempts=0
    while [ "$launch_attempts" -lt 3 ]; do
        if [ "$#" -gt 0 ]; then
            "$launcher_path" "$destination_path" --args "$@" && exit 0
        else
            "$launcher_path" "$destination_path" && exit 0
        fi
        launch_attempts=$((launch_attempts + 1))
        [ "$launch_attempts" -ge 3 ] || /bin/sleep 0.2
    done

    /usr/bin/logger -t ActionHalo "Failed to relaunch the renamed app at $destination_path"
    exit 69
    """

    static func assessment(
        bundleURL: URL,
        bundleIdentifier: String?,
        bundleName: String?,
        bundlePackageType: String?,
        bundleExecutable: String?,
        destinationEntryExists: Bool
    ) -> Assessment {
        let sourceURL = bundleURL.standardizedFileURL
        guard sourceURL.lastPathComponent == legacyBundleFileName,
              bundleIdentifier == stableBundleIdentifier,
              bundleName == currentBundleName,
              bundlePackageType == applicationPackageType,
              bundleExecutable == currentExecutableName else {
            return .notNeeded
        }

        let destinationURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(currentBundleFileName, isDirectory: true)
        guard !destinationEntryExists else {
            return .destinationExists(destinationURL)
        }
        return .ready(Plan(sourceURL: sourceURL, destinationURL: destinationURL))
    }

    static func pathEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &metadata) == 0
        }
    }

    static func directoryIdentity(at url: URL) -> DirectoryIdentity? {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            return nil
        }
        return DirectoryIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    static func renameExclusively(from sourceURL: URL, to destinationURL: URL) -> Bool {
        sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return false
                }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                ) == 0
            }
        }
    }

    static func relaunchHelperArguments(
        plan: Plan,
        processIdentifier: pid_t,
        identity: DirectoryIdentity,
        launcherURL: URL,
        launchArguments: [String] = []
    ) -> [String] {
        [
            "-c",
            relaunchHelperScript,
            "actionhalo-app-name-migration",
            String(processIdentifier),
            plan.destinationURL.path,
            identity.shellValue,
            launcherURL.path
        ] + launchArguments
    }

    @discardableResult
    static func renameAndScheduleRelaunchIfNeeded(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        bundleName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
        bundlePackageType: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
        bundleExecutable: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        launchArguments: [String] = Array(CommandLine.arguments.dropFirst()),
        fileManager: FileManager = .default,
        launcherURL: URL = URL(fileURLWithPath: "/usr/bin/open"),
        launchHelper: (Process) throws -> Void = { try $0.run() }
    ) -> Bool {
        let destinationURL = bundleURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(currentBundleFileName, isDirectory: true)
        let migrationAssessment = assessment(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            bundleName: bundleName,
            bundlePackageType: bundlePackageType,
            bundleExecutable: bundleExecutable,
            destinationEntryExists: pathEntryExists(at: destinationURL)
        )

        let plan: Plan
        switch migrationAssessment {
        case .notNeeded:
            return false
        case .destinationExists(let existingURL):
            NSLog("[ActionHalo] Keeping the legacy app path because %@ already exists.", existingURL.path)
            return false
        case .ready(let readyPlan):
            plan = readyPlan
        }

        guard processIdentifier > 0,
              !plan.sourceURL.pathComponents.contains("AppTranslocation"),
              let volumeValues = try? plan.sourceURL.resourceValues(
                forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey]
              ),
              volumeValues.volumeIsLocal == true,
              volumeValues.volumeIsReadOnly == false,
              fileManager.isWritableFile(atPath: plan.sourceURL.deletingLastPathComponent().path),
              let identity = directoryIdentity(at: plan.sourceURL),
              !pathEntryExists(at: plan.destinationURL) else {
            NSLog("[ActionHalo] The legacy app bundle cannot be safely renamed at %@.", plan.sourceURL.path)
            return false
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = relaunchHelperArguments(
            plan: plan,
            processIdentifier: processIdentifier,
            identity: identity,
            launcherURL: launcherURL,
            launchArguments: launchArguments
        )
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice

        do {
            try launchHelper(helper)
        } catch {
            NSLog("[ActionHalo] Failed to start the app-name migration helper: %@", error.localizedDescription)
            return false
        }

        guard directoryIdentity(at: plan.sourceURL) == identity,
              !pathEntryExists(at: plan.destinationURL) else {
            if helper.isRunning {
                helper.terminate()
            }
            NSLog("[ActionHalo] The legacy app bundle changed before it could be renamed.")
            return false
        }

        guard renameExclusively(from: plan.sourceURL, to: plan.destinationURL) else {
            let renameError = errno
            if helper.isRunning {
                helper.terminate()
            }
            NSLog(
                "[ActionHalo] Failed to atomically rename %@ to %@: %@",
                plan.sourceURL.path,
                plan.destinationURL.path,
                String(cString: strerror(renameError))
            )
            return false
        }

        NSLog(
            "[ActionHalo] Renamed the installed app from %@ to %@; relaunching.",
            plan.sourceURL.path,
            plan.destinationURL.path
        )
        return true
    }
}
