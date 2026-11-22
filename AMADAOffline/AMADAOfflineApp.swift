import SwiftUI
import FirebaseCore
import FirebaseAppCheck

final class SheetMasterAppCheckFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}

@main
struct AMADAOfflineApp: App {
    init() {
        AppCheck.setAppCheckProviderFactory(SheetMasterAppCheckFactory())
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup { MainView() }
    }
}
