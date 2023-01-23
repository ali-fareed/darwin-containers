import Foundation

@MainActor
final class VirtualMachineManager {
    enum InstanceState {
        case ready
        case starting
        case acquiringCredentials(Task<Void, Never>)
        case running(InstanceCredentials)
        case stopping(Task<Void, Error>)
        case stopped(Error?)
    }
    
    private final class InstanceArguments {
        let id: String
        let type: InstanceType
        let name: String
        let displayWindowAutomatically: Bool
        let started: @MainActor (DarwinVirtualMachine, InstanceCredentials) -> Void
        let stopped: @MainActor (Error?) -> Void
        
        init(
            id: String,
            type: InstanceType,
            name: String,
            displayWindowAutomatically: Bool,
            started: @escaping @MainActor (DarwinVirtualMachine, InstanceCredentials) -> Void,
            stopped: @escaping @MainActor (Error?) -> Void
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.displayWindowAutomatically = displayWindowAutomatically
            self.started = started
            self.stopped = stopped
        }
    }
    
    @MainActor
    private final class InstanceContext {
        enum StateError: Error {
            case invalidState
        }
        
        let id: String
        let virtualMachine: DarwinVirtualMachine
        let configuration: VirtualMachineConfiguration
        let tempWorkingPath: String?
        let onStarted: @MainActor (DarwinVirtualMachine, InstanceCredentials) -> Void
        let onStopped: @MainActor (Error?) -> Void
        let stateUpdated: @MainActor (InstanceState) -> Void
        
        private var state: InstanceState = .ready
        private var isStopRequested: Bool = false
        
        init(
            id: String,
            virtualMachine: DarwinVirtualMachine,
            configuration: VirtualMachineConfiguration,
            tempWorkingPath: String?,
            onStarted: @escaping @MainActor (DarwinVirtualMachine, InstanceCredentials) -> Void,
            onStopped: @escaping @MainActor (Error?) -> Void,
            stateUpdated: @escaping @MainActor (InstanceState) -> Void
        ) {
            self.id = id
            self.virtualMachine = virtualMachine
            self.configuration = configuration
            self.tempWorkingPath = tempWorkingPath
            self.onStarted = onStarted
            self.onStopped = onStopped
            self.stateUpdated = stateUpdated
            
            virtualMachine.onStopped = { [weak self] error in
                guard let self else {
                    return
                }
                switch self.state {
                case .stopping, .stopped:
                    break
                default:
                    self.state = .stopped(error)
                    self.stateUpdated(self.state)
                }
            }
        }
        
        func start() throws {
            guard case .ready = self.state else {
                throw StateError.invalidState
            }
            
            self.state = .starting
            self.stateUpdated(self.state)
            
            self.virtualMachine.start(completion: { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    
                    if self.isStopRequested {
                        self.beginStop()
                    } else {
                        do {
                            try self.acquireCredentials()
                        } catch let e {
                            if e is CancellationError {
                            } else {
                                print("VM \(self.id): could not acquire access credentials (\(e))")
                            }
                        }
                    }
                }
            })
        }
        
