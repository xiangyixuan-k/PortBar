import AppKit
import SwiftUI
import IOKit
import IOKit.ps
import ServiceManagement
import Darwin

struct HardwareProfile {
    let model: String
    var name: String {
        for (prefix, name) in [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"), ("iMacPro", "iMac Pro"), ("iMac", "iMac"), ("Macmini", "Mac mini"), ("MacStudio", "Mac Studio"), ("MacPro", "Mac Pro")] {
            if model.hasPrefix(prefix) { return name }
        }
        return "Mac"
    }
    static let current: HardwareProfile = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return HardwareProfile(model: "Mac") }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return HardwareProfile(model: "Mac") }
        return HardwareProfile(model: String(cString: bytes))
    }()
}

struct PublicPower {
    var battery: Int?
    var hasBattery = false
    var charging: Bool?
    var external: Bool?
    var watts: Int?
    static func read() -> PublicPower {
        var result = PublicPower()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
                if type == kIOPSACPowerValue { result.external = true }
                else if type == kIOPSBatteryPowerValue { result.external = false }
            }
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                result.hasBattery = true; result.charging = Registry.bool(d, kIOPSIsChargingKey)
                if let current = Registry.int(d, kIOPSCurrentCapacityKey), let maximum = Registry.int(d, kIOPSMaxCapacityKey), maximum > 0 {
                    result.battery = min(100, max(0, current * 100 / maximum))
                }
            }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            result.watts = Registry.int(adapter, "Watts")
        }
        return result
    }
}

final class LoginLaunch: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?
    var requested: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        error = nil; refresh()
        do {
            if enabled && status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            else if !enabled && status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
        refresh()
    }
    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}

// Registry fields are driver supplied. Missing fields stay unknown.
struct Registry {
    static func entries(_ match: [String: Any]) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match as CFDictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = properties?.takeRetainedValue() as? [String: Any] { result.append(properties) }
            IOObjectRelease(entry)
        }
        return result
    }
    static func property(_ name: String, _ value: Any) -> [[String: Any]] {
        entries(["IOPropertyMatch": [name: value]])
    }
    static func bool(_ d: [String: Any], _ key: String) -> Bool? { (d[key] as? NSNumber)?.boolValue }
    static func int(_ d: [String: Any], _ key: String) -> Int? { (d[key] as? NSNumber)?.intValue }
}

enum PortState: String, Codable { case idle, connected, power, attention, unknown
    var label: String {
        switch self { case .idle: return "未连接"; case .connected: return "已连接"; case .power: return "供电中"; case .attention: return "待授权"; case .unknown: return "不可读" }
    }
    var color: Color {
        switch self { case .idle: return .secondary; case .connected: return .green; case .power: return .blue; case .attention: return .orange; case .unknown: return .secondary }
    }
    var active: Bool { self == .connected || self == .power || self == .attention }
}

