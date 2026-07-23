import Cocoa

/// Manage per-app plugin overrides for the current frontmost application.
final class CurrentAppPluginsWindow: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let appName: String
    private let bundleID: String
    private var orderedPlugins: [Plugin] = []
    private var filteredPlugins: [Plugin] = []
    private let rowHeight: CGFloat = 34

    init(appName: String, bundleID: String) {
        self.appName = appName
        self.bundleID = bundleID

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: "Plugins in %@".localized, appName)
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePluginsReloaded),
            name: PluginManager.pluginsReloadedNotification,
            object: nil
        )
        loadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: String(format: "Disable specific plugins only in %@. Global disabled plugins stay unavailable here.".localized, appName))
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 340, width: 390, height: 32)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        contentView.addSubview(label)

        let bundleLabel = NSTextField(labelWithString: bundleID)
        bundleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        bundleLabel.textColor = .tertiaryLabelColor
        bundleLabel.frame = NSRect(x: 20, y: 320, width: 390, height: 16)
        contentView.addSubview(bundleLabel)

        searchField.frame = NSRect(x: 20, y: 286, width: 400, height: 28)
        searchField.placeholderString = "Filter plugins in this app".localized
        searchField.delegate = self
        contentView.addSubview(searchField)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 400, height: 256))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin"))
        column.width = 398
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.style = .plain
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func loadData() {
        orderedPlugins = PluginManager.shared.orderedPluginsForDisplay()
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredPlugins = orderedPlugins
            tableView.reloadData()
            return
        }

        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        filteredPlugins = orderedPlugins.filter { plugin in
            [
                plugin.name,
                plugin.id,
                plugin.config.action.type.rawValue
            ].contains { field in
                field.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(foldedQuery)
            }
        }
        tableView.reloadData()
    }

    override func showWindow(_ sender: Any?) {
        loadData()
        super.showWindow(sender)
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        loadData()
    }

    @objc private func handlePluginsReloaded() {
        refreshIfVisible()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredPlugins.isEmpty ? 1 : filteredPlugins.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if filteredPlugins.isEmpty {
            let emptyView = NSView(frame: NSRect(x: 0, y: 0, width: 398, height: rowHeight))
            let emptyState = orderedPlugins.isEmpty ? "No plugins available.".localized : "No matches for the current filter.".localized
            let label = NSTextField(labelWithString: emptyState)
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 8, width: 398, height: 18)
            emptyView.addSubview(label)
            return emptyView
        }

        let plugin = filteredPlugins[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 398, height: rowHeight))

        let globallyEnabled = plugin.isEnabled
        let enabledInApp = PluginManager.shared.isPluginEnabled(plugin.id, forAppBundleID: bundleID)

        let indicator = NSTextField(labelWithString: globallyEnabled ? (enabledInApp ? "●" : "○") : "–")
        indicator.frame = NSRect(x: 12, y: 7, width: 16, height: 18)
        indicator.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        indicator.textColor = globallyEnabled ? (enabledInApp ? .systemBlue : .tertiaryLabelColor) : .quaternaryLabelColor
        cell.addSubview(indicator)

        let nameLabel = NSTextField(labelWithString: plugin.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.frame = NSRect(x: 38, y: 14, width: 230, height: 16)
        nameLabel.textColor = globallyEnabled ? .labelColor : .tertiaryLabelColor
        cell.addSubview(nameLabel)

        let detailText: String
        if !globallyEnabled {
            detailText = "Globally disabled".localized
        } else if enabledInApp {
            detailText = "Enabled in this app".localized
        } else {
            detailText = "Disabled in this app".localized
        }

        let detailLabel = NSTextField(labelWithString: detailText)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.frame = NSRect(x: 38, y: 2, width: 230, height: 14)
        cell.addSubview(detailLabel)

        let typeLabel = NSTextField(labelWithString: plugin.config.action.type.rawValue)
        typeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        typeLabel.alignment = .right
        typeLabel.textColor = .quaternaryLabelColor
        typeLabel.frame = NSRect(x: 280, y: 9, width: 106, height: 14)
        cell.addSubview(typeLabel)

        return cell
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < filteredPlugins.count else { return }

        let plugin = filteredPlugins[row]
        guard plugin.isEnabled else { return }

        let enabledInApp = PluginManager.shared.isPluginEnabled(plugin.id, forAppBundleID: bundleID)
        PluginManager.shared.setPluginEnabled(plugin.id, enabled: !enabledInApp, forAppBundleID: bundleID)
        loadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}
