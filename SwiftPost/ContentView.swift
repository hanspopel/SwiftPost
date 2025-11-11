import SwiftUI
import Combine   // <- Das war der fehlende Import
import PhotosUI
import AVFoundation
import UIKit

// MARK: - Models


enum AccountKind: String, Codable, Identifiable {
    case twitter
    case bluesky
    case mastodon
    case threads

    var id: String { rawValue } // ✅ macht es Identifiable
}

struct Account: Identifiable, Codable {
    let id: UUID
    var name: String
    var kind: AccountKind
    var enabled: Bool
    // Twitter fields
    var accessToken: String?
    var accessSecret: String?
    var apiKey: String?
    var apiSecret: String?
    // Bluesky fields
    var handle: String?
    var accessJwt: String?
    var did: String?
    // Mastodon fields
    var instanceURL: String?   // ✅ NEW
    var mastodonToken: String? // ✅ NEW
    
    init(id: UUID = UUID(),
         name: String,
         kind: AccountKind,
         enabled: Bool = true,
         accessToken: String? = nil,
         accessSecret: String? = nil,
         apiKey: String? = nil,
         apiSecret: String? = nil,
         handle: String? = nil,
         accessJwt: String? = nil,
         did: String? = nil,
         instanceURL: String? = nil,
         mastodonToken: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.accessToken = accessToken
        self.accessSecret = accessSecret
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.handle = handle
        self.accessJwt = accessJwt
        self.did = did
        self.instanceURL = instanceURL
        self.mastodonToken = mastodonToken
    }
    
    static func defaultAccount(for kind: AccountKind) -> Account {
        switch kind {
        case .twitter:
            return Account(
                name: "New Twitter Account",
                kind: .twitter,
                enabled: true,
                accessToken: "TW_ACCESS_TOKEN",
                accessSecret: "TW_ACCESS_SECRET",
                apiKey: "TW_API_KEY",
                apiSecret: "TW_API_SECRET"
            )
        case .bluesky:
            return Account(
                name: "New Bluesky Account",
                kind: .bluesky,
                enabled: true,
                accessToken: "BSKY_APP_PASSWORD",
                handle: "BSKY_HANDLE"
            )
        case .mastodon:
            return Account(
                name: "New Mastodon Account",
                kind: .mastodon,
                enabled: true,
                instanceURL: "https://mastodon.social",
                mastodonToken: "YOUR_ACCESS_TOKEN"
            )
        case .threads:
            return Account(
                name: "New Mastodon Account",
                kind: .mastodon,
                enabled: true,
                instanceURL: "https://mastodon.social",
                mastodonToken: "YOUR_ACCESS_TOKEN"
            )
        }
    }
}

// MARK: - Optional Binding Helper

extension Binding where Value == String? {
    func unwrapped(defaultValue: String = "") -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? defaultValue },
            set: { self.wrappedValue = $0 }
        )
    }
}

import UIKit

extension UIImage {
    /// Lädt ein Bild asynchron von einer URL (String)
    /// - Parameter urlString: Die URL als String
    /// - Returns: Ein UIImage, falls erfolgreich geladen
    static func loadImageFromURL(_ urlString: String) async throws -> UIImage {
        // 1️⃣ URL validieren
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        // 2️⃣ Daten laden (async/await)
        let (data, response) = try await URLSession.shared.data(from: url)

        // 3️⃣ HTTP-Status prüfen
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        // 4️⃣ In UIImage umwandeln
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        return image
    }
}



// MARK: - ViewModel

