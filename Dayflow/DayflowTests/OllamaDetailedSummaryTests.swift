import AppKit
import XCTest

@testable import Dayflow

final class OllamaDetailedSummaryTests: XCTestCase {
  private let base = 1_800_000_000

  func testFrameObservationsPreserveChangesAndDoNotFillMissingMinutes() {
    let provider = OllamaProvider()
    let observations = provider.observationsFromFrames(
      [
        (180, "Read documentation"), (0, "Edited code"), (60, "  "),
        (120, "Replied in chat"), (360, "Ran tests"), (400, "End boundary"),
      ],
      batchStartTime: Date(timeIntervalSince1970: Double(base)), videoDuration: 400)

    XCTAssertEqual(
      observations.map(\.observation),
      [
        "Edited code", "Replied in chat", "Read documentation", "Ran tests",
      ])
    XCTAssertEqual(observations.map { $0.startTs - base }, [0, 120, 180, 360])
    XCTAssertEqual(observations.map { $0.endTs - base }, [60, 180, 240, 400])
    XCTAssertTrue(observations.allSatisfy { $0.llmModel == provider.savedModelId })
  }

  func testTranscriptionKeepsMinuteSamplesAndUsesActualCaptureTimes() async throws {
    let url = try makeScreenshot()
    defer { try? FileManager.default.removeItem(at: url) }
    var calls = 0
    let provider = OllamaProvider { request, operation, _ in
      XCTAssertEqual(operation, "describe_frame")
      if let instruction = LLMOutputLanguagePreferences.languageInstruction(forJSON: false) {
        XCTAssertTrue(request.messages[0].content[0].text!.contains(instruction))
      }
      calls += 1
      return "Activity \(calls)"
    }
    let screenshots = stride(from: 0, through: 170, by: 10).map { offset in
      screenshot(at: base + offset, path: url.path)
    }
    let result = try await provider.transcribeScreenshots(
      screenshots.reversed(), batchStartTime: Date(timeIntervalSince1970: Double(base - 30)),
      batchId: 1)

    XCTAssertEqual(calls, 3)
    XCTAssertEqual(
      result.observations.map(\.observation), ["Activity 1", "Activity 2", "Activity 3"])
    XCTAssertEqual(result.observations.map { $0.startTs - base }, [0, 60, 120])
    XCTAssertEqual(result.observations.map { $0.endTs - base }, [60, 120, 170])
  }

  func testFailedDescriptionLeavesGapInsteadOfExtendingPreviousActivity() async throws {
    let url = try makeScreenshot()
    defer { try? FileManager.default.removeItem(at: url) }
    var calls = 0
    let provider = OllamaProvider { _, _, _ in
      calls += 1
      if calls == 2 { throw URLError(.timedOut) }
      return "Activity \(calls)"
    }
    let result = try await provider.transcribeScreenshots(
      [0, 60, 120, 170].map { screenshot(at: base + $0, path: url.path) },
      batchStartTime: Date(timeIntervalSince1970: Double(base)), batchId: 1)

    XCTAssertEqual(result.observations.map { $0.startTs - base }, [0, 120])
    XCTAssertEqual(result.observations.map { $0.endTs - base }, [60, 170])
  }

  func testSingleScreenshotProducesAnObservation() async throws {
    let url = try makeScreenshot()
    defer { try? FileManager.default.removeItem(at: url) }
    let provider = OllamaProvider { _, _, _ in "Edited code" }
    let result = try await provider.transcribeScreenshots(
      [screenshot(at: base, path: url.path)],
      batchStartTime: Date(timeIntervalSince1970: Double(base)), batchId: 1)
    XCTAssertEqual(result.observations.count, 1)
    XCTAssertEqual(result.observations[0].startTs, base)
    XCTAssertEqual(result.observations[0].endTs, base + 1)
  }

  func testAllEmptyDescriptionsFailInsteadOfCreatingAnEmptyCard() async throws {
    let url = try makeScreenshot()
    defer { try? FileManager.default.removeItem(at: url) }
    let provider = OllamaProvider { _, _, _ in "  \n " }
    do {
      _ = try await provider.transcribeScreenshots(
        [0, 60, 120].map { screenshot(at: base + $0, path: url.path) },
        batchStartTime: Date(timeIntervalSince1970: Double(base)), batchId: 1)
      XCTFail("Empty descriptions must fail transcription")
    } catch {
      XCTAssertEqual((error as NSError).domain, "OllamaProvider")
      XCTAssertEqual((error as NSError).code, 11)
    }
  }

