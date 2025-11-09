import Foundation
import UIKit
import CryptoKit

// MARK: - Logging
func logs(_ message: String) {
    print("[\(Date())] 🧵 \(message)")
}

// MARK: - Credentials
// Threads API benötigt einen Long-Lived Token und die Instagram User ID
struct ThreadsCredentials {
    let accessToken: String
    let userId: String
}

// Die Struktur AppCredentials wurde entfernt, da die Werte nun direkt übergeben werden.

// MARK: - API Errors
enum ThreadsAPIError: Error {
    case authenticationFailed(message: String)
    case networkError(Error)
    case apiError(message: String)
    case invalidURL
    case jsonDecodingFailed(Error)
}

// MARK: - ThreadsAPI
class ThreadsAPI {
    private var credentials: ThreadsCredentials?
    // private var appCredentials: AppCredentials? <--- ENTFERNT

    // Wir verwenden eine stabile Version der Graph API
    private let graphAPIVersion = "v19.0"
    
    // Basis-URL für die Instagram Graph API
    private var baseURL: String {
        return "https://graph.facebook.com/\(graphAPIVersion)"
    }

    // MARK: - Session Management
    
    // func setAppCredentials... <--- ENTFERNT
    
    func createSession(credentials: ThreadsCredentials) {
        self.credentials = credentials
        logs("Session erstellt für Threads User ID: \(credentials.userId)")
    }
    
    // MARK: - Token & ID Retrieval (Aktualisiert)
    
    /// Tauscht einen kurzlebigen Token gegen einen langlebigen Token (bis zu 60 Tage) aus.
    /// Nimmt clientId und clientSecret direkt entgegen.
    func exchangeShortLivedToken(
        shortLivedToken: String,
        clientId: String,
        clientSecret: String
    ) async throws -> String {
        logs("-> Starte Austausch kurzlebiger Token...")
        
        // Der Token-Exchange-Endpoint verwendet NICHT die /v19.0/ in der URL
        let urlString = "https://graph.facebook.com/oauth/access_token"
        guard let url = URL(string: urlString) else {
            logs("❌ Ungültige URL für Token-Austausch")
            throw ThreadsAPIError.invalidURL
        }
        
        let params: [String: String] = [
            "grant_type": "fb_exchange_token",
            "client_id": clientId,
            "client_secret": clientSecret,
            "fb_exchange_token": shortLivedToken
        ]
        
        // Führe eine einfache GET-Anfrage ohne gespeicherte Credentials durch
        let (data, _) = try await performTokenExchangeRequest(url: url, parameters: params)
        
        logs("Rohdaten erhalten: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")...")
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let longLivedToken = json["access_token"] as? String {
            logs("✅ Token-Austausch erfolgreich: \(longLivedToken.prefix(8))****")
            return longLivedToken
        } else {
            logs("❌ Token-Austausch fehlgeschlagen, JSON: \(String(data: data, encoding: .utf8) ?? "nil")")
            throw ThreadsAPIError.jsonDecodingFailed(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Fehlender access_token"]))
        }
    }

    /// Ruft die Instagram User ID (die für Threads erforderlich ist) mit dem langlebigen Token ab.
    func fetchUserId(longLivedToken: String) async throws -> String {
        logs("-> Rufe Instagram User ID ab...")
        // Der Endpoint /me?fields=id wird verwendet, um die Instagram ID abzurufen.
        let urlString = "\(baseURL)/me"
        guard let url = URL(string: urlString) else { throw ThreadsAPIError.invalidURL }

        let params: [String: String] = [
            "fields": "id,username", // Abfrage der ID und des Benutzernamens zur Überprüfung
            "access_token": longLivedToken
        ]

        // Hier nutzen wir wieder den Token-Exchange-Request-Helper, da wir den Token direkt übergeben
        let (data, _) = try await performTokenExchangeRequest(url: url, parameters: params)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let userId = json["id"] as? String {
            logs("✅ Instagram User ID erfolgreich abgerufen: \(userId)")
            return userId
        } else {
            throw ThreadsAPIError.jsonDecodingFailed(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Fehlender 'id' in der Antwort."]))
        }
    }
    
    // MARK: - API Request Helper (OAuth 2.0)
    
    // Helper für Token-Austausch und ID-Abruf, da diese den Token direkt als Parameter benötigen
    private func performTokenExchangeRequest(
        url: URL,
        parameters: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        guard let finalURL = components.url else {
            throw ThreadsAPIError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        
        logs("-> Calling Meta API (Exchange/ID): GET \(finalURL.path)?\(finalURL.query?.prefix(50) ?? "")...")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ThreadsAPIError.networkError(NSError(domain: "Network", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ungültiger Antworttyp"]))
            }
            
            if !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "Kein Body"
                logs("⚠️ HTTP Error Status \(httpResponse.statusCode). Antwort-Body: \(body.prefix(200))...")
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorDict = json["error"] as? [String: Any],
                   let message = errorDict["message"] as? String {
                    throw ThreadsAPIError.apiError(message: "Meta API Fehler (\(httpResponse.statusCode)): \(message)")
                }
                throw ThreadsAPIError.apiError(message: "HTTP Status \(httpResponse.statusCode)")
            }
            
            return (data, httpResponse)
            
        } catch let networkError as URLError {
            logs("❌ Netzwerkfehler: \(networkError.localizedDescription)")
            throw ThreadsAPIError.networkError(networkError)
        } catch let apiError as ThreadsAPIError {
            throw apiError
        } catch {
            logs("❌ Unbekannter Request-Fehler: \(error.localizedDescription)")
            throw error
        }
    }
    
    // Haupt-Helper für Threads-API-Aufrufe, die gespeicherte Credentials verwenden
    private func performThreadsRequest(
        url: URL,
        method: String,
        parameters: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        
        guard let creds = credentials else {
            throw ThreadsAPIError.authenticationFailed(message: "Credentials (AccessToken/UserID) fehlen.")
        }
        
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        
        // Hängt alle Parameter und den Access Token an die Query Items an
        var queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "access_token", value: creds.accessToken))
        
        components.queryItems = queryItems
        
        guard let finalURL = components.url else {
            throw ThreadsAPIError.invalidURL
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        
        logs("-> Calling Threads API: \(method) \(finalURL.path)?\(finalURL.query?.prefix(50) ?? "")...")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ThreadsAPIError.networkError(NSError(domain: "Network", code: 0, userInfo: [NSLocalizedDescriptionKey: "Ungültiger Antworttyp"]))
            }
            
            if !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "Kein Body"
                logs("⚠️ HTTP Error Status \(httpResponse.statusCode). Antwort-Body: \(body.prefix(200))...")
                // Spezifischer Fehler, falls Meta API Fehler-JSON zurückgibt
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorDict = json["error"] as? [String: Any],
                   let message = errorDict["message"] as? String {
                    throw ThreadsAPIError.apiError(message: "Meta API Fehler (\(httpResponse.statusCode)): \(message)")
                }
                throw ThreadsAPIError.apiError(message: "HTTP Status \(httpResponse.statusCode)")
            }
            
