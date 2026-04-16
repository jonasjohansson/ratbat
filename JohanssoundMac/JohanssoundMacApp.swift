import SwiftUI
import JohanssoundCore

@main
struct JohanssoundMacApp: App {
    var body: some Scene {
        WindowGroup {
            HelloView()
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
