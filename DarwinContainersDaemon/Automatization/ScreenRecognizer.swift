import Foundation
import Vision

private struct RecognizedText {
    var text: String
    var rect: CGRect
}

private func recognizeText(image: NSImage) async -> [RecognizedText] {
    let requestHandler = VNImageRequestHandler(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    return await withCheckedContinuation { (continuation: CheckedContinuation<[RecognizedText], Never>) -> Void in
        let request = VNRecognizeTextRequest { request, error in
            DispatchQueue.main.async {
                if let observations = request.results as? [VNRecognizedTextObservation] {
                    var recognizedTexts: [RecognizedText] = []
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else {
                            continue
                        }
                        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)
                        
                        let mappedRect = observation.boundingBox.applying(transform)
                        recognizedTexts.append(RecognizedText(
                            text: candidate.string,
                            rect: mappedRect
                        ))
                    }
                    continuation.resume(returning: recognizedTexts)
                } else {
                    if let error = error {
                        print("Recognition error: \(error)")
                    } else {
                        print("Recognition error")
                    }
                    continuation.resume(returning: [])
                }
            }
        }
        do {
            try requestHandler.perform([request])
        } catch let e {
            print("Recognition error: \(e)")
            continuation.resume(returning: [])
        }
    }
}

private func recognizeScreen(virtualMachine: DarwinVirtualMachine) async throws -> [RecognizedText] {
    guard let image = await virtualMachine.takeScreenshot() else {
        return []
    }
    
    let results = await recognizeText(image: image)
    return results
}

private func waitForText(virtualMachine: DarwinVirtualMachine, predicate: @escaping ([RecognizedText]) -> Bool, alternatively: @escaping () async -> Void = {}) async throws {
    while true {
        let results = try await recognizeScreen(virtualMachine: virtualMachine)
        if predicate(results) {
            return
        }
        await alternatively()
        try await Task.sleep(nanoseconds: 1 * 1000 * 1000 * 1000)
    }
}

private func waitForTextWithResult<T>(virtualMachine: DarwinVirtualMachine, predicate: @escaping ([RecognizedText]) -> T?, alternatively: @escaping () async -> Void = {}) async throws -> T {
    while true {
        let results = try await recognizeScreen(virtualMachine: virtualMachine)
        if let value = predicate(results) {
            return value
        }
        await alternatively()
        try await Task.sleep(nanoseconds: 1 * 1000 * 1000 * 1000)
    }
}

@MainActor
private func performInitialSetup(virtualMachine: DarwinVirtualMachine, verbose: Bool) async throws {
    if verbose {
        print("Setup: setting language...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "language" })
    }, alternatively: {
        await virtualMachine.pressKey(code: 51)
    })
    try await Task.sleep(nanoseconds: 1 * 1000 * 1000 * 1000)
    
    await virtualMachine.pressKey(code: 36)
    
    if verbose {
        print("Setup: setting region...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "select your country or region" })
    })
    try await Task.sleep(nanoseconds: 1 * 1000 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [32, 45, 34, 17, 14, 2, 49, 40])
    
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "united kingdom" })
    })
    
    await virtualMachine.pressKeys(codes: [48, 48, 48])
    await virtualMachine.pressKey(code: 49)
    
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "written and spoken languages" })
    })
    try await Task.sleep(nanoseconds: 1 * 1000 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: setting accessibility...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "accessibility" })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48, 48, 48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: setting data & privacy...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "data & privacy" })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: skipping migration...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "migration assistant" })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: skipping online account setup...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "sign in with your apple id" })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48], holdingKeys: [56])
    await virtualMachine.pressKeys(codes: [49])
    
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "skip" })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: accepting terms and conditions...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased() == "terms and conditions" })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().contains("have read and agree") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: creating local account...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("create a computer account") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [8, 31, 45, 17, 0, 34, 45, 14, 15, 4, 31, 1, 17])
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [8, 31, 45, 17, 0, 34, 45, 14, 15, 4, 31, 1, 17])
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [8, 31, 45, 17, 0, 34, 45, 14, 15, 4, 31, 1, 17])
    await virtualMachine.pressKeys(codes: [48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: skipping location services...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("enable location services") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
    
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("are you sure you") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: setting time zone...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("select your time zone") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48])
    
    await virtualMachine.pressKeys(codes: [37, 31, 45, 2, 31, 45])
    await virtualMachine.pressKeys(codes: [36])
    await virtualMachine.pressKeys(codes: [48], holdingKeys: [56])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: skipping analytics...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("analytics") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    if virtualMachine.configuration.initialPlatformVersion.majorVersion == 12 {
        await virtualMachine.pressKeys(codes: [48])
        await virtualMachine.pressKeys(codes: [49])
        await virtualMachine.pressKeys(codes: [48, 48, 48, 48])
        await virtualMachine.pressKeys(codes: [49])
    } else if virtualMachine.configuration.initialPlatformVersion.majorVersion == 13 {
        if virtualMachine.configuration.initialPlatformVersion.minorVersion == 0 {
            await virtualMachine.pressKeys(codes: [48, 48, 48, 48, 48], holdingKeys: [56])
            await virtualMachine.pressKeys(codes: [49])
        }
        
        await virtualMachine.pressKeys(codes: [48], holdingKeys: [56])
        await virtualMachine.pressKeys(codes: [49])
    }
    
    if verbose {
        print("Setup: skipping screen time...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("screen time") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48])
    await virtualMachine.pressKeys(codes: [49])
    
    if verbose {
        print("Setup: setting theme...")
    }
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        return results.contains(where: { $0.text.lowercased().hasPrefix("choose your look") })
    })
    try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    
    await virtualMachine.pressKeys(codes: [48, 48, 48, 48])
    await virtualMachine.pressKeys(codes: [49])
}

