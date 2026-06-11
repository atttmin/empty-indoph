//
//  AIProviderSettings.swift
//  Empty
//

import Foundation

/// Which inference route serves AI features.
nonisolated enum AIProviderMode: String, CaseIterable, Sendable {
    /// Apple's Foundation Models: free, offline, private — the default.
    case onDevice
    /// An OpenAI-compatible endpoint (DeepSeek preset) with the user's key.
    case cloud
}

/// Persisted provider choice. Only non-secrets live in UserDefaults;
/// the API key goes through `KeychainStore`.
nonisolated struct AIProviderSettings: Equatable, Sendable {
    var mode: AIProviderMode = .onDevice
    var cloudBaseURL: String = Self.deepSeekBaseURL
    var cloudModel: String = Self.deepSeekModel

    static let deepSeekBaseURL = "https://api.deepseek.com"
    /// Fast/cheap default; the right fit for summarize/recap workloads.
    static let deepSeekModel = "deepseek-v4-flash"
    /// Deeper-reasoning sibling for heavier analysis (argument maps etc.).
    static let deepSeekProModel = "deepseek-v4-pro"
    /// Keychain account under which the cloud key is stored.
    static let apiKeyAccount = "cloud-provider-api-key"

    private enum Keys {
        static let mode = "ai.provider.mode"
        static let baseURL = "ai.cloud.baseURL"
        static let model = "ai.cloud.model"
    }

    static func load(from defaults: UserDefaults = .standard) -> AIProviderSettings {
        var settings = AIProviderSettings()
        if let raw = defaults.string(forKey: Keys.mode),
           let mode = AIProviderMode(rawValue: raw) {
            settings.mode = mode
        }
        if let baseURL = defaults.string(forKey: Keys.baseURL), !baseURL.isEmpty {
            settings.cloudBaseURL = baseURL
        }
        if let model = defaults.string(forKey: Keys.model), !model.isEmpty {
            settings.cloudModel = model
        }
        // DeepSeek retires the V3-era aliases on 2026-07-24; upgrade stored
        // configs to their V4 equivalents (chat → flash, reasoner → pro).
        if settings.cloudBaseURL == Self.deepSeekBaseURL {
            if settings.cloudModel == "deepseek-chat" {
                settings.cloudModel = Self.deepSeekModel
            } else if settings.cloudModel == "deepseek-reasoner" {
                settings.cloudModel = Self.deepSeekProModel
            }
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(cloudBaseURL, forKey: Keys.baseURL)
        defaults.set(cloudModel, forKey: Keys.model)
    }

    /// Builds the service for the current choice. `apiKey` defaults to the
    /// stored Keychain secret; pass explicitly in tests.
    @MainActor
    func resolveService(
        apiKey: String? = KeychainStore.read(account: AIProviderSettings.apiKeyAccount)
    ) -> any AIService {
        switch mode {
        case .onDevice:
            return FoundationModelsAIService()
        case .cloud:
            return CloudAIService(
                configuration: CloudAIService.Configuration(
                    baseURLString: cloudBaseURL,
                    model: cloudModel,
                    apiKey: apiKey ?? ""
                )
            )
        }
    }

    /// The chosen route's service when it can serve; otherwise the *other*
    /// route when it can (e.g. on-device model ineligible but a DeepSeek key
    /// is configured — features shouldn't dead-end). When neither is usable,
    /// returns the chosen route's service so its unavailability reason
    /// surfaces to the user.
    @MainActor
    func resolveUsableService(
        apiKey: String? = KeychainStore.read(account: AIProviderSettings.apiKeyAccount)
    ) -> (service: any AIService, route: AIProviderMode, fellBack: Bool) {
        let chosen = resolveService(apiKey: apiKey)
        if chosen.availability.isAvailable {
            return (chosen, mode, false)
        }
        var alternate = self
        alternate.mode = mode == .onDevice ? .cloud : .onDevice
        let alternateService = alternate.resolveService(apiKey: apiKey)
        if alternateService.availability.isAvailable {
            return (alternateService, alternate.mode, true)
        }
        return (chosen, mode, false)
    }
}
