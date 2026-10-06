import Foundation
import ImageIO
import Vision
import UIKit

struct RecognizedShiftText: Sendable {
    let lines: [String]
    let previewData: Data
}

enum ShiftPhotoReadError: LocalizedError {
    case tooLarge, invalidImage, noText
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "画像が大きすぎます。20MB以下の画像を選んでください。"
        case .invalidImage: return "画像を開けませんでした。別の写真を選んでください。"
        case .noText: return "文字を読み取れませんでした。明るく、文字がはっきりした画像を選んでください。"
        }
    }
}

enum ShiftPhotoReader {
    /// The image is processed locally. Neither image bytes nor recognized text are uploaded.
    static func read(_ data: Data) async throws -> RecognizedShiftText {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard data.count <= 20 * 1024 * 1024 else { throw ShiftPhotoReadError.tooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3000,
                    kCGImageSourceShouldCacheImmediately: false
                  ] as CFDictionary) else { throw ShiftPhotoReadError.invalidImage }
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["ja-JP", "en-US"].filter { supported.contains($0) }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()
            let observations = (request.results ?? []).filter { $0.topCandidates(1).first != nil }
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            guard !observations.isEmpty else { throw ShiftPhotoReadError.noText }
            var groups: [[VNRecognizedTextObservation]] = []
            for observation in observations {
                if let last = groups.last, let anchor = last.first,
                   abs(anchor.boundingBox.midY - observation.boundingBox.midY) <
                    max(0.004, min(anchor.boundingBox.height, observation.boundingBox.height) * 0.5) {
                    groups[groups.count - 1].append(observation)
                } else { groups.append([observation]) }
            }
            let lines = groups.map { group in
                group.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            }
            let preview = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(preview, "public.jpeg" as CFString, 1, nil) else {
                throw ShiftPhotoReadError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ShiftPhotoReadError.invalidImage }
            return RecognizedShiftText(lines: lines, previewData: preview as Data)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

@MainActor
enum ShiftPhotoSample {
    static func data() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 720), format: format).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 720))
            let heading: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: UIColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 48, weight: .medium), .foregroundColor: UIColor.black]
            ("自分のシフト 2026年10月" as NSString).draw(at: CGPoint(x: 50, y: 45), withAttributes: heading)
            let lines = ["2026/10/06 17:00-22:00 休憩30分",
                         "2026/10/08 18:00-22:00 休憩0分",
                         "2026/10/10 10:00-16:00 休憩45分"]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 50, y: 180 + index * 140), withAttributes: body)
            }
        }
    }
}
