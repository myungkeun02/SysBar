import Cocoa
import IOKit.ps
import ServiceManagement
import SwiftUI
import Charts

// MARK: - Samplers

struct CPUSample { var user: Double; var system: Double; var idle: Double; var nice: Double }

final class CPUMonitor {
    private var prev: CPUSample?
    /// returns (user%, system%) since last call
    func sample() -> (user: Double, sys: Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let t = info.cpu_ticks
        let cur = CPUSample(user: Double(t.0), system: Double(t.1), idle: Double(t.2), nice: Double(t.3))
        defer { prev = cur }
        guard let p = prev else { return (0, 0) }
        let du = cur.user - p.user + cur.nice - p.nice
        let ds = cur.system - p.system
        let di = cur.idle - p.idle
        let total = du + ds + di
        guard total > 0 else { return (0, 0) }
        return (du / total * 100, ds / total * 100)
    }
}

struct MemInfo { var used: UInt64; var total: UInt64; var wired: UInt64; var compressed: UInt64; var app: UInt64; var swapUsed: UInt64; var swapTotal: UInt64 }

func memoryInfo() -> MemInfo {
    let total = ProcessInfo.processInfo.physicalMemory
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let ps = UInt64(pageSize)
    let app = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * ps
    let wired = UInt64(stats.wire_count) * ps
    let compressed = UInt64(stats.compressor_page_count) * ps
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
    return MemInfo(used: min(app + wired + compressed, total), total: total, wired: wired,
                   compressed: compressed, app: app, swapUsed: swap.xsu_used, swapTotal: swap.xsu_total)
}

final class NetMonitor {
    private var prev: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private func totals() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var rx: UInt64 = 0, tx: UInt64 = 0, off = 0
        buf.withUnsafeBytes { raw in
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: off, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    // skip loopback
                    if h2.ifm_data.ifi_type != UInt8(IFT_LOOP) {
                        rx += h2.ifm_data.ifi_ibytes
                        tx += h2.ifm_data.ifi_obytes
                    }
                }
                guard hdr.ifm_msglen > 0 else { break }
                off += Int(hdr.ifm_msglen)
            }
        }
        return (rx, tx)
    }
    /// bytes per second
    func sample() -> (down: Double, up: Double) {
        let (rx, tx) = totals()
        let now = Date().timeIntervalSince1970
        defer { prev = (rx, tx, now) }
        guard let p = prev, now > p.t, rx >= p.rx, tx >= p.tx else { return (0, 0) }
        let dt = now - p.t
        return (Double(rx - p.rx) / dt, Double(tx - p.tx) / dt)
    }
}

func diskInfo() -> (free: Int64, total: Int64) {
    let url = URL(fileURLWithPath: "/")
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
}

func batteryInfo() -> String? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let state = charging ? "충전 중" : (ac ? "전원 연결됨" : "배터리 사용")
        return "\(cap)% · \(state)"
    }
    return nil
}

func topProcesses(_ n: Int) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Aceo", "pcpu=,rss=,comm=", "-r"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(n)
    return lines.compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let cpu = Double(parts[0]), let rssKB = UInt64(parts[1]) else { return nil }
        let name = String(parts[2]).prefix(24)
        return String(format: "%5.1f%%  %8@  ", cpu, fmtBytes(rssKB * 1024) as NSString) + name
    }
}

// MARK: - Formatting

func fmtBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1000 { return String(format: "%.2f TB", gb / 1024) }
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(b) / 1_048_576)
}

func fmtRate(_ bps: Double) -> String {
    switch bps {
    case ..<1024: return String(format: "%.0fB", bps)
    case ..<(1024 * 1024): return String(format: "%.0fK", bps / 1024)
    default: return String(format: "%.1fM", bps / 1_048_576)
    }
}

func uptimeString() -> String {
    let s = Int(ProcessInfo.processInfo.systemUptime)
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    return d > 0 ? "\(d)일 \(h)시간 \(m)분" : "\(h)시간 \(m)분"
}

// MARK: - Model

struct Proc: Identifiable { let id = UUID(); let name: String; let cpu: Double; let mem: UInt64 }

