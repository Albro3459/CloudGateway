import CoreImage
import Foundation

public enum CloudGatewayMacQRCode {
    public static func matrix(_ url: URL) throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw CocoaError(.coderInvalidValue) }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let bitmap = CIContext().createCGImage(image, from: image.extent, format: .L8,
                                                     colorSpace: CGColorSpaceCreateDeviceGray()),
              let data = bitmap.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              bitmap.width == bitmap.height, (21...185).contains(bitmap.width) else {
            throw CocoaError(.coderInvalidValue)
        }
        let pixels = (0..<bitmap.height).map { row in
            (0..<bitmap.width).map { column in bytes[row * bitmap.bytesPerRow + column] < 128 }
        }
        guard let top = pixels.firstIndex(where: { $0.contains(true) }),
              let bottom = pixels.lastIndex(where: { $0.contains(true) }),
              let left = pixels.compactMap({ $0.firstIndex(of: true) }).min(),
              let right = pixels.compactMap({ $0.lastIndex(of: true) }).max() else {
            throw CocoaError(.coderInvalidValue)
        }
        let size = bottom - top + 1
        guard size == right - left + 1, (21...177).contains(size), (size - 21).isMultiple(of: 4) else {
            throw CocoaError(.coderInvalidValue)
        }
        return pixels[top...bottom].map { Array($0[left...right]) }
    }
}