@MainActor
final class SocialPosterViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var message: String = ""
    @Published var selectedImages: [UIImage] = []
    @Published var capturedVideoURL: URL? = nil
    @Published var statusLog: [String] = []
    @Published var selectedFile: URL? = nil
    let twitterAPI = TwitterAPI()
    
    private let storageURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("accounts.json")
    }()

    func loadAccounts() async {
        do {
            let data = try Data(contentsOf: storageURL)
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            accounts = []
        }
    }
    
    func saveAccounts() async {
        do {
            let data = try JSONEncoder().encode(accounts)
            try data.write(to: storageURL)
        } catch {
            print("Failed to save accounts:", error)
        }
    }
    
    func addAccount(_ account: Account) async {
        accounts.append(account)
        await saveAccounts()
    }
    
    func editAccount(_ account: Account) async {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx] = account
        await saveAccounts()
    }
    
    func deleteAccount(_ account: Account) async {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts.remove(at: idx)
        await saveAccounts()
        statusLog.append("[\(account.kind.rawValue)] \(account.name) deleted")
    }
    
    // MARK: - Image Handling
    private func imageFromSelectedFile() async throws -> UIImage? {
        guard let url = selectedFile else { return nil }
        
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            guard let image = UIImage(data: data) else {
                throw MastodonError.invalidImageData
            }
            return image
        } else {
            return try await UIImage.loadImageFromURL(url.absoluteString)
        }
    }

    private func imageToData(_ image: UIImage) -> (Data, String)? {
        if let jpegData = image.jpegData(compressionQuality: 0.85) {
            return (jpegData, "image/jpeg")
        } else if let pngData = image.pngData() {
            return (pngData, "image/png")
        } else {
            return nil
        }
    }


    // MARK: - Posting Logic
    func postMessage() async {
        let image: UIImage?
        
        do {
            image = try await imageFromSelectedFile() ?? selectedImages.first
        } catch {
            statusLog.append("[Media] ❌ \(error.localizedDescription)")
            image = selectedImages.first
        }
        
        for account in accounts where account.enabled {
            do {
                switch account.kind {
                case .twitter:
                    try await postToTwitter(account: account, text: message, image: image)
                case .bluesky:
                    try await postToBluesky(account: account, text: message, image: image)
                case .mastodon:
                    try await postToMastodon(account: account, text: message, image: image)
                case .threads:
                    try await postToThreads(account: account, text: message, image: image)
                }
            } catch {
                statusLog.append("[\(account.kind.rawValue.capitalized)] \(account.name): ❌ \(error.localizedDescription)")
            }
        }
    }


    // MARK: - Platform Posting Methods
    private func postToTwitter(account: Account, text: String, image: UIImage?) async throws {
        let creds = OAuthCredentials(
            apiKey: account.apiKey ?? "",
            apiSecret: account.apiSecret ?? "",
            accessToken: account.accessToken ?? "",
            accessSecret: account.accessSecret ?? ""
        )
        let twitterAPI = TwitterAPI()
        twitterAPI.createSession(credentials: creds)
        statusLog.append("[Twitter] \(account.name): Session created ✅")
        
        do {
            let tweetId = try await postTweetAsync(text: text, image: image)
            statusLog.append("[Twitter] \(account.name): ✅ Tweet posted (\(tweetId))")
        } catch {
            statusLog.append("[Twitter] \(account.name): ❌ \(error.localizedDescription)")
        }
    }


    private func postToBluesky(account: Account, text: String, image: UIImage?) async throws {
        let handle = account.handle ?? ""
        let password = account.accessToken ?? ""
        let client = BlueskyAPIClient()
        
        try await client.createSession(handle: handle, password: password)
        statusLog.append("[Bluesky] \(account.name): Session created ✅")
        
        if let image = image, let compressedData = image.prepareForBlueskyUpload() {
            let response = try await client.createPostWithMedia(
                text: text,
                imageData: compressedData,
                imageMimeType: "image/jpeg"
            )
            statusLog.append("[Bluesky] \(account.name): ✅ \(response.uri)")
        } else {
            _ = try await client.createPost(text: text)
            statusLog.append("[Bluesky] \(account.name): ✅ Text-only post")
        }
    }


    private func postToMastodon(account: Account, text: String, image: UIImage?) async throws {
        guard let instanceURL = account.instanceURL,
              let token = account.mastodonToken else {
            throw MastodonError.missingCredentials
        }
        
        let client = MastodonAPIClient()
        client.setCredentials(instanceURL: instanceURL, accessToken: token)
        
        let result = try await client.postStatus(text: text, image: image, altText: nil)
        statusLog.append("[Mastodon] \(account.name): ✅ \(result.uri)")
    }


    // MARK: - Threads Posting
    private func postToThreads(account: Account, text: String, image: UIImage?) async throws {
        // Hinweis: Dieser Code MUSS in einer asynchronen Umgebung (Task, Button-Action etc.) ausgeführt werden.
        let api = ThreadsAPI()
        
        // --- 1. Erforderliche Platzhalter (bitte ersetzen!) ---
        let YOUR_CLIENT_ID = "2079581072803358" // Ihre App ID
        let YOUR_CLIENT_SECRET = "fcbd0554043713267dd595a74e4e2214" // Ihr App Secret
        let YOUR_SHORT_LIVED_TOKEN = "699056029465531|lNz2986Fl_GhJuEtTyvO-OB4MfY"
        
        // --------------------------------------------------------
        Task {
            do {
                // 2. Kurzlebigen Token gegen langlebigen Token austauschen
                print("Schritt 2: Starte Token-Austausch...")
                let longToken = try await api.exchangeShortLivedToken(
                    shortLivedToken: YOUR_SHORT_LIVED_TOKEN,
                    clientId: YOUR_CLIENT_ID,
                    clientSecret: YOUR_CLIENT_SECRET
                )
                
                print("✅ Langlebiger Token erhalten.")
                
                // 3. Instagram User ID abrufen
                print("Schritt 3: Rufe User ID ab...")
                let userId = try await api.fetchUserId(longLivedToken: longToken)
                print("✅ User ID erhalten: \(userId)")
                
                // 4. API-Session für das Posten erstellen
                let threadsCreds = ThreadsCredentials(accessToken: longToken, userId: userId)
                api.createSession(credentials: threadsCreds)
                
                // 5. POSTEN STARTEN
                let postText = "Erfolgreicher Test-Post nach dem Token-Austausch! 🚀"
                
                api.postToThreads(text: postText) { result in
                    switch result {
                    case .success(let postId):
                        print("\n**✅ POSTING ERFOLGREICH!**")
                        print("Post ID: \(postId)")
                    case .failure(let error):
                        print("\n**❌ POSTING FEHLGESCHLAGEN!**")
                        print("Fehler: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("\n**❌ FEHLER im AUTHENTIFIZIERUNGS-WORKFLOW:**")
                print("Bitte prüfen Sie Client ID/Secret und Ihren kurzlebigen Token.")
                print("Detail: \(error.localizedDescription)")
            }
        }
    }

    
    // MARK: - Twitter Async Bridge
      private func postTweetAsync(text: String, image: UIImage?) async throws -> String {
          try await withCheckedThrowingContinuation { continuation in
              twitterAPI.postTweet(text: text, image: image) { result in
                  switch result {
                  case .success(let tweetId):
                      continuation.resume(returning: tweetId)
                  case .failure(let error):
                      continuation.resume(throwing: error)
                  }
              }
          }
      }

}

// MARK: - Media Picker

struct MediaPicker: UIViewControllerRepresentable {
    enum MediaType { case photo, camera, video }
    @Binding var selectedImages: [UIImage]
    @Binding var selectedVideoURL: URL?
    let type: MediaType
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        
        switch type {
        case .photo:
            picker.sourceType = .photoLibrary
            picker.mediaTypes = ["public.image"]
        case .camera:
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        case .video:
            picker.sourceType = .camera
            picker.cameraCaptureMode = .video
        }
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: MediaPicker
        init(_ parent: MediaPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.selectedImages.append(image)
            }
            if let videoURL = info[.mediaURL] as? URL {
                parent.selectedVideoURL = videoURL
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Multi Image Picker

struct MultiImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImages: [UIImage]
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiImagePicker
        init(_ parent: MultiImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            for result in results {
                result.itemProvider.loadObject(ofClass: UIImage.self) { reading, _ in
                    if let img = reading as? UIImage {
                        DispatchQueue.main.async { self.parent.selectedImages.append(img) }
                    }
                }
            }
        }
    }
}

// MARK: - Add/Edit Account Views


// MARK: - Custom Toolbar

import SwiftUI

struct CustomKeyboardToolbar: View {
    var onPhoto: () -> Void
    var onCamera: () -> Void
    var onVideo: () -> Void
    var onEmoji: () -> Void
    var onHideKeyboard: () -> Void   // ✅ NEU

    var body: some View {
        HStack(spacing: 30) {
            Button(action: onPhoto) {
                Image(systemName: "photo")
                    .font(.system(size: 22))
            }

            Button(action: onCamera) {
                Image(systemName: "camera")
                    .font(.system(size: 22))
            }

            Button(action: onVideo) {
                Image(systemName: "video")
                    .font(.system(size: 22))
            }

//            Button(action: onEmoji) {
//                Image(systemName: "face.smiling")
//                    .font(.system(size: 22))
//            }

            Spacer()

            // ✅ Button zum Schließen der Tastatur
            Button(action: onHideKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 22))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(radius: 2)
    }
}



struct ToolbarStyleButton: ToolbarContent {
    let action: () -> Void
    let isActive: Bool // just to change icon if needed, optional

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: action) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.blue.opacity(0.8)))
                    .shadow(radius: 3)
            }
        }
    }
}