struct Port: Identifiable, Equatable, Codable {
    var id: String
    var title: String
    var symbol: String
    var state: PortState = .unknown
    var detail: String = "系统未提供接口状态"
    var speed: String = ""
}
struct Snapshot: Equatable, Codable {
    var deviceName = HardwareProfile.current.name
    var hasBattery = false
    var portDetailAvailable = true
    var ports: [Port]
    var battery: Int?
    var external: Bool?
    var charging: Bool?
    var watts: Int?
    var inputWatts: Double?
    var connectedCount: Int { ports.filter { $0.state.active }.count }
    var powerTitle: String {
        guard let external else { return "电源状态不可读" }
        if !external { return "使用电池" }
        if !hasBattery { return "已接通电源" }
        if charging == true { return "正在充电" }
        if (battery ?? 0) >= 100 { return "电池已充满" }
        return charging == true ? "正在充电" : "已接通电源"
    }
    static func read() -> Snapshot {
        let battery = Registry.entries(["IOProviderClass": "AppleSmartBattery"]).first ?? [:]
        return parse(battery: battery, allRoots: Registry.property("BuiltIn", true),
                     allTransports: Registry.property("ParentPortBuiltIn", true),
                     allPower: Registry.entries(["IOProviderClass": "IOPortFeaturePowerIn"]),
                     publicPower: PublicPower.read(), usbDevices: Registry.entries(["IOProviderClass": "IOUSBHostDevice"]))
    }
    static func parse(battery: [String: Any], allRoots: [[String: Any]], allTransports: [[String: Any]], allPower: [[String: Any]],
                      publicPower: PublicPower = PublicPower(), usbDevices: [[String: Any]] = [],
                      profile: HardwareProfile = .current, externalDisplays: [Port]? = nil) -> Snapshot {
        let external = Registry.bool(battery, "ExternalConnected") ?? publicPower.external
        let adapter = battery["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        var ports: [Port] = []
        var seen = Set<String>()
        let catalog = allRoots.filter {
            guard Registry.int($0, "PortType") != nil, Registry.int($0, "PortNumber") != nil,
                  Registry.bool($0, "BuiltIn") == true, $0["PortTypeDescription"] as? String != nil else { return false }
            let key = "\(Registry.int($0, "PortType")!):\(Registry.int($0, "PortNumber")!)"
            return seen.insert(key).inserted
        }.sorted {
            let a = Registry.int($0, "PortType") ?? 0, b = Registry.int($1, "PortType") ?? 0
            return a == b ? (Registry.int($0, "PortNumber") ?? 0) < (Registry.int($1, "PortNumber") ?? 0) : a < b
        }
        let definitions: [(String, String, Int, Int, String)] = catalog.map { root in
            let type = Registry.int(root, "PortType")!, number = Registry.int(root, "PortNumber")!
            let description = root["PortTypeDescription"] as? String ?? "接口"
            let name = description.contains("SD") ? "SD 卡" : description.hasPrefix("MagSafe") ? "MagSafe" : description
            let count = catalog.filter { Registry.int($0, "PortType") == type }.count
            let title = count > 1 ? "\(name) \(number)" : name
            let symbol = description.contains("USB") ? "cable.connector" : description.contains("SD") ? "sdcard" : description.contains("HDMI") || description.contains("Display") ? "display" : description.contains("MagSafe") || description.contains("Power") ? "powerplug" : description.contains("Ethernet") ? "network" : description.contains("Audio") ? "headphones" : "point.3.connected.trianglepath.dotted"
            return ("\(type):\(number)", title, type, number, symbol)
        }
        for (id, title, type, number, symbol) in definitions {
            var port = Port(id: id, title: title, symbol: symbol)
            let roots = allRoots.filter {
                Registry.int($0, "PortType") == type && Registry.int($0, "PortNumber") == number
            }
            let transports = allTransports.filter {
                Registry.int($0, "ParentBuiltInPortType") == type && Registry.int($0, "ParentBuiltInPortNumber") == number && $0["TransportTypeDescription"] != nil
            }
            let power = allPower.filter {
                Registry.int($0, "ParentPortType") == type && Registry.int($0, "ParentPortNumber") == number && Registry.int($0, "FeatureType") == 3
            }
            if let root = roots.first, let connected = Registry.bool(root, "ConnectionActive") {
                port.state = connected ? .connected : .idle
                port.detail = connected ? "连接已建立" : "等待连接"
                if type == 11 {
                    let present = Registry.bool(root, "Card Present") ?? connected
                    port.state = present ? .connected : .idle
                    port.detail = present ? "SD 卡已插入" : "卡槽空闲"
                }
                if connected {
                    let active = transports.filter { Registry.bool($0, "Active") == true }
                    let products = Array(Set(active.compactMap { $0["Product"] as? String })).sorted()
                    let data = active.filter { ($0["TransportTypeDescription"] as? String) != "CC" }
                    if !products.isEmpty { port.detail = products.joined(separator: "、") }
                    else if type == 2 && data.isEmpty { port.detail = "线缆已连接 · 无数据链路" }
                    else if type == 17 { port.detail = "磁吸充电线已连接" }
                    else if type == 6 { port.detail = "显示链路已连接" }
                    let rates = data.compactMap { ($0["DataRateDescription"] ?? $0["LinkRateDescription"]) as? String }
                        .filter { $0 != "None" && $0 != "No Link" }
                        .map { $0.components(separatedBy: " (").first ?? $0 }
                    port.speed = Array(Set(rates)).sorted().joined(separator: " · ")
                    let pending = Registry.bool(root, "AuthorizationPending") == true || Registry.bool(root, "UserAuthorizationPending") == true
                    let unauthorized = (root["TransportsUnauthorized"] as? [String] ?? []).contains { $0 != "CC" }
                    if pending || unauthorized {
                        port.state = .attention; port.detail = "请在系统提示中允许配件连接"
                    }
                    if power.contains(where: { Registry.bool($0, "Active") == true }) {
                        port.state = .power; port.detail = "正在为 Mac 供电"
                    }
                }
            }
            ports.append(port)
        }
        if catalog.isEmpty {
            ports = fallbackUSB(usbDevices)
            ports += externalDisplays ?? displayConnections()
        }
        let hasBattery = publicPower.hasBattery || Registry.int(battery, "CurrentCapacity") != nil || profile.model.hasPrefix("MacBook")
        let batteryPercent: Int?
        if let current = Registry.int(battery, "CurrentCapacity"), let maximum = Registry.int(battery, "MaxCapacity"), maximum > 0 {
            batteryPercent = min(100, max(0, current * 100 / maximum))
        } else { batteryPercent = publicPower.battery }
        return Snapshot(deviceName: profile.name, hasBattery: hasBattery, portDetailAvailable: !catalog.isEmpty,
                        ports: ports, battery: batteryPercent, external: external,
                        charging: Registry.bool(battery, "IsCharging") ?? publicPower.charging,
                        watts: external == true ? (Registry.int(adapter, "Watts") ?? publicPower.watts) : nil,
                        inputWatts: external == true ? Registry.int(telemetry, "SystemPowerIn").map { Double($0) / 1000 } : nil)
    }
    static func fallbackUSB(_ devices: [[String: Any]]) -> [Port] {
        devices.enumerated().compactMap { index, d in
            let name = d["USB Product Name"] as? String ?? "USB 设备"
            if Registry.bool(d, "BuiltIn") == true { return nil }
            let internalNames = ["Apple Internal", "Internal ", "FaceTime", "iSight", "Touch Bar", "Apple T2"]
            if internalNames.contains(where: { name.hasPrefix($0) }) { return nil }
            let location = Registry.int(d, "locationID") ?? index
            return Port(id: "usb-device:\(location):\(index)", title: "USB 设备", symbol: "externaldrive", state: .connected, detail: name)
        }
    }
    static func displayConnections() -> [Port] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.enumerated().map { index, display in
            Port(id: "display:\(display)", title: "外接显示器 \(index + 1)", symbol: "display", state: .connected,
                 detail: "\(CGDisplayPixelsWide(display)) × \(CGDisplayPixelsHigh(display))")
        }
    }
    static func demo(desktop: Bool = false) -> Snapshot {
        if desktop {
            return Snapshot(deviceName: "Mac mini", hasBattery: false, portDetailAvailable: true, ports: [
                Port(id: "a1", title: "USB-A 1", symbol: "cable.connector", state: .connected, detail: "键盘"),
                Port(id: "a2", title: "USB-A 2", symbol: "cable.connector", state: .idle, detail: "等待连接"),
                Port(id: "c1", title: "USB-C 1", symbol: "cable.connector", state: .connected, detail: "移动硬盘", speed: "10 Gbps"),
                Port(id: "c2", title: "USB-C 2", symbol: "cable.connector", state: .idle, detail: "等待连接"),
                Port(id: "hdmi", title: "HDMI", symbol: "display", state: .connected, detail: "外接显示器"),
                Port(id: "ethernet", title: "Ethernet", symbol: "network", state: .unknown, detail: "系统未提供接口状态")
            ], battery: nil, external: true, charging: nil, watts: nil, inputWatts: nil)
        }
        return Snapshot(deviceName: "MacBook Pro", hasBattery: true, portDetailAvailable: true, ports: [
            Port(id: "c1", title: "USB-C 1", symbol: "cable.connector", state: .power, detail: "正在为 Mac 供电"),
            Port(id: "c2", title: "USB-C 2", symbol: "cable.connector", state: .connected, detail: "扩展坞", speed: "5 Gbps"),
            Port(id: "c3", title: "USB-C 3", symbol: "cable.connector", state: .connected, detail: "移动硬盘", speed: "10 Gbps"),
            Port(id: "sd", title: "SD 卡", symbol: "sdcard", state: .idle, detail: "卡槽空闲"),
            Port(id: "hdmi", title: "HDMI", symbol: "display", state: .connected, detail: "4K 显示器"),
            Port(id: "magsafe", title: "MagSafe", symbol: "powerplug", state: .idle, detail: "等待连接")
        ], battery: 76, external: true, charging: true, watts: 67, inputWatts: 24.6)
    }
}

