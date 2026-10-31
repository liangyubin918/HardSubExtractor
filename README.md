# 硬字幕提取器

从视频画面里把「烧进画面」的字幕识别出来，生成 SRT / VTT 字幕文件。
macOS 原生 SwiftUI，纯本地运行，不上传任何视频。

## 功能

- **双 OCR 引擎** —— Apple Vision（系统内置零依赖）/ PaddleOCR ONNX（中文小字更准），可切换
- **锚点式识别** —— 自动定位字幕在画面上的位置，逐行独立判重与识别，双语字幕天然拆行
- **格式兼容** —— AVFoundation 优先，内置 FFmpeg 兜底：MKV / AVI / 10-bit H.264 / AV1 / VP9 都能解
- **GUI 校对** —— 搜索、撤销、时间轴编辑、片段合并、拖拽调整识别区域、疑似水印过滤
- **完整 CLI** —— 提取 / 单帧探测 / 合成测试视频生成 / 界面快照，方便自动化与回归

## 快速开始

系统要求：macOS 14+。仓库已附带 `Vendor/`（ffmpeg、onnxruntime）与 `Resources/Models/`（OCR 模型），克隆即可构建。

```bash
git clone https://github.com/liangyubin918/HardSubExtractor.git
cd HardSubExtractor
./Scripts/make-app.sh
open "build/硬字幕提取器.app"
```

没有素材也能立刻验证，内置合成测试视频生成器：

```bash
BIN="build/硬字幕提取器.app/Contents/MacOS/HardSubExtractor"
$BIN --make-sample testdata/clean.mp4          # 720p 标准字幕
$BIN --make-sample testdata/tiny.mp4  --tiny   # 360p 小字花背景（最难）
$BIN --extract testdata/tiny.mp4 out.srt --engine paddle
```

### 常用命令行

| 命令 | 说明 |
|---|---|
| `--extract <视频> [输出.srt]` | 提取字幕，省略输出路径则打印到终端 |
| `--engine vision\|paddle` | OCR 引擎，默认 vision |
| `--fps <帧率>` | 采样帧率，默认 10 |
| `--roi <上,下>` | 字幕区域纵向范围 |
| `--make-sample <输出.mp4>` | 生成测试视频，可加 `--hard` / `--tiny` / `--faint` / `--bilingual` / `--dense` |
| `--probe` / `--selftest` / `--render-ui` | 单帧探测 / GUI 路径自检 / 界面快照（开发调试用） |

## 实测

四种难度合成样本（720p 大字 → 360p 小字花背景 → 半透明细描边）+ 中英双语，两个引擎全部满分；
MKV、10-bit H.264 由 FFmpeg 后端正确处理。70 秒 720p 密集字幕（27 句）默认设置约 9 秒完成。
完整实测数据与调参经验见 [docs/DESIGN.md](docs/DESIGN.md)。

## 已知限制

- 时间轴精度 ±0.1s（受采样间隔限制，调密更准但更慢）
- 双语字幕按行合并为一条（换行分隔），未自动拆成两条独立字幕
- 滚动字幕、卡拉OK 逐字特效可能产生碎片
- 纯视觉方案，无音频对齐；一次处理一个文件

## 设计

核心是「锚点」：字幕不是一个矩形区域，而是若干条位置固定的「行」。先扫片头自动发现这些行，
之后每行独立感知哈希判重、只对变化的行做 OCR、多帧投票定稿。
设计决策、PaddleOCR 接入细节、性能与内存实测等完整笔记见 [docs/DESIGN.md](docs/DESIGN.md)。

锚点设计参考 [望言OCR / SubtitleOCR](https://github.com/nhjydywd/SubtitleOCR)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
内置组件：onnxruntime（MIT）、PP-OCRv3 模型（Apache-2.0）、FFmpeg 为 GPL 构建（仅解码自用）。
