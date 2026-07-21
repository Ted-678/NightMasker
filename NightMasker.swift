//
//  NightMasker.swift
//  自适应掩蔽音 App —— 单文件版本
//
//  用法:新建一个 SwiftUI iOS App 工程,删除自动生成的
//  ContentView.swift 和 App 入口文件,把本文件加入工程即可。
//
//  功能:
//  - 8 个倍频程频段(63Hz–8kHz)的带限粉噪,启动时程序内生成无缝循环
//  - 麦克风实时分析环境噪音的 8 频段能量
//  - 自适应模式:哪个频段被窗外噪音入侵,就只在那个频段抬升掩蔽音
//  - 自动校准:测量"自己播的声音在麦克风里有多响",运行时减掉,避免自听回授
//  - 静态模式:手动 8 段均衡
//  - 定时淡出、整夜频谱 CSV 记录(只存分贝数字,不存录音)
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - 快速伪随机数(生成噪音用,避免加密级 RNG 太慢)

struct XorShift64 {
    private var state: UInt64
    init(seed: UInt64 = 0x9E3779B97F4A7C15) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// 均匀分布 [-1, 1)
    mutating func uniform() -> Double {
        Double(next() >> 11) * (2.0 / 9007199254740992.0) - 1.0
    }
}

// MARK: - 双二阶带通滤波器(RBJ,峰值 0dB)

struct Biquad {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    static func bandpass(fc: Double, q: Double, fs: Double) -> Biquad {
        let w = 2.0 * Double.pi * fc / fs
        let alpha = sin(w) / (2.0 * q)
        let cw = cos(w)
        let a0 = 1.0 + alpha
        var f = Biquad()
        f.b0 = alpha / a0
        f.b1 = 0.0
        f.b2 = -alpha / a0
        f.a1 = -2.0 * cw / a0
        f.a2 = (1.0 - alpha) / a0
        return f
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// 两级级联带通 = 一个倍频程频段滤波器
struct BandFilter {
    var s1: Biquad
    var s2: Biquad
    init(fc: Double, fs: Double) {
        let q = 1.414  // 约一个倍频程带宽
        s1 = .bandpass(fc: fc, q: q, fs: fs)
        s2 = .bandpass(fc: fc, q: q, fs: fs)
    }
    mutating func process(_ x: Double) -> Double { s2.process(s1.process(x)) }
}

// MARK: - 噪音循环段生成

enum NoiseFactory {
    static let bandCenters: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000]
    static let bandLabels = ["63", "125", "250", "500", "1k", "2k", "4k", "8k"]

    /// 生成某个倍频程频段的带限粉噪无缝循环
    static func makeLoopBuffer(fc: Double, sampleRate: Double = 48000, seconds: Double = 12) -> AVAudioPCMBuffer {
        let n = Int(sampleRate * seconds)
        let warmup = Int(sampleRate)              // 丢掉滤波器建立期
        var filt = BandFilter(fc: fc, fs: sampleRate)
        var rng = XorShift64(seed: UInt64(fc) &* 0x2545F4914F6CDD1D)
        var out = [Float](repeating: 0, count: n)

        for i in 0..<(n + warmup) {
            let y = filt.process(rng.uniform())
            if i >= warmup { out[i - warmup] = Float(y) }
        }

        // 粉噪权重:低频段能量高,高频段递减(以 1kHz 为基准)
        let weight = min(Float(sqrt(1000.0 / fc)), 3.0)

        // RMS 归一化
        var sumSq: Float = 0
        for v in out { sumSq += v * v }
        let rms = sqrt(sumSq / Float(n))
        var gain = (0.04 / max(rms, 1e-9)) * weight

        // 防削波
        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        if peak * gain > 0.95 { gain = 0.95 / peak }
        for i in 0..<n { out[i] *= gain }

        // 首尾交叉淡化,消除循环接缝
        let L = Int(sampleRate * 0.5)
        for i in 0..<L {
            let a = Float(i) / Float(L)
            out[i] = out[i] * a + out[n - L + i] * (1 - a)
        }
        let usable = n - L

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(usable))!
        buf.frameLength = AVAudioFrameCount(usable)
        out.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: usable)
        }
        return buf
    }
}

// MARK: - 麦克风频段分析(运行在音频线程,自带锁)

final class AnalyzerBank {
    private var filters: [BandFilter]
    private var accum = [Double](repeating: 0, count: 8)
    private var count: Int = 0
    private let lock = NSLock()

