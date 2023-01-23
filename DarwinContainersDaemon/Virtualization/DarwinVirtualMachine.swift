import Foundation
import Virtualization

struct VirtualMachineConfiguration: Codable {
    enum State: String, Codable {
        case empty
        case installing
        case installed
        case settingUp
        case ready
    }
    
    struct PlatformVersion: Codable {
        var majorVersion: Int
        var minorVersion: Int
        var patchVersion: Int
    }
    
    var machineIdentifier: Data
    var hardwareModel: Data
    var sshPrivateKey: String
    var sshPublicKey: String
    var initialPlatformVersion: PlatformVersion
    
    init(
        machineIdentifier: Data,
        hardwareModel: Data,
        sshPrivateKey: String,
        sshPublicKey: String,
        initialPlatformVersion: PlatformVersion
    ) {
        self.machineIdentifier = machineIdentifier
        self.hardwareModel = hardwareModel
        self.sshPrivateKey = sshPrivateKey
        self.sshPublicKey = sshPublicKey
        self.initialPlatformVersion = initialPlatformVersion
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.machineIdentifier = try container.decode(Data.self, forKey: .machineIdentifier)
        self.hardwareModel = try container.decode(Data.self, forKey: .hardwareModel)
        self.sshPrivateKey = try container.decode(String.self, forKey: .sshPrivateKey)
        self.sshPublicKey = try container.decode(String.self, forKey: .sshPublicKey)
        self.initialPlatformVersion = try container.decodeIfPresent(VirtualMachineConfiguration.PlatformVersion.self, forKey: .initialPlatformVersion) ?? VirtualMachineConfiguration.PlatformVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
    }
}

extension VirtualMachineConfiguration.PlatformVersion {
    init(_ version: OperatingSystemVersion) {
        self.init(majorVersion: version.majorVersion, minorVersion: version.minorVersion, patchVersion: version.patchVersion)
    }
}

private func createPlaformConfiguration(imagePath: String, configuration: VirtualMachineConfiguration) -> VZMacPlatformConfiguration {
    let auxiliaryStorageURL = URL(fileURLWithPath: imagePath + "/auxiliary-storage.img")
    let macPlatform = VZMacPlatformConfiguration()

    let auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxiliaryStorageURL)
    macPlatform.auxiliaryStorage = auxiliaryStorage

    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: configuration.hardwareModel) else {
        fatalError("Failed to create hardware model.")
    }
    if !hardwareModel.isSupported {
        fatalError("The hardware model is not supported on the current host")
    }
    macPlatform.hardwareModel = hardwareModel
    
    guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: configuration.machineIdentifier) else {
        fatalError("The machine identifier is invalid")
    }
    macPlatform.machineIdentifier = machineIdentifier

    return macPlatform
}

private func createBootLoader() -> VZMacOSBootLoader {
    return VZMacOSBootLoader()
}

private func computeCPUCount() -> Int {
    let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
    
    var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
    virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    
    return virtualCPUCount
}

private func computeMemorySize() -> UInt64 {
    var memorySize = (10 * 1024 * 1024 * 1024) as UInt64
    memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

    return memorySize
}

private func createGraphicsDeviceConfiguration(resolution: CGSize) -> VZMacGraphicsDeviceConfiguration {
    let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
    graphicsConfiguration.displays = [
        VZMacGraphicsDisplayConfiguration(widthInPixels: Int(resolution.width), heightInPixels: Int(resolution.height), pixelsPerInch: 80)
    ]

    return graphicsConfiguration
}

private func createBlockDeviceConfiguration(imagePath: String, configuration: VirtualMachineConfiguration) -> VZVirtioBlockDeviceConfiguration {
    guard let diskImageAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: imagePath + "/main-storage.img"), readOnly: false) else {
        fatalError("Failed to create Disk image.")
    }
    let disk = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
    return disk
}

private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()

    let networkAttachment = VZNATNetworkDeviceAttachment()
    networkDevice.attachment = networkAttachment
    return networkDevice
}

private func createPointingDeviceConfiguration() -> VZUSBScreenCoordinatePointingDeviceConfiguration {
    return VZUSBScreenCoordinatePointingDeviceConfiguration()
}

private func createKeyboardConfiguration() -> VZUSBKeyboardConfiguration {
    return VZUSBKeyboardConfiguration()
}

