import Cocoa

private struct JsonImageCredentials: Codable {
    var id: String
    var ipAddress: String
    var publicKey: String
    var privateKey: String
    var login: String
    var password: String
}

private func performPostInstallSetup(
    virtualMachine: DarwinVirtualMachine,
    verbose: Bool
) async throws {
    try await ScreenRecognizer.setupAfterInstallation(virtualMachine: virtualMachine, verbose: verbose)
    
    let ipAddress = try await virtualMachine.ipAddress()
       
    try await installSshCredentials(ipAddress: ipAddress, privateKey: virtualMachine.configuration.sshPrivateKey, publicKey: virtualMachine.configuration.sshPublicKey, verbose: verbose)
    
    try await ScreenRecognizer.stop(virtualMachine: virtualMachine, verbose: verbose)
}

@MainActor
private func createMasterImage(
    restoreImage: VZMacOSRestoreImage,
    stagingPath: String,
    imagesPath: String,
    name: String,
    diskSize: Int,
    appDelegate: AppDelegate,
    isManual: Bool,
    onInstallationProgress: @escaping @MainActor (Int) -> Void,
    onContinueManualInstallation: @escaping @MainActor (VirtualMachineManager.InstanceCredentials) -> Void,
    verbose: Bool
) async throws -> VirtualMachineConfiguration {
    let hardwareModel = restoreImage.mostFeaturefulSupportedConfiguration!.hardwareModel
    
    let initialInstancePath = stagingPath + "/\(UUID())"
    let copyInstancePath = stagingPath + "/\(UUID())"
    
    let _ = try FileManager.default.createDirectory(atPath: initialInstancePath, withIntermediateDirectories: true)
    var configuration = try DarwinVirtualMachine.allocate(
        directoryPath: initialInstancePath,
        hardwareModel: hardwareModel,
        osVersion: restoreImage.operatingSystemVersion,
        diskSize: diskSize
    )
    
    var virtualMachine = DarwinVirtualMachine(imagePath: initialInstancePath, configuration: configuration)
    
    try await virtualMachine.install(restoreImage: restoreImage, onProgress: onInstallationProgress)
    
    print("VM state after install: \(virtualMachine.virtualMachine.state)")
    
    try FileManager.default.moveItem(atPath: initialInstancePath, toPath: initialInstancePath + "-move")
    
    /*try setupMasterImage(
        appDelegate: appDelegate,
        baseImagePath: initialInstancePath + "-move",
        workingImagePath: copyInstancePath,
        displayWindowAutomatically: true
    )*/
    
    try FileManager.default.createDirectory(atPath: copyInstancePath, withIntermediateDirectories: true)
    configuration = DarwinVirtualMachine.duplicate(sourceDirectoryPath: initialInstancePath + "-move", directoryPath: copyInstancePath)
    try FileManager.default.removeItem(atPath: initialInstancePath + "-move")
    
    virtualMachine = DarwinVirtualMachine(imagePath: copyInstancePath, configuration: configuration)
    //virtualMachine = DarwinVirtualMachine(imagePath: baseImagePath, configuration: configuration)
    
    if isManual || verbose {
        appDelegate.attachVirtualMachineView(virtualMachine: virtualMachine)
    }
    
    try await virtualMachine.start()
    
    let ipAddress = try await virtualMachine.ipAddress()
    
    if isManual {
        let credentials = VirtualMachineManager.InstanceCredentials(
            id: "",
            ipAddress: ipAddress,
            publicKey: configuration.sshPublicKey,
            privateKey: configuration.sshPrivateKey
        )
        
        onContinueManualInstallation(credentials)
    } else {
        try await Task.sleep(for: .seconds(10))
        
        try await performPostInstallSetup(
            virtualMachine: virtualMachine,
            verbose: verbose
        )
    }
    
    await virtualMachine.awaitShutdown()
    
    appDelegate.detachVirtualMachineView(virtualMachine: virtualMachine)
    
    try FileManager.default.moveItem(atPath: copyInstancePath, toPath: imagesPath + "/\(name)")
    
    return configuration
    
    /*if isManual || verbose {
        appDelegate.attachVirtualMachineView(virtualMachine: virtualMachine)
    }
    
    print("VM state: \(virtualMachine.virtualMachine.state)")
    
    if isManual {
        let ipAddress = try await virtualMachine!.ipAddress()
        let credentials = VirtualMachineManager.InstanceCredentials(
            id: "",
            ipAddress: ipAddress,
            publicKey: configuration.sshPublicKey,
            privateKey: configuration.sshPrivateKey
        )
        
        onContinueManualInstallation(credentials)
    } else {
        try await performPostInstallSetup(
            virtualMachine: virtualMachine!,
            verbose: verbose
        )
    }
    
    await virtualMachine!.awaitShutdown()
    appDelegate.detachVirtualMachineView(virtualMachine: virtualMachine!)
    
    try FileManager.default.moveItem(atPath: initialInstancePath, toPath: imagesPath + "/\(name)")
    
    return configuration*/
}