    init(sampleRate: Double) {
        filters = NoiseFactory.bandCenters.map { BandFilter(fc: $0, fs: sampleRate) }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var local = [Double](repeating: 0, count: 8)
        for i in 0..<n {
            let x = Double(data[i])
            for b in 0..<8 {
                let y = filters[b].process(x)
                local[b] += y * y
            }
        }
        lock.lock()
        for b in 0..<8 { accum[b] += local[b] }
        count += n
        lock.unlock()
    }

    /// 取走窗口内平均功率并清零
    func takeAverages() -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return nil }
        let avg = accum.map { $0 / Double(count) }
        accum = [Double](repeating: 0, count: 8)
        count = 0
        return avg
    }

    func reset() {
        lock.lock()
        accum = [Double](repeating: 0, count: 8)
        count = 0
        lock.unlock()
    }
}

// MARK: - 核心引擎

enum MaskerMode: String, CaseIterable, Identifiable {
    case adaptive = "自适应"
    case staticEQ = "静态"
    var id: String { rawValue }
}

final class MaskerEngine: ObservableObject {

    // 播放
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var bank: AnalyzerBank?
    private var graphBuilt = false

    // 校准结果:selfGain[b] = 麦克风频段功率 / 播放音量²
    private var selfGain = [Double](repeating: 0, count: 8)
    private var floorPower = [Double](repeating: 1e-10, count: 8)

    // 控制环状态
    private var vol = [Double](repeating: 0, count: 8)        // 当前指令音量(平滑后)
    private var lastSetVol = [Double](repeating: 0, count: 8) // 上个窗口实际播放音量,用于自听减法
    private var controlTimer: Timer?
    private var startDate: Date?
    private var fade: Double = 1.0

    // UI 状态
    @Published var running = false
    @Published var busy = false
    @Published var mode: MaskerMode = .adaptive
    @Published var status = "未运行"
    @Published var calibrated = false
    @Published var ambientDB = [Double](repeating: -80, count: 8)
    @Published var maskerDB = [Double](repeating: -80, count: 8)
    @Published var remainingText = ""

    // 可调参数
    @Published var offsetDB: Double = 4        // 掩蔽余量:掩蔽声比环境声高多少 dB
    @Published var maxVol: Double = 0.6        // 每频段音量上限
    @Published var baseVol: Double = 0.04      // 基础底噪音量(防止完全静音后突然出声)
    @Published var quietGateDB: Double = -58   // 低于此环境声级视为"安静",回落到底噪
    @Published var timerHours: Double = 8      // 定时(小时),到时后 10 分钟淡出
    @Published var staticVol = [Double](repeating: 0.35, count: 8)
    @Published var staticMaster: Double = 0.8

