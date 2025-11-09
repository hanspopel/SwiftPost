//



import SwiftUI
import PhotosUI
internal import Combine // Added to resolve @StateObject initializer errors (e.g., line 787)
import Foundation // Added to resolve errors like 'whitespacesAndNewlines' (e.g., line 385)
import SwiftUI


// MARK: - AccountKind

enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case twitter, mastodon, bluesky, threads
    var id: String { rawValue }
}

// MARK: - Account
struct Account: Identifiable, Codable {
    var id = UUID()
    var kind: AccountKind
    var name: String
    var enabled: Bool = true
    
    // Twitter
    var accessToken: String? = nil
    var accessSecret: String? = nil
    var apiKey: String? = nil
    var apiSecret: String? = nil
    
    // Bluesky
    var handle: String? = nil
    
    // Mastodon
    var instanceURL: String? = nil
    var mastodonToken: String? = nil

    // Threads
    var clientId: String? = nil
    var clientSecret: String? = nil
    
    
    static func defaultAccount(for kind: AccountKind) -> Account {
        Account(kind: kind, name: "\(kind.rawValue.capitalized) Account")
    }
}
import UIKit

extension UIImage {
    static func loadImageFromURL(_ urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }

        return image
    }
}

// MARK: - SocialPosterViewModel


@MainActor
final class SocialPosterViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var accounts: [Account] = []
    @Published var message: String = ""
    @Published var selectedFile: URL? = nil
    @Published var selectedImage: UIImage? = nil
    @Published var statusLog: [String] = []

    // MARK: - Dependencies
    private let twitterAPI = TwitterAPI()

    // MARK: - Storage Path
    private let storageURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("accounts.json")
    }()
    
    // MARK: - Account Management
    func loadAccounts() async {
        do {
            let data = try Data(contentsOf: storageURL)
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            accounts = []
            print("⚠️ No accounts found or failed to load: \(error)")
        }
    }
    
    func saveAccounts() async {
        do {
            let data = try JSONEncoder().encode(accounts)
            try data.write(to: storageURL)
        } catch {
            print("❌ Failed to save accounts: \(error)")
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
        statusLog.append("[\(account.kind.rawValue)] \(account.name): Deleted")
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
            image = try await imageFromSelectedFile() ?? selectedImage
        } catch {
            statusLog.append("[Media] ❌ \(error.localizedDescription)")
            image = selectedImage
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
                    try await postToMastodon(account: account, text: message, image: image)
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


// NOTE: AccountKind, Account, and SocialPosterViewModel should ONLY be defined in Model.swift
// and are assumed to be available here.

// MARK: - TwitterStylePostView (Restored/Assumed)

// This structure is needed for ContentView on line 324: TwitterStylePostView(vm: vm)


// MARK: - Subviews (AccountsSectionView)


// MARK: - Message Composer
struct MessageComposerView: View {
    @Binding var message: String
    @Binding var selectedImage: UIImage?
    @Binding var showImagePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compose Message").font(.headline)
                Spacer()
                Button { showImagePicker = true } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            ZStack(alignment: .bottom) {
                TextEditor(text: $message)
                    .padding(8)
                    .frame(minHeight: 160)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground)))
                    .padding(.horizontal)

                if let image = selectedImage {
                    VStack(spacing: 4) {
                        Divider().padding(.horizontal)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        Button(role: .destructive) {
                            selectedImage = nil
                        } label: {
                            Label("Remove Image", systemImage: "trash")
                                .font(.caption)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }
}

// MARK: - LogPanelView
// MARK: - Post Button
struct PostAllButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Post All", systemImage: "paperplane.fill")
                .font(.headline)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .padding(.horizontal)
    }
}

struct LogPanelView: View {
    var statusLog: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(statusLog.indices, id: \.self) { i in
                    Text(statusLog[i])
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal)
    }
}

// MARK: - ContentView

//
//  ContentView.swift
//  SwiftPost
//
//  Kompilierversion mit Platzhaltern für fehlende Subviews.
//

import SwiftUI
import PhotosUI

// MARK: - ContentView



// MARK: - Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}



// MessageInputArea – wird separat kompiliert, reduziert Typ-Complexity
fileprivate struct MessageInputArea: View {
    @Binding var message: String
    @Binding var selectedImage: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            TextEditor(text: $message)
                .padding(8)
                .frame(minHeight: 160)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal)

            if let image = selectedImage {
                VStack(spacing: 6) {
                    Divider().padding(.horizontal)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    Button(role: .destructive) {
                        selectedImage = nil
                    } label: {
                        Label("Remove Image", systemImage: "trash")
                            .font(.caption)
                    }
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
        }
    }
}