        private func acquireCredentials() throws {
            guard case .starting = self.state else {
                throw StateError.invalidState
            }
            
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                
                do {
                    let ipAddress = try await self.virtualMachine.ipAddress()
                    let credentials = InstanceCredentials(
                        id: self.id,
                        ipAddress: ipAddress,
                        publicKey: self.configuration.sshPublicKey,
                        privateKey: self.configuration.sshPrivateKey
                    )
                    self.state = .running(credentials)
                    self.stateUpdated(self.state)
                } catch let e {
                    if e is CancellationError {
                    } else {
                        print("VM \(self.id): could not acquire access credentials (\(e))")
                    }
                }
            }
            self.state = .acquiringCredentials(task)
            self.stateUpdated(self.state)
        }
        
        func stop() throws {
            switch self.state {
            case .ready:
                self.state = .stopped(nil)
                self.stateUpdated(self.state)
            case .starting:
                self.isStopRequested = true
            case .running:
                self.beginStop()
            case let .acquiringCredentials(task):
                task.cancel()
                self.beginStop()
            case .stopping, .stopped:
                break
            }
        }
        
        private func beginStop() {
            self.state = .stopping(Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try await self.virtualMachine.stop()
                    self.state = .stopped(nil)
                    self.stateUpdated(self.state)
                } catch let e {
                    print("VM \(self.id): could not stop (\(e))")
                    self.state = .stopped(e)
                    self.stateUpdated(self.state)
                }
            })
            self.stateUpdated(self.state)
        }
    }
    
    enum InstanceType {
        case base
        case clone
    }
    
    enum RunInstanceError: Error {
        case baseImageNotFound
    }
    
    struct InstanceCredentials {
        var id: String
        var ipAddress: String
        var publicKey: String
        var privateKey: String
    }
    
    private let appDelegate: AppDelegate
    private let baseImagesPath: String
    private let stagingImagesPath: String
    
    private var instanceContexts: [InstanceContext] = []
    private var pendingStarts: [InstanceArguments] = []
    
    init(appDelegate: AppDelegate, baseImagesPath: String, stagingImagesPath: String) {
        self.appDelegate = appDelegate
        self.baseImagesPath = baseImagesPath
        self.stagingImagesPath = stagingImagesPath
    }
    
    func runInstance(
        type: InstanceType,
        name: String,
        displayWindowAutomatically: Bool,
        started: @escaping @MainActor (DarwinVirtualMachine, InstanceCredentials) -> Void,
        stopped: @escaping @MainActor (Error?) -> Void
    ) throws -> String {
        let id = UUID().uuidString
        
        self.pendingStarts.append(InstanceArguments(
            id: id,
            type: type,
            name: name,
            displayWindowAutomatically: displayWindowAutomatically,
            started: started,
            stopped: stopped
        ))
        
        self.runPendingInstanceIfPossible()
        
        return id
    }
    
    private func runPendingInstanceIfPossible() {
        if !self.instanceContexts.isEmpty {
            return
        }
        
        guard !self.pendingStarts.isEmpty else {
            return
        }
        let arguments = self.pendingStarts.removeFirst()
        
        let baseImagePath = self.baseImagesPath + "/\(arguments.name)"
        if !FileManager.default.fileExists(atPath: baseImagePath) {
            arguments.stopped(RunInstanceError.baseImageNotFound)
            return
        }
        
        let configuration: VirtualMachineConfiguration
        let virtualMachine: DarwinVirtualMachine
        
        var tempWorkingPath: String?
        
        do {
            switch arguments.type {
            case .base:
                configuration = try JSONDecoder().decode(VirtualMachineConfiguration.self, from: try Data(contentsOf: URL(fileURLWithPath: baseImagePath + "/configuration.json")))
                virtualMachine = DarwinVirtualMachine(imagePath: baseImagePath, configuration: configuration)
            case .clone:
                let workingImagePath = self.stagingImagesPath + "/\(arguments.id)"
                tempWorkingPath = workingImagePath
                try FileManager.default.createDirectory(atPath: workingImagePath, withIntermediateDirectories: true)
                
                configuration = DarwinVirtualMachine.duplicate(sourceDirectoryPath: baseImagePath, directoryPath: workingImagePath)
                virtualMachine = DarwinVirtualMachine(imagePath: workingImagePath, configuration: configuration)
            }
            
            if arguments.displayWindowAutomatically {
                self.appDelegate.attachVirtualMachineView(virtualMachine: virtualMachine)
            }
            
            let id = arguments.id
            let instanceContext = InstanceContext(
                id: arguments.id,
                virtualMachine: virtualMachine,
                configuration: configuration,
                tempWorkingPath: tempWorkingPath,
                onStarted: arguments.started,
                onStopped: arguments.stopped,
                stateUpdated: { @MainActor [weak self] state in
                    guard let self else {
                        return
                    }
                    self.handleInstanceStateUpdated(id: id, state: state)
                }
            )
            
            self.instanceContexts.append(instanceContext)
            
            try instanceContext.start()
        } catch let e {
            arguments.stopped(e)
        }
    }
    
    func disposeInstance(id: String) {
        guard let instanceContext = self.instanceContexts.first(where: { $0.id == id }) else {
            return
        }
        do {
            try instanceContext.stop()
        } catch let e {
            print("VM \(id): error while requesting stop (\(e))")
        }
    }
    
    private func handleInstanceStateUpdated(id: String, state: InstanceState) {
        guard let instanceContext = self.instanceContexts.first(where: { $0.id == id }) else {
            return
        }
        switch state {
        case let .running(credentials):
            instanceContext.onStarted(instanceContext.virtualMachine, credentials)
        case let .stopped(error):
            instanceContext.onStopped(error)
            self.instanceContexts.removeAll(where: { $0.id == id })
            
            self.appDelegate.detachVirtualMachineView(virtualMachine: instanceContext.virtualMachine)
            
            if let tempWorkingPath = instanceContext.tempWorkingPath {
                DispatchQueue.global(qos: .default).async {
                    let _ = try? FileManager.default.removeItem(atPath: tempWorkingPath)
                }
            }
            
            self.runPendingInstanceIfPossible()
        default:
            break
        }
    }
    
    func runningInstanceIds() -> [String] {
        return self.instanceContexts.map(\.id)
    }
}