private func createDiskImage(path: String, sizeGigabytes: Int) throws {
    let diskFd = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    if diskFd == -1 {
        fatalError("Cannot create disk image at \(path).")
    }

    var result = ftruncate(diskFd, Int64(sizeGigabytes) * 1024 * 1024 * 1024)
    if result != 0 {
        fatalError("ftruncate() failed at \(path).")
    }

    result = close(diskFd)
    if result != 0 {
        fatalError("Failed to close the disk image at \(path).")
    }
}

private func extractIpAddressFromArpOutput(string: String) -> String? {
    let regularExpression = try! NSRegularExpression(pattern: "\\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)")
    guard let match = regularExpression.firstMatch(in: string, options: [], range: NSRange(string.startIndex..., in: string)) else {
        return nil
    }
    if match.numberOfRanges < 2 {
        return nil
    }
    guard let range = Range(match.range(at: 1), in: string) else {
        return nil
    }
    return String(string[range])
}

@MainActor
final class DarwinVirtualMachine: NSObject, VZVirtualMachineDelegate {
    enum TaskError: Error {
        case taskCancelled
    }
    
    let resolution: CGSize
    let virtualMachine: VZVirtualMachine
    let configuration: VirtualMachineConfiguration
    weak var view: VZVirtualMachineView?
    private let macAddress: String
    
    private var stoppedContinuation: CheckedContinuation<Void, Never>?
    
    var onStopped: ((Error?) -> Void)?
    
    static func allocate(directoryPath: String, hardwareModel: VZMacHardwareModel, osVersion: OperatingSystemVersion, diskSize: Int) throws -> VirtualMachineConfiguration {
        if !FileManager.default.fileExists(atPath: directoryPath) {
            preconditionFailure()
        }
        
        let mainStoragePath = directoryPath + "/main-storage.img"
        try! createDiskImage(path: mainStoragePath, sizeGigabytes: diskSize)
        
        let auxiliaryStoragePath = directoryPath + "/auxiliary-storage.img"
        
        guard let _ = try? VZMacAuxiliaryStorage(
            creatingStorageAt: URL(fileURLWithPath: auxiliaryStoragePath),
            hardwareModel: hardwareModel,
            options: []
        ) else {
            fatalError("Failed to create auxiliary storage at \(auxiliaryStoragePath).")
        }
        
        let configurationPath = directoryPath + "/configuration.json"
        
        let tempKeysPath = FileManager.default.temporaryDirectory.path + "/\(UUID())"
        try FileManager.default.createDirectory(atPath: tempKeysPath, withIntermediateDirectories: true)
        
        let _ = shell("ssh-keygen -t ed25519 -C \"Host\" -f \"\(tempKeysPath)/id_ed25519\" -P \"\"")
        let privateKey = try String(contentsOf: URL(fileURLWithPath: tempKeysPath + "/id_ed25519")).trimmingCharacters(in: .newlines)
        let publicKey = try String(contentsOf: URL(fileURLWithPath: tempKeysPath + "/id_ed25519.pub")).trimmingCharacters(in: .newlines)
        
        try FileManager.default.removeItem(atPath: tempKeysPath)
        
        let configuration = VirtualMachineConfiguration(
            machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
            hardwareModel: hardwareModel.dataRepresentation,
            sshPrivateKey: privateKey,
            sshPublicKey: publicKey,
            initialPlatformVersion: VirtualMachineConfiguration.PlatformVersion(osVersion)
        )
        
        try! JSONEncoder().encode(configuration).write(to: URL(fileURLWithPath: configurationPath))
        
        return configuration
    }
    
