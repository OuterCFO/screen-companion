@preconcurrency import AVFoundation
import OCComputerUseCore
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OCCore
import OCUI
import OCMarkdown
import OCMemory

extension CompanionManager {
    func beginRequestTiming(source: String, text: String) -> OpenClickyRequestTiming {
        let timing = OpenClickyRequestTiming(
            requestID: UUID().uuidString,
            source: source,
            text: text,
            requestedAt: Date()
        )
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: "incoming",
            event: "openclicky.request.received",
            fields: requestTimingFields(
                timing,
                extra: [
                    "textLength": text.count,
                    "textPreview": Self.truncatedLogText(text, maxLength: 240)
                ]
            )
        )
        return timing
    }

    func withActiveRequestTiming<T>(_ timing: OpenClickyRequestTiming, perform work: () -> T) -> T {
        let previousTiming = activeRequestTiming
        activeRequestTiming = timing
        defer { activeRequestTiming = previousTiming }
        return work()
    }

    func markRequestExecutionStarted(
        route: String,
        timing: OpenClickyRequestTiming? = nil,
        extra: [String: Any] = [:]
    ) -> Date {
        let startedAt = Date()
        var fields = extra
        fields["executionStartedAt"] = startedAt
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: "outgoing",
            event: "openclicky.request.execution_started",
            fields: requestTimingFields(
                timing ?? activeRequestTiming,
                route: route,
                at: startedAt,
                extra: fields
            )
        )
        return startedAt
    }

    func markRequestStageCompleted(
        route: String,
        stage: String,
        stageStartedAt: Date,
        timing: OpenClickyRequestTiming? = nil,
        status: String = "success",
        extra: [String: Any] = [:]
    ) {
        let completedAt = Date()
        var fields = extra
        fields["stage"] = stage
        fields["status"] = status
        fields["stageStartedAt"] = stageStartedAt
        fields["stageCompletedAt"] = completedAt
        fields["stageDurationMs"] = Self.elapsedMilliseconds(from: stageStartedAt, to: completedAt)
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: "outgoing",
            event: "openclicky.request.stage_completed",
            fields: requestTimingFields(
                timing ?? activeRequestTiming,
                route: route,
                status: status,
                at: completedAt,
                extra: fields
            )
        )
    }

    func markRequestCompleted(
        route: String,
        executionStartedAt: Date? = nil,
        timing: OpenClickyRequestTiming? = nil,
        status: String = "success",
        extra: [String: Any] = [:]
    ) {
        let completedAt = Date()
        var fields = extra
        fields["status"] = status
        fields["completedAt"] = completedAt
        if let executionStartedAt {
            fields["executionStartedAt"] = executionStartedAt
            fields["executionDurationMs"] = Self.elapsedMilliseconds(from: executionStartedAt, to: completedAt)
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "request",
            direction: status == "success" ? "outgoing" : "error",
            event: "openclicky.request.completed",
            fields: requestTimingFields(
                timing ?? activeRequestTiming,
                route: route,
                status: status,
                at: completedAt,
                extra: fields
            )
        )
    }

    func requestTimingFields(
        _ timing: OpenClickyRequestTiming?,
        route: String? = nil,
        status: String? = nil,
        at: Date = Date(),
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var fields = extra
        fields["timingEventAt"] = at
        if let route {
            fields["route"] = route
        }
        if let status {
            fields["status"] = status
        }
        guard let timing else {
            fields["requestID"] = "none"
            return fields
        }

        fields["requestID"] = timing.requestID
        fields["requestSource"] = timing.source
        fields["requestReceivedAt"] = timing.requestedAt
        fields["requestAgeMs"] = Self.elapsedMilliseconds(from: timing.requestedAt, to: at)
        return fields
    }

    static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func elapsedMilliseconds(since startDate: Date?) -> Int {
        guard let startDate else { return -1 }
        return elapsedMilliseconds(from: startDate, to: Date())
    }

    static func voiceResponseCompletionAudioPlaybackState(
        spokenText: String,
        playbackFinished: Bool,
        audioStarted: Bool = true
    ) -> String {
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "empty"
        }
        // A TTS session whose engine was torn down still resolves finish()
        // successfully — "finished" is only honest if audio actually
        // reached the speaker.
        guard audioStarted else {
            return "never_started"
        }
        return playbackFinished ? "finished" : "interrupted"
    }

    static func truncatedLogText(_ value: String, maxLength: Int) -> String {
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        return String(flattened.prefix(maxLength))
    }

    func voiceResponseExecutionFields(effectiveModelID: String? = nil) -> [String: Any] {
        let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
        let executionModel = effectiveModelID.map { OpenClickyModelCatalog.voiceResponseModel(withID: $0) }
            ?? selectedVoiceResponseModel
        var fields: [String: Any] = [
            "executor": "voice_response",
            "model": executionModel.id,
            "modelProvider": executionModel.provider.rawValue,
            "maxOutputTokens": executionModel.maxOutputTokens
        ]

        if executionModel.id != selectedVoiceResponseModel.id {
            fields["selectedVoiceResponseModel"] = selectedVoiceResponseModel.id
            fields["visualAnalysisModel"] = executionModel.id
        }

        // Reports the provider that will actually answer, in fallback order.
        let available = answerProviders.chain(for: executionModel).filter(\.isAvailable)
        fields["provider"] = available.first?.id ?? "none"
        fields["billing"] = available.first.map { String(describing: $0.billing) } ?? "none"
        fields["fallbackProviders"] = available.dropFirst().map(\.id).joined(separator: ",")

        return fields
    }
}