// MARK: - Example usage in a NavigationStack
struct ParentView: View {
    @State private var toolbarActive = false
    @State private var isUnfolded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Example fold/unfold content
                Button(action: {
                    withAnimation {
                        isUnfolded.toggle()
                    }
                }) {
                    Image(systemName: isUnfolded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .resizable()
                        .frame(width: 50, height: 50)
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.blue.opacity(0.8)))
                        .rotationEffect(.degrees(isUnfolded ? 180 : 0))
                        .shadow(radius: 5)
                }

                if isUnfolded {
                    Text("Folded content here")
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
                        .transition(.slide)
                }
            }
            .padding()
            .toolbar {
                ToolbarStyleButton(action: {
                    toolbarActive.toggle()
                    print("Toolbar button tapped, state: \(toolbarActive)")
                }, isActive: toolbarActive)
            }
        }
    }
}

struct FoldButtonView: View {
    @Binding var isUnfolded: Bool  // <- Now comes from parent

    var body: some View {
        VStack(spacing: 20) {
            
            // The fold/unfold button
            Button(action: {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    isUnfolded.toggle()
                }
            }) {
                Image(systemName: isUnfolded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.blue.opacity(0.8)))
                    .rotationEffect(.degrees(isUnfolded ? 180 : 0))
                    .shadow(radius: 5)
            }

