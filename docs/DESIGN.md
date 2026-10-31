# 设计与实测笔记

> 这里保留完整的工程笔记：设计决策、PaddleOCR 接入细节、性能与内存实测、踩坑记录。
> 项目概览见 [README](../README.md)。

# 硬字幕提取器

从视频画面里把「烧进画面」的字幕识别出来，生成 SRT / VTT 字幕文件。
macOS 原生 SwiftUI，纯本地运行，不上传任何视频。

双 OCR 引擎：

- **Apple Vision** —— 系统内置，零依赖，开箱即用
- **PaddleOCR (ONNX)** —— PP-OCRv3 检测 + 识别，中文小字更准

---

## 快速开始

> 仓库已附带 `Vendor/`（ffmpeg、onnxruntime）与 `Resources/Models/`（OCR 模型），克隆即可构建，无需额外下载。

```bash
# 编译并打包成 .app（会自动带上模型和 onnxruntime）
./Scripts/make-app.sh

open "build/硬字幕提取器.app"
```

没有素材也能立刻验证 —— 内置四种难度的合成视频生成器：

```bash
BIN=./build/硬字幕提取器.app/Contents/MacOS/HardSubExtractor

$BIN --make-sample testdata/clean.mp4            # 720p / 48px / 有衬底
$BIN --make-sample testdata/hard.mp4  --hard     # 480p / 24px / 花背景无衬底
$BIN --make-sample testdata/tiny.mp4  --tiny     # 360p / 17px / 花背景无衬底
$BIN --make-sample testdata/faint.mp4 --faint    # 480p / 26px / 半透明 0.55 细描边

$BIN --extract testdata/tiny.mp4 out.srt --engine paddle
```

命令行参数：

| 参数 | 说明 |
|---|---|
| `--make-sample <输出.mp4>` | 生成测试视频，可加 `--hard` / `--tiny` / `--faint` / `--bilingual` / `--dense` |
| `--extract <视频> [输出.srt]` | 提取字幕，省略输出路径则打印到终端 |
| `--engine vision\|paddle` | 选择 OCR 引擎，默认 vision |
| `--fps <帧率>` | 采样帧率，默认 10（`--interval` 仍兼容） |
| `--roi <上,下>` | 字幕区域纵向范围，默认 `0.72,0.98` |
| `--interval <秒>` | 抽帧最小间隔，默认 `0.10` |
| `--verbose` | 打印每一帧的观测结果 |
| `--probe <视频> [秒]` | 单帧探测：取帧 → 裁剪 → OCR，输出中间量 |
| `--selftest <视频>` | 无界面驱动 GUI 用的那套 ViewModel，验证交互路径 |
| `--render-ui <输出.png>` | 离屏渲染界面快照（布局自检用） |

---

## 核心设计：锚点（anchor）

