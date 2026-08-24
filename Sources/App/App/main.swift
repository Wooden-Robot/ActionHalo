import Cocoa

MainActor.assumeIsolated {
    // Import the old defaults domain and compatible plugins before constructing
    // AppDelegate: StatusBarController and PluginManager read their state during
    // delegate initialization and launch.
    let legacyDataImportResult = LegacyDataImporter().importIfNeeded()
    let app = NSApplication.shared
    let delegate = AppDelegate(legacyDataImportResult: legacyDataImportResult)
    app.delegate = delegate
    app.run()
}