            // The content that folds/unfolds
            if isUnfolded {
//                VStack {
//                    Text("Here is some extra content!")
//                        .padding()
//                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
//                        .transition(.move(edge: .top).combined(with: .opacity))
//                    Text("You can add anything here")
//                        .padding()
//                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
//                        .transition(.move(edge: .top).combined(with: .opacity))
//                }
//                .padding(.horizontal)
            }
        }
        .padding()
    }
}

struct EditAccountView: View {
    @State var account: Account
    let onSave: (Account) -> Void
    let onDelete: (Account) -> Void
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        Form {
            Section("Account Info") {
                TextField("Name", text: $account.name)
                Toggle("Enabled", isOn: $account.enabled)
            }
            
            switch account.kind {
            case .twitter:
                Section("Twitter Credentials") {
                    TextField("Access Token", text: $account.accessToken.unwrapped())
                    TextField("Access Secret", text: $account.accessSecret.unwrapped())
                    TextField("API Key", text: $account.apiKey.unwrapped())
                    TextField("API Secret", text: $account.apiSecret.unwrapped())
                }
            case .bluesky:
                Section("Bluesky Credentials") {
                    TextField("Handle", text: $account.handle.unwrapped())
                    TextField("App Password", text: $account.accessToken.unwrapped())
                }
            case .mastodon:
                Section("Mastodon Credentials") {
                    TextField("Instance URL", text: $account.instanceURL.unwrapped())
                    TextField("Access Token", text: $account.mastodonToken.unwrapped())
                }
            case .threads:
                Section("Mastodon Credentials") {
                    TextField("Instance URL", text: $account.instanceURL.unwrapped())
                    TextField("Access Token", text: $account.mastodonToken.unwrapped())
                }
            }
            
            Button("Save") {
                onSave(account)
                presentationMode.wrappedValue.dismiss()
            }
            Button("Delete") {
                onDelete(account)
                presentationMode.wrappedValue.dismiss()
            }
            .foregroundColor(.red)
        }
    }
}

struct AddAccountView: View {
    @State var account: Account
    let kind: AccountKind
    let onSave: (Account) -> Void
    @Environment(\.presentationMode) var presentationMode
    
    // Neue State-Variable für die Anzeige des HelpViews
    @State private var showHelp = false

    init(kind: AccountKind, onSave: @escaping (Account) -> Void) {
        self.kind = kind
        _account = State(initialValue: Account(name: "", kind: kind))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Account Info") {
                TextField("Name", text: $account.name)
                Toggle("Enabled", isOn: $account.enabled)
            }

            switch kind {
            case .twitter:
                Section("Twitter Credentials") {
                    TextField("Access Token", text: $account.accessToken.unwrapped())
                    TextField("Access Secret", text: $account.accessSecret.unwrapped())
                    TextField("API Key", text: $account.apiKey.unwrapped())
                    TextField("API Secret", text: $account.apiSecret.unwrapped())
                }
            case .bluesky:
                Section("Bluesky Credentials") {
                    TextField("Handle", text: $account.handle.unwrapped())
                    TextField("App Password", text: $account.accessToken.unwrapped())
                }
            case .mastodon:
                Section("Mastodon Credentials") {
                    TextField("Instance URL", text: $account.instanceURL.unwrapped())
                    TextField("Access Token", text: $account.mastodonToken.unwrapped())
                }
            case .threads:
                Section("Threads Credentials") {
                    TextField("Instance URL", text: $account.instanceURL.unwrapped())
                    TextField("Access Token", text: $account.mastodonToken.unwrapped())
                }
            }

            Button("Add") {
                onSave(account)
                presentationMode.wrappedValue.dismiss()
            }

