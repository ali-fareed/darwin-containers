import Foundation
import Network

final class RpcServer {
    enum Endpoint {
        case unixSocket(path: String)
        case tcp(port: Int)
    }
    
    class ResponseHandler {
        private weak var server: RpcServer?
        private let connectionId: Int
        
        fileprivate init(server: RpcServer, connectionId: Int) {
            self.server = server
            self.connectionId = connectionId
        }
        
        func onClose(_ handler: @escaping () -> Void) {
            guard let server = self.server else {
                print("ResponseHandler: send: server object is unavailable")
                return
            }
            server.addConnectionCloseHandler(id: self.connectionId, handler: handler)
        }
        
        func send(message: [String: Any]) {
            guard let server = self.server else {
                print("ResponseHandler: send: server object is unavailable")
                return
            }
            guard let connection = server.currentConnections[self.connectionId] else {
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                print("ResponseHandler: send: could not serialize message \(message)")
                return
            }
            connection.send(data: data)
        }
        
        func close() {
            guard let server = self.server else {
                print("ResponseHandler: send: server object is unavailable")
                return
            }
            server.closeConnection(id: self.connectionId)
        }
    }
    
    private final class Connection {
        private let connection: NWConnection
        private let onRequest: ([String: Any]) -> Void
        private let onRemoved: () -> Void
        
        private var didComplete: Bool = false
        private var queuedPackets: [Data] = []
        
        private var nextPendingSendRequest: Int = 0
        private var pendingSendRequests = Set<Int>()
        private var currentCloseHandler: (() -> Void)?
        
        var externalCloseHandlers: [() -> Void] = []
        
        init(connection: NWConnection, onRequest: @escaping ([String: Any]) -> Void, onRemoved: @escaping () -> Void) {
            self.connection = connection
            self.onRequest = onRequest
            self.onRemoved = onRemoved
            
            self.connection.stateUpdateHandler = { [weak self] state in
                self?.onStateUpdated(state: state)
            }
            self.connection.start(queue: .main)
            
            //self.queuedPackets.append("{\"result\": \"ok\"}".data(using: .utf8)!)
            self.receivePacketHeader()
        }
        
        private func receivePacketHeader() {
            self.connection.receive(minimumIncompleteLength: 4, maximumLength: 4, completion: { [weak self] data, _, _, error in
                guard let self else {
                    return
                }
                if let data = data, data.count == 4 {
                    let payloadSize = data.withUnsafeBytes { bytes -> UInt32 in
                        return bytes.baseAddress!.assumingMemoryBound(to: UInt32.self).pointee
                    }
                    if payloadSize < 2 * 1024 * 1024 {
                        self.receivePacketPayload(size: Int(payloadSize))
                    } else {
                        print("Onvalid packet size: \(payloadSize)")
                    }
                } else {
                    print("Invalid packet size")
                    //close
                }
            })
        }
        
        private func receivePacketPayload(size: Int) {
            self.connection.receive(minimumIncompleteLength: size, maximumLength: size, completion: { [weak self] data, _, _, error in
                guard let self else {
                    return
                }
                if let data = data, data.count == size {
                    if let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        self.onRequest(payload)
                    } else {
                        print("Could not decode payload")
                    }
                } else {
                    print("Connection receive packet payload error: \(String(describing: error))")
                    //close
                }
            })
        }
        
        private func onStateUpdated(state: NWConnection.State) {
            switch state {
            case .cancelled, .failed:
                if !self.didComplete {
                    self.didComplete = true
                    self.onRemoved()
                }
            case .ready:
                self.sendQueuedPackets()
            default:
                break
            }
        }
        
        private func sendQueuedPackets() {
            for data in self.queuedPackets {
                let requestId = self.nextPendingSendRequest
                self.nextPendingSendRequest += 1
                self.pendingSendRequests.insert(requestId)
                
                var length: Int32 = Int32(data.count)
                let lengthData = withUnsafeBytes(of: &length, { bytes -> Data in
                    return Data(bytes: bytes.baseAddress!, count: bytes.count)
                })
                self.connection.send(content: lengthData, completion: .contentProcessed({ _ in }))
                self.connection.send(content: data, completion: .contentProcessed({ [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.pendingSendRequests.remove(requestId)
                    if self.pendingSendRequests.isEmpty {
                        self.closeIfNeeded()
                    }
                }))
            }
            self.queuedPackets.removeAll()
        }
        
        func send(data: Data) {
            self.queuedPackets.append(data)
            if self.connection.state == .ready {
                self.sendQueuedPackets()
            }
        }
        
        private func closeIfNeeded() {
            if let currentCloseHandler = self.currentCloseHandler {
                self.connection.cancel()
                self.currentCloseHandler = nil
                currentCloseHandler()
            }
        }
        
        func close(completion: @escaping () -> Void) {
            if self.currentCloseHandler != nil {
                print("Attempting to close connection twice")
            } else {
                self.currentCloseHandler = completion
                
                if self.pendingSendRequests.isEmpty {
                    self.closeIfNeeded()
                }
            }
        }
        
        func performCloseHandlers() {
            for handler in self.externalCloseHandlers {
                handler()
            }
            self.externalCloseHandlers.removeAll()
        }
    }
    
    private let requestHandler: ([String: Any], ResponseHandler) async -> Void
    
    private let listener: NWListener
    
    private var nextConnectionId: Int = 0
    private var currentConnections: [Int: Connection] = [:]
    private var closingConnections: [Int: Connection] = [:]
    
    init(endpoint: Endpoint, requestHandler: @escaping ([String: Any], ResponseHandler) async -> Void) throws {
        self.requestHandler = requestHandler
        
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        switch endpoint {
        case let .unixSocket(path):
            try? FileManager.default.removeItem(atPath: path)
            parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
            self.listener = try NWListener(using: parameters, on: 0)
        case let .tcp(port):
            let intPort = UInt16(truncatingIfNeeded: port)
            guard let parsedPort = NWEndpoint.Port(rawValue: intPort) else {
                print("Invalid port number \(port)")
                preconditionFailure()
            }
            self.listener = try NWListener(using: parameters, on: parsedPort)
        }
        
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection: connection)
        }
        self.listener.start(queue: .main)
    }
    
    private func acceptConnection(connection: NWConnection) {
        let id = self.nextConnectionId
        self.nextConnectionId += 1
        self.currentConnections[id] = Connection(
            connection: connection,
            onRequest: { [weak self] dict in
                guard let self else {
                    return
                }
                Task { @MainActor () -> Void in
                    await self.requestHandler(dict, ResponseHandler(server: self, connectionId: id))
                }
            },
            onRemoved: { [weak self] in
                guard let self else {
                    return
                }
                if let connection = self.currentConnections.removeValue(forKey: id) {
                    connection.performCloseHandlers()
                }
            }
        )
    }
    
    private func closeConnection(id: Int) {
        if let connection = self.currentConnections.removeValue(forKey: id) {
            connection.performCloseHandlers()
            
            self.closingConnections[id] = connection
            connection.close(completion: { [weak self] in
                guard let self else {
                    return
                }
                self.closingConnections.removeValue(forKey: id)
            })
        }
    }
    
    private func addConnectionCloseHandler(id: Int, handler: @escaping () -> Void) {
        if let connection = self.currentConnections[id] {
            connection.externalCloseHandlers.append(handler)
        }
    }
}
