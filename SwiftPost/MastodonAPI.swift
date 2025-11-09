import Foundation
import UIKit // Für die Verwendung von UIImage

// MARK: - 1. Fehler- und Hilfsstrukturen

/**
 * Allgemeine Fehler, die bei Mastodon API-Aufrufen auftreten können.
 */
enum MastodonError: Error {
    case invalidURL
    case invalidImageData
    case missingCredentials
    case encodingError(Error)
    case decodingError(Error)
    case apiError(status: Int, message: String)
}

/**
 * Antwortstruktur für Medien-Upload (/api/v1/media).
 */
struct MediaResponse: Codable {
    let id: String // Media ID, die für den Status-Post benötigt wird
    let type: String // "image", "video", "gif"
    let url: String? // Temporäre URL
    let previewUrl: String?
    
    // Wir ignorieren hier die anderen optionalen Felder wie metadata, remote_url, etc.
}

/**
 * Antwortstruktur für Status-Post (/api/v1/statuses).
 */
struct StatusResponse: Codable {
    let id: String
    let uri: String
    let url: String? // Link zum Post im Web
    let content: String // Der gerenderte HTML-Inhalt des Posts
    // Weitere Felder (account, created_at, reblog, etc.) wurden weggelassen.
}


// MARK: - 2. MastodonAPIClient Klasse

class MastodonAPIClient {
    
    // Status-Speicher
    private(set) var instanceURL: String?
    private(set) var accessToken: String?
    
    // MARK: - Initialisierung & Authentifizierung
    
    init() {
        // Der Client wird initialisiert. Zugangsdaten müssen separat gesetzt werden.
    }
    
    /**
     * Speichert die Zugangsdaten (Instanz-URL und Bearer Token).
     * Mastodon verwendet OAuth 2.0 Bearer Token, die typischerweise im Voraus über die App-Registrierung
     * oder einen OAuth-Flow beschafft werden.
     */
    func setCredentials(instanceURL: String, accessToken: String) {
        // Entfernt den nachfolgenden Schrägstrich, falls vorhanden
        self.instanceURL = instanceURL.hasSuffix("/") ? String(instanceURL.dropLast()) : instanceURL
        self.accessToken = accessToken
        print("Mastodon Client: Zugangsdaten für \(self.instanceURL ?? "unbekannte Instanz") gespeichert.")
    }
    
    // MARK: - Hilfsfunktionen
    
    /**
     * Erstellt den Body für einen Multipart/Form-Data Request (für Medien-Upload).
     */
    private func createMultipartBody(mediaData: Data, mimeType: String, boundary: String, mediaAlt: String?) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        
        // Füge das Medien-Teil hinzu (die eigentliche Datei)
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"media.\(mimeType.split(separator: "/").last ?? "dat")\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(mediaData)
        body.append("\(lineBreak)".data(using: .utf8)!)

        // Füge den Alt-Text hinzu, falls vorhanden
        if let alt = mediaAlt {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"description\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append(alt.data(using: .utf8)!)
            body.append("\(lineBreak)".data(using: .utf8)!)
        }
        
        // Abschluss-Boundary
        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        
        return body
    }
    
    // MARK: - API-Funktion 1: Medien-Upload
    
    /**
     * Lädt Medien (Bild, Video) hoch und gibt die Media ID zur späteren Verwendung zurück.
     * Endpunkt: POST /api/v1/media
     */
    private func uploadMedia(imageData: Data, mimeType: String, altText: String? = nil) async throws -> String {
        guard let baseURL = instanceURL, let token = accessToken else {
            throw MastodonError.missingCredentials
        }
        
        guard let url = URL(string: "\(baseURL)/api/v1/media") else {
            throw MastodonError.invalidURL
        }
        
        let boundary = UUID().uuidString
        let multipartBody = createMultipartBody(mediaData: imageData, mimeType: mimeType, boundary: boundary, mediaAlt: altText)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody
        
        let (respData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MastodonError.apiError(status: 0, message: "Keine HTTP-Antwort erhalten.")
        }
        
        // Mastodon antwortet mit 200 (Synchron) oder 202 (Asynchron)
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
            let errorMsg = String(data: respData, encoding: .utf8) ?? "Unbekannter Fehler"
            print("API Fehler Status \(httpResponse.statusCode): \(errorMsg)")
            throw MastodonError.apiError(status: httpResponse.statusCode, message: "Medien-Upload fehlgeschlagen: \(errorMsg)")
        }
        
        do {
            let mediaResponse = try JSONDecoder().decode(MediaResponse.self, from: respData)
            print("Medien-Upload erfolgreich. Media ID: \(mediaResponse.id)")
            return mediaResponse.id
        } catch {
            print("Decodierungsfehler (Media Response): \(error)")
            throw MastodonError.decodingError(error)
        }
    }
    
    // MARK: - API-Funktion 2: Status erstellen (Toot)
    
    /**
     * Erstellt einen Status (Toot) mit Text und optionalen Medien-IDs.
     * Endpunkt: POST /api/v1/statuses
     */
    private func createStatus(text: String, mediaIds: [String]? = nil) async throws -> StatusResponse {
        guard let baseURL = instanceURL, let token = accessToken else {
            throw MastodonError.missingCredentials
        }
        
        guard let url = URL(string: "\(baseURL)/api/v1/statuses") else {
            throw MastodonError.invalidURL
        }
        
        // Das Payload-Format ist eine einfache JSON-Struktur
        var payload: [String: Any] = ["status": text, "visibility": "public"]
        
        if let ids = mediaIds, !ids.isEmpty {
            payload["media_ids"] = ids
        }
        
        let jsonBody = try JSONSerialization.data(withJSONObject: payload)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        
        let (respData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MastodonError.apiError(status: 0, message: "Keine HTTP-Antwort erhalten.")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: respData, encoding: .utf8) ?? "Unbekannter Fehler"
            print("API Fehler Status \(httpResponse.statusCode): \(errorMsg)")
            throw MastodonError.apiError(status: httpResponse.statusCode, message: "Status-Post fehlgeschlagen: \(errorMsg)")
        }
        
        do {
            let statusResponse = try JSONDecoder().decode(StatusResponse.self, from: respData)
            print("Status erfolgreich erstellt. ID: \(statusResponse.id)")
            return statusResponse
        } catch {
            print("Decodierungsfehler (Status Response): \(error)")
            throw MastodonError.decodingError(error)
        }
    }
    
    // MARK: - API-Funktion 3: Kombinierter Post
    
    /**
     * Kombinierte Funktion zum Erstellen eines Posts, der optional ein Bild hochlädt.
     * 1. Lädt das Medium hoch, falls vorhanden.
     * 2. Erstellt den Status mit der erhaltenen Media ID.
     */
    func postStatus(text: String, image: UIImage?, altText: String? = nil) async throws -> StatusResponse {
        var mediaIds: [String]? = nil
        
        if let image = image {
            guard let imageData = image.jpegData(compressionQuality: 0.9) else {
                throw MastodonError.invalidImageData
            }
            
            // Mastodon benötigt den MIME-Typ (hier nehmen wir JPEG)
            let mimeType = "image/jpeg"
            
            // 1. Medien-Upload durchführen
            let mediaId = try await uploadMedia(imageData: imageData, mimeType: mimeType, altText: altText)
            mediaIds = [mediaId]
        }
        
        // 2. Status erstellen (mit oder ohne Media IDs)
        return try await createStatus(text: text, mediaIds: mediaIds)
    }
}