            // Button für die Hilfe
            Button("Help") {
                showHelp.toggle()
            }
            .sheet(isPresented: $showHelp) {
                HelpView(kind: kind)
            }
        }
        .navigationTitle("Add Account")
    }
}

//import S  wiftUI

//enum AccountKind {
//    case twitter, bluesky, mastodon, threads
//}

struct HelpView: View {
    let kind: AccountKind
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(helpTitle)
                    .font(.title)
                    .bold()
                
                Text(helpText)
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Help")
    }
    
    private var helpTitle: String {
        switch kind {
        case .twitter:
            return "Twitter Account Setup"
        case .bluesky:
            return "Bluesky Account Setup"
        case .mastodon, .threads:
            return "Mastodon/Threads Account Setup"
        }
    }
    
    private var helpText: String {
        switch kind {
        case .twitter:
            return """
To use Twitter in this app, you need the following credentials:

- **API Key & Secret**: Obtain these from your Twitter Developer account.
- **Access Token & Secret**: Also generated in your developer account.

Steps:
1. Open the app.
2. Enter all credentials.
3. Tap 'Add' to save the account.
"""
        case .bluesky:
            return """
To use Bluesky in this app, you need:

- **Bluesky Handle**: Your username on Bluesky (e.g., @username).
- **App Password**: Create this in Bluesky Settings > Security > App Passwords.

Steps:
1. Open the app.
2. Enter your Bluesky handle.
3. Paste the app password.
4. Tap 'Connect to Bluesky'.
"""
        case .mastodon, .threads:
            return """
To use Mastodon or Threads in this app, you need:

- **Instance URL**: e.g., https://mastodon.social
- **Access Token**: Generated in your instance's settings.

Steps:
1. Open the app.
2. Enter instance URL and access token.
3. Tap 'Add' to save the account.
"""
        }
    }
}




struct UsersView: View {
    @EnvironmentObject var vm: SocialPosterViewModel
    @State private var expandedAccounts: [UUID: Bool] = [:] // Track expanded state
    @State private var showingEditSheet: Account? = nil
    @State private var showingAddSheet = false
    @State private var addingKind: AccountKind? = nil

    var body: some View {
        NavigationStack {
            ScrollView { accountsSection }
            .padding(.top , 5)
            .navigationTitle("Users")
          
        }
    }
    
    // MARK: Accounts Section
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if vm.accounts.isEmpty {
                Text("Add Accounts here")
            }
            
            ForEach(vm.accounts) { acc in
                HStack {
                    Label(acc.name, systemImage: icon(for: acc.kind))
                    Spacer()
                    Text(acc.kind.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        showingEditSheet = acc
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundColor(.blue)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .navigationTitle("SwiftPost")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { addAccountMenu  }
        .sheet(item: $showingEditSheet) { acc in
            EditAccountView(
                account: acc,
                onSave: { updatedAcc in Task { await vm.editAccount(updatedAcc) } },
                onDelete: { deletedAcc in Task { await vm.deleteAccount(deletedAcc) } }
            )
        }
        .sheet(item: $addingKind) { kind in
            AddAccountView(kind: kind) { newAcc in
                Task { await vm.addAccount(newAcc) }
                addingKind = nil // ✅ Nach Hinzufügen wieder schließen
            }
        }
//        .sheet(isPresented: $showingAddSheet) {
//            AddAccountView(kind: addingKind!) { newAcc in
//                Task { await vm.addAccount(newAcc) }
//            }
//        }


    }
    
    
    // MARK: Toolbar Menu
    private var addAccountMenu: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Button { addingKind = .twitter } label: { Label("Add Twitter", systemImage: "bird") }
                Button { addingKind = .mastodon } label: { Label("Add Mastodon", systemImage: "bubble.left.and.text.bubble.right.fill") }
                Button { addingKind = .bluesky } label: { Label("Add Bluesky", systemImage: "cloud.fill") }
                Button { addingKind = .threads } label: { Label("Add Threads", systemImage: "circle.hexagonpath.fill") }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 22))
            }
        }
    }
    
    private func icon(for kind: AccountKind) -> String {
        switch kind {
        case .twitter: return "bird"
        case .mastodon: return "bubble.left.and.text.bubble.right.fill"
        case .bluesky, .threads: return "cloud.fill"
        }
    }
}


struct MainAppView: View {
    @StateObject var vm = SocialPosterViewModel()
    @State private var showPostView = false
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 1️⃣ Always show UsersView
            UsersView()
                .environmentObject(vm)
            
