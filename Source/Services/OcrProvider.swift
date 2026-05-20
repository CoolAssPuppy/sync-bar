//
//  OcrProvider.swift
//  SyncNerds
//
//  Copyright (c) 2026 Strategic Nerds. All rights reserved.
//

import Foundation
import AppKit
// Vision predates Sendable. VNImageRequestHandler / VNRecognizeTextRequest are
// created locally and only touched on the background queue below, so the
// capture is race-free; @preconcurrency silences the Sendable warnings.
@preconcurrency import Vision

/// Outcome of an OCR transcription, including any detected diagram.
struct OcrResult: Sendable, Equatable {
    var text: String
    var mermaidSource: String?
    var provider: String
    var model: String?
    var tokensIn: Int?
    var tokensOut: Int?

    /// Combined plain-text body used in destinations that don't render mermaid.
    var combined: String {
        guard let mermaidSource else { return text }
        return text + "\n\n```mermaid\n\(mermaidSource)\n```"
    }
}

enum OcrError: LocalizedError, Sendable {
    case visionFailed(String)
    case providerKeyMissing(provider: String)
    case providerRefused(String)
    case rateLimited
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .visionFailed(let msg):                return "Vision OCR failed: \(msg)"
        case .providerKeyMissing(let provider):     return "Add your \(provider) API key in Settings to use this provider."
        case .providerRefused(let reason):          return reason
        case .rateLimited:                          return "OCR provider rate-limited us. Try again in a minute."
        case .network(let msg):                     return msg
        case .decoding(let msg):                    return "Couldn't decode the OCR response: \(msg)"
        }
    }
}

protocol OcrProvider: Sendable {
    var name: String { get }
    func transcribe(imageData: Data) async throws -> OcrResult
}

// MARK: - Vision (on-device)

/// Apple's Vision framework. Pure on-device OCR, no network. Used by default.
/// Vision doesn't take prompts; we just call `VNRecognizeTextRequest` and
/// post-process the result so it lines up with `OCRPrompts` conventions.
struct VisionOcrProvider: OcrProvider {
    let name = "vision"

    func transcribe(imageData: Data) async throws -> OcrResult {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return OcrResult(text: "[blank page]", mermaidSource: nil, provider: name, model: nil, tokensIn: nil, tokensOut: nil)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OcrResult, Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OcrError.visionFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = OcrResult(
                    text: cleaned.isEmpty ? "[blank page]" : cleaned,
                    mermaidSource: nil,
                    provider: "vision",
                    model: "VNRecognizeTextRequest",
                    tokensIn: nil,
                    tokensOut: nil
                )
                continuation.resume(returning: result)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(throwing: OcrError.visionFailed(error.localizedDescription)) }
            }
        }
    }
}

// MARK: - OpenAI

struct OpenAIOcrProvider: OcrProvider {
    let name = "openai"
    let apiKey: String
    let model: String

    func transcribe(imageData: Data) async throws -> OcrResult {
        guard !apiKey.isEmpty else { throw OcrError.providerKeyMissing(provider: "OpenAI") }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": OCRPrompts.systemPrompt],
                ["role": "user", "content": [
                    ["type": "text", "text": OCRPrompts.userMessage],
                    ["type": "image_url",
                     "image_url": ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]]
                ]]
            ],
            "max_tokens": 2_000
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)

        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        let raw = parsed.choices.first?.message.content ?? ""
        let extracted = OCRPrompts.extractMermaid(from: raw)
        return OcrResult(
            text: extracted.text,
            mermaidSource: extracted.mermaidSource,
            provider: "openai",
            model: model,
            tokensIn: parsed.usage?.prompt_tokens,
            tokensOut: parsed.usage?.completion_tokens
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 429:       throw OcrError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OcrError.providerRefused("OpenAI returned \(http.statusCode): \(body.prefix(200))")
        }
    }
}

// MARK: - Anthropic

struct AnthropicOcrProvider: OcrProvider {
    let name = "anthropic"
    let apiKey: String
    let model: String

    func transcribe(imageData: Data) async throws -> OcrResult {
        guard !apiKey.isEmpty else { throw OcrError.providerKeyMissing(provider: "Anthropic") }

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 2_000,
            "system": OCRPrompts.systemPrompt,
            "messages": [
                ["role": "user", "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png",
                                "data": imageData.base64EncodedString()]],
                    ["type": "text", "text": OCRPrompts.userMessage]
                ]]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
            let content: [Block]
            let usage: Usage?
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        let raw = parsed.content.compactMap { $0.text }.joined(separator: "\n")
        let extracted = OCRPrompts.extractMermaid(from: raw)
        return OcrResult(
            text: extracted.text,
            mermaidSource: extracted.mermaidSource,
            provider: "anthropic",
            model: model,
            tokensIn: parsed.usage?.input_tokens,
            tokensOut: parsed.usage?.output_tokens
        )
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 429:       throw OcrError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OcrError.providerRefused("Anthropic returned \(http.statusCode): \(body.prefix(200))")
        }
    }
}

// MARK: - Factory

enum OcrProviderFactory {
    static func make(provider: OcrProviderChoice, model: String, keychain: KeychainStore = .shared) -> OcrProvider {
        switch provider {
        case .vision:
            return VisionOcrProvider()
        case .openai:
            let resolvedModel = model.isEmpty ? "gpt-4o-mini" : model
            return OpenAIOcrProvider(apiKey: keychain.value(for: .openaiApiKey) ?? "", model: resolvedModel)
        case .anthropic:
            let resolvedModel = model.isEmpty ? "claude-sonnet-4-6" : model
            return AnthropicOcrProvider(apiKey: keychain.value(for: .anthropicApiKey) ?? "", model: resolvedModel)
        }
    }
}
