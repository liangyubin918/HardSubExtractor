import Foundation
import SwiftUI
import AppKit
import AVFoundation

/// 开发用启动选项：允许不点界面就载入视频并开始提取，
/// 用于在没有辅助功能权限的环境下测量真实窗口的内存行为。
enum LaunchOptions {
    nonisolated(unsafe) static var initialVideo: URL?
    nonisolated(unsafe) static var autoStart = false
    nonisolated(unsafe) static var autoPlay = false
    nonisolated(unsafe) static var expandSettings = false
}

/// 跨视图共享 ViewModel 弱引用：退出确认（applicationShouldTerminate）需要
/// 读到当前窗口的模型，而 Commands/FocusedValue 在终止流程里不可靠。
@MainActor
final class UnsavedChangesGate {
    static let shared = UnsavedChangesGate()
    weak var model: ExtractorViewModel?
}

/// 关窗/退出时若有未导出的识别结果或修改，弹确认。
/// NSApplicationDelegate 的实现保证跑在主线程，用 assumeIsolated 进入模型。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = UnsavedChangesGate.shared.model, model.hasUnsavedChanges else {
                return NSApplication.TerminateReply.terminateNow
            }
            let alert = NSAlert()
            alert.messageText = "有未导出的字幕"
            alert.informativeText = "字幕列表里有尚未导出的识别结果或修改，退出后将丢失。"
            alert.addButton(withTitle: "仍要退出")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
                ? NSApplication.TerminateReply.terminateNow
                : NSApplication.TerminateReply.terminateCancel
        }
    }
}

@main
enum ApplicationEntry {
    static func main() {
        if CommandLineRunner.runIfNeeded() {
            exit(0)
        }

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--gui"), index + 1 < arguments.count {
            LaunchOptions.initialVideo = URL(fileURLWithPath: arguments[index + 1])
            LaunchOptions.autoStart = arguments.contains("--autorun")
            LaunchOptions.autoPlay = arguments.contains("--play")
            LaunchOptions.expandSettings = arguments.contains("--settings")
        }

        HardSubExtractorApp.main()
    }
}

struct HardSubExtractorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("硬字幕提取器") {
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands()
        }
    }
}

// MARK: - 菜单命令

/// 通过 focusedSceneValue 把窗口里的 ViewModel 传给菜单，
/// 这样菜单项和界面按钮操作的是同一个对象，不会出现两套状态。
struct ExtractorFocusKey: FocusedValueKey {
    typealias Value = ExtractorViewModel
}

extension FocusedValues {
    var extractor: ExtractorViewModel? {
        get { self[ExtractorFocusKey.self] }
        set { self[ExtractorFocusKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.extractor) private var model

    private var canStart: Bool {
        model?.canStart == true
    }

    private var hasSegments: Bool {
        model?.segments.isEmpty == false
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开视频…") {
                model?.isImporterPresented = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("开始提取") {
                model?.start()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!canStart)

            Button("停止提取") {
                model?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model?.isRunning != true)

            Divider()

            Button("撤销修改") {
                model?.undoLastEdit()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(model?.canUndo != true)

            Button("播放/暂停") {
                model?.togglePlayback()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model?.player == nil)

            Divider()

            Button("跳到上一句") {
                model?.seekToPreviousSegment()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!hasSegments)

            Button("跳到下一句") {
                model?.seekToNextSegment()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!hasSegments)

            Divider()

            Button("显示字幕区域框") {
                if let model { model.showsROIOverlay.toggle() }
            }
            .disabled(model?.hasVideo != true)
        }

        CommandGroup(after: .saveItem) {
            Divider()

            Menu("导出字幕") {
                Button("SRT 字幕 (.srt)") { model?.export(as: .srt) }
                    .keyboardShortcut("e", modifiers: .command)
                Button("WebVTT (.vtt)") { model?.export(as: .vtt) }
                Button("纯文本 (.txt)") { model?.export(as: .txt) }
            }
            .disabled(model?.exportableSegments.isEmpty != false)
        }
    }
}