            // 2️⃣ Floating "New Post" button
            Button {
                withAnimation {
                    showPostView = true
                }
            } label: {
                Label("New Post", systemImage: "square.and.pencil")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(.blue.gradient)
                    .foregroundColor(.white)
                    .cornerRadius(30)
                    .shadow(radius: 4)
            }
            .padding()
        }
        // 3️⃣ Present PostView modally
        .fullScreenCover(isPresented: $showPostView) {
            PostView()
                .environmentObject(vm)
                .onDisappear {
                    // Optional reset when PostView closes
                    vm.message = ""
                    vm.selectedImages.removeAll()
                }
        }
        .task {
            await vm.loadAccounts()
        }
    }
}


//struct MainAppView: View {
//    @StateObject public var vm = SocialPosterViewModel()
//    
//    
//    @State private var selectedTab = 0
//    
//    
//    
//
//    var body: some View {
//        TabView {
//            UsersView()
//                .environmentObject(vm)
//                .tabItem {
//                    Label("Users", systemImage: "person.3.fill")
//                }
//            PostView()
//                .environmentObject(vm)
//                .tabItem {
//                    Label("Posts", systemImage: "square.and.pencil")
//                }
//        }
//        .onChange(of: selectedTab) { newTab in
//            if newTab == 1 {
//                Task {
//                    try? await Task.sleep(nanoseconds: 200_000_000)
//                    vm.message = "" // optional reset
//                }
//            }
//        }
//        .task { await vm.loadAccounts() }
//    }
//}

