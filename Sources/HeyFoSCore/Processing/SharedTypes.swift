import Foundation

public enum StackProcessingError: Error {
    case directoryNotFound
    case noImagesFound
    case invalidInput
    case processingFailed(String)
    case failedToCreateTexture
    case failedToCreateCommandBuffer
}
