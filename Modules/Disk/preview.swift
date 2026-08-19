//
//  preview.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 22/04/2026
//  Using Swift 6.0
//  Running on macOS 26.4
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Preview: PreviewWrapper {
    private var main: disk_s? = nil
    
    private var circle: PieChartView? = nil
    private var bar: BarChartView? = nil
    private var chart: NetworkChartView? = nil
    
    private var usedField: NSTextField? = nil
    private var freeField: NSTextField? = nil
    
    private var readState: NSView? = nil
    private var writeState: NSView? = nil
    
    private var allDisks: PreferencesSection? = nil
    private var disks: NSGridView = {
        let grid = NSGridView(frame: .zero)
        grid.rowSpacing = 0
        grid.rowAlignment = .none
        grid.yPlacement = .fill
        return grid
    }()
    private var diskRows: [String: DriveRow] = [:]
    private var drives: [physicalDrive] = []
    private var selectedDrive: String = ""
    
    private var initialized: Bool = false
    
    private var readColorState: SColor = .secondBlue
    private var readColor: NSColor { self.readColorState.additional as? NSColor ?? NSColor.systemRed }
    private var writeColorState: SColor = .secondRed
    private var writeColor: NSColor { self.writeColorState.additional as? NSColor ?? NSColor.systemBlue }
    private var reverseOrderState: Bool = false
    private var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(self.module.stringValue)_base", defaultValue: DataSizeBase.byte.rawValue)) ?? .byte
    }
    private var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(self.module.stringValue)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }
    
    private var uri: URL? = nil
    private let finder: URL?
    
    private var readSpeedValueField: ValueField?
    private var writeSpeedValueField: ValueField?
    
    private var totalReadValueField: ValueField?
    private var totalWrittenValueField: ValueField?
    private var modelValueField: ValueField?
    private var serialValueField: ValueField?
    private var capacityValueField: ValueField?
    private var connectionTypeValueField: ValueField?
    private var bsdNameValueField: ValueField?

    private var smartTotalReadValueField: ValueField?
    private var smartTotalWrittenValueField: ValueField?
    private var temperatureValueField: ValueField?
    private var healthValueField: ValueField?
    private var powerCyclesValueField: ValueField?
    private var powerOnHoursValueField: ValueField?
    private var criticalWarningValueField: ValueField?
    private var availableSpareValueField: ValueField?
    private var unsafeShutdownsValueField: ValueField?
    private var mediaErrorsValueField: ValueField?
    
    public init(_ module: ModuleType) {
        self.finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Finder")
        
        super.init(type: module)
        
        self.loadColors()
        self.selectedDrive = Store.shared.string(key: "\(module.stringValue)_preview_selected", defaultValue: "")
        
        self.addArrangedSubview(PreferencesSection([self.usageView()]))
        
        let allDisks = PreferencesSection(title: localizedString("All disks"), subtitle: "", [self.disks])
        allDisks.isHidden = true
        self.addArrangedSubview(allDisks)
        self.allDisks = allDisks
        
        self.addArrangedSubview(PreferencesSection(title: localizedString("Read / Write history"), [self.historyView()]))
        
        let splitView = NSStackView()
        splitView.orientation = .horizontal
        splitView.distribution = .fillEqually
        splitView.alignment = .top
        splitView.addArrangedSubview(PreferencesSection(title: localizedString("Details"), [self.detailsView()]))
        splitView.addArrangedSubview(PreferencesSection(title: localizedString("SMART"), [self.smartView()]))
        
        self.addArrangedSubview(splitView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func loadColors() {
        self.readColorState = SColor.fromString(Store.shared.string(key: "\(self.module.stringValue)_readColor", defaultValue: self.readColorState.key))
        self.writeColorState = SColor.fromString(Store.shared.string(key: "\(self.module.stringValue)_writeColor", defaultValue: self.writeColorState.key))
        self.reverseOrderState = Store.shared.bool(key: "\(self.module.stringValue)_reverseOrder", defaultValue: self.reverseOrderState)
    }
    
    private func usageView() -> NSView {
        let view = NSStackView()
        view.distribution = .fill
        view.orientation = .horizontal
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 90).isActive = true
        view.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin,
            left: Constants.Settings.margin,
            bottom: Constants.Settings.margin,
            right: Constants.Settings.margin
        )
        view.spacing = Constants.Settings.margin
        
        let circle = PieChartView(drawValue: true)
        circle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        circle.toolTip = localizedString("Disk usage")
        self.circle = circle
        
        let details: NSView = {
            let view = NSStackView()
            view.orientation = .vertical
            view.distribution = .fillEqually
            view.spacing = 2
            
            var nameValue = localizedString("Unknown")
            var fileSystemValue = localizedString("Unknown")
            var sizeValue = localizedString("Unknown")
            if let disk = SystemKit.shared.device.info.disk?.first {
                if let name = disk.name {
                    nameValue = name
                }
                if let fileSystem = disk.fileSystem {
                    fileSystemValue = fileSystem.uppercased()
                }
                if let size = disk.size {
                    sizeValue = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                }
                self.main = disk
            }
            
            let title: NSView = {
                let view = NSStackView()
                view.orientation = .horizontal
                view.spacing = 2
                
                let nameField = NSButton()
                nameField.bezelStyle = .inline
                nameField.isBordered = false
                nameField.contentTintColor = .labelColor
                nameField.action = #selector(self.openDisk)
                nameField.target = self
                nameField.toolTip = nameValue
                nameField.title = nameValue
                nameField.cell?.truncatesLastVisibleLine = true
                
                let fileSystemField = LabelField(fileSystemValue)
                fileSystemField.textColor = .tertiaryLabelColor
                
                let activity: NSStackView = NSStackView()
                activity.distribution = .fill
                activity.spacing = 2
                
                let readState: NSView = NSView()
                readState.widthAnchor.constraint(equalToConstant: 8).isActive = true
                readState.heightAnchor.constraint(equalToConstant: 8).isActive = true
                readState.wantsLayer = true
                readState.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.75).cgColor
                readState.layer?.cornerRadius = 4
                readState.toolTip = localizedString("Read")
                let writeState: NSView = NSView()
                writeState.widthAnchor.constraint(equalToConstant: 8).isActive = true
                writeState.heightAnchor.constraint(equalToConstant: 8).isActive = true
                writeState.wantsLayer = true
                writeState.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.75).cgColor
                writeState.layer?.cornerRadius = 4
                writeState.toolTip = localizedString("Write")
                self.readState = readState
                self.writeState = writeState
                
                activity.addArrangedSubview(readState)
                activity.addArrangedSubview(writeState)
                
                view.addArrangedSubview(nameField)
                view.addArrangedSubview(activity)
                view.addArrangedSubview(NSView())
                view.addArrangedSubview(fileSystemField)
                
                return view
            }()
            
            let bar = BarChartView(size: 11, horizontal: true)
            self.bar = bar
            
            let levels = NSStackView()
            levels.orientation = .horizontal
            levels.distribution = .fill
            
            self.usedField = previewRow(levels, space: false, color: NSColor.systemBlue, title: "\(localizedString("Used")):", value: "")
            self.freeField = previewRow(levels, space: false, color: NSColor.lightGray, title: "\(localizedString("Free")):", value: "")
            
            let fileSystemField = LabelField(sizeValue)
            fileSystemField.textColor = .tertiaryLabelColor
            
            levels.addArrangedSubview(NSView())
            levels.addArrangedSubview(fileSystemField)
            
            view.addArrangedSubview(title)
            view.addArrangedSubview(bar)
            view.addArrangedSubview(levels)
            
            return view
        }()
        
        view.addArrangedSubview(circle)
        view.addArrangedSubview(details)
        
        return view
    }
    
    private func historyView() -> NSView {
        let view: NSStackView = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Settings.margin*2
        view.heightAnchor.constraint(equalToConstant: 140).isActive = true
        
        let chart = NetworkChartView(frame: .zero, num: 600)
        self.chart = chart
        chart.setColors(in: self.readColor, out: self.writeColor)
        chart.setReverseOrder(self.reverseOrderState)
        chart.setLegend(x: true, y: false)
        view.addArrangedSubview(chart)
        
        return view
    }
    
    private func detailsView() -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = 2
        
        self.readSpeedValueField = previewRow(view, color: self.readColor, title: "\(localizedString("Read")):", value: "0 KB/s")
        self.writeSpeedValueField = previewRow(view, color: self.writeColor, title: "\(localizedString("Write")):", value: "0 KB/s")
        self.totalReadValueField = previewRow(view, title: "\(localizedString("Total read")):", value: "0 KB")
        self.totalWrittenValueField = previewRow(view, title: "\(localizedString("Total written")):", value: "0 KB")
        self.modelValueField = previewRow(view, title: "\(localizedString("Model")):", value: localizedString("Unknown"))
        self.serialValueField = previewRow(view, title: "\(localizedString("Serial number")):", value: localizedString("Unknown"))
        self.capacityValueField = previewRow(view, title: "\(localizedString("Capacity")):", value: localizedString("Unknown"))
        self.connectionTypeValueField = previewRow(view, title: "\(localizedString("Connection type")):", value: localizedString("Unknown"))
        self.bsdNameValueField = previewRow(view, title: "\(localizedString("BSD name")):", value: localizedString("Unknown"))
        
        return view
    }
    
    private func smartView() -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = 2
        
        self.smartTotalReadValueField = previewRow(view, title: "\(localizedString("Total read")):", value: "0 KB")
        self.smartTotalWrittenValueField = previewRow(view, title: "\(localizedString("Total written")):", value: "0 KB")
        self.temperatureValueField = previewRow(view, title: "\(localizedString("Temperature")):", value: "\(temperature(0))")
        self.healthValueField = previewRow(view, title: "\(localizedString("Health")):", value: "0%")
        self.powerCyclesValueField = previewRow(view, title: "\(localizedString("Power cycles")):", value: "0")
        self.powerOnHoursValueField = previewRow(view, title: "\(localizedString("Power on hours")):", value: "0")
        self.criticalWarningValueField = previewRow(view, title: "\(localizedString("Critical warning")):", value: localizedString("Unknown"))
        self.availableSpareValueField = previewRow(view, title: "\(localizedString("Available spare")):", value: localizedString("Unknown"))
        self.unsafeShutdownsValueField = previewRow(view, title: "\(localizedString("Unsafe shutdowns")):", value: localizedString("Unknown"))
        self.mediaErrorsValueField = previewRow(view, title: "\(localizedString("Media errors")):", value: localizedString("Unknown"))
        
        return view
    }
    
    internal func capacityCallback(_ value: Disks) {
        DispatchQueue.main.async(execute: {
            guard (self.window?.isVisible ?? false) || !self.initialized else { return }
            guard let main = self.main, let update = value.first(where: { $0.uuid == main.id }) else { return }
            
            let free = update.free
            let used = update.size - free
            self.usedField?.stringValue = DiskSize(used).getReadableMemory()
            self.freeField?.stringValue = DiskSize(free).getReadableMemory()
            
            self.circle?.setValue(update.percentage)
            self.bar?.setValue(ColorValue(update.percentage, color: update.percentage.usageColor()))
            
            self.uri = update.path
            
            self.initialized = true
        })
    }
    
    // The drive list and everything below it follows the selection, the usage summary and the history
    // chart at the top stay on the boot volume.
    internal func smartCallback(_ value: [physicalDrive]) {
        DispatchQueue.main.async(execute: {
            self.drives = value
            
            guard (self.window?.isVisible ?? false) || !self.initialized else { return }
            
            self.allDisks?.isHidden = value.isEmpty
            let external = value.filter({ !$0.isInternal }).count
            self.allDisks?.setSubtitle("\(value.count) \(localizedString("drives")) · \(external) \(localizedString("external"))")
            
            self.syncRows(value)
            self.renderSelection()
        })
    }
    
    private func syncRows(_ value: [physicalDrive]) {
        let ids = Set(value.map { $0.id })
        for id in Array(self.diskRows.keys) where !ids.contains(id) {
            guard let row = self.diskRows[id] else { continue }
            row.cells.forEach { $0.removeFromSuperview() }
            if let gridRow = row.gridRow {
                let index = self.disks.index(of: gridRow)
                if index != NSNotFound {
                    self.disks.removeRow(at: index)
                }
            }
            self.diskRows.removeValue(forKey: id)
        }
        
        value.forEach { d in
            if let row = self.diskRows[d.id] {
                row.update(d)
                return
            }
            
            let row = DriveRow(d)
            row.clickCallback = { [weak self] id in
                self?.select(id)
            }
            let isFirst = self.disks.numberOfRows == 0
            row.gridRow = self.disks.addRow(with: row.cells)
            if isFirst {
                self.disks.column(at: 0).xPlacement = .fill
            }
            self.diskRows[d.id] = row
        }
        
        // the hairline belongs to the row, not to a row of its own, otherwise the gaps around it
        // are dead space that swallows clicks
        let ordered = self.diskRows.values.compactMap { row -> (row: DriveRow, index: Int)? in
            guard let gr = row.gridRow else { return nil }
            let idx = self.disks.index(of: gr)
            return idx == NSNotFound ? nil : (row, idx)
        }.sorted(by: { $0.index < $1.index })
        ordered.enumerated().forEach { $0.element.row.showSeparator($0.offset != 0) }
    }
    
    private func select(_ id: String) {
        guard self.selectedDrive != id else { return }
        self.selectedDrive = id
        Store.shared.set(key: "\(self.module.stringValue)_preview_selected", value: id)
        self.renderSelection()
    }
    
    private func renderSelection() {
        // a drive can be unplugged while it is selected, fall back to the built in one
        var selected = self.drives.first(where: { $0.id == self.selectedDrive })
        if selected == nil {
            selected = self.drives.first(where: { $0.isInternal }) ?? self.drives.first
            self.selectedDrive = selected?.id ?? ""
        }
        
        self.diskRows.forEach { $0.value.setSelected($0.key == self.selectedDrive) }
        
        guard let d = selected else { return }
        
        self.modelValueField?.stringValue = d.model.isEmpty ? localizedString("Unknown") : d.model
        self.serialValueField?.stringValue = d.serial.isEmpty ? localizedString("Unknown") : d.serial
        self.capacityValueField?.stringValue = DiskSize(d.size).getReadableMemory()
        self.connectionTypeValueField?.stringValue = d.connectionType.isEmpty ? localizedString("Unknown") : d.connectionType
        self.bsdNameValueField?.stringValue = d.BSDName.isEmpty ? localizedString("Unknown") : d.BSDName
        
        self.readSpeedValueField?.stringValue = Units(bytes: d.activity.read).getReadableSpeed(base: self.base, unit: self.speedUnit)
        self.writeSpeedValueField?.stringValue = Units(bytes: d.activity.write).getReadableSpeed(base: self.base, unit: self.speedUnit)
        self.totalReadValueField?.stringValue = Units(bytes: d.activity.readBytes).getReadableMemory()
        self.totalWrittenValueField?.stringValue = Units(bytes: d.activity.writeBytes).getReadableMemory()
        
        guard let smart = d.smart else {
            [self.smartTotalReadValueField, self.smartTotalWrittenValueField, self.temperatureValueField,
             self.healthValueField, self.powerCyclesValueField, self.powerOnHoursValueField,
             self.criticalWarningValueField, self.availableSpareValueField, self.unsafeShutdownsValueField,
             self.mediaErrorsValueField].forEach {
                $0?.stringValue = localizedString("Unavailable")
                $0?.textColor = .textColor
            }
            return
        }
        
        self.smartTotalReadValueField?.toolTip = "\(smart.totalRead / (512 * 1000))"
        self.smartTotalWrittenValueField?.toolTip = "\(smart.totalWritten / (512 * 1000))"
        self.smartTotalReadValueField?.stringValue = Units(bytes: smart.totalRead).getReadableMemory()
        self.smartTotalWrittenValueField?.stringValue = Units(bytes: smart.totalWritten).getReadableMemory()
        
        self.temperatureValueField?.stringValue = "\(temperature(Double(smart.temperature)))"
        self.healthValueField?.stringValue = "\(smart.life)%"
        
        self.powerCyclesValueField?.stringValue = "\(smart.powerCycles)"
        self.powerOnHoursValueField?.stringValue = "\(smart.powerOnHours)"
        
        if let warning = smart.criticalWarning {
            let list = smartCriticalWarnings(warning)
            self.criticalWarningValueField?.stringValue = list.isEmpty ? localizedString("None") : list.joined(separator: ", ")
            self.criticalWarningValueField?.textColor = list.isEmpty ? .textColor : .systemRed
        } else {
            self.criticalWarningValueField?.stringValue = localizedString("Unavailable")
            self.criticalWarningValueField?.textColor = .textColor
        }
        
        if let spare = smart.availableSpare {
            self.availableSpareValueField?.stringValue = "\(spare)%"
            if let threshold = smart.spareThreshold {
                self.availableSpareValueField?.textColor = spare < threshold ? .systemRed : .textColor
                self.availableSpareValueField?.toolTip = "\(localizedString("Threshold")): \(threshold)%"
            }
        } else {
            self.availableSpareValueField?.stringValue = localizedString("Unavailable")
        }
        
        self.unsafeShutdownsValueField?.stringValue = smart.unsafeShutdowns.map { "\($0)" } ?? localizedString("Unavailable")
        
        if let mediaErrors = smart.mediaErrors {
            self.mediaErrorsValueField?.stringValue = "\(mediaErrors)"
            self.mediaErrorsValueField?.textColor = mediaErrors > 0 ? .systemRed : .textColor
        } else {
            self.mediaErrorsValueField?.stringValue = localizedString("Unavailable")
            self.mediaErrorsValueField?.textColor = .textColor
        }
    }
    
    internal func activityCallback(_ value: Disks) {
        guard let main = self.main, let update = value.first(where: { $0.uuid == main.id }) else {
            return
        }
        let read = update.activity.read
        let write = update.activity.write
        
        self.chart?.addValue(upload: Double(write), download: Double(read))
        
        self.readState?.toolTip = "Read: \(Units(bytes: read).getReadableSpeed(base: self.base, unit: self.speedUnit))"
        self.readState?.layer?.backgroundColor = read != 0 ? self.readColor.cgColor : NSColor.lightGray.withAlphaComponent(0.75).cgColor
        
        self.writeState?.toolTip = "Write: \(Units(bytes: write).getReadableSpeed(base: self.base, unit: self.speedUnit))"
        self.writeState?.layer?.backgroundColor = write != 0 ? self.writeColor.cgColor : NSColor.lightGray.withAlphaComponent(0.75).cgColor
    }
    @objc private func openDisk() {
        if let uri = self.uri, let finder = self.finder {
            NSWorkspace.shared.open([uri], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// One physical drive in the "All disks" list. The whole row is the selection target, so it lives in a
// single grid cell and lays its own columns out instead of leaning on the grid.
internal class DriveRow: NSView {
    public let id: String
    public var gridRow: NSGridRow?
    public var clickCallback: ((String) -> Void)? = nil
    
    private let nameField: NSTextField
    private let modelField: NSTextField
    private let healthField: NSTextField
    private let temperatureField: NSTextField
    private let bar: BarChartView = BarChartView(size: 6, horizontal: true)
    private let separator: NSView = NSView()
    
    private var selected: Bool = false
    
    public var cells: [NSView] { [self] }
    
    init(_ d: physicalDrive) {
        self.id = d.id
        
        self.nameField = LabelField(d.name, size: 11)
        self.nameField.font = .systemFont(ofSize: 11, weight: .semibold)
        self.nameField.textColor = .labelColor
        
        self.modelField = LabelField("", size: 10)
        self.modelField.textColor = .tertiaryLabelColor
        
        self.healthField = LabelField("", size: 10)
        self.healthField.alignment = .right
        
        self.temperatureField = ValueField("")
        self.temperatureField.font = .systemFont(ofSize: 12, weight: .regular)
        
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 34))
        
        self.wantsLayer = true
        self.layer?.cornerRadius = 4
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 34).isActive = true
        self.toolTip = "\(d.model) · \(d.serial)"
        
        let title = NSStackView()
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 1
        title.addArrangedSubview(self.nameField)
        title.addArrangedSubview(self.modelField)
        
        let health = NSStackView()
        health.orientation = .vertical
        health.alignment = .trailing
        health.spacing = 2
        health.addArrangedSubview(self.healthField)
        health.addArrangedSubview(self.bar)
        health.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.bar.widthAnchor.constraint(equalToConstant: 90).isActive = true
        self.bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        
        self.temperatureField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = Constants.Settings.margin
        container.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(title)
        container.addArrangedSubview(NSView())
        container.addArrangedSubview(health)
        container.addArrangedSubview(self.temperatureField)
        
        self.separator.wantsLayer = true
        self.separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        self.separator.translatesAutoresizingMaskIntoConstraints = false
        self.separator.isHidden = true
        
        self.addSubview(container)
        self.addSubview(self.separator)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            container.topAnchor.constraint(equalTo: self.topAnchor),
            container.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.separator.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            self.separator.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            self.separator.topAnchor.constraint(equalTo: self.topAnchor),
            self.separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        
        self.update(d)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = self.selected ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : NSColor.clear.cgColor
    }
    
    // the row is one click target, the labels inside must not swallow the event
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview = self.superview else { return nil }
        return self.bounds.contains(self.convert(point, from: superview)) ? self : nil
    }
    
    override func mouseDown(with event: NSEvent) {
        self.clickCallback?(self.id)
    }
    
    public func showSeparator(_ newValue: Bool) {
        guard self.separator.isHidden == newValue else { return }
        self.separator.isHidden = !newValue
    }
    
    public func setSelected(_ newValue: Bool) {
        guard self.selected != newValue else { return }
        self.selected = newValue
        self.needsDisplay = true
    }
    
    public func update(_ d: physicalDrive) {
        let model = "\(d.model) · \(DiskSize(d.size).getReadableMemory())"
        if self.modelField.stringValue != model {
            self.modelField.stringValue = model
        }
        
        guard let smart = d.smart else {
            self.healthField.stringValue = localizedString("Unavailable")
            self.temperatureField.stringValue = "-"
            self.bar.setValue(ColorValue(0))
            return
        }
        
        self.healthField.stringValue = "\(localizedString("Health")): \(smart.life)%"
        self.temperatureField.stringValue = temperature(Double(smart.temperature))
        self.temperatureField.textColor = smart.temperature >= 70 ? .systemRed : .textColor
        // the bar tracks the health, so a full bar is a healthy drive
        let life = Double(min(max(smart.life, 0), 100)) / 100
        self.bar.setValue(ColorValue(life, color: (1 - life).usageColor()))
    }
}

