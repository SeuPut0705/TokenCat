import Foundation
import ServiceManagement

/// Login item registration happens only from the explicit settings toggle; nothing calls it automatically.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static func isOn(_ status: SMAppService.Status) -> Bool { status == .enabled || status == .requiresApproval }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return loc("켜짐 · macOS 로그인 항목에 등록돼 있습니다", "On · registered as a macOS login item")
        case .requiresApproval: return loc("시스템 설정 > 일반 > 로그인 항목에서 허용이 필요합니다",
                                           "Needs approval in System Settings > General > Login Items")
        case .notRegistered: return loc("꺼짐 · 켤 때만 로그인 항목에 등록합니다", "Off · registers as a login item only when you turn it on")
        case .notFound: return loc("꺼짐 · 로그인 항목에 등록돼 있지 않습니다", "Off · not registered as a login item")
        @unknown default: return loc("로그인 항목 상태를 확인할 수 없습니다", "Can't read the login item status")
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