@MainActor
private func performSharingSetup(virtualMachine: DarwinVirtualMachine, verbose: Bool) async throws {
    if virtualMachine.configuration.initialPlatformVersion.majorVersion == 12 {
        if verbose {
            print("Setup: enabling ssh...")
        }
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("finder") })
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("system preferences") })
        }, alternatively: {
            await virtualMachine.pressMouse(location: CGPoint())
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        await virtualMachine.pressKeys(codes: [1, 16, 1, 17, 14, 46, 46, 49, 35])
        await virtualMachine.pressKeys(codes: [36])
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            if !results.contains(where: { $0.text.lowercased().hasPrefix("sign in") }) {
                return false
            }
            return true
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        await virtualMachine.pressKeys(codes: [1, 4, 0, 15, 34, 45, 5])
        await virtualMachine.pressKeys(codes: [36])
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("screen sharing") })
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        while true {
            let remoteLogin = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
                guard let remoteLogin = results.first(where: { $0.text.lowercased() == "remote login" }) else {
                    return nil
                }
                return remoteLogin
            })
            
            await virtualMachine.pressMouse(location: CGPoint(x: remoteLogin.rect.midX, y: remoteLogin.rect.midY))
            let results = try await recognizeScreen(virtualMachine: virtualMachine)
            
            if results.contains(where: { $0.text.lowercased().hasPrefix("allow full disk access") }) {
                break
            }
        }
        
        let remoteLogin = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
            guard let remoteLogin = results.first(where: { $0.text.lowercased() == "remote login" }) else {
                return nil
            }
            return remoteLogin
        })
        
        await virtualMachine.pressMouse(location: CGPoint(x: remoteLogin.rect.minX - remoteLogin.rect.width * 0.3, y: remoteLogin.rect.midY))
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            guard let _ = results.first(where: { $0.text.lowercased() == "remote login: on" }) else {
                return false
            }
            return true
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        await virtualMachine.pressKeys(codes: [12], holdingKeys: [55])
    } else {
        if verbose {
            print("Setup: enabling ssh...")
        }
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("finder") })
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("system settings") })
        }, alternatively: {
            await virtualMachine.pressMouse(location: CGPoint())
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        await virtualMachine.pressKeys(codes: [125, 125, 36])
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            if !results.contains(where: { $0.text.lowercased().hasPrefix("sign in") }) {
                return false
            }
            return true
        })
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        let general = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
            if let item = results.first(where: { $0.text.lowercased() == "general" }) {
                return item
            }
            if let item = results.first(where: { $0.text.lowercased().hasSuffix(" general") }) {
                return item
            }
            return nil
        })
        
        await virtualMachine.pressMouse(location: CGPoint(x: general.rect.midX, y: general.rect.midY))
        
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        while true {
            let results = try await recognizeScreen(virtualMachine: virtualMachine)
            if results.contains(where: { $0.text.lowercased().contains("sharing") }) {
                break
            }
            try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        }
        
        let sharing = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
            return results.first(where: { $0.text.lowercased().contains("sharing") })
        })
        
        await virtualMachine.pressMouse(location: CGPoint(x: sharing.rect.midX, y: sharing.rect.midY))
        
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        while true {
            let results = try await recognizeScreen(virtualMachine: virtualMachine)
            if results.contains(where: { $0.text.lowercased().hasPrefix("remote login") }) {
                break
            } else {
                try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
            }
        }
        
        let remoteLogin = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
            return results.first(where: { $0.text.lowercased() == "remote login" })
        })
        
        await virtualMachine.pressMouse(location: CGPoint(x: remoteLogin.rect.maxX + remoteLogin.rect.width * 3.5, y: remoteLogin.rect.midY))
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        if virtualMachine.configuration.initialPlatformVersion.minorVersion > 0 {
            let _ = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
                return results.first(where: { $0.text.lowercased().contains("enter your password") })
            })
            
            try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
            
            await virtualMachine.pressKeys(codes: [8, 31, 45, 17, 0, 34, 45, 14, 15, 4, 31, 1, 17])
            await virtualMachine.pressKeys(codes: [36])
            
            try await Task.sleep(nanoseconds: 2000 * 1000 * 1000)
        }
        
        await virtualMachine.pressMouse(location: CGPoint(x: remoteLogin.rect.maxX + remoteLogin.rect.width * 4.0, y: remoteLogin.rect.midY))
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().contains("allow full disk access") })
        })
        
        try await Task.sleep(nanoseconds: 1000 * 1000 * 1000)
        
        let fullDiskAccess = try await waitForTextWithResult(virtualMachine: virtualMachine, predicate: { results -> RecognizedText? in
            return results.first(where: { $0.text.lowercased().contains("allow full disk access") })
        })
        await virtualMachine.pressMouse(location: CGPoint(x: fullDiskAccess.rect.midX, y: fullDiskAccess.rect.midY))
        
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        await virtualMachine.pressKeys(codes: [36, 36])
        
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        
        await virtualMachine.pressKeys(codes: [12], holdingKeys: [55])
        
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
    }
}

