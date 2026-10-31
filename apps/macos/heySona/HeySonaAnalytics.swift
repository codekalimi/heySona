import Foundation
import PostHog

enum HeySonaAnalytics {

    

    static func configure() {
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    

    
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
    }

    

    
    static func trackOnboardingStarted() {
        PostHogSDK.shared.capture("onboarding_started")
    }

    
    static func trackOnboardingCompleted() {
        PostHogSDK.shared.capture("onboarding_completed")
    }

    
    static func trackOnboardingReplayed() {
        PostHogSDK.shared.capture("onboarding_replayed")
    }

    
    static func trackOnboardingDemoTriggered() {
        PostHogSDK.shared.capture("onboarding_demo_triggered")
    }

    

    
    static func trackAllPermissionsGranted() {
        PostHogSDK.shared.capture("all_permissions_granted")
    }

    
    static func trackPermissionGranted(permission: String) {
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    

    
    static func trackPushToTalkStarted() {
        PostHogSDK.shared.capture("push_to_talk_started")
    }

    
    static func trackPushToTalkReleased() {
        PostHogSDK.shared.capture("push_to_talk_released")
    }

    
    static func trackUserMessageSent(transcript: String) {
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    
    static func trackAIResponseReceived(response: String) {
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    
    
    static func trackElementPointed(elementLabel: String?) {
        PostHogSDK.shared.capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    

    
    static func trackResponseError(error: String) {
        PostHogSDK.shared.capture("response_error", properties: [
            "error": error
        ])
    }

    
    static func trackTTSError(error: String) {
        PostHogSDK.shared.capture("tts_error", properties: [
            "error": error
        ])
    }
}
