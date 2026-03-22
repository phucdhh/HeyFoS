import Foundation
import ArgumentParser
import HeyFoSCore
import Logging

@main
struct HeyFoSCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heyfos",
        abstract: "HeyFoS Focus Stacking Tool",
        version: "0.1.0"
    )
    
    @Option(name: .shortAndLong, help: "Input directory containing image stack")
    var input: String
    
    @Option(name: .shortAndLong, help: "Output file path (TIFF)")
    var output: String
    
    @Option(name: .long, help: "Focus measure method (laplacian or tenengrad)")
    var method: String = "laplacian"
    
    @Flag(name: .long, inversion: .prefixedNo, help: "Check and report alignment issues")
    var checkAlignment: Bool = true
    
    @Flag(name: .long, help: "Use pyramid blending (experimental, currently has bugs)")
    var pyramidBlending: Bool = false
    
    @Flag(name: .long, help: "Enable verbose output")
    var verbose: Bool = false
    
    func run() throws {
        // Setup logging
        let verboseFlag = verbose
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = verboseFlag ? .debug : .info
            return handler
        }
        
        let logger = Logger(label: "com.heyfos.cli")
        
        logger.info("HeyFoS CLI v0.1.0")
        logger.info("Input: \(input)")
        logger.info("Output: \(output)")
        logger.info("Method: \(method)")
        
        // Initialize Metal context
        logger.info("Initializing Metal...")
        let metalContext = try MetalContext()
        logger.info("✓ Metal initialized: \(metalContext.device.name)")
        
        // Create stack processor
        let stackProcessor = StackProcessor(metalContext: metalContext)
        
        // Check if input directory exists
        let inputURL = URL(fileURLWithPath: input)
        let fileManager = FileManager.default
        
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: input, isDirectory: &isDirectory) && isDirectory.boolValue {
            // Process real image stack
            logger.info("Processing image stack from directory...")
            
            let focusMethod: FocusMeasureProcessor.Method = method == "tenengrad" ? .tenengrad : (method == "ensemble" ? .ensemble : .laplacian)
            
            try stackProcessor.processStack(
                inputDirectory: inputURL,
                outputPath: output,
                method: focusMethod,
                useAlignment: checkAlignment,
                usePyramidBlending: pyramidBlending,
                verbose: verboseFlag
            )
            
            logger.info("🎉 Focus stacking complete!")
            logger.info("Output: \(output)")
            
        } else {
            // No directory - run test mode
            logger.info("Input directory not found, running test mode...")
            logger.info("Creating synthetic test image...")
            
            let imageLoader = ImageLoader(metalContext: metalContext)
            let focusProcessor = FocusMeasureProcessor(metalContext: metalContext)
            
            // Create test checkerboard image (1024x768)
            let testImage = try imageLoader.createTestImage(width: 1024, height: 768, checkerSize: 32)
            logger.info("✓ Test image created: 1024×768")
            
            // Convert to grayscale
            let grayImage = try focusProcessor.convertToGrayscale(inputTexture: testImage)
            logger.info("✓ Converted to grayscale")
            
            // Compute focus measure
            let focusMap = try focusProcessor.computeFocusMeasure(
                inputTexture: grayImage,
                method: method == "tenengrad" ? .tenengrad : (method == "ensemble" ? .ensemble : .laplacian)
            )
            logger.info("✓ Focus measure computed")
            
            // Save result
            let outputURL = URL(fileURLWithPath: output)
            try imageLoader.saveTexture(focusMap, to: outputURL)
            logger.info("✓ Test focus map saved to: \(output)")
            
            logger.info("")
            logger.info("To process real images:")
            logger.info("  1. Create directory: mkdir -p \(input)")
            logger.info("  2. Place TIFF/JPEG/PNG images in \(input)/")
            logger.info("  3. Run: swift run heyfos-cli --input \(input) --output result.tiff")
        }
    }
}