参考了 [望言OCR / SubtitleOCR](https://github.com/nhjydywd/SubtitleOCR)（Swift，GPL-3.0）的做法。
它的引擎接口里有一个关键结构：

```c
typedef struct SubtitleAnchor{
    int center_x, center_y, height;
    SubtitleLanguage lang;
    int is_primary;
    int avg_width, min_width, mid_width, max_width;
}SubtitleAnchor;
```

字幕不是一个矩形区域，而是**若干条固定的「行」**，每行带位置、高度、语种、主次标记和宽度统计。
流程是两阶段：先 `subocr_start_predet`（最多扫 20 分钟）自动发现这些行，再 `subocr_start_pipeline`
按 `fps` 采样逐行提取。字幕条目本身是**字符串数组**（`CStringArray`），一行一个锚点。

这解决了我之前实测出来的两个硬伤：固定矩形 ROI 必然在「放宽漏句」和「收紧切字」之间摇摆。

现在本项目的做法：

1. **分析字幕行**：扫描片头若干秒，把检测到的文本框按纵向位置聚类，得到稳定的行
   （位置取中位数、高度取 p75 再放大、宽度放宽 1.35 倍防止长句被切）。
2. **逐行提取**：每帧对每条锚点独立算感知哈希，只有变化的那一行才 OCR。
3. **跨锚点合并**：同一时刻有几行字幕就输出几行，双语因此天然是两条独立文本。

## 实测对比

四组单语样本 + 一组中英双语样本，两个引擎：

| 样本 | Vision | PaddleOCR |
|---|---|---|
| 720p / 48px | 4/4 | 4/4 |
| 480p / 24px / 花背景 | 4/4 | 4/4 |
| 360p / 17px / 花背景 | 4/4 | 4/4 |
| 480p / 26px / 半透明细描边 | 4/4 | 4/4 |
| 720p 中英双语两行 | 4 条 × 2 行 | 4 条 × 2 行 |

改成锚点之后 8 组单语组合全部满分（改造前 Vision 在 360p 上会多吐一个空格、Paddle 在半透明样本上
会把「行」读成「衍」）。双语样本两个引擎都能正确拆成两行、时间轴与真值一致。

内存：150 秒片子全程 79 MB 平坦，没有增长。

### 双语输出示例

```
3
00:00:06,033 --> 00:00:08,267
Hard subtitle extraction
硬字幕提取测试
```

### 调参经验（改造前用固定 ROI 测的，规律仍然适用）

| 参数 | 结果 | 原因 |
|---|---|---|
| `0.72–0.98` | 4/4 | 贴着字幕 |
| `0.60–1.00` | 3/4，最后一句丢失 | 区域变大后静止背景占比升高，感知哈希不敏感 |
| `0.80–0.90` | 3/4，第二句丢失且出错字 | 切掉了文字上半截，「幕」被认成「墓」 |

现在这个矩形只表示**去哪儿找字幕**，具体哪几行由自动分析决定，所以不再需要贴着字幕调。

## 界面

按 macOS 原生工具（Operate 类界面）的定位做的：系统控件、系统字体、单一强调色只用于主操作和选中态。

左栏播放区上方是文件信息条（文件名、分辨率、时长、跳句按钮、字幕区域框开关），
下方是状态条（进度 + OCR 帧数）。右侧是参数面板（默认折叠）和字幕列表。

几个不是装饰、而是解决实际问题的设计：

- **画面上直接叠加字幕区域框**。原来只能靠滑块盲调，现在框的位置实时可见，框外压暗，
  一眼能判断有没有框住字幕。这是这个工具最容易调错的参数，必须可见。
- **空状态给出主操作**。不是一句「请导入视频」，而是直接一个「选择视频」按钮。
- **识别中显示骨架行**，形状和真实行一致，结果出现时不跳版。
- **跳上一句 / 下一句**。校对时反复听同一句是最高频动作，播放器自带的控件做不到这个粒度。
- **菜单栏命令和快捷键**：⌘O 打开、⌘R 开始提取、⌘. 停止、⌘[ / ⌘] 跳句、⌘E 导出 SRT。
- **行内编辑无额外态**。文本用 plain TextField，看起来就是文字，点进去才能编辑；
  悬停才出现删除按钮，当前播放到的那一句用强调色淡底标出。

设计令牌集中在 `Views/Theme.swift`，间距、字号、颜色只从那里取，避免每个视图各写一套。

## 图标

`Scripts/make-icon.swift` 用 CoreGraphics 程序化生成，不依赖外部素材：

- 1024 画布，主体 824，遵循 macOS 图标网格
- 外形用 n≈5 的超椭圆采样，比圆角矩形更接近系统观感
- 深灰蓝屏幕渐变 + 上方一片柔光 + 内沿细边
- 底部一条暖白色字幕条，两行居中文字，长短不一

一条命令重新生成并打进包：

```bash
swift Scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
```

改颜色或比例直接改脚本里的常量，`make-app.sh` 每次打包都会重新生成。

---

## 格式兼容

AVFoundation 只覆盖 Apple 自己的编解码栈。为了兼容更多片源，内置了一份 FFmpeg 做兜底，
两套解码器自动切换：

| 情况 | 解码器 |
|---|---|
| H.264 / H.265 的 MP4、MOV，且能解出一帧 | AVFoundation（硬件加速，最快） |
| MKV / AVI / FLV / WMV 等容器 | FFmpeg |
| 10-bit H.264（High 10）、AV1、VP9、Dolby Vision | FFmpeg |
| 文件损坏 / 加密 | 直接报错，不启动提取 |

导入时会**真解一帧**验证，所以不会出现「点了开始提取才失败」。

FFmpeg 走**子进程**而不是链接 libav*：不用处理 ABI 和构建系统，库版本冲突也不会把 app 带崩。
帧率过滤和缩放交给 FFmpeg 的滤镜（`fps=N,scale=W:H`），读端按固定字节数切帧；
管道满时 FFmpeg 自然阻塞，形成背压，内存里始终只有一帧。

实测：

| 文件 | 编码 | 解码器 | 结果 |
|---|---|---|---|
| sample.mp4 | H.264 High | AVFoundation | 4/4 |
| sample_hevc.mp4 | H.265 | AVFoundation | 4/4 |
| sample.mkv | H.264 High | FFmpeg | 4/4 |
| hi10.mp4 | H.264 High 10 | FFmpeg | 4/4 |

内存：MKV 全程 86 MB 平坦。

> **许可提醒**：内置的 FFmpeg 是 `--enable-gpl` 构建（含 libx264/libx265）。
> 自己用没问题；如果要分发这个 app，需要遵守 GPL。换成 LGPL 构建（去掉 x264/x265）可以规避，
> 但那样就不能用 `-c:v libx264` 转码了 —— 本项目只做解码，理论上 LGPL 版够用。

## 速度

70 秒 720p、全片密集字幕（27 句）的实测拆解：

| 阶段 | 耗时 | 占比 |
|---|---|---|
| 解码 | 0.75s | 8% |
| 感知哈希 | 0.50s | 6% |
| 裁剪 | 0.12s | 1% |
| **OCR** | **4.64s** | **52%** |
| 字幕行分析（一次性） | ~2.5s | 28% |

OCR 是绝对大头。所以速度杠杆只有一个：**每句话识别几次**。

| 投票帧数 | OCR 次数 | 总耗时 | 准确率 |
|---|---|---|---|
| 1 | 55 | 5.9s | 四组样本全 4/4 |
| 2 | 110 | 7.8s | 四组样本全 4/4 |
| 3（默认） | 139 | 9.0s | 四组样本全 4/4 |

「投票帧数」在参数面板里可调。1 帧比 3 帧快约 1.5 倍，代价是对噪声大的片源少了一层保险。
合成样本上 1 帧也没掉准确率，但真实片源建议先用默认值跑，觉得慢再降。

按这个比例推算，2 小时的 1080p 片子（约 1800 句）：
默认设置约 5~6 分钟（20 倍速），投票帧数调到 1 约 3.5 分钟（33 倍速）。

**试过但没采用的两条优化**：

- **Vision 的 `.fast` 模式做字幕行分析** —— 实测快好几倍，但查了
  `supportedRecognitionLanguages(for: .fast)` 才发现它只支持 6 种拉丁语系，
  **完全不支持中日韩**，中文内容一行都认不出来。现在只在纯拉丁语种时才启用。
- **改 dHash 不生成中间 CGImage** —— 直接渲染到 9×8 缓冲区反而更慢（0.50s → 0.64s），
  因为每次都要新建 IOSurface。已回退。

`HS_PROFILE=1` 可以在命令行打印上面那张耗时拆解表。

## 架构

```
Sources/
├── COnnxRuntime/                   onnxruntime 的 C 桥接（dlopen 运行时加载）
│   ├── include/ort_shim.h
│   ├── include/onnxruntime_c_api.h
│   └── ort_shim.c
└── HardSubExtractor/
    ├── App/
    │   ├── ApplicationEntry.swift      入口，先判断命令行再决定是否进 GUI
    │   └── CommandLineRunner.swift     extract / probe / make-sample / render-ui
    ├── Models/
    │   ├── SubtitleAnchor.swift        字幕行锚点 + 语种判定
    ├── Pipeline/
    │   ├── VideoFrameSampler.swift     AVAssetReader 顺序解码 + 时间维抽稀
    │   ├── PixelToolkit.swift          ROI 裁剪 / 放大 / dHash 感知哈希
    │   ├── AnchorDetector.swift        扫描片头，自动发现字幕行（锚点）
    │   ├── BGRAImage.swift             CVPixelBuffer → 紧凑字节数组 + 双线性采样 + NCHW 归一化
    │   ├── OnnxSession.swift           onnxruntime 会话封装
    │   ├── SubtitleRecognizer.swift    OCR 引擎协议
    │   ├── VisionRecognizer.swift      Apple Vision 实现
    │   ├── PaddleOCRRecognizer.swift   DBNet 检测 + SVTR 识别 + CTC 解码
    │   ├── SubtitleAggregator.swift    逐行聚合 → 跨行合并 → 时间轴 ★最容易做砸
    │   └── ExtractionEngine.swift      管线编排
    ├── Export/SubtitleExporter.swift
    ├── ViewModels/  Views/
    └── DevTools/SampleVideoGenerator.swift

Resources/Models/                     det 2.3MB + rec 10MB + 字典
Vendor/onnxruntime/lib/               libonnxruntime.1.dylib 32MB
```

管线：

```
分析字幕行（扫片头）→ 得到 N 条锚点
        ↓
解码 → 逐行 dHash 判重 → 变化行才 OCR → 变化后补几帧投票 → 逐行聚合 → 跨行合并 → 时间轴 → 导出
```

### 关键设计决策

**1. onnxruntime 用 dlopen 而不是链接。**
`ort_shim.c` 在包含头文件前把 `OrtGetApiBase` 的声明改名，运行时再用 `dlsym` 取地址。
这样链接期不依赖 onnxruntime —— 缺库时应用照常启动，PaddleOCR 显示为不可用并给出原因，
而不是 dyld 直接崩在启动阶段。

**2. OCR 引擎抽象在最外层。**
下游只依赖 `SubtitleRecognizer` 协议。换引擎不需要动聚合、时间轴、导出、UI。

**3. 空文本观测不能丢。**
OCR 只在画面变化时触发。某帧识别出空文本 = 字幕刚消失，这是收尾上一句最精确的时间点。

**4. 判同一句要双条件。**
文本相似度（归一化编辑距离 ≥ 0.80）**且** 时间连续（间隔 ≤ 0.6s）。

**5. 同一句的多帧读法按置信度择优，不是按长度。**
实测踩到的坑：第一帧把「行」读成「衍」（置信度 0.916），后面有一帧读对了（0.990）。
早期版本用「取最长文本」的规则，因为两者等长，错误版本一直没被替换。现在分三种情况：
更长且置信度不差太多 → 采纳（补漏字）；更短 → 只有明显更可信才采纳；等长 → 直接比置信度。

---

## PaddleOCR 接入细节

### 依赖文件

| 文件 | 大小 | 来源 |
|---|---|---|
| `ch_PP-OCRv3_det_infer.onnx` | 2.3 MB | `pip install rapidocr-onnxruntime`，模型在包内 |
| `ch_PP-OCRv3_rec_infer.onnx` | 10 MB | 同上 |
| `ppocr_keys_v1.txt` | 26 KB | PaddleOCR 仓库 `ppocr/utils/` |
| `libonnxruntime.1.dylib` | 32 MB | `pip install onnxruntime`，在 `onnxruntime/capi/` |

### 实现要点

- **det**：输入缩放到长边 ≤1280、宽高补齐到 32 的倍数，ImageNet 均值方差归一化，
  **BGR** 通道序（模型按 cv2 约定训练）。输出概率图 → 阈值 0.3 二值化 →
  8 邻域连通域 → 面积/均分过滤 → 按 `area × ratio / perimeter` 做 unclip 膨胀 →
  同一水平线上的碎片框合并成整行。
- **rec**：文本框裁出后缩放到高 48、宽按比例（上限 320），归一化到 [-1,1]，
  右侧补 0 到 320。CTC 贪心解码，blank 在 index 0。
- **一个容易踩的坑**：PP-OCR 导出的 rec 模型末端**已经带 softmax**，输出就是概率。
  如果按 raw logits 再算一遍 softmax，置信度会被压到 0.0001 量级，全部被阈值过滤掉。
  代码里用取值域判断（>1 或 <0 才当 logits）来兼容两种导出方式。

### 模型选择：v3 还是 v4

PaddleOCR 官方仓库提供 v3/v4 的 ONNX 导出（HuggingFace `SWHL/RapidOCR` 有现成文件）。
两个都实测过，结论和直觉相反：

| 样本 | PP-OCRv3 | PP-OCRv4 |
|---|---|---|
| 720p / 48px，27 行 | 27/27 | 27/27 |
| 360p / 17px，27 行 | **27/27** | 24/27（会把「一」读成「→」，并把行切碎） |

v4 单字置信度更高（0.999 vs 0.98），但在小字上更容易切碎行。放大到 2 倍也救不回来，
而且慢到超时。v3 体积还小一半。

所以**默认用 v3**。想换 v4：把 `ch_PP-OCRv4_det_infer.onnx` 和 `ch_PP-OCRv4_rec_infer.onnx`
放进模型目录即可（`resolveModels()` 会自动识别），或者用 `HS_PADDLE_MODELS` 指向另一个目录。

注意：这些是合成样本的结论，真实片源上 v4 可能更好。换模型前先用你自己的片子跑一遍。

### 和官方参考实现的比对

对照了 `ppocr/postprocess/db_postprocess.py` 和 `tools/infer/predict_rec.py`，确认：

- **BGR 通道序**、ImageNet 均值方差、`(x/255-0.5)/0.5` 归一化 —— 一致
- **rec 补齐**用 0（归一化空间），不是 -1 —— 一致
- **CTC 字符表** `['blank'] + dict + [' ']` 共 6625 项 —— 一致
- **unclip** 距离 `area × ratio / perimeter` —— 一致

差异只在参数和近似：官方 `box_thresh=0.7`、`unclip_ratio=2.0`，本项目用 0.55 / 1.6。
因为官方算框分数时把框内背景也算进去（更严格），我只统计连通域内的像素（更宽松），
所以用更低的阈值能对上同样的召回。检测框用轴对齐矩形近似官方的旋转最小外接矩形，
对水平字幕没有区别。

官方还有个 `cls` 方向分类器（572KB）处理 180° 倒置文本，字幕场景极少见，没有引入。

---

## 已知限制

- **时间轴精度 ±0.1s**：受抽帧间隔限制。调到 0.04s 可提升，代价是慢 2.5 倍。
- **双语字幕**按行合并成一条（换行分隔），没有自动拆成两条独立字幕。
- **滚动字幕 / 卡拉OK 逐字变色**会被判成连续变化，可能产生大量碎片。
- **应用体积 93MB**：FFmpeg 48MB + onnxruntime 32MB + 模型 13MB。
  删掉 `Vendor/onnxruntime/lib/` 和 `Resources/Models/` 会让 PaddleOCR 降级；
  删掉 `Vendor/ffmpeg/` 会让格式兼容退回 AVFoundation 支持的范围。
- **未做音频对齐**，纯视觉方案。
- **批量处理**还没做，一次只能处理一个文件。

## 内存排查

正常占用：空载 90 MB 上下，提取长片时峰值 120~135 MB，全程平坦。
实测过的场景（720p，播放 + 提取同时进行）：

| 场景 | 峰值 |
|---|---|
| 12 秒，4 句字幕 | 78 MB |
| 120 秒，全片密集字幕（42 条） | 135 MB |
| 150 秒，播放中持续观察 130 秒 | 115 MB |

自己量一遍：

```bash
# 图形界面下
footprint -p $(pgrep -f "硬字幕提取器.app/Contents/MacOS")

# 或者在终端里跑，每 2 秒打一行内存
HS_DEBUG_MEMORY=1 "./build/硬字幕提取器.app/Contents/MacOS/HardSubExtractor" --gui 你的视频.mp4 --play --autorun
```

`--gui <视频>`、`--play`、`--autorun` 是开发用参数，可以不点界面就驱动完整流程，
方便测量和回归。

如果内存异常增长，先看是哪个阶段：载入视频就涨 → 播放器或视图层；
点开始提取才涨 → 提取管线；列表条数很多时涨 → 列表渲染。

### 已验证 / 未验证

已验证：两个引擎在四种难度样本上的端到端提取、SRT 生成、缺库降级、
GUI 的 ViewModel 路径（`--selftest` 驱动 `load → start → segments → 导出` 全流程）、
窗口正常渲染与长时间稳定运行、界面布局与字幕区域框的几何（离屏渲染 + 逐像素校验）。

未验证：真实鼠标交互（文件选择器弹窗、行内文本编辑、保存面板、快捷键）。
开发环境的屏幕录制权限受限，无法点击验证，只能靠代码路径覆盖。
离屏渲染也有盲区：TextField、Button、Slider、ProgressView、ScrollView 都是 AppKit 支撑的，
在快照里会渲染成占位块，所以这些控件的实际观感需要你打开应用确认。

## 下一步

1. 双语字幕自动分行（按 y 坐标聚类 + 语言检测）
2. 批量队列：一次拖入多集，后台串行处理
3. 时间轴微调：拖动字幕条 + 波形图辅助对齐
4. 导出 ASS，保留字号、颜色、位置
5. 用真实片源跑一轮评测，替换合成样本的结论

## 第三方组件

- onnxruntime — MIT
- PP-OCRv3 模型 — Apache-2.0
