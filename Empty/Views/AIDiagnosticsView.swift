//
//  AIDiagnosticsView.swift
//  Empty
//

import SwiftUI

/// AI provider configuration + end-to-end check: pick the route (on-device
/// Apple Intelligence or an OpenAI-compatible cloud endpoint, BYOK), then
/// prove the pipeline with a windowed summarize round trip.
struct AIDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = AIProviderSettings.load()
    @State private var apiKey = KeychainStore.read(account: AIProviderSettings.apiKeyAccount) ?? ""

    @State private var sampleText = ""
    @State private var summary = ""
    @State private var errorMessage = ""
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Route", selection: $settings.mode) {
                        Text("On-Device (Apple)").tag(AIProviderMode.onDevice)
                        Text("Cloud (OpenAI-compatible)").tag(AIProviderMode.cloud)
                    }

                    if settings.mode == .cloud {
                        TextField("Base URL", text: $settings.cloudBaseURL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        TextField("Model", text: $settings.cloudModel)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        SecureField("API Key", text: $apiKey)
                        HStack {
                            Button("DeepSeek Flash") {
                                applyDeepSeekPreset(model: AIProviderSettings.deepSeekModel)
                            }
                            Button("DeepSeek Pro") {
                                applyDeepSeekPreset(model: AIProviderSettings.deepSeekProModel)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section("Status") {
                    availabilityRow
                }

                Section("Summarize Round Trip") {
                    TextField(
                        "Paste a few paragraphs…",
                        text: $sampleText,
                        axis: .vertical
                    )
                    .lineLimit(4...10)

                    Button {
                        runRoundTrip()
                    } label: {
                        if isRunning {
                            ProgressView()
                        } else {
                            Text("Summarize")
                        }
                    }
                    .disabled(
                        isRunning
                            || !resolvedAvailability.isAvailable
                            || sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    if !summary.isEmpty {
                        Text(summary).textSelection(.enabled)
                    }
                    if !errorMessage.isEmpty {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("AI Provider")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: settings) { _, newValue in
                newValue.save()
            }
            .onChange(of: apiKey) { _, newValue in
                persistAPIKey(newValue)
            }
        }
    }

    private var resolvedAvailability: AIAvailability {
        settings.resolveService(apiKey: apiKey).availability
    }

    @ViewBuilder
    private var availabilityRow: some View {
        switch resolvedAvailability {
        case .available:
            Label(
                settings.mode == .onDevice
                    ? "On-device model available"
                    : "\(settings.cloudModel) @ \(settings.cloudBaseURL)",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private func applyDeepSeekPreset(model: String) {
        settings.cloudBaseURL = AIProviderSettings.deepSeekBaseURL
        settings.cloudModel = model
    }

    private func persistAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: AIProviderSettings.apiKeyAccount)
        } else {
            try? KeychainStore.save(trimmed, account: AIProviderSettings.apiKeyAccount)
        }
    }

    private func runRoundTrip() {
        summary = ""
        errorMessage = ""
        isRunning = true
        let text = sampleText
        let service = settings.resolveService(apiKey: apiKey)
        Task {
            defer { isRunning = false }
            do {
                summary = try await service.summarize(text, focus: .digest)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    AIDiagnosticsView()
}
