import AppKit
import DesignScaffold
import PixelAgencyRun
import SwiftUI

/// First-launch onboarding, step one (README APP-3): what the working folder is for, then choose or create it. Also
/// shown when the folder can't be opened any more (APP-4): locate it, choose another, or quit.
public struct WorkingFolderOnboarding: View {
    let folder: WorkingFolder
    let appName: String
    /// What this app keeps in the folder, in a sentence.
    let purpose: String
    @State private var choosing = false
    @State private var problem: String?

    public init(folder: WorkingFolder, appName: String, purpose: String) {
        self.folder = folder
        self.appName = appName
        self.purpose = purpose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            Image(systemName: unavailable == nil ? "folder.badge.plus" : "folder.badge.questionmark")
                .font(.system(size: 40)).foregroundStyle(unavailable == nil ? Tokens.Color.accent : Tokens.Color.degraded)
            Text(unavailable == nil ? "Choose a working folder" : "The working folder isn't available")
                .font(Tokens.Font.screenTitle)
            Text(unavailable ?? "\(appName) keeps your work in a folder you choose. \(purpose) Nothing is kept anywhere else, and you can change the folder later in Settings.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(unavailable == nil ? Tokens.Color.label : Tokens.Color.degraded)
            if let problem { Text(problem).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure) }
            HStack {
                if unavailable != nil { Button("Quit") { NSApp.terminate(nil) } }
                Spacer()
                Button(unavailable == nil ? "Choose Folder…" : "Locate or Choose Another…") { choosing = true }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(Tokens.Space.xxl)
        .frame(width: 520)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                // The panel's URL is security-scoped for this launch; the bookmark keeps it for the next ones.
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                do { try folder.choose(url) } catch { problem = "Couldn't keep access to that folder: \(error.localizedDescription)" }
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
        .fileDialogMessage("Choose or create the folder \(appName) works in")
        .fileDialogConfirmationLabel("Use This Folder")
    }

    var unavailable: String? { if case .unavailable(let why) = folder.status { why } else { nil } }
}