@MainActor
private func setupMasterImage(
    appDelegate: AppDelegate,
    baseImagePath: String,
    workingImagePath: String,
    displayWindowAutomatically: Bool
) throws {
    let configuration: VirtualMachineConfiguration
    let virtualMachine: DarwinVirtualMachine
    
    try FileManager.default.createDirectory(atPath: workingImagePath, withIntermediateDirectories: true)
    
    configuration = DarwinVirtualMachine.duplicate(sourceDirectoryPath: baseImagePath, directoryPath: workingImagePath)
    try FileManager.default.removeItem(atPath: baseImagePath)
    
    virtualMachine = DarwinVirtualMachine(imagePath: workingImagePath, configuration: configuration)
    //virtualMachine = DarwinVirtualMachine(imagePath: baseImagePath, configuration: configuration)
    
    if displayWindowAutomatically {
        appDelegate.attachVirtualMachineView(virtualMachine: virtualMachine)
    }
    
    virtualMachine.start(completion: { error in
        Task { @MainActor in
            let _ = virtualMachine
        }
    })
    
    
}

private func macosVersionString(for version: OperatingSystemVersion) -> String {
    var result = ""
    result.append("\(version.majorVersion)")
    result.append(".")
    result.append("\(version.minorVersion)")
    if version.patchVersion != 0 {
        result.append(".")
        result.append("\(version.patchVersion)")
    }
    return result
}

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let basePath: String
    private let baseImagesPath: String
    private let stagingImagesPath: String
    private let cleanupPath: String
    private let restoreImagesPath: String
    
    private var virtualMachineManager: VirtualMachineManager?
    private var rpcServer: RpcServer?
    private var windows: [VirtualMachineWindow] = []
    
    override init() {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        self.basePath = homeDirectoryPath + "/DarwinContainers"
        self.baseImagesPath = self.basePath + "/images"
        self.stagingImagesPath = self.basePath + "/staging"
        self.cleanupPath = self.basePath + "/cleanup"
        self.restoreImagesPath = basePath + "/restore-images"
        
        super.init()
        
        swizzleRuntimeMethods()
        
        do {
            if !FileManager.default.fileExists(atPath: self.basePath) {
                let _ = try FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: self.baseImagesPath) {
                let _ = try FileManager.default.createDirectory(atPath: self.baseImagesPath, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: self.stagingImagesPath) {
                let _ = try FileManager.default.createDirectory(atPath: self.stagingImagesPath, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: self.cleanupPath) {
                let _ = try FileManager.default.createDirectory(atPath: self.cleanupPath, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: self.restoreImagesPath) {
                let _ = try FileManager.default.createDirectory(atPath: self.restoreImagesPath, withIntermediateDirectories: true)
            }
            
            for item in try FileManager.default.contentsOfDirectory(atPath: self.stagingImagesPath) {
                try FileManager.default.moveItem(atPath: self.stagingImagesPath + "/" + item, toPath: self.cleanupPath + "/" + item)
            }
        } catch let e {
            print("Initialization error: \(e)")
            preconditionFailure()
        }
        
        DispatchQueue.global(qos: .default).async { [cleanupPath = self.cleanupPath] in
            for item in try! FileManager.default.contentsOfDirectory(atPath: cleanupPath) {
                let _ = try? FileManager.default.removeItem(atPath: cleanupPath + "/" + item)
            }
        }
        
        self.virtualMachineManager = VirtualMachineManager(appDelegate: self, baseImagesPath: baseImagesPath, stagingImagesPath: self.stagingImagesPath)
    }
    
    @MainActor
    func attachVirtualMachineView(virtualMachine: DarwinVirtualMachine) {
        let window = NSWindow()
        window.styleMask = NSWindow.StyleMask(rawValue: 0xf)
        window.backingType = .buffered
        
        let viewController = ViewController(virtualMachine: virtualMachine)
        window.contentViewController = viewController
        window.setFrame(window.frameRect(forContentRect: NSRect(x: floor((NSScreen.main!.frame.size.width - 800) / 2.0), y: floor((NSScreen.main!.frame.size.height - 800) / 2.0), width: 800, height: 800)), display: false)
        let windowController = NSWindowController()
        windowController.contentViewController = window.contentViewController
        windowController.window = window
        windowController.showWindow(self)
        
        self.windows.append(VirtualMachineWindow(window: window, windowController: windowController, viewController: viewController))
        
        window.makeKeyAndOrderFront(nil)
        let _ = window.becomeFirstResponder()
    }
    
    @MainActor
    func detachVirtualMachineView(virtualMachine: DarwinVirtualMachine) {
        if let index = self.windows.firstIndex(where: { $0.viewController.virtualMachine === virtualMachine }) {
            let window = self.windows[index]
            self.windows.remove(at: index)
            
            window.viewController.virtualMachine.view = nil
            window.window.close()
        }
    }

    /*@MainActor
    func runImage(imagesPath: String, location: RunImageLocation, name: String, appDelegate: AppDelegate, verbose: Bool) throws -> ActiveVirtualMachine {
        let baseImagePath = imagesPath + "/\(name)"
        if !FileManager.default.fileExists(atPath: baseImagePath) {
            throw RunImageError.baseImageNotFound
        }
        
        let configuration: VirtualMachineConfiguration
        let virtualMachine: DarwinVirtualMachine
        
        var tempWorkingPath: String?
        
        switch location {
        case .base:
            configuration = try JSONDecoder().decode(VirtualMachineConfiguration.self, from: try Data(contentsOf: URL(fileURLWithPath: baseImagePath + "/configuration.json")))
            virtualMachine = DarwinVirtualMachine(imagePath: baseImagePath, configuration: configuration)
        case let .clone(stagingPath):
            let workingImagePath = stagingPath + "/\(UUID())"
            tempWorkingPath = workingImagePath
            try FileManager.default.createDirectory(atPath: workingImagePath, withIntermediateDirectories: true)
            
            configuration = DarwinVirtualMachine.duplicate(sourceDirectoryPath: baseImagePath, directoryPath: workingImagePath)
            virtualMachine = DarwinVirtualMachine(imagePath: workingImagePath, configuration: configuration)
        }
        
        self.attachVirtualMachineView(virtualMachine: virtualMachine)
        
        return ActiveVirtualMachine(
            virtualMachine: virtualMachine,
            configuration: configuration,
            tempWorkingPath: tempWorkingPath
        )
    }
    
    @MainActor
    func disposeVirtualMachine(virtualMachine: ActiveVirtualMachine) async throws {
        await virtualMachine.virtualMachine.awaitShutdown()
        self.detachVirtualMachineView(virtualMachine: virtualMachine.virtualMachine)
        
        if let tempWorkingPath = virtualMachine.tempWorkingPath {
            try FileManager.default.removeItem(atPath: tempWorkingPath)
        }
    }*/
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let apppication = NSApplication.shared
        apppication.setActivationPolicy(.regular)
        apppication.activate(ignoringOtherApps: true)
        
        enum InternalError: Error {
            case generic
        }
        
        self.rpcServer = try? RpcServer(endpoint: .unixSocket(path: FileManager.default.homeDirectoryForCurrentUser.path + "/.darwin-containers.sock"), requestHandler: { dict, response in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    response.send(message: [
                        "error": "Internal error"
                    ])
                    response.close()
                    return
                }
                guard let request = dict["request"] as? String else {
                    response.send(message: [
                        "error": "Missing \"request\" field"
                    ])
                    response.close()
                    return
                }
                switch request {
                case "image-list":
                    do {
                        var result: [String] = []
                        for item in try FileManager.default.contentsOfDirectory(atPath: self.baseImagesPath) {
                            if FileManager.default.fileExists(atPath: self.baseImagesPath + "/\(item)/configuration.json") {
                                result.append(item)
                            }
                        }
                        response.send(message: ["list": result])
                        response.close()
                    } catch {
                        response.send(message: [
                            "error": "Internal error"
                        ])
                        response.close()
                    }
                case "container-list":
                    guard let virtualMachineManager = self.virtualMachineManager else {
                        response.send(message: [
                            "error": "Internal error"
                        ])
                        response.close()
                        return
                    }
                    response.send(message: [
                        "list": virtualMachineManager.runningInstanceIds()
                    ])
                    response.close()
                case "container-kill":
                    guard let virtualMachineManager = self.virtualMachineManager else {
                        response.send(message: [
                            "error": "Internal error"
                        ])
                        response.close()
                        return
                    }
                    guard let id = dict["id"] as? String else {
                        response.send(message: [
                            "error": "Missing \"id\" field"
                        ])
                        response.close()
                        return
                    }
                    if id == "all" {
                        for instanceId in virtualMachineManager.runningInstanceIds() {
                            virtualMachineManager.disposeInstance(id: instanceId)
                        }
                    } else {
                        virtualMachineManager.disposeInstance(id: id)
                    }
                    response.close()
                case "installable-image-list":
                    let result: [String] = InstallationImages.listAvailable()
                    response.send(message: ["list": result])
                    response.close()
                case "run-base-image", "run-working-image":
                    Task { @MainActor in
                        guard let virtualMachineManager = self.virtualMachineManager else {
                            response.send(message: [
                                "error": "Internal error"
                            ])
                            response.close()
                            return
                        }
                        guard let name = dict["name"] as? String else {
                            response.send(message: [
                                "error": "Missing \"name\" field"
                            ])
                            response.close()
                            return
                        }
                        
                        if !FileManager.default.fileExists(atPath: self.baseImagesPath + "/\(name)/configuration.json") {
                            response.send(message: [
                                "error": "Image \"\(name)\" does not exist"
                            ])
                            response.close()
                            return
                        }
                        
                        do {
                            let instanceType: VirtualMachineManager.InstanceType
                            if request == "run-base-image" {
                                instanceType = .base
                            } else {
                                instanceType = .clone
                            }
                            
                            var displayWindowAutomatically = false
                            if let gui = dict["gui"] as? Bool, gui {
                                displayWindowAutomatically = true
                            }
                            
                            var isDaemon = false
                            if let daemon = dict["daemon"] as? Bool, daemon {
                                isDaemon = true
                            }
                            
                            let id = try virtualMachineManager.runInstance(type: instanceType, name: name, displayWindowAutomatically: displayWindowAutomatically, started: { @MainActor virtualMachine, credentials in
                                
                                do {
                                    let jsonCredentials = JsonImageCredentials(
                                        id: credentials.id,
                                        ipAddress: credentials.ipAddress,
                                        publicKey: credentials.publicKey,
                                        privateKey: credentials.privateKey,
                                        login: "containerhost",
                                        password: "containerhost"
                                    )
                                    let sshObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(jsonCredentials))
                                    response.send(message: ["ssh": sshObject])
                                    if isDaemon {
                                        response.close()
                                    }
                                    
                                    /*#if DEBUG
                                    Task { @MainActor in
                                        if name.hasPrefix("install") {
                                            try await performPostInstallSetup(
                                                virtualMachine: virtualMachine,
                                                verbose: true
                                            )
                                        }
                                    }
                                    #endif*/
                                } catch let e {
                                    print("Error: \(e)")
                                    
                                    response.send(message: [
                                        "error": "Internal error"
                                    ])
                                    response.close()
                                }
                            }, stopped: { @MainActor _ in
                                response.send(message: [
                                    "status": "stopped"
                                ])
                                response.close()
                            })
                            
                            if !isDaemon {
                                response.onClose { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    self.virtualMachineManager?.disposeInstance(id: id)
                                }
                            }
                        } catch {
                            response.send(message: [
                                "error": "Internal error"
                            ])
                            response.close()
                        }
                    }
                case "fetch":
                    guard let name = dict["name"] as? String else {
                        response.send(message: [
                            "error": "Missing \"name\" field"
                        ])
                        response.close()
                        return
                    }
                    
                    guard let url = InstallationImages.url(for: name) else {
                        response.send(message: [
                            "status": "unknown",
                            "error": "Unknown restore image name \"\(name)\""
                        ])
                        response.close()
                        return
                    }
                    
                    if let _ = InstallationImages.fetchedPath(basePath: self.restoreImagesPath, name: name) {
                        response.send(message: [
                            "status": "already"
                        ])
                        response.close()
                    } else {
                        response.send(message: [
                            "status": "downloading"
                        ])
                        
                        final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
                            private let restoreImagesPath: String
                            private let name: String
                            private let response: RpcServer.ResponseHandler
                            private var reportedProgress: Int?
                            var continuation: CheckedContinuation<Void, Error>?
                            
                            init(restoreImagesPath: String, name: String, response: RpcServer.ResponseHandler) {
                                self.restoreImagesPath = restoreImagesPath
                                self.name = name
                                self.response = response
                            }
                            
                            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                                InstallationImages.storeFetched(location: location, basePath: self.restoreImagesPath, name: name)
                                
                                response.send(message: [
                                    "status": "done"
                                ])
                                response.close()
                                self.continuation?.resume(returning: Void())
                            }
                            
                            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                                if let error = error {
                                    self.continuation?.resume(throwing: error)
                                }
                            }
                            
                            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
                                if totalBytesExpectedToWrite != 0 {
                                    let progress = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
                                    if self.reportedProgress != progress {
                                        self.reportedProgress = progress
                                        response.send(message: [
                                            "status": "progress",
                                            "progress": progress
                                        ])
                                    }
                                }
                            }
                        }
                        
                        let delegate = DownloadDelegate(restoreImagesPath: self.restoreImagesPath, name: name, response: response)
                        
                        do {
                            try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) -> Void in
                                let task = URLSession.shared.downloadTask(with: URLRequest(url: url))
                                task.delegate = delegate
                                delegate.continuation = continuation
                                
                                response.onClose { [weak task] in
                                    task?.cancel()
                                }
                                
                                task.resume()
                            })
                        } catch let e {
                            print("Download error: \(e)")
                            
                            response.send(message: [
                                "error": "Download error"
                            ])
                            response.close()
                        }
                        
                        withExtendedLifetime(delegate, {})
                    }
                case "install":
                    guard let name = dict["name"] as? String else {
                        response.send(message: [
                            "error": "Missing \"name\" field"
                        ])
                        response.close()
                        return
                    }
                    guard let tag = dict["tag"] as? String else {
                        response.send(message: [
                            "error": "Missing \"tag\" field"
                        ])
                        response.close()
                        return
                    }
                    guard let restoreImagePath = InstallationImages.fetchedPath(basePath: self.restoreImagesPath, name: name) else {
                        response.send(message: [
                            "error": "Restore image \"\(name)\" is not available locally"
                        ])
                        response.close()
                        return
                    }
                    
                    var isManual = false
                    if let manual = dict["manual"] as? Bool, manual {
                        isManual = true
                    }
                    
                    var diskSize = 80
                    if let diskSizeValue = dict["diskSize"] as? Int {
                        diskSize = diskSizeValue
                    }
                    
                    do {
                        let restoreImage = try await VZMacOSRestoreImage.image(from: URL(fileURLWithPath: restoreImagePath))
                        
                        response.send(message: [
                            "status": "creating"
                        ])
                        
                        let _ = try await createMasterImage(
                            restoreImage: restoreImage,
                            stagingPath: self.stagingImagesPath,
                            imagesPath: self.baseImagesPath,
                            name: tag,
                            diskSize: diskSize,
                            appDelegate: self,
                            isManual: isManual,
                            onInstallationProgress: { value in
                                response.send(message: [
                                    "status": "progress",
                                    "progress": value
                                ])
                            },
                            onContinueManualInstallation: { @MainActor credentials in
                                let jsonCredentials = JsonImageCredentials(
                                    id: credentials.id,
                                    ipAddress: credentials.ipAddress,
                                    publicKey: credentials.publicKey,
                                    privateKey: credentials.privateKey,
                                    login: "containerhost",
                                    password: "containerhost"
                                )
                                
                                do {
                                    let sshObject = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(jsonCredentials))
                                    
                                    response.send(message: [
                                        "status": "manualInstallation",
                                        "ssh": sshObject
                                    ])
                                } catch let e {
                                    response.send(message: [
                                        "error": "Internal error: \(e)"
                                    ])
                                    response.close()
                                }
                            },
                            verbose: true
                        )
                        
                        /*if "".isEmpty {
                            guard let virtualMachineManager = self.virtualMachineManager else {
                                response.send(message: [
                                    "error": "Internal error"
                                ])
                                response.close()
                                return
                            }
                            
                            let _ = try virtualMachineManager.runInstance(type: .clone, name: tag, displayWindowAutomatically: true, started: { _, _ in
                            }, stopped: { _ in
                            })
                        }*/
                        
                        response.send(message: [
                            "status": "done"
                        ])
                        response.close()
                    } catch let e {
                        response.send(message: [
                            "error": "Internal error: \(e)"
                        ])
                        response.close()
                        return
                    }
                default:
                    response.send(message: [
                        "error": "Unknown request type"
                    ])
                    response.close()
                }
            }
            
            let _ = await task.result
        })
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
