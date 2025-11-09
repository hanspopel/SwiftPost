import Foundation

// MARK: - 1. Fehler- und Hilfsstrukturen

/**
 * Allgemeine Fehler, die bei API-Aufrufen auftreten können.
 */
enum BlueskyError: Error {
    case invalidURL
    case encodingError(Error)
    case decodingError(Error)
    case apiError(status: Int, message: String)
}

/**
 * Struktur für die Authentifizierungsantwort (Session).
 */
struct CreateSessionResponse: Codable {
    let did: String
    let handle: String
    let email: String?
    let accessJwt: String
    let refreshJwt: String
}

/**
 * Struktur für die createRecord-Antwort (Posten).
 */
struct CreateRecordResponse: Codable {
    let uri: String // URI des neu erstellten Records
    let cid: String // CID des Inhalts
}

/**
 * Erzeugt einen Zeitstempel im AT-Protocol-Format (ISO 8601).
 */
func createBlueskyTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    // Das Bluesky-Protokoll benötigt Millisekunden-Genauigkeit
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}


// MARK: - 2. Datenstrukturen für createRecord Payload

/**
 * 2a. PostRecord für den app.bsky.feed.post Record.
 * Enthält Text, Zeitstempel und optionale Embeds/Metadaten.
 */
struct PostRecord: Codable {
    let type: String = "app.bsky.feed.post" // Hardcoded für den Post-Typ
    let text: String
    let createdAt: String
    let langs: [String]?
    let facets: [String]? // Für Links, Mentions, etc. (Optional, hier leer gelassen)
    let reply: [String]? // Für Antworten (Optional)
    
    // 🚨 WICHTIG: Muss MediaEmbed (oder andere Embed-Typen) sein, NICHT String oder [String].
    let embed: MediaEmbed?
    
    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case text, createdAt, langs, facets, reply, embed
    }
}

/**
 * 2b. Payload für den com.atproto.repo.createRecord Aufruf.
 */
struct CreateRecordPayload<Record: Codable>: Codable {
    let repo: String // Die DID des Repositories (typischerweise die Benutzer-DID)
    let collection: String // Z.B. "app.bsky.feed.post"
    let record: Record
}

// MARK: - 3. Datenstrukturen für Media/Upload

// 3a. BlobRef: Repräsentiert die Referenz auf die hochgeladenen Bilddaten.
struct UploadBlobResponse: Codable {
    let blob: BlobRef
}

struct BlobRef: Codable {
    let type: String?
    let ref: BlobRefLink
    let mimeType: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case ref
        case mimeType
        case size
    }
}

struct BlobRefLink: Codable {
    let link: String

    enum CodingKeys: String, CodingKey {
        case link = "$link"
    }
}



// 3c. ImageEntry: Repräsentiert ein einzelnes Bild im Embed-Array (enthält den Blob und Alt-Text).
struct ImageEntry: Codable {
    let image: BlobRef
    let alt: String

    init(image: BlobRef, alt: String?) {
        // Bluesky requires the field "alt" to exist — empty string if none provided
        self.image = image
        self.alt = alt ?? ""
    }
}

// 3d. MediaEmbed: Repräsentiert das gesamte Embed-Objekt für Bilder.
struct MediaEmbed: Codable {
    let type: String = "app.bsky.embed.images"
    let images: [ImageEntry]
    
    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case images
    }
}


// MARK: - 4. Haupt-API-Client

class BlueskyAPIClient {
    // Standard-PDS (Personal Data Server). Dies kann vom Benutzer angepasst werden.
    private let defaultPDS = "https://bsky.social/xrpc"
    
    // Status-Speicher
    private(set) var pdsURL: String
    private(set) var accessToken: String?
    private(set) var did: String?
    
    init(customPDS: String? = nil) {
        self.pdsURL = customPDS ?? defaultPDS
    }
    
    // MARK: - API-Funktion 1: Session erstellen (Login)
    
