import XCTest
import Vision
import CoreGraphics

final class VisionTests: XCTestCase {
    func testFeaturePrintCacheRoundTripAndAesthetics() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 50, width: 120, height: 120))
        let image = try XCTUnwrap(context.makeImage())
        let feature = VNGenerateImageFeaturePrintRequest()
        feature.revision = VNGenerateImageFeaturePrintRequestRevision2
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(cgImage: image).perform([feature, aesthetics])
        let observation = try XCTUnwrap(feature.results?.first)
        XCTAssertNotNil(aesthetics.results?.first)
        let data = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data))
        var distance: Float = 1
        try observation.computeDistance(&distance, to: restored)
        XCTAssertEqual(distance, 0, accuracy: 0.00001)
    }
}