// MARK: - Placeholder EditAccountView / AddAccountView (ersetzten)


struct AddAccountView: View {
    var kind: AccountKind
    var onCreate: (Account) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("New Account") {
                    TextField("Name", text: $name)
                }
                Section {
                    Button("Create") {
                        let acc = Account.defaultAccount(for: kind)
                        onCreate(acc)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Add Account")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - PostView (kompakte, verwendbare Version)

struct PostView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @ObservedObject var vm: SocialPosterViewModel

    @State private var showPhotoPicker = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var selectedImageLocal: UIImage? = nil
    private let characterLimit = 280

    var remainingCharacters: Int {
        characterLimit - (vm.message.count)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .frame(width: 46, height: 46)
                                .foregroundStyle(.tint)
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $vm.message)
                                    .focused($isFocused)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 140)
                                    .padding(.horizontal, 2)
                                    .font(.body)
                                    .onChange(of: vm.message) { newValue in
                                        if newValue.count > characterLimit {
                                            vm.message = String(newValue.prefix(characterLimit))
                                        }
                                    }

                                if let img = selectedImageLocal ?? vm.selectedImage {
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(Color.gray.opacity(0.3))
                                            )
                                            .shadow(radius: 1)

                                        Button {
                                            withAnimation {
                                                selectedImageLocal = nil
                                                vm.selectedImage = nil
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title3)
                                                .foregroundColor(.white)
                                                .background(Circle().fill(Color.black.opacity(0.5)))
                                        }
                                        .padding(6)
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top)
                    }
                }
                .scrollDismissesKeyboard(.interactively)

                Divider()
                HStack {
                    AccessoryToolbar(
                        onPhoto: { showPhotoPicker = true },
                        onCamera: { /* Implement camera capture */ },
                        onVideo: { /* Implement video */ },
                        onGIF: { /* Implement GIF */ }
                    )
                    Spacer()
                    Text("\(remainingCharacters)")
                        .font(.caption)
                        .foregroundColor(remainingCharacters < 0 ? .red : .secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Post") {
                        Task {
                            await vm.postMessage()
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(vm.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { newItem in
                Task {
                    guard let item = newItem,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: data) else { return }
                    // set both local and VM so ContentView also sees the image if needed
                    selectedImageLocal = uiImage
                    vm.selectedImage = uiImage
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isFocused = true
                }
            }
        }
    }
}


struct AccessoryToolbar: View {
    var onPhoto: () -> Void
    var onCamera: () -> Void
    var onVideo: () -> Void
    var onGIF: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onPhoto) {
                Image(systemName: "photo.on.rectangle")
            }
            Button(action: onCamera) {
                Image(systemName: "camera.fill")
            }
            Button(action: onVideo) {
                Image(systemName: "video.fill")
            }
            Button(action: onGIF) {
                Image(systemName: "face.smiling.fill")
            }
        }
        .font(.system(size: 20))
        .tint(.primary)
    }
}


struct CustomKeyboardView: View {
    @ObservedObject var vm: SocialPosterViewModel
    
    @State private var showPhotoPicker = false
    @State private var selectedImages: [UIImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 8) {
    
            // MARK: TextEditor
            TextEditor(text: $vm.message)
                .frame(minHeight: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            
            // MARK: Selected Images Scroll
            if !selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 70, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                
                                Button {
                                    selectedImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 80)
            }
            
            // MARK: Toolbar (Photos / GIF / Camera)
            HStack(spacing: 20) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 5,
                    matching: .images
                ) {
                    Image(systemName: "photo.fill")
                }
                
                Button(action: { print("Camera tapped") }) { Image(systemName: "camera.fill") }
                Button(action: { print("Video tapped") }) { Image(systemName: "video.fill") }
                Button(action: { print("GIF tapped") }) { Text("GIF").font(.caption).bold() }
                
                Spacer()
            }
            .foregroundColor(.blue)
            .padding(.horizontal)
            
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground).shadow(radius: 1))
        .onChange(of: pickerItems) { newItems in
            // Process items asynchronously, then update UI state on the main actor
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            selectedImages.append(uiImage)
                            // Optionally insert placeholder text into message
                            vm.message += "[img\(selectedImages.count)]"
                        }
                    }
                }
                await MainActor.run {
                    pickerItems.removeAll()
                }
            }
        }
    }
}