//struct PostView: View {
//    @EnvironmentObject var vm: SocialPosterViewModel
//
//    
//    @State private var showPhotoPicker = false
//    @State private var showCameraPicker = false
//    @State private var showVideoPicker = false
//    @State private var showMultiImagePicker = false
//    
//    @FocusState private var isMessageFieldFocused: Bool
//    @State private var keyboardHeight: CGFloat = 0
//    
//    @State private var extraBottomPadding: CGFloat = 0
//    @State private var unfoldingState = false
//    @State private var isUnfoldede: Bool = false
//    @State private var isButtonUnfolded = false  // parent owns the state
//    @State private var toolbarActive = false
//
//    
//    
//    var body: some View {
//        NavigationStack {
//            GeometryReader { geo in
//                ZStack(alignment: .bottom) {
//                    Color(.systemGroupedBackground).ignoresSafeArea()
//
//                    VStack(spacing: 0) {
//                        Divider()
//                        messageComposer(maxHeight: geo.size.height * 0.3)
//                            //.onAppear { isMessageFieldFocused = true }
//                            .onAppear { isMessageFieldFocused = true
//                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
//                                    isMessageFieldFocused = true
//                                }
//                            }
////                        postButton
////                            .background(.ultraThinMaterial)
////                            .cornerRadius(keyboardHeight)
////                            .padding(.horizontal)
//                    }
//                    .padding(.top,extraBottomPadding)
//                    // Wichtig: bleibt fixiert, kein Keyboard-Offset mehr hier!
//                }
//
//            }
//            .sheet(isPresented: $showPhotoPicker) {
//                MediaPicker(selectedImages: $vm.selectedImages,
//                            selectedVideoURL: .constant(nil),
//                            type: .photo)
//            }
//            .sheet(isPresented: $showCameraPicker) {
//                MediaPicker(selectedImages: $vm.selectedImages,
//                            selectedVideoURL: .constant(nil),
//                            type: .camera)
//            }
//            .sheet(isPresented: $showVideoPicker) {
//                MediaPicker(selectedImages: .constant([]),
//                            selectedVideoURL: $vm.capturedVideoURL,
//                            type: .video)
//            }
//            .sheet(isPresented: $showMultiImagePicker) {
//                MultiImagePicker(selectedImages: $vm.selectedImages)
//            }
//            .onAppear { isMessageFieldFocused = true
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
//                    isMessageFieldFocused = true
//                }
//            }
//            .onReceive(Publishers.keyboardPublisher) { height in
//                       self.keyboardHeight = height
//                
////                if height == 0 {
////                    showPhotoPicker = false
////                    showCameraPicker = false
////                    showVideoPicker = false
////                    showMultiImagePicker = false
////                }
//            }
//            .safeAreaInset(edge: .bottom) {
//                if keyboardHeight > 0 {   // ✅ Nur anzeigen, wenn Tastatur sichtbar
//                    CustomKeyboardToolbar(
//                        onPhoto: { showPhotoPicker = true },
//                        onCamera: { showCameraPicker = true },
//                        onVideo: { showVideoPicker = true },
//                        onEmoji: { print("Emoji tapped") },
//                        onHideKeyboard: { hideKeyboard() }
//                    )
//                    .transition(.move(edge: .bottom).combined(with: .opacity))
//                    .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
//                }
//            }
//            .task {
//                // Laden der Accounts
//                await vm.loadAccounts()
//                // Fokus auf TextEditor setzen
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                    isMessageFieldFocused = true
//                }
//            }
//        }
//        .onAppear { isMessageFieldFocused = true
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
//                isMessageFieldFocused = true
//            }
//        }
//
//    }
//    
//   
//    
//    // MARK: Message Composer
//    private func messageComposer(maxHeight: CGFloat) -> some View {
//        VStack(alignment: .leading, spacing: 12) {
//            HStack {
//                // 🔴 Cancel-Button (links)
//                Button {
//                    // ✅ Tastatur schließen
//                    hideKeyboard()
//                    // ✅ Text und Bilder zurücksetzen
//                    vm.message = ""
//                    vm.selectedImages.removeAll()
//                } label: {
//                    Label("Cancel", systemImage: "xmark.circle.fill")
//                        .font(.headline)
//                        .labelStyle(.titleAndIcon)
//                        .foregroundColor(.red)
//                }
//                .buttonStyle(.bordered)
//                .tint(.red.opacity(0.2))
//
//                Spacer()
//
//                // 🟢 Post-Button (rechts)
//                Button {
//                    Task {
//                        await vm.postMessage()
//                        // ✅ Nach erfolgreichem Post: zurücksetzen & Tastatur schließen
//                        hideKeyboard()
//                        vm.message = ""
//                        vm.selectedImages.removeAll()
//                    }
//                } label: {
//                    Label("Post", systemImage: "paperplane.circle.fill")
//                        .font(.headline)
//                        .labelStyle(.titleAndIcon)
//                        .foregroundColor(.white)
//                        .padding(.horizontal, 16)
//                        .padding(.vertical, 8)
//                        .background(
//                            LinearGradient(colors: [.blue, .green],
//                                           startPoint: .leading, endPoint: .trailing)
//                                .cornerRadius(12)
//                        )
//                        .shadow(radius: 3)
//                }
//            }
//            .padding(.horizontal)
//
//            // 📝 Textfeld
//            TextEditor(text: $vm.message)
//                .padding(10)
//                .background(
//                    RoundedRectangle(cornerRadius: 14)
//                        .fill(Color(.secondarySystemBackground))
//                )
//                .focused($isMessageFieldFocused)
//                .onAppear {
//                      // Verzögert den Fokus minimal, damit Keyboard zuverlässig erscheint
//                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                          isMessageFieldFocused = true
//                      }
//                  }
//            // 🖼️ Bilder-Vorschau
//            if !vm.selectedImages.isEmpty {
//                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
//                    ForEach(vm.selectedImages.indices, id: \.self) { idx in
//                        ZStack(alignment: .topTrailing) {
//                            Image(uiImage: vm.selectedImages[idx])
//                                .resizable()
//                                .scaledToFill()
//                                .frame(height: vm.selectedImages.count == 1 ? 200 : 120)
//                                .clipped()
//                                .cornerRadius(12)
//                            Button(action: { vm.selectedImages.remove(at: idx) }) {
//                                Image(systemName: "xmark.circle.fill")
//                                    .foregroundColor(.white)
//                                    .background(Circle().fill(Color.black.opacity(0.7)))
//                            }
//                            .offset(x: 6, y: -6)
//                        }
//                    }
//                }
//            }
//        }
//        .padding()
//        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
//
//    }
//
//    // MARK: Log Panel
//    private var logPanel: some View {
//        VStack(alignment: .leading, spacing: 8) {
//            Text("Status Log").font(.headline)
//            ScrollView {
//                VStack(alignment: .leading, spacing: 6) {
//                    ForEach(vm.statusLog.indices, id: \.self) { i in
//                        Text(vm.statusLog[i])
//                            .font(.caption)
//                            .frame(maxWidth: .infinity, alignment: .leading)
//                            .padding(8)
//                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
//                    }
//                }.padding(8)
//            }
//            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
//        }
//        .padding()
//        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
//    }
//    
//    // MARK: Post Button
//    private var postButton: some View {
//        Button {
//            Task { await vm.postMessage() }
//        } label: {
//            Label("Post All", systemImage: "paperplane.fill")
//                .font(.headline)
//                .frame(maxWidth: .infinity)
//                .padding(.vertical, 16)
//        }
//        .buttonStyle(.borderedProminent)
//        .tint(.green)
//        .clipShape(Capsule())
//    }
//    
//
//}


struct PostView: View {
    @EnvironmentObject var vm: SocialPosterViewModel
    @Environment(\.dismiss) private var dismiss // 👈 for closing