// Driver messages are best effort; the one-second sampler covers missing messages.
final class HardwareEvents {
    private var port: IONotificationPortRef?
    private var matchingTokens: [io_iterator_t] = []
    private var interestTokens: [io_object_t] = []
    private var powerSource: CFRunLoopSource?
    private let changed: () -> Void
    var matchingCount: Int { matchingTokens.count }
    var interestCount: Int { interestTokens.count }
    var watchesPower: Bool { powerSource != nil }

    init(changed: @escaping () -> Void) {
        self.changed = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        for serviceClass in ["IOUSBHostDevice", "IOThunderboltNub", "IOMedia"] {
            for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port, event, IOServiceMatching(serviceClass), { context, iterator in
                    let count = HardwareEvents.drain(iterator)
                    if count > 0, let context {
                        Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().changed()
                    }
                }, context, &iterator)
                if result == KERN_SUCCESS {
                    matchingTokens.append(iterator)
                    // Empty the initial iterator to arm it, without inventing a plug event.
                    _ = HardwareEvents.drain(iterator)
                } else if iterator != 0 { IOObjectRelease(iterator) }
            }
        }
        var iterator: io_iterator_t = 0
        let match = ["IOPropertyMatch": ["BuiltIn": true]] as CFDictionary
        if IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                let type = IORegistryEntryCreateCFProperty(service, "PortType" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                guard type != nil else { continue }
                var token: io_object_t = 0
                let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, _, _ in
                    guard let context else { return }
                    Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().changed()
                }, context, &token)
                if result == KERN_SUCCESS { interestTokens.append(token) }
                else if token != 0 { IOObjectRelease(token) }
            }
        }
    }
    private static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { return count }
            count += 1; IOObjectRelease(service)
        }
    }
    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        for token in interestTokens { IOObjectRelease(token) }
        for token in matchingTokens { IOObjectRelease(token) }
        if let port { IONotificationPortDestroy(port) }
    }
}

