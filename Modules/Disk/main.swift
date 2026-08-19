//
//  main.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 07/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import WidgetKit

public struct stats: Codable {
    var read: Int64 = 0
    var write: Int64 = 0
    
    var readBytes: Int64 = 0
    var writeBytes: Int64 = 0
}

public struct smart_t: Codable {
    var temperature: Int = 0
    var life: Int = 0
    var totalRead: Int64 = 0
    var totalWritten: Int64 = 0
    var powerCycles: Int = 0
    var powerOnHours: Int = 0
    var criticalWarning: Int? = nil
    var availableSpare: Int? = nil
    var spareThreshold: Int? = nil
    var unsafeShutdowns: Int? = nil
    var mediaErrors: Int64? = nil
}

internal func smartCriticalWarnings(_ value: Int) -> [String] {
    var list: [String] = []
    if value & 0x01 != 0 { list.append(localizedString("Spare below threshold")) }
    if value & 0x02 != 0 { list.append(localizedString("Temperature out of range")) }
    if value & 0x04 != 0 { list.append(localizedString("Reliability degraded")) }
    if value & 0x08 != 0 { list.append(localizedString("Read-only mode")) }
    if value & 0x10 != 0 { list.append(localizedString("Backup failed")) }
    return list
}

public struct physicalDrive: Codable {
    var serial: String = ""
    var model: String = ""
    var BSDName: String = ""
    
    var size: Int64 = 0
    var isInternal: Bool = true
    var removable: Bool = false
    var connectionType: String = ""
    
    // topology, used to derive a stable bay number inside an enclosure
    var enclosure: String = ""
    var slotPath: [Int] = []
    var slot: Int = 0
    
    var smart: smart_t? = nil
    var activity: stats = stats()
    
    // BSD names of every IOMedia living on this device, mounted or not
    var media: [String] = []
    
    public var id: String {
        self.serial.isEmpty ? self.BSDName : self.serial
    }
    
    public var name: String {
        if self.isInternal { return localizedString("Internal") }
        return "\(localizedString("Drive")) \(self.slot)"
    }
    
    public var popupState: Bool {
        Store.shared.bool(key: "Disk_physical_\(self.id)_popup", defaultValue: true)
    }
    public var temperatureState: Bool {
        Store.shared.bool(key: "Disk_physical_\(self.id)_temperature", defaultValue: false)
    }
    public var lifeState: Bool {
        Store.shared.bool(key: "Disk_physical_\(self.id)_life", defaultValue: false)
    }
}

// A volume can be spread over several drives. Reporting the hottest and the most worn of them keeps
// the volume level numbers honest instead of silently picking whichever member came back first.
internal func aggregateSMART(_ list: [physicalDrive]) -> smart_t? {
    let values = list.compactMap({ $0.smart })
    guard !values.isEmpty else { return nil }
    guard values.count > 1 else { return values[0] }
    
    let warnings = values.compactMap({ $0.criticalWarning })
    let shutdowns = values.compactMap({ $0.unsafeShutdowns })
    let errors = values.compactMap({ $0.mediaErrors })
    
    return smart_t(
        temperature: values.map({ $0.temperature }).max() ?? 0,
        life: values.map({ $0.life }).min() ?? 0,
        totalRead: values.reduce(0, { $0 + $1.totalRead }),
        totalWritten: values.reduce(0, { $0 + $1.totalWritten }),
        powerCycles: values.map({ $0.powerCycles }).max() ?? 0,
        powerOnHours: values.map({ $0.powerOnHours }).max() ?? 0,
        criticalWarning: warnings.isEmpty ? nil : warnings.reduce(0, { $0 | $1 }),
        availableSpare: values.compactMap({ $0.availableSpare }).min(),
        spareThreshold: values.compactMap({ $0.spareThreshold }).max(),
        unsafeShutdowns: shutdowns.isEmpty ? nil : shutdowns.reduce(0, +),
        mediaErrors: errors.isEmpty ? nil : errors.reduce(0, +)
    )
}

public struct drive: Codable {
    var parent: io_object_t = 0
    