            return (data, httpResponse)
            
        } catch let networkError as URLError {
            logs("❌ Netzwerkfehler: \(networkError.localizedDescription)")
            throw ThreadsAPIError.networkError(networkError)
        } catch let apiError as ThreadsAPIError {
            // Re-throw API errors caught inside the response block
            throw apiError
        } catch {
            logs("❌ Unbekannter Request-Fehler: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Main Post Entry Point
    func postToThreads(text: String, imageURL: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        logs("--- Starte Threads Post ---")
        guard let creds = credentials else {
            logs("❌ Posten bei Threads fehlgeschlagen: Credentials fehlen.")
            completion(.failure(ThreadsAPIError.authenticationFailed(message: "Fehlende Credentials.")));
            return
        }

        Task {
            do {
                let containerId: String
                
                if let imageURL = imageURL, !imageURL.isEmpty {
                    logs("Bild-URL erkannt. Erstelle Medien-Container...")
                    containerId = try await self.createMediaContainer(text: text, imageURL: imageURL, userId: creds.userId)
                } else {
                    logs("Nur-Text-Post. Erstelle Text-Container...")
                    containerId = try await self.createTextContainer(text: text, userId: creds.userId)
                }
                
                logs("Schritt 2: Veröffentliche Container ID: \(containerId)...")
                let postId = try await self.publishContainer(containerId: containerId, userId: creds.userId)
                
                logs("✅ Posten abgeschlossen. Threads Post ID: \(postId)")
                completion(.success(postId))
            } catch {
                logs("❌ Threads Post FEHLGESCHLAGEN: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Internal Async Container/Publish Flow
extension ThreadsAPI {
    
    // Step 1A: Erstelle Text-Container
    private func createTextContainer(text: String, userId: String) async throws -> String {
        let urlString = "\(baseURL)/\(userId)/threads_containers"
        guard let url = URL(string: urlString) else { throw ThreadsAPIError.invalidURL }
        
        let params: [String: String] = [
            "text": text
        ]
        
        let (data, _) = try await performThreadsRequest(url: url, method: "POST", parameters: params)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let containerId = json["id"] as? String {
            logs("✅ Text-Container erstellt, ID: \(containerId)")
            return containerId
        } else {
            throw ThreadsAPIError.jsonDecodingFailed(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Fehlende Container ID"]))
        }
    }
    
    // Step 1B: Erstelle Medien-Container
    private func createMediaContainer(text: String, imageURL: String, userId: String) async throws -> String {
        let urlString = "\(baseURL)/\(userId)/threads_containers"
        guard let url = URL(string: urlString) else { throw ThreadsAPIError.invalidURL }
        
        let params: [String: String] = [
            "text": text,
            "media_url": imageURL,
            "media_type": "IMAGE" // Kann VIDEO oder IMAGE sein
        ]
        
        let (data, _) = try await performThreadsRequest(url: url, method: "POST", parameters: params)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let containerId = json["id"] as? String {
            logs("✅ Medien-Container erstellt, ID: \(containerId)")
            return containerId
        } else {
            throw ThreadsAPIError.jsonDecodingFailed(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Fehlende Container ID"]))
        }
    }

    // Step 2: Veröffentliche Container
    private func publishContainer(containerId: String, userId: String) async throws -> String {
        let urlString = "\(baseURL)/\(userId)/threads_publish"
        guard let url = URL(string: urlString) else { throw ThreadsAPIError.invalidURL }
        
        let params: [String: String] = [
            "creation_id": containerId // Threads verwendet 'creation_id' für die Container ID
        ]
        
        let (data, _) = try await performThreadsRequest(url: url, method: "POST", parameters: params)
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let postId = json["id"] as? String {
            logs("✅ Container erfolgreich veröffentlicht.")
            return postId
        } else {
            throw ThreadsAPIError.jsonDecodingFailed(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Fehlende Post ID"]))
        }
    }
}