final class Monitor: ObservableObject {
    @Published var snapshot: Snapshot
    @Published var updated = Date()
    var onChange: (() -> Void)?
    var expanded = false
    private var timer: Timer?
    private var busy = false
    private var pending = false
    private var sleeping = false
    private var hardware: HardwareEvents?
    private var eventTask: DispatchWorkItem?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private let reader: () -> Snapshot
    private(set) var completedReads = 0
    private(set) var lastReadMilliseconds: Double = 0
    init(reader: @escaping () -> Snapshot = Snapshot.read) {
        self.reader = reader; snapshot = reader()
    }
    func start(observeHardware: Bool = true) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.1
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        if observeHardware {
            hardware = HardwareEvents { [weak self] in self?.hardwareChanged() }
            let workspace = NSWorkspace.shared.notificationCenter
            observations.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = true; self?.pending = false; self?.eventTask?.cancel()
            }))
            observations.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = false; self?.refresh()
            }))
            let center = NotificationCenter.default
            observations.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.hardwareChanged() }))
        }
    }
    func hardwareChanged() {
        guard !sleeping else { return }
        eventTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.refresh() }
        eventTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }
    func stop() {
        timer?.invalidate(); timer = nil
        eventTask?.cancel(); eventTask = nil
        pending = false; hardware = nil
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
    }
    func refresh() {
        guard !sleeping else { return }
        guard !busy else { pending = true; return }; busy = true
        DispatchQueue.global(qos: .utility).async {
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = self.reader()
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            DispatchQueue.main.async {
                self.busy = false; self.completedReads += 1; self.lastReadMilliseconds = milliseconds
                if self.snapshot != snapshot {
                    let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    withAnimation(reduced ? nil : .easeInOut(duration: 0.22)) { self.snapshot = snapshot }
                    self.onChange?()
                }
                self.updated = Date()
                if self.pending { self.pending = false; self.refresh() }
            }
        }
    }
    deinit { stop() }
}

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PortRow: View {
    let port: Port
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: port.symbol).font(.system(size: 19, weight: .medium))
                .foregroundStyle(port.state.active ? port.state.color : .secondary)
                .frame(width: 38, height: 38)
                .background(port.state.active ? port.state.color.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(port.title).font(.system(size: 13, weight: .semibold))
                Text(port.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .help(port.detail)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(port.state.color).frame(width: 5, height: 5)
                    Text(port.state.label).font(.system(size: 11, weight: .medium))
                }.foregroundStyle(port.state.color)
                if !port.speed.isEmpty {
                    Text(port.speed).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help("协商链路速率：\(port.speed)；并非实时传输速度")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(hover ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.035), lineWidth: 0.5))
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
}