func topProcs(_ n: Int) -> [Proc] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Aceo", "pcpu=,rss=,comm=", "-r"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(n).compactMap { line in
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard f.count == 3, let c = Double(f[0]), let kb = UInt64(f[1]) else { return nil }
        return Proc(name: String(f[2]), cpu: c, mem: kb * 1024)
    }
}

struct Battery { let percent: Int; let charging: Bool; let onAC: Bool }
func battery() -> Battery? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
        return Battery(percent: cap, charging: (d[kIOPSIsChargingKey] as? Bool) ?? false,
                       onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
    }
    return nil
}

struct Point: Identifiable { let id: Int; let v: Double }

enum Metric: String, CaseIterable, Identifiable {
    case cpu, mem, net, disk, bat
    var id: String { rawValue }
    var label: String { ["cpu": "CPU", "mem": "메모리", "net": "네트워크", "disk": "디스크", "bat": "배터리"][rawValue]! }
    var symbol: String { ["cpu": "cpu", "mem": "memorychip", "net": "arrow.up.arrow.down", "disk": "internaldrive", "bat": "battery.75percent"][rawValue]! }
}

final class Stats: ObservableObject {
    static let historyLen = 90   // 2초 × 90 = 3분
    private let cpuMon = CPUMonitor(), netMon = NetMonitor()
    private var n = 0

    @Published var cpuUser: [Point] = []
    @Published var cpuSys: [Point] = []
    @Published var memPct: [Point] = []
    @Published var netDown: [Point] = []
    @Published var netUp: [Point] = []
    @Published var cpu = (user: 0.0, sys: 0.0)
    @Published var mem = memoryInfo()
    @Published var net = (down: 0.0, up: 0.0)
    @Published var disk = diskInfo()
    @Published var bat = battery()
    @Published var load = [0.0, 0.0, 0.0]
    @Published var procs: [Proc] = []

    init() { _ = cpuMon.sample(); _ = netMon.sample() }

    var cpuTotal: Double { cpu.user + cpu.sys }
    var memPercent: Double { Double(mem.used) / Double(mem.total) * 100 }
    var diskPercent: Double { disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) * 100 : 0 }

    private func push(_ a: inout [Point], _ v: Double) {
        a.append(Point(id: n, v: v))
        if a.count > Stats.historyLen { a.removeFirst(a.count - Stats.historyLen) }
    }

    func update(withProcs: Bool) {
        n += 1
        cpu = cpuMon.sample(); net = netMon.sample(); mem = memoryInfo()
        disk = diskInfo(); bat = battery()
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); load = l
        push(&cpuUser, cpu.user); push(&cpuSys, cpu.sys)
        push(&memPct, memPercent)
        push(&netDown, net.down); push(&netUp, net.up)
        if withProcs {
            DispatchQueue.global(qos: .utility).async {
                let p = topProcs(5)
                DispatchQueue.main.async { self.procs = p }
            }
        }
    }

    func statusText(_ m: Metric) -> String {
        switch m {
        case .cpu: return pad(String(format: "%.0f%%", cpuTotal), 4)
        case .mem: return pad(String(format: "%.0f%%", memPercent), 4)
        case .net: return "↓" + pad(fmtRate(net.down), 5) + " ↑" + pad(fmtRate(net.up), 5)
        case .disk: return pad(String(format: "%.0f%%", diskPercent), 4)
        case .bat: return pad(bat.map { "\($0.percent)%" } ?? "-", 4)
        }
    }
}

/// 숫자 폭 공백(U+2007)으로 왼쪽을 채워 상태바 폭이 값에 따라 흔들리지 않게 함
func pad(_ t: String, _ n: Int) -> String {
    String(repeating: "\u{2007}", count: max(0, n - t.count)) + t
}

// MARK: - Views

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Card<Content: View>: View {
    let title: String, symbol: String, value: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct Bar: View {
    let fraction: Double; let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }.frame(height: 6)
    }
}

struct Sub: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
}

