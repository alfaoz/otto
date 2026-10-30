// Prints the QR payloads in an image, one per line, the way Otto.app reads them (Vision).
// Usage: swift tests/qr.swift <image>
import Foundation
import Vision

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let req = VNDetectBarcodesRequest()
req.symbologies = [.qr]
try VNImageRequestHandler(url: url).perform([req])
for r in req.results ?? [] { if let s = r.payloadStringValue { print(s) } }
