import Foundation
import AppKit

/// 更新检查：查询 GitHub Releases 的最新版本号，与当前版本比较。
///
/// 这是整个应用唯一的网络调用——只取一个 JSON 的 tag_name 字段，
/// 不上传任何视频或用户数据（README「纯本地运行」的承诺不因此破例）。
/// 形态参考 VSE 的 version_service.py：5 秒超时、失败静默降级、
/// 提示后跳转 Releases 页面让用户手动下载，不做应用内下载。
enum UpdateService {

    // 仓库发布 Release 后检查即生效；启动时的自动检查默认关闭
    //（UserDefaults 键 checkUpdateOnStartup），用户可手动「检查更新…」。
    private static let repoOwner = "liangyubin918"
    private static let repoName = "HardSubExtractor"

    /// Releases 页面（提示用户去这里下载新版）
    static var releasesPageURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases")!
    }

    struct Release: Equatable {
        let version: String
    }

    enum Outcome: Equatable {
        case upToDate
        case updateAvailable(Release)
        /// 网络失败、仓库不存在、响应解析不出来——一律静默降级，不当错误弹
        case unavailable
    }

    /// 查询最新版本并与当前版本比较。
    static func checkForUpdate(timeout: TimeInterval = 5) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return .unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // GitHub API 要求带 User-Agent，否则 403
        request.setValue("HardSubExtractor/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let latest = parseVersion(release.tagName),
              let current = parseVersion(AppVersion.current) else {
            return .unavailable
        }

        guard isVersion(latest, newerThan: current) else { return .upToDate }
        return .updateAvailable(Release(version: release.tagName))
    }

    // MARK: - 内部

    /// 只解析需要的字段
    private struct GitHubRelease: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    /// "v2.10.3" / "2.10" → [2, 10, 3]。解析失败返回 nil（非版本号 tag 视为不可用）。
    private static func parseVersion(_ tag: String) -> [Int]? {
        let digits = tag.split(separator: ".")
            .map { $0.prefix(while: \.isNumber) }
            .map { Int($0) }
        guard !digits.isEmpty, digits.allSatisfy({ $0 != nil }) else { return nil }
        return digits.map { $0! }
    }

    /// 逐段数值比较，2.10.0 > 2.9.0；段数不齐按短的一方补 0
    private static func isVersion(_ left: [Int], newerThan right: [Int]) -> Bool {
        let length = max(left.count, right.count)
        for index in 0..<length {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
