//
//  Untitled.swift
//  SwiftPost
//
//  Created by Pascal Kaap on 06.11.25.
//

import SwiftUI
import Foundation

// MARK: - Models

enum AccountKind: String, Codable {
    case twitter
    case bluesky
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
         did: String? = nil) {
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
        
    }
    
    static func defaultAccount(for kind: AccountKind) -> Account {
        switch kind {
        case .twitter:
            return Account(
                name: "New Twitter Account",
                kind: .twitter,
                enabled: true,
                accessToken: "TW_ACCESS_TOKEN",
                accessSecret: "TW_ACCESS_TOKEN_SECRET",
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

// MARK: - ViewModel

@MainActor
final class SocialPosterViewModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var message: String = ""
    @Published var selectedFile: URL? = nil
    @Published var statusLog: [String] = []

    private let storageURL: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("accounts.json")
    }()

    func loadAccounts() async {
        do {
            let data = try Data(contentsOf: storageURL)
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            accounts = []
            print("No accounts found or failed to load: \(error)")
        }
    }

    func saveAccounts() async {
        do {
            let data = try JSONEncoder().encode(accounts)
            try data.write(to: storageURL)
        } catch {
            print("Failed to save accounts: \(error)")
        }
    }

    func addAccount(_ account: Account) async {
        accounts.append(account)
        await saveAccounts()
    }

    func editAccount(_ account: Account) async {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
            await saveAccounts()
        }
    }

    
    func deleteAccount(_ account: Account) async {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts.remove(at: idx)
            await saveAccounts()
            statusLog.append("[\(account.kind.rawValue)] \(account.name): Deleted")
        }
    }
    
    @MainActor
    func postMessage() async {
        for acc in accounts where acc.enabled {
            do {
                let _: String
                switch acc.kind {
                case .twitter:
                    let myCredentials = OAuthCredentials(
                        consumerKey: (acc.apiKey!) as String,
                        consumerSecret: (acc.apiSecret!) as String,
                        accessToken: (acc.accessToken!) as String,
                        accessTokenSecret: (acc.accessSecret!) as String,
                        v2AuthToken: "AAAAAAAAAAAAAAAAAAAAAPX5igEAAAAABp1YC4py63%2BvOMIHlxJ7JhIq13Y%3Dz0iUHZQS7DKkAPN23NH0obA2kAG1vRdkgojqNhLVSMeVkiZSqR" // Oder wieder der Access Token, je nach API-App-Einstellungen
                    )

                    // 2. Sitzung initialisieren
                    let twitterAPI = TwitterAPI()
                    twitterAPI.createSession(credentials: myCredentials)
                    let neues_image = self.selectedFile;
                    // 3. Tweet posten
                    // Beispiel für nur Text
                    twitterAPI.postTweet(text: self.message , image: nil) { result in
                        switch result {
                        case .success(let tweetId):
                            print("Text-Tweet erfolgreich, ID: \(tweetId)")
                        case .failure(let error):
                            print("Fehler beim Text-Tweet: \(error.localizedDescription)")
                        }
                    }
                case .bluesky:
                    
                    let  BLUESKY_HANDLE = (acc.handle!) as String// Ersetzen
                    let  BLUESKY_APP_PASSWORD = (acc.accessToken!) as String // Ersetzen (App-Passwort)
                    let client = BlueskyAPIClient()
                    try? await client.createSession(handle: BLUESKY_HANDLE, password: BLUESKY_APP_PASSWORD)
                    print("BLUESKY_HANDLE",BLUESKY_HANDLE)
                    print("BLUESKY_APP_PASSWORD",BLUESKY_APP_PASSWORD)

                    print("Attempting to create session...")
                    print("Session successful!")
                    
                    let postText = self.message
                    let languages = ["en-US"]

                    print("Attempting to create post...")
                    let postResponse = try await client.createPost(text: postText, langs: languages)
                    
                    print("✅ Post successful!")
                    print("URI: \(postResponse.uri)")
                }
                // Optionally mark success
                self.statusLog.append("[\(acc.kind.rawValue.capitalized)] \(acc.name): Success")
            } catch {
                self.statusLog.append("[\(acc.kind.rawValue.capitalized)] \(acc.name): \(error.localizedDescription)")
            }
        }
    }


    
}

// MARK: - Views

