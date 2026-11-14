import Foundation

/// 应用版本号的唯一来源。
///
/// `Scripts/make-app.sh` 从这个文件 grep 出版本号写进 Info.plist，
/// 改版本只改这一行，避免脚本和代码两处漂移。
/// （CLI 直接跑 .build 里的裸二进制时没有 Info.plist，版本号以这里为准。）
enum AppVersion {
    static let current = "0.3.0"
}