private class LegendView: NSStackView {
    private let size: Int64
    private var free: Int64
    private let id: String
    private var ready: Bool = false
    
    private var showUsedSpace: Bool {
        get { Store.shared.bool(key: "\(self.id)_preview_usedSpace", defaultValue: false) }
        set { Store.shared.set(key: "\(self.id)_preview_usedSpace", value: newValue) }
    }
    
    private var legendField: NSTextField? = nil
    
    public init(id: String, size: Int64, free: Int64) {
        self.id = id
        self.size = size
        self.free = free
        
        super.init(frame: .zero)
        self.toolTip = localizedString("Switch view")
        
        let legendField = TextView()
        legendField.font = NSFont.systemFont(ofSize: 11, weight: .light)
        legendField.stringValue = self.legend(free: free)
        legendField.cell?.truncatesLastVisibleLine = true
        
        self.addArrangedSubview(legendField)
        
        self.legendField = legendField
        
        let trackingArea = NSTrackingArea(
            rect: CGRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height),
            options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(free: Int64) {
        self.free = free
        
        if (self.window?.isVisible ?? false) || !self.ready {
            if let view = self.legendField {
                view.stringValue = self.legend(free: free)
            }
            self.ready = true
        }
    }
    
    private func legend(free: Int64) -> String {
        var value: String
        var percentage: Int
        
        if self.showUsedSpace {
            var usedSpace = self.size - free
            if usedSpace < 0 {
                usedSpace = 0
            }
            percentage = Int((Double(self.size - free) / Double(self.size)) * 100)
            value = localizedString("Used disk memory", DiskSize(usedSpace).getReadableMemory(), DiskSize(self.size).getReadableMemory())
        } else {
            percentage = Int((Double(free) / Double(self.size)).rounded(toPlaces: 2) * 100)
            value = localizedString("Free disk memory", DiskSize(free).getReadableMemory(), DiskSize(self.size).getReadableMemory())
        }
        
        value += " (\(percentage)%)"
        
        return value
    }
    
    override func mouseEntered(with: NSEvent) {
        NSCursor.pointingHand.set()
    }
    
    override func mouseExited(with: NSEvent) {
        NSCursor.arrow.set()
    }
    
    override func mouseDown(with: NSEvent) {
        self.showUsedSpace = !self.showUsedSpace
        
        if let view = self.legendField {
            view.stringValue = self.legend(free: self.free)
        }
    }
}