import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject var vm = SocialPosterViewModel()
    @State private var showingEditSheet: Account? = nil
    @State private var showingAddSheet = false
    @State private var addingKind: AccountKind = .twitter
    
    // Neue States für Medienauswahl
    @State private var showingMediaPicker = false
    @State private var selectedMediaItem: PhotosPickerItem? = nil
    @State private var mediaPreviewData: Data? = nil
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("+ Add Twitter") {
                    addingKind = .twitter
                    showingAddSheet = true
                }
                .padding(6)
                .background(Color.blue.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(6)

                Button("+ Add Bluesky") {
                    addingKind = .bluesky
                    showingAddSheet = true
                }
                .padding(6)
                .background(Color.cyan.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(6)
            }

            List {
                ForEach(vm.accounts) { acc in
                    HStack {
                        Text(acc.name)
                            .foregroundColor(acc.enabled ? .primary : .gray)
                        Spacer()
                        Text(acc.kind.rawValue.capitalized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Edit") { showingEditSheet = acc }
                            .padding(.leading)
                    }
                }
            }
            .frame(height: 200)

            Text("Message").font(.headline)
            TextEditor(text: $vm.message)
                .frame(height: 100)
                .border(Color.gray)
            
            // Button für Medien hinzufügen
            Button(action: {
                showingMediaPicker = true
            }) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("Add Image/Video")
                }
                .padding(6)
                .background(Color.orange.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            
            // Vorschau der ausgewählten Datei
            if let data = mediaPreviewData {
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                        .cornerRadius(6)
                        .padding(.vertical, 4)
                } else {
                    Text("Selected media preview not available")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }

            Button("🚀 Post") {
                // Media wird mit übergeben
                vm.selectedFile = saveTempFile(data: mediaPreviewData)
                Task { await vm.postMessage() }
            }
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(8)

            LogPanelView(statusLog: vm.statusLog)
                .frame(height: 180)
                .border(Color.gray)
        }
        .padding()
        // MARK: - Sheets
        .sheet(item: $showingEditSheet) { acc in
            EditAccountView(
                account: acc,
                onSave: { updated in Task { await vm.editAccount(updated) } },
                onDelete: { deleted in Task { await vm.deleteAccount(deleted) } }
            )
        }
        .sheet(isPresented: $showingAddSheet) {
            AddAccountView(kind: addingKind) { newAcc in
                Task { await vm.addAccount(newAcc) }
            }
        }
        // MARK: - Media Picker
        .photosPicker(isPresented: $showingMediaPicker, selection: $selectedMediaItem, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedMediaItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    mediaPreviewData = data
                }
            }
        }

        .task { await vm.loadAccounts() }
    }
    
    // Hilfsfunktion zum Speichern temporärer Datei für den Post
    private func saveTempFile(data: Data?) -> URL? {
        guard let data = data else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("Failed to write temp media file: \(error)")
            return nil
        }
    }
}


// MARK: - Log Panel

private struct LogPanelView: View {
    let statusLog: [String]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(statusLog.reversed(), id: \.self) { entry in
                    Text(entry).font(.caption)
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Edit / Add Views
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

            if account.kind == .twitter {
                Section("Twitter Credentials") {
                    TextField("Access Token", text: $account.accessToken.unwrapped())
                    TextField("Access Secret", text: $account.accessSecret.unwrapped())
                    TextField("API Key", text: $account.apiKey.unwrapped())
                    TextField("API Secret", text: $account.apiSecret.unwrapped())
                }
            } else if account.kind == .bluesky {
                Section("Bluesky Credentials") {
                    TextField("Handle", text: $account.handle.unwrapped())
                    TextField("App Password", text: $account.accessToken.unwrapped())
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
        .padding()
    }
}


struct AddAccountView: View {
    @State var account: Account
    let kind: AccountKind
    let onSave: (Account) -> Void
    @Environment(\.presentationMode) var presentationMode

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

            if kind == .twitter {
                Section("Twitter Credentials") {
                    TextField("Access Token", text: $account.accessToken.unwrapped())
                    TextField("Access Secret", text: $account.accessSecret.unwrapped())
                    TextField("API Key", text: $account.apiKey.unwrapped())
                    TextField("API Secret", text: $account.apiSecret.unwrapped())
                }
            } else if kind == .bluesky {
                Section("Bluesky Credentials") {
                    TextField("Handle", text: $account.handle.unwrapped())
                    TextField("App Password", text: $account.accessToken.unwrapped())
                }
            }

            Button("Add") {
                onSave(account)
                presentationMode.wrappedValue.dismiss()
            }
        }
        .padding()
    }
}