struct DashboardView: View {
    @ObservedObject var s: Stats
    let onQuit: () -> Void, onActivity: () -> Void, onSettingsChanged: () -> Void
    @State private var showSettings = false
    @State private var contentH: CGFloat = 560
    /// 화면에서 메뉴바·Dock을 뺀 높이 안에 팝오버 전체가 들어가도록 카드 영역 높이를 제한
    var maxScroll: CGFloat {
        let vis = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, vis - 40 - 150 - (showSettings ? 60 : 0))
    }
    @AppStorage("statusMetric") private var statusMetric = Metric.cpu.rawValue
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var xDomain: ClosedRange<Int> {
        let last = s.memPct.last?.id ?? Stats.historyLen
        return max(0, last - Stats.historyLen + 1)...max(last, Stats.historyLen)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("시스템 리소스").font(.headline)
                Spacer()
                Text("가동 \(uptimeString())").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("상태바에 표시할 항목").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(Metric.allCases.filter { $0 != .bat || s.bat != nil }) { m in
                        let on = statusMetric == m.rawValue
                        Text(m.label)
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                            .onTapGesture { statusMetric = m.rawValue; onSettingsChanged() }
                    }
                }
            }

            Group {
                if contentH > maxScroll {
                    ScrollView(.vertical) { cards }.frame(height: maxScroll)
                } else {
                    cards
                }
            }
            .onPreferenceChange(HeightKey.self) { contentH = $0 }

            if showSettings { settings }

            HStack {
                Button(action: { withAnimation { showSettings.toggle() } }) { Image(systemName: "gearshape") }
                    .help("설정")
                Button("활성 상태 보기", action: onActivity)
                Spacer()
                Button("종료", action: onQuit).keyboardShortcut("q")
            }
            .buttonStyle(.borderless).font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 360)
    }

    var cards: some View {
        VStack(spacing: 10) {
            Card(title: "CPU", symbol: "cpu", value: String(format: "%.0f%%", s.cpuTotal)) {
                Chart {
                    ForEach(s.cpuSys) { AreaMark(x: .value("t", $0.id), y: .value("%", $0.v)).foregroundStyle(by: .value("k", "시스템")) }
                    ForEach(s.cpuUser) { AreaMark(x: .value("t", $0.id), y: .value("%", $0.v)).foregroundStyle(by: .value("k", "사용자")) }
                }
                .chartForegroundStyleScale(["사용자": Color.blue.opacity(0.75), "시스템": Color.red.opacity(0.75)])
                .chartYScale(domain: 0...100).chartXScale(domain: xDomain).chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { val in AxisGridLine(); AxisValueLabel { if let v = val.as(Int.self) { Text("\(v)%") } } } }
                .chartLegend(.hidden).frame(height: 60)
                HStack {
                    Circle().fill(.blue).frame(width: 6, height: 6); Sub(text: String(format: "사용자 %.0f%%", s.cpu.user))
                    Circle().fill(.red).frame(width: 6, height: 6); Sub(text: String(format: "시스템 %.0f%%", s.cpu.sys))
                    Spacer()
                    Sub(text: String(format: "부하 %.2f %.2f %.2f", s.load[0], s.load[1], s.load[2]))
                }
            }

            Card(title: "메모리", symbol: "memorychip", value: String(format: "%.0f%%", s.memPercent)) {
                Chart(s.memPct) {
                    AreaMark(x: .value("t", $0.id), y: .value("%", $0.v))
                        .foregroundStyle(LinearGradient(colors: [.green.opacity(0.6), .green.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", $0.id), y: .value("%", $0.v)).foregroundStyle(.green)
                }
                .chartYScale(domain: 0...100).chartXScale(domain: xDomain).chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { val in AxisGridLine(); AxisValueLabel { if let v = val.as(Int.self) { Text("\(v)%") } } } }
                .frame(height: 48)
                Sub(text: "사용 \(fmtBytes(s.mem.used)) / \(fmtBytes(s.mem.total))  ·  스왑 \(fmtBytes(s.mem.swapUsed))")
                Sub(text: "앱 \(fmtBytes(s.mem.app)) · 와이어드 \(fmtBytes(s.mem.wired)) · 압축 \(fmtBytes(s.mem.compressed))")
            }

            Card(title: "네트워크", symbol: "arrow.up.arrow.down", value: "↓\(fmtRate(s.net.down))/s ↑\(fmtRate(s.net.up))/s") {
                Chart {
                    ForEach(s.netDown) { LineMark(x: .value("t", $0.id), y: .value("B/s", $0.v)).foregroundStyle(by: .value("k", "다운로드")) }
                    ForEach(s.netUp) { LineMark(x: .value("t", $0.id), y: .value("B/s", $0.v)).foregroundStyle(by: .value("k", "업로드")) }
                }
                .chartForegroundStyleScale(["다운로드": Color.cyan, "업로드": Color.orange])
                .chartXScale(domain: xDomain).chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { val in AxisGridLine(); AxisValueLabel { if let v = val.as(Double.self) { Text(fmtRate(v)) } } } }
                .chartLegend(.hidden).frame(height: 48)
                HStack {
                    Circle().fill(.cyan).frame(width: 6, height: 6); Sub(text: "다운로드")
                    Circle().fill(.orange).frame(width: 6, height: 6); Sub(text: "업로드")
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Card(title: "디스크", symbol: "internaldrive", value: String(format: "%.0f%%", s.diskPercent)) {
                    Bar(fraction: s.diskPercent / 100, color: .purple)
                    Sub(text: "여유 \(fmtBytes(UInt64(max(s.disk.free, 0))))")
                }
                if let b = s.bat {
                    Card(title: "배터리", symbol: b.charging ? "battery.100percent.bolt" : "battery.75percent", value: "\(b.percent)%") {
                        Bar(fraction: Double(b.percent) / 100, color: b.percent <= 20 ? .red : .green)
                        Sub(text: b.charging ? "충전 중" : (b.onAC ? "전원 연결됨" : "배터리 사용"))
                    }
                }
            }

            Card(title: "CPU 상위 프로세스", symbol: "list.bullet", value: "") {
                ForEach(s.procs) { p in
                    HStack {
                        Text(p.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpu)).font(.system(size: 11).monospacedDigit()).frame(width: 50, alignment: .trailing)
                        Text(fmtBytes(p.mem)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                }
                if s.procs.isEmpty { Sub(text: "불러오는 중…") }
            }

        }
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
    }

    var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("로그인 시 자동 실행", isOn: $loginOn)
                .font(.system(size: 12))
                .onChange(of: loginOn) { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { loginOn = SMAppService.mainApp.status == .enabled }
                }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stats = Stats()
    let popover = NSPopover()
    var sampleTimer: Timer?
    let d = UserDefaults.standard

    var current: Metric {
        let m = Metric(rawValue: d.string(forKey: "statusMetric") ?? "") ?? .cpu
        return (m == .bat && stats.bat == nil) ? .cpu : m
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = item.button {
            b.action = #selector(togglePopover); b.target = self
            b.imagePosition = .imageLeft
        }
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: DashboardView(
            s: stats,
            onQuit: { NSApp.terminate(nil) },
            onActivity: { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) },
            onSettingsChanged: { [weak self] in self?.render() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        stats.update(withProcs: true)
        sampleTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats.update(withProcs: self.popover.isShown)
            self.render()
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
        render()
    }

    func render() {
        guard let b = item.button else { return }
        let m = current
        var symbol = m.symbol
        if m == .bat, let bt = stats.bat {
            symbol = bt.charging ? "battery.100percent.bolt"
                : ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent"][min(4, (bt.percent + 12) / 25)]
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: m.label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        img?.isTemplate = true
        b.image = img
        b.attributedTitle = NSAttributedString(string: " " + stats.statusText(m), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        b.toolTip = m.label
    }

    @objc func togglePopover() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        stats.update(withProcs: true)
        render()
        if let v = popover.contentViewController?.view {
            v.layoutSubtreeIfNeeded()
            popover.contentSize = v.fittingSize
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--login") {
    let svc = SMAppService.mainApp
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
    do {
        if arg == "on" { try svc.register() } else if arg == "off" { try svc.unregister() }
    } catch { print("error: \(error.localizedDescription)") }
    let names: [SMAppService.Status: String] = [.enabled: "enabled", .notRegistered: "notRegistered",
                                                 .requiresApproval: "requiresApproval", .notFound: "notFound"]
    print("login item:", names[svc.status] ?? "unknown")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let st = Stats()
    for _ in 0..<12 { Thread.sleep(forTimeInterval: 0.25); st.update(withProcs: false) }
    st.procs = topProcs(6)
    MainActor.assumeIsolated {
    let r = ImageRenderer(content: DashboardView(s: st, onQuit: {}, onActivity: {}, onSettingsChanged: {})
        .background(Color(nsColor: .windowBackgroundColor)))
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