struct PortsView: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var login = LoginLaunch()
    @State private var showInfo = false
    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PortBar").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("\(s.deviceName) · 连接总览").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(s.connectedCount > 0 ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text("\(s.connectedCount) 已连接").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }.padding(.horizontal, 10).padding(.vertical, 7).background(.quaternary.opacity(0.6), in: Capsule())
            }
            HStack(spacing: 12) {
                Image(systemName: s.hasBattery ? (s.external == true ? "bolt.batteryblock" : "battery.100percent") : "powerplug")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(s.external == true ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.powerTitle).font(.system(size: 13, weight: .semibold))
                    Text(s.watts.map { "电源适配器 · 额定 \($0) W" } ?? (s.external == false ? "电源适配器未接入" : s.hasBattery ? "适配器功率未提供" : s.external == true ? "使用外接电源" : "系统未提供电源信息"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let watts = s.inputWatts {
                        Text(String(format: "系统输入约 %.1f W", watts)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("系统报告的输入功率，包含电脑运行和电池充电的用电")
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    if s.hasBattery {
                      Text(s.battery.map { "\($0)%" } ?? "—").font(.system(size: 25, weight: .light, design: .rounded)).monospacedDigit()
                    } else {
                      Image(systemName: s.external == true ? "checkmark.circle" : "questionmark.circle")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                    }
                    if s.hasBattery, let battery = s.battery {
                        Capsule().fill(Color.primary.opacity(0.08)).frame(width: 46, height: 3)
                            .overlay(alignment: .leading) { Capsule().fill(Color.green).frame(width: 46 * CGFloat(min(100,max(0,battery))) / 100, height: 3) }
                    }
                }
            }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
            ScrollView(.vertical, showsIndicators: true) {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(s.portDetailAvailable ? "接口状态" : "系统识别的连接").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(s.portDetailAvailable ? "按系统编号" : "设备视图").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 3)
                ForEach(s.ports) { PortRow(port: $0) }
                if !s.portDetailAvailable {
                    Text(s.ports.isEmpty ? "尚未识别到外接设备。连接 USB 设备或显示器后，这里会自动更新。此机型未提供逐接口状态。" : "此机型未提供逐接口状态，当前显示系统识别的 USB 设备与外接显示器。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
                }
            }
            if showInfo {
                Text("约每秒采样，插拔与供电事件触发额外刷新。接口列表按系统可提供的数据自动适配；编号不代表已校准的物理位置。连接状态不能诊断物理损坏。链路速率不等于实时传输速度；系统输入功率包含电脑运行用电。读数以系统更新时间为准。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("登录时启动", isOn: Binding(get: { login.requested }, set: { login.setEnabled($0) }))
                    .toggleStyle(.switch).font(.system(size: 12, weight: .medium))
                if login.status == .requiresApproval {
                    HStack {
                        Text("需要在系统设置中允许自启").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button("前往设置") { SMAppService.openSystemSettingsLoginItems() }.font(.system(size: 10))
                    }
                } else if let error = login.error {
                    Text("自启设置未完成：\(error)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    Text("开启后，登录 Mac 时自动运行").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Text("实时 · \(monitor.updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 0)
                Button { withAnimation(.easeInOut(duration: 0.2)) { showInfo.toggle() } } label: { Image(systemName: "info.circle") }
                    .help("状态说明").accessibilityLabel("状态说明")
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新").accessibilityLabel("刷新状态")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .help("退出 PortBar").accessibilityLabel("退出 PortBar")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(20)
        .frame(width: 410, height: min(CGFloat(max(360, s.ports.count * 66 + 340 + (showInfo ? 140 : 0) + (!s.portDetailAvailable ? 40 : 0))), min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 40)))
        .background(Glass())
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in login.refresh() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = Monitor(reader: CommandLine.arguments.contains("--demo") ? { Snapshot.demo(desktop: CommandLine.arguments.contains("--desktop")) } : Snapshot.read)
    var item: NSStatusItem!
    let popover = NSPopover()
    var previewWindow: NSWindow?
    func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let screen = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 5, width: 13, height: 10), xRadius: 1.7, yRadius: 1.7)
            screen.lineWidth = 1.2; screen.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5, width: 18, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            let ring = NSBezierPath(); ring.lineWidth = 1.2; ring.lineCapStyle = .round
            ring.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 2.3, startAngle: 70, endAngle: 20, clockwise: false)
            ring.stroke()
            let offset = 2.3 / sqrt(2.0)
            NSBezierPath(ovalIn: NSRect(x: 10 + offset - 0.5, y: 10 + offset - 0.5, width: 1, height: 1)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PortBar 接口状态"
        return image
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = menuBarIcon()
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let controller = NSHostingController(rootView: PortsView(monitor: monitor))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.behavior = .transient; popover.animates = true; popover.delegate = self
        monitor.onChange = { [weak self] in self?.updateTitle() }
        updateTitle(); monitor.start()
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.toggle() } }
        if CommandLine.arguments.contains("--preview") {
            let host = NSHostingController(rootView: PortsView(monitor: monitor))
            let window = NSWindow(contentViewController: host)
            window.title = "PortBar"; window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window; monitor.expanded = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func updateTitle() {
        item.button?.title = " \(monitor.snapshot.connectedCount)"
        item.button?.toolTip = "PortBar · \(monitor.snapshot.connectedCount) 项连接 · 点击查看连接状态"
    }
    @objc func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "刷新状态", action: #selector(refresh), keyEquivalent: "r").target = self
            let startup = menu.addItem(withTitle: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
            startup.target = self
            startup.state = SMAppService.mainApp.status == .enabled ? .on : SMAppService.mainApp.status == .requiresApproval ? .mixed : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 PortBar", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            monitor.expanded = true; monitor.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func popoverDidClose(_ notification: Notification) { monitor.expanded = false }
    @objc func refresh() { monitor.refresh() }
    @objc func toggleLogin() {
        let login = LoginLaunch(); login.setEnabled(!login.requested)
        if login.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--enable-login") || CommandLine.arguments.contains("--disable-login") || CommandLine.arguments.contains("--login-status") {
    let login = LoginLaunch()
    if CommandLine.arguments.contains("--enable-login") { login.setEnabled(true) }
    if CommandLine.arguments.contains("--disable-login") { login.setEnabled(false) }
    print("Login at startup: \(LoginLaunch.statusName(login.status))")
    if let error = login.error { print("Error: \(error)"); exit(1) }
    if CommandLine.arguments.contains("--enable-login") && login.status != .enabled { exit(2) }
} else if CommandLine.arguments.contains("--realtime-test") {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let events = HardwareEvents {}
    precondition(events.matchingCount == 6)
    print("PASS: USB/Thunderbolt/media subscriptions, \(events.interestCount) port subscriptions, power source notification")
    var totalMilliseconds = 0.0
    for _ in 0..<20 {
        let start = ProcessInfo.processInfo.systemUptime; _ = Snapshot.read()
        totalMilliseconds += (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
    print(String(format: "Registry sample average: %.2f ms", totalMilliseconds / 20))
    let fixture = Snapshot.read()
    let lock = NSLock(); var sequence = 0
    let monitor = Monitor(reader: {
        lock.lock(); sequence += 1; let value = sequence; lock.unlock()
        if value > 1 { Thread.sleep(forTimeInterval: 0.08) }
        var next = fixture; next.inputWatts = Double(value); return next
    })
    monitor.start(observeHardware: false); monitor.refresh()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { monitor.refresh() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        precondition(monitor.completedReads == 2, "A change arriving during a read must queue another read")
        for _ in 0..<6 { monitor.hardwareChanged() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        precondition(monitor.completedReads == 3, "A notification burst must coalesce into one extra read")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
        precondition(monitor.completedReads == 5, "The sampler must run every second, even when the popover is closed")
        monitor.stop()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
        precondition(monitor.completedReads == 5, "Stopping must cancel the sampler")
        print("PASS: in-flight change is preserved, burst coalescing, one-second background updates, stop cleanup")
        CFRunLoopStop(CFRunLoopGetMain())
    }
    withExtendedLifetime(events) { CFRunLoopRun() }
} else if CommandLine.arguments.contains("--self-test") {
    var root: [String: Any] = ["BuiltIn": true, "PortType": 2, "PortTypeDescription": "USB-C", "PortNumber": 1, "ConnectionActive": false]
    let stale: [String: Any] = ["ParentPortBuiltIn": true, "ParentBuiltInPortType": 2, "ParentBuiltInPortNumber": 1,
                               "TransportTypeDescription": "USB3", "Active": true, "Product": "Old Device", "DataRateDescription": "10 Gbps"]
    func sample(_ root: [String: Any]) -> Snapshot { Snapshot.parse(battery: [:], allRoots: [root], allTransports: [stale], allPower: [], externalDisplays: []) }
    precondition(sample(root).ports[0].state == .idle && sample(root).ports[0].speed.isEmpty)
    var unknown = root; unknown.removeValue(forKey: "ConnectionActive")
    precondition(sample(unknown).ports[0].state == .unknown && sample(root).external == nil)
    root["ConnectionActive"] = true
    precondition(sample(root).ports[0].detail == "Old Device" && sample(root).ports[0].speed == "10 Gbps")
    root["AuthorizationPending"] = true
    precondition(sample(root).ports[0].state == .attention)
    let airPorts: [[String: Any]] = [
        ["BuiltIn": true, "PortType": 2, "PortTypeDescription": "USB-C", "PortNumber": 1, "ConnectionActive": false],
        ["BuiltIn": true, "PortType": 2, "PortTypeDescription": "USB-C", "PortNumber": 2, "ConnectionActive": false]]
    let air = Snapshot.parse(battery: ["CurrentCapacity": 2700, "MaxCapacity": 4500], allRoots: airPorts, allTransports: [], allPower: [], profile: HardwareProfile(model: "MacBookAir9,1"), externalDisplays: [])
    precondition(air.ports.count == 2 && air.battery == 60 && air.hasBattery && air.deviceName == "MacBook Air")
    let desktop = Snapshot.parse(battery: [:], allRoots: [["BuiltIn": true, "PortType": 1, "PortTypeDescription": "USB-A", "PortNumber": 1, "ConnectionActive": false]], allTransports: [], allPower: [], publicPower: PublicPower(external: true), profile: HardwareProfile(model: "Macmini9,1"), externalDisplays: [])
    precondition(desktop.ports.count == 1 && desktop.ports[0].title == "USB-A" && !desktop.hasBattery && desktop.external == true)
    let fallback = Snapshot.parse(battery: [:], allRoots: [], allTransports: [], allPower: [], usbDevices: [["USB Product Name": "External Drive", "locationID": 1], ["USB Product Name": "Apple Internal Keyboard", "locationID": 2]], profile: HardwareProfile(model: "iMac18,3"), externalDisplays: [])
    precondition(!fallback.portDetailAvailable && fallback.ports.count == 1 && fallback.ports[0].detail == "External Drive")
    let modernMac = Snapshot.parse(battery: [:], allRoots: [], allTransports: [], allPower: [], publicPower: PublicPower(battery: 72, hasBattery: true, charging: false, external: false), profile: HardwareProfile(model: "Mac15,12"), externalDisplays: [])
    precondition(modernMac.hasBattery && modernMac.battery == 72 && modernMac.powerTitle == "使用电池")
    print("PASS: unplugged metadata, unknown values, connected device, pending authorization")
    print("PASS: discovered ports, Intel battery scaling, MacBook Air, desktop Mac, generic Apple Silicon model, legacy fallback")
} else if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let monitor = Monitor(reader: CommandLine.arguments.contains("--demo") ? { Snapshot.demo(desktop: CommandLine.arguments.contains("--desktop")) } : Snapshot.read)
    let host = NSHostingView(rootView: PortsView(monitor: monitor))
    host.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            print("Rendered \(Int(size.width)) × \(Int(size.height))")
        }
    }
} else if CommandLine.arguments.contains("--diagnostics") {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(Snapshot.read()), let text = String(data: data, encoding: .utf8) { print(text) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
