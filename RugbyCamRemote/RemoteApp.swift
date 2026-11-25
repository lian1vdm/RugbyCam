import SwiftUI

@main
struct RugbyCamRemoteApp: App {
    @StateObject private var client = PhoneClient()
    @StateObject private var finder = PhoneFinder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(finder)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                finder.start()
                client.resume()
            case .background:
                client.pause()
                finder.stop()
            default:
                // Inactive (Control Centre pulled down, a call): let go of the arrows.
                client.stopMove()
            }
        }
    }
}

enum Theme {
    static let gold = Color(red: 0.96, green: 0.71, blue: 0.13)
    static let green = Color(red: 0.18, green: 0.70, blue: 0.42)
    static let red = Color(red: 0.90, green: 0.22, blue: 0.21)
    static let panel = Color(white: 0.11)
    static let dim = Color(white: 0.62)
}

struct RootView: View {
    @EnvironmentObject var client: PhoneClient

    var body: some View {
        Group {
            switch client.link {
            case .idle, .wrongPin:
                ConnectView()
            case .connecting, .connected, .unreachable:
                ControlView()
            }
        }
        .animation(.default, value: client.link)
        .onAppear {
            // Reconnect to the iPhone used last time, with the saved PIN.
            if client.link == .idle && client.hasSavedPhone {
                client.connect(to: client.address, pin: client.pin)
            }
        }
    }
}