    var uuid: String = ""
    var mediaName: String = ""
    var BSDName: String = ""
    
    var root: Bool = false
    var removable: Bool = false
    
    var model: String = ""
    var path: URL?
    var connectionType: String = ""
    var fileSystem: String = ""
    var writable: Bool = true
    var encrypted: Bool = false
    
    var size: Int64 = 1
    var free: Int64 = 0
    
    var activity: stats = stats()
    var smart: smart_t? = nil
    
    public var percentage: Double {
        let total = self.size
        let free = self.free
        var usedSpace = total - free
        if usedSpace < 0 {
            usedSpace = 0
        }
        if total == 0 {
            return 0
        }
        return Double(usedSpace) / Double(total)
    }
    
    public var popupState: Bool {
        Store.shared.bool(key: "Disk_\(self.uuid)_popup", defaultValue: true)
    }
    
    public func remote() -> String {
        return "\(self.uuid),\(self.size),\(self.size-self.free),\(self.free),\(self.activity.read),\(self.activity.write)"
    }
}

public class Disks: Codable, RemoteType {
    private var queue: DispatchQueue = DispatchQueue(label: "zone.lyl.stats.Disk.SynchronizedArray")
    private var _array: [drive] = []
    public var array: [drive] {
        get { self.queue.sync { self._array } }
        set { self.queue.sync { self._array = newValue } }
    }
    
    enum CodingKeys: String, CodingKey {
        case array
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.array = try container.decode(Array<drive>.self, forKey: CodingKeys.array)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(array, forKey: .array)
    }
    
    init() {}
    
    public var count: Int {
        self.queue.sync { self._array.count }
    }
    
    public func first(where predicate: (drive) -> Bool) -> drive? {
        return self.array.first(where: predicate)
    }
    
    public func index(where predicate: (drive) -> Bool) -> Int? {
        return self.array.firstIndex(where: predicate)
    }
    
    public func map<ElementOfResult>(_ transform: (drive) -> ElementOfResult?) -> [ElementOfResult] {
        return self.array.compactMap(transform)
    }
    
    public func filter(where isIncluded: (drive) -> Bool) -> [drive] {
        return self.array.filter(isIncluded)
    }
    
    public func reversed() -> [drive] {
        return self.array.reversed()
    }
    
    func forEach(_ body: (drive) -> Void) {
        self.array.forEach(body)
    }
    
    public func append( _ element: drive) {
        if !self.array.contains(where: {$0.BSDName == element.BSDName}) {
            self.array.append(element)
        }
    }
    
    public func remove(at index: Int) {
        self.array.remove(at: index)
    }
    
    public func sort() {
        self.array.sort{ $1.removable }
    }
    
    func updateFreeSize(_ idx: Int, newValue: Int64) {
        self.array[idx].free = newValue
    }
    
    func updateReadWrite(_ idx: Int, read: Int64, write: Int64) {
        self.array[idx].activity.readBytes = read
        self.array[idx].activity.writeBytes = write
    }
    
    func updateRead(_ idx: Int, newValue: Int64) {
        self.array[idx].activity.read = newValue
    }
    
    func updateWrite(_ idx: Int, newValue: Int64) {
        self.array[idx].activity.write = newValue
    }
    
    func updateSMARTData(_ idx: Int, smart: smart_t?) {
        self.array[idx].smart = smart
    }
    
    public func remote() -> Data? {
        let arr = self.array.filter({ !$0.removable })
        var string = "\(arr.count),"
        for (i, v) in arr.enumerated() {
            string += v.remote()
            if i != self.array.count {
                string += ","
            }
        }
        string += "$"
        return string.data(using: .utf8)
    }
}

public struct Disk_process: Process_p, Codable {
    public var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(ModuleType.disk.stringValue)_base", defaultValue: "byte")) ?? .byte
    }
    public var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(ModuleType.disk.stringValue)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }
    
    public var pid: Int
    public var name: String
    public var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid_t(self.pid)) {
            return app.icon ?? Constants.defaultProcessIcon
        }
        return Constants.defaultProcessIcon
    }
    
    var read: Int
    var write: Int
    
    init(pid: Int, name: String, read: Int, write: Int) {
        self.pid = pid
        self.name = name
        self.read = read
        self.write = write
        
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if let name = app.localizedName {
                self.name = name
            }
        }
    }
}

