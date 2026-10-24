import CoreImage
import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func generatedLoginQRDecodesToApprovalURLInMatrixOrientation() throws {
    let url = URL(string: "https://dashboard.example.com/#/auth/code?deviceRequestId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&userCode=000012")!
    let matrix = try CloudGatewayMacQRCode.matrix(url)
    let side = matrix.count + 8
    let scale = 8
    var pixels = [UInt8](repeating: 255, count: side * side)
    for row in matrix.indices {
        for column in matrix[row].indices {
            pixels[(row + 4) * side + column + 4] = matrix[row][column] ? 0 : 255
        }
    }
    let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side,
                        size: CGSize(width: side, height: side), format: .L8,
                        colorSpace: CGColorSpaceCreateDeviceGray())
        .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
    let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                         options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let codes = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(codes == [url.absoluteString])
    #expect(matrix.count >= 21)
    #expect(matrix[0].prefix(7).allSatisfy { $0 })
    #expect(matrix[6].prefix(7).allSatisfy { $0 })
    #expect(matrix.prefix(7).allSatisfy { $0[0] && $0[6] })
}
