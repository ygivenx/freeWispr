import SwiftUI

@main
struct FreeWisprApp: App {
    var body: some Scene {
        MenuBarExtra("FreeWispr", systemImage: "mic") {
            Text("FreeWispr is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
