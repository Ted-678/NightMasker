# NightMasker

**Adaptive sound masking for sleeping with open windows.**
**为夏天开窗睡觉设计的自适应掩蔽音 iOS App。**

[English](#english) · [中文](#中文)

---

## English

An iOS app that listens to the noise coming through your open window and raises masking noise **only in the frequency bands that are actually being invaded**, leaving the rest quiet. Unlike a fixed white-noise track, it doesn't blast you at the same volume all night.

### The problem

In Switzerland and much of Central Europe, homes rarely have air conditioning. On summer nights the only way to cool a bedroom is to open the window — which lets in traffic noise, trams, and mosquitoes along with the cool air. Ventilation, sound insulation and insect protection form a trilemma: you can't have all three. NightMasker addresses the noise corner of it.

### How it works

```
Playback:  8 octave-band noise loops -> 8 AVAudioPlayerNodes -> MainMixer -> speaker
Analysis:  inputNode tap -> band filter bank -> 8 band energy values
Control:   every 500ms compare [ambient spectrum vs masking spectrum] -> adjust per-band gain
```

Four design decisions worth explaining:

- **No real-time noise synthesis.** Eight pre-generated band-limited pink noise loops (63 Hz – 8 kHz octave bands) are created at launch; at runtime only eight volume values change. This reduces "spectral shaping" to "moving eight sliders" — robust, and essentially free on CPU.
- **Self-hearing feedback is solved with calibration subtraction.** On first start the app runs a ~15 s calibration, briefly playing each band in turn to measure the mapping from *playback gain* to *microphone level*. At runtime its own contribution is subtracted from the measurement, avoiding the runaway loop where the app hears itself and keeps turning up.
- **Asymmetric smoothing.** Masking rises in ~1.5 s when noise appears, but falls back over ~40 s. Fast release produces an audible pumping effect that is more irritating at 3 a.m. than the noise itself.
- **Hard-clamped volume ceiling.** No matter how loud the street gets, the app can never wake you up on its own.

### Setup

1. Xcode → New Project → iOS App (SwiftUI, Swift, Deployment Target ≥ iOS 16)
2. Delete the generated `ContentView.swift` and app entry file
3. Add `NightMasker.swift` to the project
4. In the Info tab, add `Privacy - Microphone Usage Description`
5. Signing & Capabilities → + Capability → Background Modes → check **Audio**
6. Connect your iPhone and press ⌘R

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| Masking offset | 4 dB | How far the masking sound sits above the ambient level |
| Volume ceiling | 0.60 | Hard per-band limit |
| Noise floor | 0.04 | Thin baseline kept during quiet periods |
| Quiet gate | −58 dB | Below this the room counts as quiet |
| Timer | 8 h | Fades out over 10 minutes when it expires |

### Known limitations

- **Low frequencies can't be masked.** The iPhone speaker produces almost nothing below 250 Hz, and tram and traffic rumble live precisely there. An external speaker helps noticeably (re-run calibration afterwards).
- **Cost of measurement mode.** To keep microphone readings comparable, the app disables the system's automatic gain control, which makes output slightly quieter than normal playback.
- **Changing output device requires re-calibration.** Calibration captures the mapping for one specific acoustic path.

### Privacy

The app never records and never uploads. The optional CSV log stores only the eight band levels in dB and the playback gains, sampled twice per second.

### Safety

Overnight bedside sound exposure should stay below roughly 45–50 dB(A). The goal of masking is to *cover*, not to *drown out*. If you find yourself pushing the volume ceiling higher and higher and still wanting more, that's a sign to go back to physical solutions — window screen, tilt-vent position, earplugs.

### Roadmap

- Read sleep stages from HealthKit for an ABAB self-controlled experiment
- Automatically lower the masking offset during deep sleep
- Upgrade calibration from diagonal to full matrix (accounting for inter-band leakage)
- Use historical CSV data to predict noise 10 minutes ahead and pre-ramp the masking

---

## 中文

麦克风实时分析窗外噪音的频谱,**只在被入侵的频段抬升掩蔽噪音**,其余频段保持安静。相比固定白噪音,它不会整夜用同一个音量轰你。

### 问题

在瑞士等中欧地区,住宅普遍没有空调,夏夜只能开窗降温。但开窗意味着噪音和蚊虫一起进来。"通风、隔音、防虫"是一个不可兼得的三角矛盾。NightMasker 处理其中的噪音一环。

### 原理

```
播放链: 8个倍频程噪音loop -> 8个AVAudioPlayerNode -> MainMixer -> 扬声器
分析链: inputNode tap -> 频段滤波器组 -> 8个频段能量值
控制环: 每500ms比较 [环境频谱 vs 掩蔽频谱] -> 调整对应频段音量
```

四个值得解释的设计决策:

- **不实时合成噪音**。启动时生成 8 段带限粉噪循环(63Hz–8kHz 倍频程),运行时只调 8 个音量值。把"频谱塑形"降维成"调 8 个滑块",鲁棒且几乎零 CPU 开销。
- **自听回授用校准减法解决**。首次启动自动跑约 15 秒校准,逐个频段短促播放,测出"播放音量 → 麦克风响度"的映射;运行时把自己的贡献从测量值里减掉,避免"听到自己→加大音量→听到更大"的死循环。
- **非对称平滑**。噪音出现约 1.5 秒盖上去,消失后约 40 秒才缓慢回落。回落快了会产生一起一伏的呼吸感,凌晨三点比噪音本身更烦人。
- **硬钳位音量上限**。再大的窗外噪音,也不会让 App 自己把你轰醒。

### 安装

1. Xcode → New Project → iOS App(SwiftUI,Swift,Deployment Target ≥ iOS 16)
2. 删除自动生成的 `ContentView.swift` 和 App 入口文件
3. 把 `NightMasker.swift` 加入工程
4. Info 标签添加 `Privacy - Microphone Usage Description`
5. Signing & Capabilities → + Capability → Background Modes → 勾选 **Audio**
6. 连上 iPhone,按 ⌘R 运行

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| 掩蔽余量 | 4 dB | 掩蔽声比环境声高多少 |
| 音量上限 | 0.60 | 每频段硬上限 |
| 基础底噪 | 0.04 | 安静时保留的薄底噪 |
| 安静门限 | −58 dB | 低于此值视为安静 |
| 定时 | 8 小时 | 到时后 10 分钟淡出 |

### 已知局限

- **低频盖不住**。iPhone 扬声器在 250Hz 以下几乎没有输出,而电车和马路轰鸣恰恰在低频。接外置小音箱可明显改善(接后需重新校准)。
- **测量模式的代价**。为让麦克风读数可比,App 关闭了系统自动增益,输出响度略低于正常播放。
- **换输出设备需重新校准**。校准记录的是特定声学路径下的映射关系。

### 隐私

App 不录音、不上传。可选的 CSV 日志只写入每 0.5 秒的 8 个频段分贝数字和播放音量。

### 安全

枕边整夜声音暴露建议不超过 45–50 dB(A)。掩蔽的目标是"盖过",不是"轰鸣"。如果发现自己不断调高音量上限仍嫌不够,说明该回到物理方案(纱窗 + 通风缝 + 耳塞)。

### 路线图

- 接 HealthKit 读取睡眠阶段,做 ABAB 自身对照实验
- 深睡阶段自动降低掩蔽余量
- 校准从对角线升级为全矩阵(考虑频段间泄漏)
- 用历史 CSV 预测未来 10 分钟噪音,提前铺垫掩蔽声
