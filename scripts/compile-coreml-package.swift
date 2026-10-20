import CoreML
import Foundation

// Compiles a Core ML package to a .mlmodelc and loads it once as a check. Compute units are CPU and GPU:
// loading SAM 2.1's image encoder for the Neural Engine took over 500 seconds on the target Mac and the
// mask decoder does not run there at all (conv_transpose shape error), so nothing here asks for `.all`.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: compile-coreml-package.swift model.mlpackage output.mlmodelc")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if !FileManager.default.fileExists(atPath: destination.path) {
    let compiled = try MLModel.compileModel(at: source)
    try FileManager.default.copyItem(at: compiled, to: destination)
}
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndGPU
let model = try MLModel(contentsOf: destination, configuration: configuration)
print("Compiled \(destination.lastPathComponent)")
print("  inputs: \(model.modelDescription.inputDescriptionsByName.keys.sorted())")
print("  outputs: \(model.modelDescription.outputDescriptionsByName.keys.sorted())")