@MainActor
private func performPostInstallationSetup(virtualMachine: DarwinVirtualMachine, verbose: Bool) async throws {
    try await waitForText(virtualMachine: virtualMachine, predicate: { results in
        if results.contains(where: { $0.text.lowercased() == "language" }) {
            return true
        }
        if results.contains(where: { $0.text.lowercased() == "shut down" }) {
            return true
        }
        return false
    }, alternatively: {
        await virtualMachine.pressKey(code: 51)
    })
    
    var onlyFinish = false
    if (try await recognizeScreen(virtualMachine: virtualMachine)).contains(where: { $0.text.lowercased().hasPrefix("shut down") }) {
        onlyFinish = true
        
        await virtualMachine.pressKeys(codes: [8, 31, 45, 17, 0, 34, 45, 14, 15, 4, 31, 1, 17])
        try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        await virtualMachine.pressKeys(codes: [36])
    }
    
    if !onlyFinish {
        try await performInitialSetup(virtualMachine: virtualMachine, verbose: verbose)
    }
    try await performSharingSetup(virtualMachine: virtualMachine, verbose: verbose)
}

enum ScreenRecognizer {
    static func setupAfterInstallation(virtualMachine: DarwinVirtualMachine, verbose: Bool) async throws {
        try await performPostInstallationSetup(virtualMachine: virtualMachine, verbose: verbose)
    }
    
    static func stop(virtualMachine: DarwinVirtualMachine, verbose: Bool) async throws {
        if verbose {
            print("Setup: shutting down...")
        }
        
        await virtualMachine.pressMouse(location: CGPoint(x: 0.0, y: 0.0))
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("about this mac") })
        })
        
        await virtualMachine.pressKeys(codes: [1, 4, 32, 17])
        await virtualMachine.pressKeys(codes: [36])
        
        try await waitForText(virtualMachine: virtualMachine, predicate: { results in
            return results.contains(where: { $0.text.lowercased().hasPrefix("are you sure you want") })
        })
        
        await virtualMachine.pressKeys(codes: [48, 48])
        await virtualMachine.pressKeys(codes: [49])
    }
}
