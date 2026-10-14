import CoreML
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: compile-sky-model.swift model.mlpackage output.mlmodelc")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if !FileManager.default.fileExists(atPath: destination.path) {
    let compiled = try MLModel.compileModel(at: source)
    try FileManager.default.copyItem(at: compiled, to: destination)
}
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuOnly
let model = try MLModel(contentsOf: destination, configuration: configuration)
print("Compiled sky model: \(destination.path)")
print("Inputs: \(model.modelDescription.inputDescriptionsByName)")
print("Outputs: \(model.modelDescription.outputDescriptionsByName)")
if let fields = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
   let json = fields["com.apple.coreml.model.preview.params"],
   let data = json.data(using: .utf8),
   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
   let labels = object["labels"] as? [String] {
    print("Sky classes: \(labels.enumerated().filter { $0.element.lowercased().contains("sky") })")
}