    /// Stellt eine Verbindung zum PDS her und authentifiziert den Benutzer.
    func createSession(handle: String, password: String) async throws -> CreateSessionResponse {
        guard let url = URL(string: "\(pdsURL)/com.atproto.server.createSession") else {
            throw BlueskyError.invalidURL
        }
        
        let payload: [String: String] = ["identifier": handle, "password": password]
        let jsonBody = try JSONEncoder().encode(payload)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        
        let (respData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorMsg = String(data: respData, encoding: .utf8) ?? "Unknown Error"
            throw BlueskyError.apiError(status: status, message: "Login fehlgeschlagen: \(errorMsg)")
        }
        
        do {
            let result = try JSONDecoder().decode(CreateSessionResponse.self, from: respData)
            
            // Status speichern
            self.accessToken = result.accessJwt
            self.did = result.did
            
            return result
        } catch {
            print("Decoding Error (Session Response): \(error)")
            throw BlueskyError.decodingError(error)
        }
    }
    
    // MARK: - API-Funktion 2: Text-Post erstellen
    
    /// Erstellt einen reinen Text-Post.
    func createPost(text: String, langs: [String]? = nil) async throws -> CreateRecordResponse {
        guard let token = accessToken, let repoDid = did else {
            throw BlueskyError.apiError(status: 401, message: "Authentication required. Call createSession first.")
        }
        
        guard let url = URL(string: "\(pdsURL)/com.atproto.repo.createRecord") else {
            throw BlueskyError.invalidURL
        }
        
        let now = createBlueskyTimestamp()
        
        let postRecord = PostRecord(
            text: text,
            createdAt: now,
            langs: langs,
            facets: nil,
            reply: nil,
            embed: nil // Kein Embed für reinen Text
        )
        
        let createRecordPayload = CreateRecordPayload(
            repo: repoDid,
            collection: "app.bsky.feed.post",
            record: postRecord
        )
        
        let encoder = JSONEncoder()
        let payloadData: Data
        
        do {
            payloadData = try encoder.encode(createRecordPayload)
        } catch {
            print("Encoding Error (Post Payload): \(error)")
            throw BlueskyError.encodingError(error)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payloadData
        
        let (respData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorMsg = String(data: respData, encoding: .utf8) ?? "Unknown Error"
            print("API Error Status \(status): \(errorMsg)")
            throw BlueskyError.apiError(status: status, message: errorMsg)
        }
        
        do {
            let result = try JSONDecoder().decode(CreateRecordResponse.self, from: respData)
            return result
        } catch {
            print("Decoding Error (Post Response): \(error)")
            throw BlueskyError.decodingError(error)
        }
    }
    
    
    // MARK: - API-Funktion 3: Blob hochladen (Medien-Upload)
    
    /// Lädt binäre Daten (z.B. ein Bild) hoch und gibt eine Blob-Referenz zurück.
//    func uploadBlob(data: Data, mimeType: String) async throws -> BlobRef {
//        guard let token = accessToken else {
//            throw BlueskyError.apiError(status: 401, message: "Authentication required.")
//        }
//        
//        guard let url = URL(string: "\(pdsURL)/com.atproto.repo.uploadBlob") else {
//            throw BlueskyError.invalidURL
//        }
//        
//        var request = URLRequest(url: url)
//        request.httpMethod = "POST"
//        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
//        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
//        request.httpBody = data
//        
//        let (respData, response) = try await URLSession.shared.data(for: request)
//        
//        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
//            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
//            let errorMsg = String(data: respData, encoding: .utf8) ?? "Unknown Error"
//            throw BlueskyError.apiError(status: status, message: "UploadBlob failed: \(errorMsg)")
//        }
//        
//        do {
//            let result = try JSONDecoder().decode(UploadBlobResponse.self, from: respData)
//            return result.blob
//        } catch {
//            print("Decoding Error (Upload Blob Response): \(error)")
//            throw BlueskyError.decodingError(error)
//        }
//    }
//    
    func uploadBlob(data: Data, mimeType: String) async throws -> BlobRef {
        guard let token = accessToken else {
            throw BlueskyError.apiError(status: 401, message: "Not authenticated")
        }
        guard let url = URL(string: "\(pdsURL)/com.atproto.repo.uploadBlob") else {
            throw BlueskyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (respData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BlueskyError.apiError(status: 0, message: "No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let msg = String(data: respData, encoding: .utf8) ?? "Unknown error"
            throw BlueskyError.apiError(status: httpResponse.statusCode, message: msg)
        }

        do {
            let decoded = try JSONDecoder().decode(UploadBlobResponse.self, from: respData)
            return decoded.blob
        } catch {
            print("Decoding Error (Upload Blob Response): \(error)")
            print("Raw response:", String(data: respData, encoding: .utf8) ?? "n/a")
            throw BlueskyError.decodingError(error)
        }
    }

    // MARK: - API-Funktion 4: Post mit Medien erstellen
    
    /// Erstellt einen Feed-Post mit Text und einem Bild.
    /// Der Prozess besteht aus: 1. Blob hochladen, 2. Post mit Blob-Referenz erstellen.
    func createPostWithMedia(
        text: String,
        imageData: Data,
        imageMimeType: String,
        imageAlt: String? = nil,
        langs: [String]? = nil
    ) async throws -> CreateRecordResponse {
        
        guard let token = accessToken, let repoDid = did else {
            throw BlueskyError.apiError(status: 401, message: "Authentication required. Call createSession first.")
        }
        let blobRef = try await uploadBlob(data: imageData, mimeType: imageMimeType)
        // 1. BLOB HOCHLADEN
        
        // 2. EMBED-OBJEKT ERSTELLEN
        let imageEntry = ImageEntry(image: blobRef, alt: imageAlt)
        let mediaEmbed = MediaEmbed(images: [imageEntry])
        
        // 3. RECORD ERSTELLEN
        guard let url = URL(string: "\(pdsURL)/com.atproto.repo.createRecord") else {
            throw BlueskyError.invalidURL
        }
        
        let now = createBlueskyTimestamp()
        
        let postRecord = PostRecord(
            text: text,
            createdAt: now,
            langs: langs,
            facets: nil,
            reply: nil,
            embed: mediaEmbed // Hier wird die Blob-Referenz eingebettet
        )
        
        let createRecordPayload = CreateRecordPayload(
            repo: repoDid,
            collection: "app.bsky.feed.post",
            record: postRecord
        )
        
        let encoder = JSONEncoder()
        let payloadData: Data
        
        do {
            payloadData = try encoder.encode(createRecordPayload)
        } catch {
            print("Encoding Error (Post Payload with Media): \(error)")
            throw BlueskyError.encodingError(error)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payloadData
        
        let (respData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorMsg = String(data: respData, encoding: .utf8) ?? "Unknown Error"
            print("API Error Status \(status): \(errorMsg)")
            throw BlueskyError.apiError(status: status, message: errorMsg)
        }
        
        do {
            let result = try JSONDecoder().decode(CreateRecordResponse.self, from: respData)
            return result
        } catch {
            print("Decoding Error (Post Response with Media): \(error)")
            throw BlueskyError.decodingError(error)
        }
    }
}

import UIKit

extension UIImage {
    /// Compresses and resizes the image to stay below 900 KB (safe for Bluesky)
    func prepareForBlueskyUpload(maxBytes: Int = 950_000) -> Data? {
        // Step 1: Resize large images down (e.g. 2048 px max dimension)
        let maxDimension: CGFloat = 2048
        let aspectRatio = size.width / size.height
        var newSize = size

        if size.width > maxDimension || size.height > maxDimension {
            if aspectRatio > 1 {
                newSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
            } else {
                newSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
            }
        }

        // Create resized image context
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard var imageData = resizedImage?.jpegData(compressionQuality: 0.9) else { return nil }

        // Step 2: Gradually reduce quality until below maxBytes
        var compression: CGFloat = 0.9
        while imageData.count > maxBytes && compression > 0.1 {
            compression -= 0.1
            if let data = resizedImage?.jpegData(compressionQuality: compression) {
                imageData = data
            }
        }

        print("📦 Compressed image size: \(Double(imageData.count) / 1024.0) KB (quality: \(compression))")
        return imageData
    }
}
