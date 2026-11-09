//
//  OllamaProvider+Transcription.swift
//  Dayflow
//

import AppKit
import Foundation

extension OllamaProvider {
  private struct FrameData {
    let image: Data  // Base64 encoded image
    let timestamp: TimeInterval  // Seconds from batch start
  }

  private func getSimpleFrameDescription(_ frame: FrameData, batchId: Int64?) async -> String? {
    // Simple prompt focused on just describing what's happening
    let prompt = """
      Describe what you see on this computer screen in 1-2 sentences.
      Focus on: what application/site is open, what the user is doing, and any relevant details visible.
      Be specific and factual.

      GOOD EXAMPLES:
      ✓ "VS Code open with index.js file, writing a React component for user authentication."
      ✓ "Gmail compose window writing email to client@company.com about project timeline."
      ✓ "Slack conversation in #engineering channel discussing API rate limiting issues."

      BAD EXAMPLES:
      ✗ "User is coding" (too vague)
      ✗ "Looking at a website" (doesn't identify which site)
      ✗ "Working on computer" (completely non-specific)

      \(LLMOutputLanguagePreferences.languageInstruction(forJSON: false) ?? "")
      """

    // Convert base64 data back to string (return nil if we can't decode)
    guard let base64String = String(data: frame.image, encoding: .utf8) else {
      print("[OLLAMA] ⚠️ Failed to decode frame image — skipping frame")
      return nil
    }

    // Build message content with image and text
    let content: [MessageContent] = [
      MessageContent(type: "text", text: prompt, image_url: nil),
      MessageContent(
        type: "image_url", text: nil,
        image_url: MessageContent.ImageURL(url: "data:image/jpeg;base64,\(base64String)")),
    ]

    let request = ChatRequest(
      model: savedModelId,
      messages: [
        ChatMessage(role: "user", content: content)
      ]
    )

    do {
      let response = try await callChatAPI(
        request, operation: "describe_frame", batchId: batchId, maxRetries: 1)
      // Return the raw text response (no JSON parsing needed for simple descriptions)
      return response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    } catch {
      print(
        "[OLLAMA] ⚠️ describe_frame failed at \(frame.timestamp)s — skipping frame: \(error.localizedDescription)"
      )
      return nil
    }
  }

  // Keep the individual descriptions: grouping them into 2-5 segments loses
  // the app changes and interruptions needed by the detailed activity log.
  func observationsFromFrames(
    _ frameDescriptions: [(timestamp: TimeInterval, description: String)],
    batchStartTime: Date,
    videoDuration: TimeInterval
  ) -> [Observation] {
    let sortedFrames = frameDescriptions.sorted { $0.timestamp < $1.timestamp }
    return sortedFrames.enumerated().compactMap { index, frame in
      let description = frame.description.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !description.isEmpty else { return nil }

      let startSeconds = max(0, frame.timestamp)
      let nextTimestamp =
        index + 1 < sortedFrames.count ? sortedFrames[index + 1].timestamp : videoDuration
      // Do not stretch a screenshot across a recording gap or failed frame.
      let endSeconds = min(startSeconds + 60, nextTimestamp, videoDuration)
      guard endSeconds > startSeconds else { return nil }

      return Observation(
        id: nil,
        batchId: 0,
        startTs: Int(batchStartTime.timeIntervalSince1970 + startSeconds),
        endTs: Int(batchStartTime.timeIntervalSince1970 + endSeconds),
        observation: description,
        metadata: nil,
        llmModel: savedModelId,
        createdAt: Date()
      )
    }
  }

}

// MARK: - Screenshot Transcription

extension OllamaProvider {
  /// Transcribe observations from screenshots.
  func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?)
    async throws -> (observations: [Observation], log: LLMCall)
  {
    guard !screenshots.isEmpty else {
      throw NSError(
        domain: "OllamaProvider", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
    }

    let callStart = Date()
    let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

    // One sample per clock minute preserves minute-level changes at local-model cost.
    var sampledMinutes = Set<Int>()
    let sampledScreenshots = sortedScreenshots.filter {
      sampledMinutes.insert($0.capturedAt / 60).inserted
    }

    // Calculate duration from timestamp range
    let firstTs = sampledScreenshots.first!.capturedAt
    let lastTs = sortedScreenshots.last!.capturedAt
    let durationSeconds = TimeInterval(max(1, lastTs - firstTs))

    // Describe each screenshot
    var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []

    for screenshot in sampledScreenshots {
      guard let frameData = loadScreenshotAsFrameData(screenshot, relativeTo: firstTs) else {
        print("[OLLAMA] ⚠️ Failed to load screenshot: \(screenshot.filePath)")
        frameDescriptions.append((TimeInterval(screenshot.capturedAt - firstTs), ""))
        continue
      }

      let description = await getSimpleFrameDescription(frameData, batchId: batchId) ?? ""
      frameDescriptions.append((timestamp: frameData.timestamp, description: description))
    }

    let observations = observationsFromFrames(
      frameDescriptions,
      batchStartTime: Date(timeIntervalSince1970: TimeInterval(firstTs)),
      videoDuration: durationSeconds
    )

    guard !observations.isEmpty else {
      throw NSError(
        domain: "OllamaProvider",
        code: 11,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Failed to describe any screenshots. Please check that Ollama/LMStudio is running."
        ]
      )
    }

    let totalTime = Date().timeIntervalSince(callStart)
    let log = LLMCall(
      timestamp: callStart,
      latency: totalTime,
      input:
        "Screenshot transcription: \(screenshots.count) screenshots → \(observations.count) observations",
      output: "Processed \(screenshots.count) screenshots in \(String(format: "%.2f", totalTime))s"
    )

    return (observations, log)
  }

  /// Load a screenshot file and convert it to FrameData for description
  private func loadScreenshotAsFrameData(_ screenshot: Screenshot, relativeTo baseTimestamp: Int)
    -> FrameData?
  {
    guard let imageData = screenshot.jpegData(maxHeight: 720, quality: 0.85) else {
      return nil
    }

    let base64String = imageData.base64EncodedString()
    let base64Data = Data(base64String.utf8)
    let relativeTimestamp = TimeInterval(screenshot.capturedAt - baseTimestamp)

    return FrameData(image: base64Data, timestamp: relativeTimestamp)
  }
}
