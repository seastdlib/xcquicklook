import SwiftUI

@main
struct XCQuickLookApp: App {
    var body: some Scene {
        Window("xcquicklook", id: "about") {
            InstalledView()
        }
        .windowResizability(.contentSize)
    }
}

/// The app exists only to host the Quick Look extension; this window is all
/// there is to see when someone launches it directly.
struct InstalledView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Quick Look Syntax Highlighting")
                .font(.headline)
            Text("Previews of code, script, and configuration files are now syntax highlighted. There is nothing to configure — press Space on a file in Finder to try it. If previews are not highlighted, enable the extension in System Settings › General › Login Items & Extensions › Quick Look.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 420)
    }
}

#Preview {
    InstalledView()
}
