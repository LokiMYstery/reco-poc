import Foundation

public enum VirtualUserRegistry {
    public static let builtInDefinitions: [VirtualUserDefinition] = [
        .init(key: "u_full_permission", displayName: "全权限上限基线", purpose: "验证完整上下文效果", mask: .init(location: .full, motion: .full, health: .full, microphone: .full, calendar: .full, questionnaire: .full)),
        .init(key: "u_minimal_context", displayName: "极简隐私用户", purpose: "只保留时间、网络、蓝牙、App 行为", mask: .init(location: .none, motion: .none, health: .none, microphone: .none, calendar: .none, questionnaire: .none)),
        .init(key: "u_no_location", displayName: "拒绝定位", purpose: "健康/运动可用，靠问卷补地点缺失", mask: .init(location: .none, motion: .full, health: .full, microphone: .none, calendar: .none, questionnaire: .basic)),
        .init(key: "u_approx_location", displayName: "大致位置 / 地点低置信", purpose: "测试地点降权 + intent 兜底", mask: .init(location: .approximate, motion: .full, health: .full, microphone: .none, calendar: .none, questionnaire: .basic)),
        .init(key: "u_location_only_no_health", displayName: "给定位，不给健康", purpose: "常见普通用户组合", mask: .init(location: .full, motion: .none, health: .none, microphone: .none, calendar: .none, questionnaire: .basic)),
        .init(key: "u_motion_only_no_health", displayName: "有运动状态，无 HealthKit", purpose: "只靠 CoreMotion", mask: .init(location: .full, motion: .full, health: .none, microphone: .none, calendar: .none, questionnaire: .none)),
        .init(key: "u_steps_only_no_hr_sleep", displayName: "HealthKit 细粒度授权", purpose: "只给步数，不给心率/睡眠", mask: .init(location: .full, motion: .full, health: .stepsOnly, microphone: .none, calendar: .none, questionnaire: .basic)),
        .init(key: "u_no_watch_health_partial", displayName: "无手表心率", purpose: "iPhone-only 或无心率设备", mask: .init(location: .full, motion: .full, health: .noWatch, microphone: .none, calendar: .none, questionnaire: .none)),
        .init(key: "u_no_calendar_no_microphone", displayName: "拒绝高隐私增强", purpose: "核心权限可用，但不给麦克风/日历", mask: .init(location: .full, motion: .full, health: .full, microphone: .none, calendar: .none, questionnaire: .full)),
        .init(key: "u_calendar_enabled", displayName: "只测试日历增强", purpose: "验证日历是否提升特定场景", mask: .init(location: .full, motion: .full, health: .full, microphone: .none, calendar: .full, questionnaire: .basic)),
        .init(key: "u_noise_enabled", displayName: "只测试噪音增强", purpose: "验证环境噪音是否有用", mask: .init(location: .full, motion: .full, health: .full, microphone: .full, calendar: .none, questionnaire: .basic)),
        .init(key: "u_no_bluetooth_route", displayName: "蓝牙/音频路由缺失", purpose: "`bluetooth=任意`", mask: .init(location: .full, motion: .full, health: .full, microphone: .none, calendar: .none, audioRoute: .unknown, questionnaire: .none)),
        .init(key: "u_weak_cellular_commuter", displayName: "蜂窝弱网通勤", purpose: "通勤/在途弱网场景", mask: .init(location: .full, motion: .full, health: .noWatch, microphone: .none, calendar: .none, network: .weakCellular, questionnaire: .basic)),
        .init(key: "u_home_speaker_no_health", displayName: "家用音响 + 无健康", purpose: "家庭/睡眠/照护类弱信号", mask: .init(location: .full, motion: .none, health: .none, microphone: .none, calendar: .none, questionnaire: .basic)),
        .init(key: "u_full_no_questionnaire", displayName: "全传感器但无问卷", purpose: "测试没有 intent 时传感器是否足够", mask: .init(location: .full, motion: .full, health: .full, microphone: .full, calendar: .full, questionnaire: .none)),
        .init(key: "u_intent_only_minimal_context", displayName: "极简权限但有问卷", purpose: "测试 intent 对冷启动的兜底能力", mask: .init(location: .none, motion: .none, health: .none, microphone: .none, calendar: .none, questionnaire: .full))
    ]

    public static let builtInKeys: [String] = builtInDefinitions.map(\.key)

    public static func defaultUsers(deviceUUID: String) -> [VirtualUser] {
        builtInDefinitions.map { materialize($0, deviceUUID: deviceUUID) }
    }

    public static func users(for willingness: PermissionWillingness, questionnaire: QuestionnaireState, deviceUUID: String) -> [VirtualUser] {
        var users = defaultUsers(deviceUUID: deviceUUID)
        if !builtInDefinitions.contains(where: { $0.mask == willingness.asMask }) {
            let key = StableIdentityDeriver.adHocVirtualUserKey(willingness: willingness, questionnaire: questionnaire)
            users.append(VirtualUser(
                key: key,
                displayName: "自定义权限组合",
                purpose: "被试当前 willingness/questionnaire 未命中内置组合",
                mask: willingness.asMask,
                userID: StableIdentityDeriver.userID(deviceUUID: deviceUUID, virtualUserKey: key)
            ))
        }
        return users
    }

    private static func materialize(_ definition: VirtualUserDefinition, deviceUUID: String) -> VirtualUser {
        VirtualUser(
            key: definition.key,
            displayName: definition.displayName,
            purpose: definition.purpose,
            mask: definition.mask,
            userID: StableIdentityDeriver.userID(deviceUUID: deviceUUID, virtualUserKey: definition.key)
        )
    }
}

public protocol VirtualUserProviding: Sendable {
    func users(for willingness: PermissionWillingness, questionnaire: QuestionnaireState, deviceUUID: String) -> [VirtualUser]
}

public struct RegistryVirtualUserProvider: VirtualUserProviding {
    public init() {}

    public func users(for willingness: PermissionWillingness, questionnaire: QuestionnaireState, deviceUUID: String) -> [VirtualUser] {
        VirtualUserRegistry.users(for: willingness, questionnaire: questionnaire, deviceUUID: deviceUUID)
    }
}