struct PostViewWithHeader: View {
    @ObservedObject var vm: SocialPosterViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    
    @State private var showPhotoPicker = false
    @State private var selectedImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var characterLimit = 280
    
    var remainingCharacters: Int { characterLimit - vm.message.count }

    var body: some View {
        VStack(spacing: 0) {
            
            // MARK: Header
            HStack {
                Button("Cancel") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Post") {
                    Task { await vm.postMessage() }
                }
                .fontWeight(.bold)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(vm.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color(.systemGray6))
            
            Divider()
            
            // MARK: TextEditor + optionales Bild
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $vm.message)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 200)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                        .onChange(of: vm.message) { newValue in
                            if newValue.count > characterLimit {
                                vm.message = String(newValue.prefix(characterLimit))
                            }
                        }
                    
                    if let image = selectedImage {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.gray.opacity(0.3))
                                )
                                .shadow(radius: 1)
                            
                            Button {
                                withAnimation { selectedImage = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.5)))
                            }
                            .padding(6)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.horizontal)
            }
            
            Divider()
            
            // MARK: Toolbar + Charakterzähler
            HStack {
                AccessoryToolbar(
                    onPhoto: { showPhotoPicker = true },
                    onCamera: { print("Camera tapped") },
                    onVideo: { print("Video tapped") },
                    onGIF: { print("GIF tapped") }
                )
                
                Spacer()
                
                Text("\(remainingCharacters)")
                    .font(.caption)
                    .foregroundColor(remainingCharacters < 0 ? .red : .secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .background(Color(.systemBackground))
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { newItem in
            Task {
                if let item = newItem,
                   let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedImage = uiImage
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }
}


// NOTE: Ensure your Preview uses the explicit init:
/*
#Preview {
    PostViewWithHeader(vm: SocialPosterViewModel())
}
*/

// MARK: - SOLUTION PART 2: Preview Ambiguity
// Assuming you have a SocialPosterViewModel (which must be an ObservableObject)
/*
#Preview {
    // You need to ensure you are passing a concrete instance of your ViewModel here.
    // If this part of your code was missing or incorrect, it would cause the 'Ambiguous use of init' error.
    PostViewWithHeader(vm: SocialPosterViewModel())
}
*/// MARK: - Placeholder EditAccountView / AddAccountView

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
                    TextField("Access Token", text: Binding(get: { account.accessToken ?? "" }, set: { account.accessToken = $0 }))
                    TextField("Access Secret", text: Binding(get: { account.accessSecret ?? "" }, set: { account.accessSecret = $0 }))
                    TextField("API Key", text: Binding(get: { account.apiKey ?? "" }, set: { account.apiKey = $0 }))
                    TextField("API Secret", text: Binding(get: { account.apiSecret ?? "" }, set: { account.apiSecret = $0 }))
                }
            case .bluesky:
                Section("Bluesky Credentials") {
                    TextField("Handle", text: Binding(get: { account.handle ?? "" }, set: { account.handle = $0 }))
                    TextField("App Password", text: Binding(get: { account.accessToken ?? "" }, set: { account.accessToken = $0 }))
                }
            case .mastodon:
                Section("Mastodon Credentials") {
                    TextField("Instance URL", text: Binding(get: { account.instanceURL ?? "" }, set: { account.instanceURL = $0 }))
                    TextField("Access Token", text: Binding(get: { account.mastodonToken ?? "" }, set: { account.mastodonToken = $0 }))
                }
            case .threads:
                Section("Threads Credentials") {
                    TextField("Client ID", text: Binding(get: { account.clientId ?? "" }, set: { account.clientId = $0 }))
                    TextField("Client Secret", text: Binding(get: { account.clientSecret ?? "" }, set: { account.clientSecret = $0 }))
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




// MARK: - Previews

//
//  ContentView.swift
//  SwiftPost
//

import SwiftUI
import PhotosUI

// MARK: - ContentView

//struct ContentView: View {
//    @StateObject var vm = SocialPosterViewModel()
//    @State private var showingEditSheet: Account? = nil
//    @State private var showingAddSheet = false
//    @State public var addingKind: AccountKind = .twitter
//    @State private var accountsExpanded: Bool = false
//    @State private var showImagePicker = false
//
//    var body: some View {
//        NavigationStack {
//            ScrollView {
//                VStack(spacing: 18) {
//                    accountsSection
//                    messageComposer
//                    postButton
//                    logPanel
//                }
//                .padding(.vertical)
//            }
//            .background(Color(.systemGroupedBackground))
//            .navigationTitle("SwiftPost")
//            .navigationBarTitleDisplayMode(.inline)
//            .toolbar {
//                // MARK: - Toolbar Items
////                ToolbarItem(placement: .navigationBarLeading) {
////                    EditButton()
//                }}
//            
//                VStack(spacing: 0) {
//                    GeometryReader { geoSize in
//                    // MARK: Accounts Section (fixe Höhe, Buttons bleiben konstant)
////                    AccountsSectionView(
////                        accounts: $vm.accounts,
////                        expanded: $accountsExpanded,
////                        onEdit: { showingEditSheet = $0 }
////                    )
////                    .background(Color(.systemGroupedBackground))
////                    .frame(height: accountsExpanded ? geo.size.height * 0.35 : geo.size.height * 0.2, alignment: .top)
////                    .offset(y: accountsExpanded ? 0 : (geo.size.height * 0.15))
////                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: accountsExpanded)
////                    .clipped()
//
//                    Divider()
//
//                    // MARK: PostView mit Header (Post/Cancel oben rechts)
////                  s
////                    TwitterStylePostView(vm: vm)
////                        .frame(height: geoSize.size.height * 0.8) // bleibt gleich groß!
////                        .background(Color(.secondarySystemBackground))
////                        .offset(y: accountsExpanded ? geoSize.size.height * 0.5 : 0) // nur nach unten verschieben
////                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: accountsExpanded)
//
//                }
//            }
//            .navigationTitle("SwiftPost")
//            .navigationBarTitleDisplayMode(.inline)
//            .toolbar {
//                ToolbarItemGroup(placement: .navigationBarTrailing) {
//                    Menu {
//                        Button { addingKind = .twitter; showingAddSheet = true } label: { Label("Add Twitter", systemImage: "bird") }
//                        Button { addingKind = .mastodon; showingAddSheet = true } label: { Label("Add Mastodon", systemImage: "bubble.left.and.text.bubble.right.fill") }
//                        Button { addingKind = .bluesky; showingAddSheet = true } label: { Label("Add Bluesky", systemImage: "cloud.fill") }
//                        Button { addingKind = .threads; showingAddSheet = true } label: { Label("Add Threads", systemImage: "circle.hexagonpath.fill") }
//                    } label: {
//                        Image(systemName: "plus.circle.fill")
//                            .font(.system(size: 24))
//                    }
//                }
//            }
//            .sheet(item: $showingEditSheet) { acc in
//                EditAccountView(
//                    account: acc,
//                    onSave: { updated in Task { await vm.editAccount(updated) } },
//                    onDelete: { deleted in Task { await vm.deleteAccount(deleted) } }
//                )
//            }
//            .sheet(isPresented: $showingAddSheet) {
//                AddAccountView(kind: addingKind) { newAcc in Task { await vm.addAccount(newAcc) } }
//            }
//            .task { await vm.loadAccounts() }
//        }
//    // MARK: - Accounts Section
//    private var accountsSection: some View {
//        GeometryReader { geo in
//            VStack(alignment: .leading, spacing: 12) {
//                DisclosureGroup(
//                    isExpanded: $accountsExpanded,
//                    content: {
//                        VStack(spacing: 18) {
//                            ForEach(vm.accounts) { acc in
//                                HStack {
//                                    Label(acc.name, systemImage: icon(for: acc.kind))
//                                    Spacer()
//                                    Text(acc.kind.rawValue.capitalized)
//                                        .font(.caption)
//                                        .foregroundColor(.secondary)
//                                    Button {
//                                        showingEditSheet = acc
//                                    } label: {
//                                        Image(systemName: "pencil")
//                                            .foregroundColor(.blue)
//                                    }
//                                }
//                                .padding()
//                                .background(
//                                    RoundedRectangle(cornerRadius: 12)
//                                        .fill(Color(.secondarySystemBackground))
//                                )
//                            }
//                        }
//                        .padding(.top, 4)
//                    },
//                    label: {
//                        HStack {
//                            Text("Accounts")
//                                .font(.headline)
//                            Spacer()
//                            Image(systemName: accountsExpanded ? "chevron.up" : "chevron.down")
//                                .foregroundColor(.secondary)
//                        }
//                        .padding(.horizontal)
//                    }
//                )
//                .accentColor(.blue)
//                .animation(.spring(), value: accountsExpanded)
//                .padding(.horizontal)
////                .background(Color(.systemGroupedBackground))
//                .frame(height: 20);
////                .offset(y: accountsExpanded ? 0 : (((geo.size.height)) * 0.15))
////                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: accountsExpanded)
////                .clipped()
//            }
//        }
//    }
//
//       // MARK: - Message Composer
//       private var messageComposer: some View {
//           VStack(alignment: .leading, spacing: 18) {
//               HStack {
//                   Text("Compose Message")
//                       .font(.headline)
//                   Spacer()
//                   Button { showImagePicker = true } label: {
//                       Image(systemName: "photo.on.rectangle.angled")
//                           .font(.system(size: 18))
//                   }
//                   .buttonStyle(.bordered)
//               }
//               .padding(.horizontal)
//
//               ZStack(alignment: .bottom) {
//                   TextEditor(text: $vm.message)
//                       .padding(8)
//                       .frame(minHeight: 190)
//                       .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
//                       .padding(.horizontal)
//
//                   if let image = vm.selectedImage {
//                       VStack(spacing: 4) {
//                           Divider().padding(.horizontal)
//                           Image(uiImage: image)
//                               .resizable()
//                               .scaledToFit()
//                               .frame(maxHeight: 120)
//                               .clipShape(RoundedRectangle(cornerRadius: 12))
//                               .padding(.horizontal)
//                           Button(role: .destructive) {
//                               vm.selectedImage = nil
//                           } label: {
//                               Label("Remove Image", systemImage: "trash")
//                                   .font(.caption)
//                           }
//                           .padding(.bottom, 8)
//                       }
//                   }
//               }
//           }
//       }
//
//       // MARK: - Post Button
//       private var postButton: some View {
//           Button {
//               Task { await vm.postMessage() }
//           } label: {
//               Label("Post All", systemImage: "paperplane.fill")
//                   .font(.headline)
//                   .padding(.vertical, 12)
//                   .frame(maxWidth: .infinity)
//           }
//           .buttonStyle(.borderedProminent)
//           .tint(.green)
//           .padding(.horizontal)
//       }
//
//       // MARK: - Log Panel
//       private var logPanel: some View {
//           VStack(alignment: .leading, spacing: 8) {
//               Text("Status Log").font(.headline)
//               LogPanelView(statusLog: vm.statusLog)
//                   .frame(height: 180)
//                   .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
//           }
//           .padding(.horizontal)
//       }
//    
//    
//    
//    
// 
//
//       private func icon(for kind: AccountKind) -> String {
//           switch kind {
//           case .twitter: return "bird"
//           case .mastodon: return "bubble.left.and.text.bubble.right.fill"
//           case .bluesky: return "cloud.fill"
//           case .threads: return "cloud.fill"
//           }
//       }
//   
//    
//    
//}
import SwiftUI
//
//let  isMessageFieldFocused: ObjCBool  = false
//
//struct ContentView: View {
//    @StateObject var vm = SocialPosterViewModel()
//    @State private var showingEditSheet: Account? = nil
//    @State private var showingAddSheet = false
//    @State public var addingKind: AccountKind = .twitter
//    @State private var accountsExpanded = false
//    @State private var showImagePicker = false
//
//    var body: some View {
//        NavigationStack {
//            ScrollView {
//                VStack(spacing: 24) {
//                    accountsSection
//                    messageComposer
//                    postButton
//                    logPanel
//                }
//                .padding()
//            }
//            .background(Color(.systemGroupedBackground))
//            .navigationTitle("SwiftPost")
//            .navigationBarTitleDisplayMode(.inline)
//            .toolbar { addAccountMenu }
//            .sheet(item: $showingEditSheet) { acc in
//                EditAccountView(
//                    account: acc,
//                    onSave: { updated in Task { await vm.editAccount(updated) } },
//                    onDelete: { deleted in Task { await vm.deleteAccount(deleted) } }
//                )
//            }
//            .sheet(isPresented: $showingAddSheet) {
//                AddAccountView(kind: addingKind) { newAcc in Task { await vm.addAccount(newAcc) } }
//            }
//            .task { await vm.loadAccounts() }
//        }
//    }
//
//    // MARK: - Accounts Section
//    private var accountsSection: some View {
//        VStack(alignment: .leading, spacing: 12) {
//            HStack {
//                Text("Accounts").font(.headline)
//                Spacer()
//                Button {
//                    UIApplication.shared.dismissKeyboard() //
//                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
//                        accountsExpanded.toggle()
//                    }
//                } label: {
//                    Image(systemName: accountsExpanded ? "chevron.up" : "chevron.down")
//                        .foregroundColor(.secondary)
//                }
//            }
//
//            if accountsExpanded {
//                VStack(spacing: 10) {
//                    ForEach(vm.accounts) { acc in
//                        HStack {
//                            Label(acc.name, systemImage: icon(for: acc.kind))
//                            Spacer()
//                            Button {
//                                showingEditSheet = acc
//                            } label: {
//                                Image(systemName: "pencil")
//                                    .foregroundColor(.blue)
//                            }
//                        }
//                        .padding()
//                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
//                        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 2)
//                    }
//                }
//                .transition(.move(edge: .top).combined(with: .opacity))
//            }
//            else {isMessageFieldFocused = true}
//        }
//        .padding()
//        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
//        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
//    }
//
//    // MARK: - Message Composer
//    private var messageComposer: some View {
//        VStack(alignment: .leading, spacing: 12) {
//            HStack {
//                Text("Compose Message").font(.headline)
//                Spacer()
//                Button { showImagePicker = true } label: {
//                    Image(systemName: "photo.on.rectangle.angled")
//                }
//                .buttonStyle(.bordered)
//            }
//
//            TextEditor(text: $vm.message)
//                .padding(10)
//                .frame(minHeight: 160)
//                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
//
//            if let image = vm.selectedImage {
//                VStack {
//                    Image(uiImage: image)
//                        .resizable()
//                        .scaledToFit()
//                        .frame(maxHeight: 140)
//                        .clipShape(RoundedRectangle(cornerRadius: 12))
//                    Button(role: .destructive) {
//                        vm.selectedImage = nil
//                    } label: {
//                        Label("Remove Image", systemImage: "trash")
//                            .font(.caption)
//                    }
//                }
//                .padding(.top, 6)
//            }
//        }
//        .padding()
//        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
//        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
//    }
//
//    // MARK: - Post Button
//    private var postButton: some View {
//        Button {
//            Task { await vm.postMessage() }
//        } label: {
//            Label("Post All", systemImage: "paperplane.fill")
//                .font(.headline)
//                .frame(maxWidth: .infinity)
//                .padding(.vertical, 14)
//        }
//        .buttonStyle(.borderedProminent)
//        .tint(.green)
//        .clipShape(Capsule())
//    }
//
//    // MARK: - Log Panel
//    private var logPanel: some View {
//        VStack(alignment: .leading, spacing: 8) {
//            Text("Status Log").font(.headline)
//            LogPanelView(statusLog: vm.statusLog)
//                .frame(height: 160)
//                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
//        }
//        .padding()
//        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
//        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
//    }
//
//    // MARK: - Toolbar Menu
//    private var addAccountMenu: some ToolbarContent {
//        ToolbarItemGroup(placement: .navigationBarTrailing) {
//            Menu {
//                Button { addingKind = .twitter; showingAddSheet = true } label: {
//                    Label("Add Twitter", systemImage: "bird")
//                }
//                Button { addingKind = .mastodon; showingAddSheet = true } label: {
//                    Label("Add Mastodon", systemImage: "bubble.left.and.text.bubble.right.fill")
//                }
//                Button { addingKind = .bluesky; showingAddSheet = true } label: {
//                    Label("Add Bluesky", systemImage: "cloud.fill")
//                }
//                Button { addingKind = .threads; showingAddSheet = true } label: {
//                    Label("Add Threads", systemImage: "circle.hexagonpath.fill")
//                }
//            } label: {
//                Image(systemName: "plus.circle.fill")
//                    .font(.system(size: 22))
//            }
//        }
//    }
//
//    private func icon(for kind: AccountKind) -> String {
//        switch kind {
//        case .twitter: return "bird"
//        case .mastodon: return "bubble.left.and.text.bubble.right.fill"
//        case .bluesky, .threads: return "cloud.fill"
//        }
//    }
//   
//}

import SwiftUI

// ✅ Hilfs-Extension (optional, falls du UIKit-Dismiss weiterhin willst)


// ✅ ContentView mit Keyboard-Steuerung & ImagePicker
import SwiftUI

// ✅ Hilfs-Extension (optional, falls du UIKit-Dismiss weiterhin willst)


// ✅ ContentView mit Keyboard-Steuerung & ImagePicker
import SwiftUI

import SwiftUI


struct ContentView: View {
    @StateObject var vm = SocialPosterViewModel()
    @State private var showingEditSheet: Account? = nil
    @State private var showingAddSheet = false
    @State public var addingKind: AccountKind = .twitter
    @State private var accountsExpanded = false
    @State private var showImagePicker = false
    
    @FocusState private var isMessageFieldFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color(.systemGroupedBackground).ignoresSafeArea()

                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 24) {
                                accountsSection

                                // Composer füllt dynamisch den Raum bis zum Button
                                messageComposer(maxHeight: geo.size.height * 0.55)

                                logPanel

                                Spacer().frame(height: 100) // Platz für Sticky Button
                            }
                            .padding()
                        }

                        // Sticky Post Button
                        postButton
                            .padding(.horizontal)
                            .padding(.bottom, geo.safeAreaInsets.bottom)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                    }
                }
            }
            .navigationTitle("SwiftPost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { addAccountMenu }
            .sheet(item: $showingEditSheet) { acc in
                EditAccountView(
                    account: acc,
                    onSave: { updated in Task { await vm.editAccount(updated) } },
                    onDelete: { deleted in Task { await vm.deleteAccount(deleted) } }
                )
            }
            .sheet(isPresented: $showingAddSheet) {
                AddAccountView(kind: addingKind) { newAcc in Task { await vm.addAccount(newAcc) } }
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePicker(selectedImage: $vm.selectedImage)
            }
            .task { await vm.loadAccounts() }
        }
    }

    // MARK: - Accounts Section
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accounts").font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        accountsExpanded.toggle()
                    }
                    if !accountsExpanded {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            isMessageFieldFocused = true
                        }
                    } else {
                        isMessageFieldFocused = false
                    }
                } label: {
                    Image(systemName: accountsExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }

            if accountsExpanded {
                VStack(spacing: 10) {
                    ForEach(vm.accounts) { acc in
                        HStack {
                            Label(acc.name, systemImage: icon(for: acc.kind))
                            Spacer()
                            Button {
                                showingEditSheet = acc
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 2)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
        )
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
    }

    // MARK: - Message Composer
    private func messageComposer(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compose Message").font(.headline)
                Spacer()
                Button { showImagePicker = true } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 6) {
                TextEditor(text: $vm.message)
                    .frame(minHeight: 200, maxHeight: maxHeight)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                    .focused($isMessageFieldFocused)

                // Inline-Bild direkt unter TextEditor
                if let image = vm.selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxHeight: 200)
                        .cornerRadius(12)
                        .clipped()
                        .shadow(radius: 2)
                        .overlay(
                            // Entfernen Button
                            Button(action: { vm.selectedImage = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.black.opacity(0.7)))
                            }
                            .offset(x: 6, y: -6),
                            alignment: .topTrailing
                        )
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
    }

    // MARK: - Post Button
    private var postButton: some View {
        Button {
            Task { await vm.postMessage() }
        } label: {
            Label("Post All", systemImage: "paperplane.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    // MARK: - Log Panel
    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status Log").font(.headline)
            LogPanelView(statusLog: vm.statusLog)
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
    }

    // MARK: - Toolbar
    private var addAccountMenu: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Button { addingKind = .twitter; showingAddSheet = true } label: {
                    Label("Add Twitter", systemImage: "bird")
                }
                Button { addingKind = .mastodon; showingAddSheet = true } label: {
                    Label("Add Mastodon", systemImage: "bubble.left.and.text.bubble.right.fill")
                }
                Button { addingKind = .bluesky; showingAddSheet = true } label: {
                    Label("Add Bluesky", systemImage: "cloud.fill")
                }
                Button { addingKind = .threads; showingAddSheet = true } label: {
                    Label("Add Threads", systemImage: "circle.hexagonpath.fill")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
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

// MARK: - Image Picker Helper
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    @Binding var selectedImage: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        picker.sourceType = .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.selectedImage = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Image Picker Helper
//struct ImagePicker: UIViewControllerRepresentable {
//    @Environment(\.dismiss) var dismiss
//    @Binding var selectedImage: UIImage?
//
//    func makeUIViewController(context: Context) -> UIImagePickerController {
//        let picker = UIImagePickerController()
//        picker.delegate = context.coordinator
//        picker.allowsEditing = false
//        picker.sourceType = .photoLibrary
//        return picker
//    }
//
//    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
//
//    func makeCoordinator() -> Coordinator {
//        Coordinator(self)
//    }
//
//    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
//        let parent: ImagePicker
//        init(_ parent: ImagePicker) { self.parent = parent }
//
//        func imagePickerController(_ picker: UIImagePickerController,
//                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
//            if let image = info[.originalImage] as? UIImage {
//                parent.selectedImage = image
//            }
//            parent.dismiss()
//        }
//
//        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
//            parent.dismiss()
//        }
//    }
//}


// MARK: - TwitterStylePostView
//
import SwiftUI
import PhotosUI

struct TwitterStylePostView: View {
    @ObservedObject var vm: SocialPosterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false
    @State private var characterLimit = 280
    @FocusState private var isFocused: Bool
    @State private var selectedImageLocal: UIImage? = nil
    @State private var pickerItem: PhotosPickerItem?

    var remainingCharacters: Int { characterLimit - vm.message.count }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundColor(.red)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    Task { await vm.postMessage() }
                } label: {
                    Text("Post")
                        .fontWeight(.bold)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding()
            .background(Color(.systemGray6))

            Divider()

            // MARK: - Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $vm.message)
                        .focused($isFocused)
                        .frame(minHeight: 200)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground)))

                    if let image = vm.selectedImage {
                        VStack(spacing: 6) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            Button(role: .destructive) {
                                vm.selectedImage = nil
                            } label: {
                                Label("Remove Image", systemImage: "trash")
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { newItem in
                Task {
                    guard let item = newItem,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: data) else { return }
                    selectedImageLocal = uiImage
                    vm.selectedImage = uiImage
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isFocused = true
                }
            }

            // MARK: - Bottom toolbar
            HStack {
                AccessoryToolbar(
                    onPhoto: { showPhotoPicker = true },
                    onCamera: { print("Camera tapped") },
                    onVideo: { print("Video tapped") },
                    onGIF: { print("GIF tapped") }
                )

                Spacer()

                Text("\(remainingCharacters)")
                    .font(.caption)
                    .foregroundColor(remainingCharacters < 0 ? .red : .secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .background(Color(.systemBackground))
    }
}


// MARK: - Subviews

//struct AccountsSectionView: View {
//    @Binding var accounts: [Account]
//    @Binding var expanded: Bool
//    let onEdit: (Account) -> Void
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 12) {
//            DisclosureGroup(isExpanded: $expanded) {
//                VStack(spacing: 8) {
//                    ForEach(accounts) { acc in
//                        HStack {
//                            Label(acc.name, systemImage: icon(for: acc.kind))
//                            Spacer()
//                            Text(acc.kind.rawValue.capitalized)
//                                .font(.caption)
//                                .foregroundColor(.secondary)
//                            Button { onEdit(acc) } label: {
//                                Image(systemName: "pencil")
//                                    .foregroundColor(.blue)
//                            }
//                        }
//                        .padding()
//                        .background(
//                            RoundedRectangle(cornerRadius: 12)
//                                .fill(Color(.secondarySystemBackground))
//                        )
//                    }
//                }
//                .padding(.top, 4)
//            } label: {
//                HStack {
//                    Text("Accounts").font(.headline)
//                    Spacer()
//                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
//                        .foregroundColor(.secondary)
//                }
//                .padding(.horizontal)
//            }
//            .animation(.spring(), value: expanded)
//            .padding(.horizontal)
//        }
//    }
//
//    private func icon(for kind: AccountKind) -> String {
//        switch kind {
//        case .twitter: return "bird"
//        case .mastodon: return "bubble.left.and.text.bubble.right.fill"
//        case .bluesky: return "cloud.fill"
//        case .threads: return "circle.hexagonpath.fill"
//        }
//    }
//}

struct AccountsSectionView: View {
    @Binding var accounts: [Account]
    @Binding var expanded: Bool
    let onEdit: (Account) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 8) {
                    ForEach(accounts) { acc in
                        HStack {
                            Label(acc.name, systemImage: icon(for: acc.kind))
                            Spacer()
                            Text(acc.kind.rawValue.capitalized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button { onEdit(acc) } label: {
                                Image(systemName: "pencil")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack {
                    Text("Accounts").font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            .animation(.spring(), value: expanded)
            .padding(.horizontal)
        }
    }

    private func icon(for kind: AccountKind) -> String {
        switch kind {
        case .twitter: return "bird"
        case .mastodon: return "bubble.left.and.text.bubble.right.fill"
        case .bluesky: return "cloud.fill"
        case .threads: return "circle.hexagonpath.fill"
        }
    }
}

// MARK: - LogPanelView



extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

}