    static func duplicate(sourceDirectoryPath: String, directoryPath: String) -> VirtualMachineConfiguration {
        if !FileManager.default.fileExists(atPath: sourceDirectoryPath) {
            preconditionFailure()
        }
        if !FileManager.default.fileExists(atPath: directoryPath) {
            preconditionFailure()
        }
        
        let mainStoragePath = directoryPath + "/main-storage.img"
        let _ = try! FileManager.default.copyItem(atPath: sourceDirectoryPath + "/main-storage.img", toPath: mainStoragePath)
        
        let auxiliaryStoragePath = directoryPath + "/auxiliary-storage.img"
        let _ = try! FileManager.default.copyItem(atPath: sourceDirectoryPath + "/auxiliary-storage.img", toPath: auxiliaryStoragePath)
        
        let previousConfiguration = try! JSONDecoder().decode(VirtualMachineConfiguration.self, from: try! Data(contentsOf: URL(fileURLWithPath: sourceDirectoryPath + "/configuration.json")))
        
        let configurationPath = directoryPath + "/configuration.json"
        
        /*guard let _ = try? VZMacAuxiliaryStorage(
            creatingStorageAt: URL(fileURLWithPath: auxiliaryStoragePath),
            hardwareModel: VZMacHardwareModel(dataRepresentation: previousConfiguration.hardwareModel)!,
            options: []
        ) else {
            fatalError("Failed to create auxiliary storage at \(auxiliaryStoragePath).")
        }*/
        
        let configuration = VirtualMachineConfiguration(
            machineIdentifier: previousConfiguration.machineIdentifier,
            hardwareModel: previousConfiguration.hardwareModel,
            sshPrivateKey: previousConfiguration.sshPrivateKey,
            sshPublicKey: previousConfiguration.sshPublicKey,
            initialPlatformVersion: previousConfiguration.initialPlatformVersion
        )
        
        //configuration.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
        //configuration.hardwareModel = hardwareModel.dataRepresentation
        
        try! JSONEncoder().encode(configuration).write(to: URL(fileURLWithPath: configurationPath))
        
        return configuration
    }
    
    init(imagePath: String, configuration: VirtualMachineConfiguration) {
        self.configuration = configuration
        self.resolution = CGSize(width: 800.0, height: 800.0)
        
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.platform = createPlaformConfiguration(imagePath: imagePath, configuration: configuration)
        virtualMachineConfiguration.bootLoader = createBootLoader()
        virtualMachineConfiguration.cpuCount = computeCPUCount()
        virtualMachineConfiguration.memorySize = computeMemorySize()
        virtualMachineConfiguration.graphicsDevices = [createGraphicsDeviceConfiguration(resolution: self.resolution)]
        virtualMachineConfiguration.storageDevices = [
            createBlockDeviceConfiguration(imagePath: imagePath, configuration: configuration)
        ]
        
        /*for additionalDirectoryMount in additionalDirectoryMounts {
            virtualMachineConfiguration.storageDevices.append(VirtualMachine.createAdditionalBlockDeviceConfiguration(path: additionalDirectoryMount.path, readOnly: additionalDirectoryMount.isReadOnly))
        }*/
        
        let networkDevice = createNetworkDeviceConfiguration()
        virtualMachineConfiguration.networkDevices = [networkDevice]
        virtualMachineConfiguration.pointingDevices = [createPointingDeviceConfiguration()]
        virtualMachineConfiguration.keyboards = [createKeyboardConfiguration()]
        //virtualMachineConfiguration.audioDevices = [VirtualMachine.createAudioDeviceConfiguration()]
        
        virtualMachineConfiguration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        try! virtualMachineConfiguration.validate()

        self.virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        
        self.macAddress = networkDevice.macAddress.string
        
        super.init()
        
        self.virtualMachine.delegate = self
    }
    