    // MARK: - State
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showVideoPicker = false
    @State private var showMultiImagePicker = false

    // We'll bind this to the custom text view
    @State private var isTextViewFirstResponder = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var extraBottomPadding: CGFloat = 0

    // UI unfolding states
    @State private var unfoldingState = false
    @State private var isUnfolded = false
    @State private var isButtonUnfolded = false
    @State private var toolbarActive = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Color(.systemGroupedBackground).ignoresSafeArea()

                    VStack(spacing: 0) {
                        Divider()
                        messageComposer(maxHeight: geo.size.height * 0.3)
                    }
                    .padding(.top, extraBottomPadding)
                }
            }
            // Media sheets
            .sheet(isPresented: $showPhotoPicker) {
                MediaPicker(selectedImages: $vm.selectedImages,
                            selectedVideoURL: .constant(nil),
                            type: .photo)
            }
            .sheet(isPresented: $showCameraPicker) {
                MediaPicker(selectedImages: $vm.selectedImages,
                            selectedVideoURL: .constant(nil),
                            type: .camera)
            }
            .sheet(isPresented: $showVideoPicker) {
                MediaPicker(selectedImages: .constant([]),
                            selectedVideoURL: $vm.capturedVideoURL,
                            type: .video)
            }
            .sheet(isPresented: $showMultiImagePicker) {
                MultiImagePicker(selectedImages: $vm.selectedImages)
            }

            // Keyboard listener (your existing publisher)
            .onReceive(Publishers.keyboardPublisher) { height in
                self.keyboardHeight = height
            }

            .safeAreaInset(edge: .bottom) {
                if keyboardHeight > 0 {
                    CustomKeyboardToolbar(
                        onPhoto: { showPhotoPicker = true },
                        onCamera: { showCameraPicker = true },
                        onVideo: { showVideoPicker = true },
                        onEmoji: { print("Emoji tapped") },
                        onHideKeyboard: { hideKeyboard() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
                }
            }

            // Load accounts + request focus once after a short delay
            .task {
                await vm.loadAccounts()
                // short delay to let layout finish
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                isTextViewFirstResponder = true
            }
            .onDisappear {
                // clear first responder when leaving
                isTextViewFirstResponder = false
            }
        }
    }

    // MARK: - Message Composer
    private func messageComposer(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Cancel Button
                Button {
                    hideKeyboard()
                    vm.message = ""
                    vm.selectedImages.removeAll()
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.2))

                Spacer()

                // Post Button
                Button {
                    Task {
                        await vm.postMessage()
                        hideKeyboard()
                        vm.message = ""
                        vm.selectedImages.removeAll()
                        dismiss()
                    }
                } label: {
                    Label("Post", systemImage: "paperplane.circle.fill")
                        .font(.headline)
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [.blue, .green],
                                           startPoint: .leading, endPoint: .trailing)
                                .cornerRadius(12)
                        )
                        .shadow(radius: 3)
                }
            }
            .padding(.horizontal)

            // REPLACE TextEditor with FocusableTextView
            FocusableTextView(text: $vm.message,
                              isFirstResponder: $isTextViewFirstResponder,
                              maxHeight: maxHeight)
            //.frame(maxHeight: maxHeight)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemBackground))
                )

            // Image Preview
            if !vm.selectedImages.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(vm.selectedImages.indices, id: \.self) { idx in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: vm.selectedImages[idx])
                                .resizable()
                                .scaledToFill()
                                .frame(height: vm.selectedImages.count == 1 ? 200 : 120)
                                .clipped()
                                .cornerRadius(12)
                            Button(action: { vm.selectedImages.remove(at: idx) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.7)))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
    }

    // Helper to hide keyboard programmatically
    private func hideKeyboard() {
        isTextViewFirstResponder = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

import SwiftUI
import UIKit

struct FocusableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    var maxHeight: CGFloat?

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isScrollEnabled = true
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        // ensure keyboard state
        if isFirstResponder && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        // respect max height by adjusting isScrollEnabled
        if let maxH = maxHeight {
            uiView.isScrollEnabled = uiView.contentSize.height > maxH
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: FocusableTextView
        init(parent: FocusableTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.text = textView.text
            }
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFirstResponder = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFirstResponder = false }
        }
    }
}



// MARK: - Keyboard Publisher
extension Publishers {
    static var keyboardPublisher: AnyPublisher<CGFloat, Never> {
        let willShow = NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillShowNotification)
            .map { ($0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0 }
        
        let willHide = NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }
        
        return MergeMany(willShow, willHide)
            .eraseToAnyPublisher()
    }
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