  func testGenerationRetriesMissingAndEmptyDetailsThenPersistsDetails() async throws {
    let detail = "9:00 AM - 9:01 AM: Edited code\n9:01 AM - 9:02 AM: Replied in chat"
    var summaryCalls = 0
    let provider = OllamaProvider { request, operation, _ in
      switch operation {
      case "generate_summary":
        summaryCalls += 1
        let prompt = request.messages.last!.content[0].text!
        XCTAssertTrue(prompt.contains("Edited code"))
        XCTAssertTrue(prompt.contains("Replied in chat"))
        XCTAssertTrue(prompt.contains("DETAILED SUMMARY:"))
        if let instruction = LLMOutputLanguagePreferences.languageInstruction(forJSON: true) {
          XCTAssertTrue(prompt.contains(instruction))
        }
        if summaryCalls > 1 { XCTAssertTrue(prompt.contains("PREVIOUS ATTEMPT FAILED")) }
        var payload: [String: String] = [
          "reasoning": "Coding with a chat interruption", "summary": "Edited code and replied.",
          "category": "Work",
        ]
        if summaryCalls == 2 { payload["detailedSummary"] = " \n " }
        if summaryCalls == 3 { payload["detailedSummary"] = detail }
        return String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
      case "generate_title":
        return "Edited code and replied in chat"
      default:
        XCTFail("Unexpected operation: \(operation)")
        throw URLError(.unsupportedURL)
      }
    }
    let observations = [observation(0, "Edited code"), observation(60, "Replied in chat")]
    let result = try await provider.generateActivityCards(
      observations: observations, context: context(observations), batchId: 1)

    XCTAssertEqual(summaryCalls, 3)
    XCTAssertEqual(result.cards.count, 1)
    XCTAssertEqual(result.cards[0].detailedSummary, detail)
    XCTAssertEqual(result.cards[0].summary, "Edited code and replied.")
  }

  func testGenerationRejectsPersistentlyMissingDetails() async {
    var calls = 0
    let provider = OllamaProvider { _, operation, _ in
      XCTAssertEqual(operation, "generate_summary")
      calls += 1
      return #"{"reasoning":"Work","summary":"Edited code","category":"Work"}"#
    }
    let observations = [observation(0, "Edited code")]
    do {
      _ = try await provider.generateActivityCards(
        observations: observations, context: context(observations), batchId: 1)
      XCTFail("A card without details must not silently succeed")
    } catch {
      XCTAssertEqual(calls, 3)
    }
  }

  func testMergePreservesBothLogsAcrossMidnightAndRepeatedMerges() async throws {
    let provider = OllamaProvider { _, operation, _ in
      XCTAssertEqual(operation, "merge_cards")
      return #"{"title":"Release work","summary":"Edited and tested the release."}"#
    }
    let firstDetail = "11:50 PM - 12:00 AM: Edited code"
    let secondDetail = "12:00 AM - 12:10 AM: Ran tests"
    let thirdDetail = "12:10 AM - 12:20 AM: Reviewed results"
    let first = card("11:50 PM", "12:00 AM", firstDetail)
    let second = card("12:00 AM", "12:10 AM", secondDetail)
    let third = card("12:10 AM", "12:20 AM", thirdDetail)

    let (merged, _) = try await provider.mergeTwoCards(
      previousCard: first, newCard: second, batchId: 1)
    let (mergedAgain, _) = try await provider.mergeTwoCards(
      previousCard: merged, newCard: third, batchId: 2)

    XCTAssertEqual(
      mergedAgain.detailedSummary, [firstDetail, secondDetail, thirdDetail].joined(separator: "\n"))
    XCTAssertEqual(mergedAgain.startTime, "11:50 PM")
    XCTAssertEqual(mergedAgain.endTime, "12:20 AM")
  }

  func testMergeWithLegacyCardRetainsNewDetailsWithoutInventingOldOnes() async throws {
    let provider = OllamaProvider { _, _, _ in
      #"{"title":"Release work","summary":"Edited and tested the release."}"#
    }
    let detail = "9:15 AM - 9:30 AM: Ran tests"
    let (merged, _) = try await provider.mergeTwoCards(
      previousCard: card("9:00 AM", "9:15 AM", ""),
      newCard: card("9:15 AM", "9:30 AM", detail), batchId: 1)
    XCTAssertEqual(merged.detailedSummary, detail)
  }

  private func observation(_ offset: Int, _ text: String) -> Observation {
    Observation(
      id: nil, batchId: 1, startTs: base + offset, endTs: base + offset + 60,
      observation: text, metadata: nil, llmModel: nil, createdAt: nil)
  }

  private func context(_ observations: [Observation]) -> ActivityGenerationContext {
    ActivityGenerationContext(
      batchObservations: observations, existingCards: [], currentTime: Date(),
      categories: [
        LLMCategoryDescriptor(
          id: UUID(), name: "Work", colorHex: "#000000", description: nil, isSystem: false,
          isIdle: false)
      ],
      hasPreviousCardWithinFiveMinutes: false)
  }

  private func card(_ start: String, _ end: String, _ details: String) -> ActivityCardData {
    ActivityCardData(
      startTime: start, endTime: end, category: "Work", subcategory: "", title: "Release work",
      summary: "Edited the release.", detailedSummary: details, distractions: nil, appSites: nil)
  }

  private func screenshot(at timestamp: Int, path: String) -> Screenshot {
    Screenshot(
      id: Int64(timestamp), capturedAt: timestamp, filePath: path, fileSize: nil,
      idleSecondsAtCapture: nil, isDeleted: false)
  }

  private func makeScreenshot() throws -> URL {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).jpg")
    try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
    return url
  }
}