    // 日志
    @Published var logEnabled = false
    @Published var logFileURL: URL?
    private var logLines: [String] = []

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.status = "输出设备发生变化,建议停止后重新校准"
        }
    }

    // MARK: 启动 / 停止

    func toggle() {
        running ? stop() : requestPermissionAndStart()
    }

    private func requestPermissionAndStart() {
        let proceed: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                if granted {
                    Task { await self.start() }
                } else {
                    self.status = "需要麦克风权限(设置 → NightMasker → 麦克风)"
                }
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: proceed)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(proceed)
        }
    }

    @MainActor
    private func start() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        if buffers.isEmpty {
            status = "正在生成噪音波形(约几秒)…"
            let generated = await Task.detached(priority: .userInitiated) {
                NoiseFactory.bandCenters.map { NoiseFactory.makeLoopBuffer(fc: $0) }
            }.value
            buffers = generated
        }

        do {
            try configureAudio()
        } catch {
            status = "音频引擎启动失败:\(error.localizedDescription)"
            return
        }

        running = true
        startDate = Date()
        fade = 1.0
        vol = [Double](repeating: 0, count: 8)
        lastSetVol = vol

        if mode == .adaptive && !calibrated {
            await runCalibration()
        }

        bank?.reset()
        controlTimer?.invalidate()
        controlTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        status = mode == .adaptive ? "自适应运行中 · 可以锁屏" : "静态运行中 · 可以锁屏"
    }

    func stop() {
        controlTimer?.invalidate()
        controlTimer = nil
        players.forEach { $0.stop() }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
        status = "已停止"
        remainingText = ""
        flushLog(force: true)
    }

    private func configureAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement 关闭系统自动增益,读数才可比;代价是输出走单个扬声器,响度略低
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)

        if !graphBuilt {
            for buf in buffers {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: buf.format)
                players.append(p)
            }
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            let analyzer = AnalyzerBank(sampleRate: fmt.sampleRate)
            bank = analyzer
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
                analyzer.process(buffer)
            }
            graphBuilt = true
        }

        engine.prepare()
        try engine.start()

        for (i, p) in players.enumerated() {
            p.volume = 0
            p.scheduleBuffer(buffers[i], at: nil, options: .loops)
            p.play()
        }
    }

    // MARK: 校准

    @MainActor
    func runCalibration() async {
        guard running else { return }
        status = "校准中,请保持房间安静(约 15 秒)…"

        players.forEach { $0.volume = 0 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        floorPower = await measure(seconds: 1.2) ?? floorPower

        let calibVol: Double = 0.4
        for b in 0..<8 {
            players[b].volume = Float(calibVol)
            try? await Task.sleep(nanoseconds: 500_000_000)          // 稳定期
            let p = await measure(seconds: 0.7) ?? floorPower
            players[b].volume = 0
            let net = max(p[b] - floorPower[b], 1e-12)
            selfGain[b] = net / (calibVol * calibVol)
        }

        calibrated = true
        status = "校准完成"
    }

    private func measure(seconds: Double) async -> [Double]? {
        bank?.reset()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return bank?.takeAverages()
    }

    func invalidateCalibration() {
        calibrated = false
        status = "已清除校准,下次启动自适应时会重新校准"
    }

    // MARK: 控制环(每 0.5 秒)

    private func tick() {
        guard running, let powers = bank?.takeAverages() else { return }

        updateFadeAndTimer()

        var newAmbient = ambientDB
        var newMasker = maskerDB

        for b in 0..<8 {
            // 从测量值里减去自己播放的贡献
            let selfP = calibrated ? selfGain[b] * lastSetVol[b] * lastSetVol[b] : 0
            let ambientP = max(powers[b] - selfP, 1e-12)
            let aDB = 10 * log10(ambientP)
            newAmbient[b] = aDB

            if mode == .adaptive {
                var desired: Double
                if !calibrated || selfGain[b] < 1e-12 {
                    desired = baseVol
                } else if aDB < quietGateDB {
                    desired = baseVol
                } else {
                    let targetP = ambientP * pow(10, offsetDB / 10)
                    desired = sqrt(targetP / selfGain[b])
                    desired = max(desired, baseVol)
                }
                desired = min(desired, maxVol)

                // 非对称平滑:上冲快(≈1.5s),回落慢(≈40s),避免呼吸感
                let coef = desired > vol[b] ? 0.45 : 0.03
                vol[b] += (desired - vol[b]) * coef
            } else {
                vol[b] = staticVol[b] * staticMaster
            }

            let effective = vol[b] * fade
            players[b].volume = Float(effective)
            lastSetVol[b] = effective

            let mP = calibrated ? selfGain[b] * effective * effective : 1e-12
            newMasker[b] = 10 * log10(max(mP, 1e-12))
        }

        ambientDB = newAmbient
        maskerDB = newMasker

        if logEnabled { appendLog() }
    }

    private func updateFadeAndTimer() {
        guard let sd = startDate else { return }
        let elapsed = Date().timeIntervalSince(sd)
        let total = timerHours * 3600
        let remain = total - elapsed
        if remain > 0 {
            let h = Int(remain) / 3600
            let m = (Int(remain) % 3600) / 60
            remainingText = String(format: "定时剩余 %d:%02d", h, m)
            fade = 1.0
        } else {
            let fadeProgress = min((-remain) / 600.0, 1.0)   // 10 分钟淡出
            fade = 1.0 - fadeProgress
            remainingText = "正在淡出…"
            if fade <= 0 {
                stop()
                status = "定时结束,已自动停止"
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        if type == .ended && running {
            // 尝试自动恢复(闹钟、电话等中断之后)
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
            for (i, p) in players.enumerated() {
                p.scheduleBuffer(buffers[i], at: nil, options: .loops)
                p.play()
            }
            status = "被系统中断后已恢复"
        } else if type == .began {
            status = "被系统音频中断…"
        }
    }

    // MARK: CSV 日志(只记录分贝数字,不存任何录音)

    private func appendLog() {
        let t = Int(Date().timeIntervalSince1970)
        let a = ambientDB.map { String(format: "%.1f", $0) }.joined(separator: ",")
        let v = vol.map { String(format: "%.3f", $0) }.joined(separator: ",")
        logLines.append("\(t),\(a),\(v)")
        if logLines.count >= 120 { flushLog(force: false) }
    }

    private func flushLog(force: Bool) {
        guard logEnabled || force, !logLines.isEmpty else { return }
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let url = dir.appendingPathComponent("masker_log_\(df.string(from: Date())).csv")

        if !fm.fileExists(atPath: url.path) {
            let header = "epoch," +
                NoiseFactory.bandLabels.map { "amb_\($0)" }.joined(separator: ",") + "," +
                NoiseFactory.bandLabels.map { "vol_\($0)" }.joined(separator: ",") + "\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = (logLines.joined(separator: "\n") + "\n").data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
        logLines.removeAll()
        logFileURL = url
    }
}

// MARK: - UI

struct SpectrumView: View {
    let ambient: [Double]
    let masker: [Double]

    private func height(_ db: Double) -> CGFloat {
        let clamped = min(max(db, -80), -10)
        return CGFloat((clamped + 80) / 70) * 110 + 4
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<8, id: \.self) { i in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.08))
                            .frame(width: 22, height: 114)
                        Capsule().fill(Color.teal.opacity(0.85))
                            .frame(width: 22, height: height(ambient[i]))
                        Capsule().fill(Color.orange.opacity(0.9))
                            .frame(width: 7, height: height(masker[i]))
                    }
                    Text(NoiseFactory.bandLabels[i])
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ContentView: View {
    @StateObject private var eng = MaskerEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {

                    VStack(spacing: 6) {
                        Text(eng.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !eng.remainingText.isEmpty {
                            Text(eng.remainingText)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }

                    SpectrumView(ambient: eng.ambientDB, masker: eng.maskerDB)

                    HStack(spacing: 14) {
                        Label("环境", systemImage: "circle.fill").foregroundStyle(.teal)
                        Label("掩蔽", systemImage: "circle.fill").foregroundStyle(.orange)
                    }
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)

                    Button(action: { eng.toggle() }) {
                        Text(eng.running ? "停止" : "开始")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(eng.running ? .red : .teal)
                    .disabled(eng.busy)

                    Picker("模式", selection: $eng.mode) {
                        ForEach(MaskerMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(eng.running)

                    if eng.mode == .adaptive {
                        adaptiveControls
                    } else {
                        staticControls
                    }

                    timerAndLog
                }
                .padding(20)
            }
            .navigationTitle("NightMasker")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private var adaptiveControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sliderRow("掩蔽余量", value: $eng.offsetDB, range: 0...12, format: "%.0f dB",
                      hint: "掩蔽声比环境噪音高多少。3–6 起步,越高越盖得住但也越吵")
            sliderRow("音量上限", value: $eng.maxVol, range: 0.1...1.0, format: "%.2f",
                      hint: "每个频段的硬上限,防止半夜大噪音时被轰醒")
            sliderRow("基础底噪", value: $eng.baseVol, range: 0...0.2, format: "%.2f",
                      hint: "安静时保留的一层薄底噪,避免忽有忽无")
            sliderRow("安静门限", value: $eng.quietGateDB, range: -75 ... -35, format: "%.0f dB",
                      hint: "环境低于此值就视为安静,回落到底噪")

            HStack {
                Image(systemName: eng.calibrated ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(eng.calibrated ? .green : .orange)
                Text(eng.calibrated ? "已校准" : "未校准(启动时会自动进行)")
                    .font(.footnote)
                Spacer()
                Button("重新校准") {
                    if eng.running {
                        Task { await eng.runCalibration() }
                    } else {
                        eng.invalidateCalibration()
                    }
                }
                .font(.footnote)
            }
            .padding(.top, 4)
        }
    }

    private var staticControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow("总音量", value: $eng.staticMaster, range: 0...1, format: "%.2f", hint: nil)
            ForEach(0..<8, id: \.self) { i in
                HStack {
                    Text(NoiseFactory.bandLabels[i])
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 34, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Slider(value: $eng.staticVol[i], in: 0...1)
                }
            }
        }
    }

    private var timerAndLog: some View {
        VStack(alignment: .leading, spacing: 14) {
            sliderRow("定时", value: $eng.timerHours, range: 1...12, format: "%.1f 小时",
                      hint: "到时后 10 分钟内淡出并停止")

            Toggle("记录整夜频谱 (CSV)", isOn: $eng.logEnabled)
                .font(.subheadline)
            Text("只记录每 0.5 秒的 8 频段分贝数字和播放音量,不保存任何录音。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let url = eng.logFileURL {
                ShareLink(item: url) {
                    Label("导出今晚的 CSV", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            }
        }
        .padding(.top, 8)
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, format: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - App 入口

@main
struct NightMaskerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