public class Disk: Module {
    private let popupView: Popup = Popup(.disk)
    private let settingsView: Settings = Settings(.disk)
    private let portalView: Portal = Portal(.disk, height: 120)
    private let notificationsView: Notifications = Notifications(.disk)
    private let previewView: Preview = Preview(.disk)
    
    private var capacityReader: CapacityReader?
    private var activityReader: ActivityReader?
    private var processReader: ProcessReader?
    private var smartReader: SMARTReader?
    
    private let physicalQueue: DispatchQueue = DispatchQueue(label: "zone.lyl.stats.Disk.physical")
    private var _physical: [physicalDrive] = []
    private var physical: [physicalDrive] {
        get { self.physicalQueue.sync { self._physical } }
        set { self.physicalQueue.sync { self._physical = newValue } }
    }
    
    private var selectedDisk: String = ""
    
    private var driveMiniTooltip: String = ""
    private var stackTooltip: String = ""
    
    private var smartDrive: String {
        Store.shared.string(key: "\(self.name)_smartDrive", defaultValue: "")
    }
    private var smartValue: String {
        Store.shared.string(key: "\(self.name)_smartValue", defaultValue: "temperature")
    }
    
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$capacity.free/$capacity.total")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    private var mainColor: NSColor {
        SColor.fromString(Store.shared.string(key: "\(self.name)_mainColor", defaultValue: SColor.secondBlue.key)).additional as! NSColor
    }
    
    public init() {
        super.init(
            moduleType: .disk,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.capacityReader = CapacityReader(.disk) { [weak self] value in
            if let value {
                self?.capacityCallback(value)
            }
        }
        self.activityReader = ActivityReader(.disk) { [weak self] value in
            if let value {
                self?.activityCallback(value)
            }
        }
        self.processReader = ProcessReader(.disk) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        self.smartReader = SMARTReader(.disk) { [weak self] value in
            if let value {
                self?.smartCallback(value)
            }
        }
        
        self.selectedDisk = Store.shared.string(key: "\(ModuleType.disk.stringValue)_disk", defaultValue: self.selectedDisk)
        
        self.settingsView.selectedDiskHandler = { [weak self] value in
            self?.selectedDisk = value
            self?.capacityReader?.read()
        }
        self.settingsView.callback = { [weak self] in
            self?.capacityReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.capacityReader?.setInterval(value)
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async {
                self?.processReader?.read()
            }
        }
        
        self.setReaders([self.capacityReader, self.activityReader, self.processReader, self.smartReader])
    }
    
    private func smartCallback(_ value: [physicalDrive]) {
        self.physical = value
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.smartCallback(value)
            self.previewView.smartCallback(value)
        })
        self.settingsView.setPhysicalList(value)
        
        // whichever drive the drive mini is pointed at, falling back to the built in one
        let selected = value.first(where: { $0.id == self.smartDrive })
            ?? value.first(where: { $0.isInternal })
            ?? value.first
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini where w.type == .driveMini:
                guard let d = selected else { return }
                self.setToolTip("\(d.name) - \(d.model)", of: widget, cache: &self.driveMiniTooltip)
                guard let smart = d.smart else { return }
                switch self.smartValue {
                case "life":
                    widget.setValue(Double(smart.life)/100)
                    widget.setSuffix("%")
                default:
                    // Mini renders value*100, so hand it the localised reading scaled down
                    let local = Double(temperature(Double(smart.temperature)).digits) ?? Double(smart.temperature)
                    widget.setValue(local/100)
                    widget.setSuffix("°")
                }
            case let widget as StackWidget:
                var list: [Stack_t] = []
                value.forEach { (d: physicalDrive) in
                    guard let smart = d.smart else { return }
                    if d.temperatureState {
                        list.append(Stack_t(
                            key: "\(d.id)_temperature",
                            value: temperature(Double(smart.temperature)),
                            label: "\(d.name) - \(localizedString("Temperature"))"
                        ))
                    }
                    if d.lifeState {
                        list.append(Stack_t(
                            key: "\(d.id)_life",
                            value: "\(smart.life)%",
                            label: "\(d.name) - \(localizedString("Health"))"
                        ))
                    }
                }
                widget.setValues(list)
                self.setToolTip(list.map({ "\($0.label ?? $0.key): \($0.value)" }).joined(separator: "\n"), of: widget, cache: &self.stackTooltip)
            default: break
            }
        }
    }
    
    private func setToolTip(_ value: String, of widget: NSView, cache: inout String) {
        guard cache != value else { return }
        cache = value
        DispatchQueue.main.async {
            widget.toolTip = value.isEmpty ? nil : value
        }
    }
    
    private func capacityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        let drives = self.physical
        if !drives.isEmpty {
            value.array.enumerated().forEach { (i: Int, v: drive) in
                value.updateSMARTData(i, smart: aggregateSMART(drives.filter({ $0.media.contains(v.BSDName) })))
            }
        }
        
        DispatchQueue.main.async(execute: {
            self.popupView.capacityCallback(value)
            self.previewView.capacityCallback(value)
        })
        self.settingsView.setList(value)
        
        guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
            return
        }
        
        self.portalView.utilizationCallback(d)
        self.notificationsView.utilizationCallback(d.percentage)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini where w.type == .mini: widget.setValue(d.percentage)
            case let widget as BarChart: widget.setValue([[ColorValue(d.percentage)]])
            case let widget as MemoryWidget:
                widget.setValue((DiskSize(d.free).getReadableMemory(), DiskSize(d.size - d.free).getReadableMemory()), usedPercentage: d.percentage)
            case let widget as PieChart:
                widget.setValue([
                    ColorValue(d.percentage, color: self.mainColor)
                ])
            case let widget as TextWidget:
                var text = "\(self.textValue)"
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$capacity":
                        switch pair.value {
                        case "total": replacement = DiskSize(d.size).getReadableMemory()
                        case "used": replacement = DiskSize(d.size - d.free).getReadableMemory()
                        case "free": replacement = DiskSize(d.free).getReadableMemory()
                        default: return
                        }
                    case "$smart":
                        guard let smart = d.smart else { return }
                        switch pair.value {
                        case "temperature": replacement = temperature(Double(smart.temperature))
                        case "life": replacement = "\(smart.life)%"
                        default: return
                        }
                    case "$percentage":
                        var percentage: Int
                        if d.size == 0 {
                            percentage = 0
                        } else {
                            switch pair.value {
                            case "used": percentage = Int((Double(d.size - d.free) / Double(d.size)) * 100)
                            case "free": percentage = Int((Double(d.free) / Double(d.size)) * 100)
                            default: return
                            }
                        }
                        replacement = "\(percentage < 0 ? 0 : percentage)%"
                    default: return
                    }
                    
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            if isWidgetActive(self.userDefaults, [Disk_entry.kind, "UnitedWidget"]), let blobData = try? JSONEncoder().encode(d) {
                self.userDefaults?.set(blobData, forKey: "Disk@CapacityReader")
            }
            WidgetCenter.shared.reloadTimelines(ofKind: Disk_entry.kind)
            WidgetCenter.shared.reloadTimelines(ofKind: "UnitedWidget")
        }
    }
    
    private func activityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.activityCallback(value)
            self.previewView.activityCallback(value)
        })
        
        guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
            return
        }
        
        self.portalView.activityCallback(d)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as SpeedWidget: 
                widget.setValue(input: d.activity.read, output: d.activity.write)
            case let widget as NetworkChart:
                widget.setValue(upload: Double(d.activity.write), download: Double(d.activity.read))
                if self.capacityReader?.interval != 1 {
                    self.settingsView.setUpdateInterval(value: 1)
                }
            default: break
            }
        }
    }
}
