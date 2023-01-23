import Cocoa
import Virtualization

class ViewController: NSViewController {
    var virtualMachineView: VZVirtualMachineView?
    let virtualMachine: DarwinVirtualMachine
    
    init(virtualMachine: DarwinVirtualMachine) {
        self.virtualMachine = virtualMachine
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        let virtualMachineView = VZVirtualMachineView()
        virtualMachineView.capturesSystemKeys = true
        self.virtualMachineView = virtualMachineView
        
        self.view = virtualMachineView
        
        virtualMachineView.virtualMachine = self.virtualMachine.virtualMachine
        self.virtualMachine.view = virtualMachineView
    }
}

@MainActor
class VirtualMachineWindow {
    let window: NSWindow
    let windowController: NSWindowController
    let viewController: ViewController
    
    init(window: NSWindow, windowController: NSWindowController, viewController: ViewController) {
        self.window = window
        self.windowController = windowController
        self.viewController = viewController
    }
}