    deinit {
        print("VM feinit")
    }
    
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            if let stoppedContinuation = self.stoppedContinuation {
                self.stoppedContinuation = nil
                stoppedContinuation.resume(returning: Void())
            }
            self.onStopped?(nil)
        }
    }
    
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            if let stoppedContinuation = self.stoppedContinuation {
                self.stoppedContinuation = nil
                stoppedContinuation.resume(returning: Void())
            }
            self.onStopped?(error)
        }
    }
    
    func install(restoreImage: VZMacOSRestoreImage, onProgress: @escaping @MainActor (Int) -> Void) async throws {
        let installer: VZMacOSInstaller = VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: restoreImage.url)
            
        var previousProgress: Int?
        let installationObserver = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { (progress, change) in
            let progress = Int(change.newValue! * 100)
            
            Task { @MainActor in
                if previousProgress != progress {
                    previousProgress = progress
                    onProgress(progress)
                }
            }
        }
        
        try await installer.install()
        
        /*installer.install(completionHandler: { result in
            switch result {
            case .success:
                continuation.resume(returning: Void())
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        })*/
        
        withExtendedLifetime(installationObserver, {})
    }
    
    func start() async throws {
        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, Error>) -> Void in
            guard let self = self else {
                continuation.resume(returning: Void())
                return
            }
            
            self.virtualMachine.start(completionHandler: { result in
                switch result {
                case let .failure(error):
                    continuation.resume(throwing: error)
                default:
                    continuation.resume(returning: Void())
                }
            })
        }
    }
    
    func start(completion: @escaping (Error?) -> Void) {
        self.virtualMachine.start(completionHandler: { result in
            switch result {
            case let .failure(error):
                completion(error)
            default:
                completion(nil)
            }
        })
    }
    
    func awaitShutdown() async {
        switch self.virtualMachine.state {
        case .stopped:
            break
        default:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) -> Void in
                self.stoppedContinuation = continuation
            }
        }
    }
    
    func shutdown() async {
        switch self.virtualMachine.state {
        case .starting, .running:
            do {
                if self.virtualMachine.canRequestStop {
                    do {
                        try self.virtualMachine.requestStop()
                    } catch let e {
                        print("Error in requestStop(): \(e)")
                        try await self.stop()
                    }
                } else {
                    try await self.stop()
                }
            } catch let e {
                print("Error in shutdown(): \(e)")
            }
        default:
            break
        }
    }
    
    func ipAddress() async throws -> String {
        while true {
            if Task.isCancelled {
                throw TaskError.taskCancelled
            }
            
            let result = shell("arp -a")
            
            let simplifiedMacAddress = self.macAddress.split(separator: ":").map { part -> String in
                var part = part
                while part.count > 1 {
                    if part.hasPrefix("0") {
                        part.removeFirst()
                    } else {
                        break
                    }
                }
                return String(part)
            }.joined(separator: ":")
            
            var ipAddress: String?
            for line in result.split(separator: "\n") {
                if line.contains(self.macAddress) || line.contains(simplifiedMacAddress) {
                    ipAddress = extractIpAddressFromArpOutput(string: String(line))
                    break
                }
            }
            
            if let ipAddress = ipAddress {
                return ipAddress
            } else {
                try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
            }
        }
    }
    
    func stop() async throws {
        try await self.virtualMachine.stop()
        
        if let stoppedContinuation = self.stoppedContinuation {
            self.stoppedContinuation = nil
            stoppedContinuation.resume(returning: Void())
        }
    }
    
    func stopNicely() async throws {
        switch self.virtualMachine.state {
        case .stopped:
            break
        default:
            try self.virtualMachine.requestStop()
            
            if case .stopped = self.virtualMachine.state {
                return
            }
            
            return await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) -> Void in
                self.stoppedContinuation = continuation
            }
        }
    }
    
    func takeScreenshot() async -> NSImage? {
        guard let framebuffer = self.virtualMachine._graphicsDevices.first?.framebuffers().first else {
            return nil
        }
        
        do {
            let screenshot = try await framebuffer.takeScreenshot()
            return screenshot
        } catch let e {
            let _ = e
            //print("Error taking screenshot: \(e)")
            return nil
        }
    }
    
    func sendKeyEvents(_ events: [_VZKeyEvent]) {
        let keyboard = (self.virtualMachine._keyboards() as! [AnyObject])[0] as! _VZKeyboard
        keyboard.sendKeyEvents(events)
    }
    
    func pressKey(code: UInt16) async {
        self.sendKeyEvents([_VZKeyEvent(type: .down, keyCode: code)])
        do {
            try await Task.sleep(nanoseconds: 100 * 1000 * 1000)
        } catch {
        }
        self.sendKeyEvents([_VZKeyEvent(type: .up, keyCode: code)])
        do {
            try await Task.sleep(nanoseconds: 20 * 1000 * 1000)
        } catch {
        }
    }
    
    func pressKeys(codes: [UInt16], holdingKeys: [UInt16] = []) async {
        for code in holdingKeys {
            self.sendKeyEvents([_VZKeyEvent(type: .down, keyCode: code)])
        }
        for code in codes {
            await self.pressKey(code: code)
        }
        for code in holdingKeys {
            self.sendKeyEvents([_VZKeyEvent(type: .up, keyCode: code)])
        }
    }
    
    func pressMouse(location: CGPoint) async {
        let pointingDevice = (self.virtualMachine._pointingDevices() as! [AnyObject])[0] as! _VZScreenCoordinatePointingDevice
        pointingDevice.sendPointerEvents([_VZScreenCoordinatePointerEvent(location: location, pressedButtons: 0)])
        do {
            try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        } catch {}
        pointingDevice.sendPointerEvents([_VZScreenCoordinatePointerEvent(location: location, pressedButtons: 1)])
        do {
            try await Task.sleep(nanoseconds: 200 * 1000 * 1000)
        } catch {}
        pointingDevice.sendPointerEvents([_VZScreenCoordinatePointerEvent(location: location, pressedButtons: 0)])
    }
}
