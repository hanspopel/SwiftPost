import Foundation
import UIKit
import CryptoKit

// MARK: - Logging
func log(_ message: String) {
    print("[\(Date())] 🐦 \(message)")
}

// MARK: - OAuth Helpers
extension String {
    // Note: The OAuth standard requires specific encoding (RFC 3986)
    var percentEncoded: String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    func hmacSHA1(key: String) -> Data {
        let keyData = Data(key.utf8)
        let messageData = Data(self.utf8)
        let symmetricKey = SymmetricKey(data: keyData)
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: messageData, using: symmetricKey)
        return Data(signature)
    }
}

// MARK: - Credentials
struct OAuthCredentials {
    let apiKey: String
    let apiSecret: String
    let accessToken: String
    let accessSecret: String
}

// MARK: - API Errors
enum APIError: Error {
    case authenticationFailed
    case networkError(Error)
    case apiError(message: String)
    case invalidMedia
    case jsonDecodingFailed(Error)
}


// MARK: - API Errors (Renamed for clarity, using the specific error in API functions)
enum TwitterAPIError: Error {
    case authenticationFailed
    case invalidMedia
    case networkError(Error)
    case apiError(String)
    case jsonDecodingFailed(Error)
}


// MARK: - TwitterAPI
class TwitterAPI {
    private var credentials: OAuthCredentials?

    // V2 endpoint for posting
    private let tweetV2URL = "https://api.twitter.com/2/tweets"
    // V1.1 endpoint for media upload (as this works)
    private let uploadURL = "https://upload.twitter.com/1.1/media/upload.json"

    func createSession(credentials: OAuthCredentials) {
        self.credentials = credentials
        log("Session created")
    }

    // MARK: - OAuth 1.0a Header
    private func buildOAuth1Header(url: URL, method: String, parameters: [String: String] = [:]) -> String? {
        guard let creds = credentials else {
            log("⚠️ Failed to build OAuth header: Credentials missing.")
            return nil
        }

        let nonce = UUID().uuidString
        let timestamp = "\(Int(Date().timeIntervalSince1970))"

        var oauthParams: [String: String] = [
            "oauth_consumer_key": creds.apiKey,
            "oauth_token": creds.accessToken,
            "oauth_nonce": nonce,
            "oauth_timestamp": timestamp,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_version": "1.0"
        ]

        // CRITICAL STEP: Combine ALL OAuth parameters and Request body/query parameters for signing
        let allParams = oauthParams.merging(parameters) { (_, new) in new }
        
        let paramString = allParams
            .map { "\($0.key.percentEncoded)=\($0.value.percentEncoded)" }
            .sorted()
            .joined(separator: "&")

        // CRITICAL STEP: Base String construction
        let baseString = "\(method)&\(url.absoluteString.percentEncoded)&\(paramString.percentEncoded)"
        
        let signingKey = "\(creds.apiSecret.percentEncoded)&\(creds.accessSecret.percentEncoded)"
        let signature = baseString.hmacSHA1(key: signingKey).base64EncodedString()

        oauthParams["oauth_signature"] = signature

        let header = "OAuth " + oauthParams
            .map { "\($0.key)=\"\($0.value.percentEncoded)\"" }
            .sorted()
            .joined(separator: ", ")

        return header
    }

    // MARK: - Post Tweet Entry Point
    func postTweet(text: String, image: UIImage? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        log("--- Initiating Tweet Post ---")
        guard let creds = credentials else {
            log("❌ Post Tweet failed: Credentials missing.")
            completion(.failure(APIError.authenticationFailed));
            return
        }

        if let image = image {
            log("Image detected. Starting media upload flow.")
            uploadMediaAndPostTweet(text: text, image: image, credentials: creds, completion: completion)
        } else {
            log("No image. Posting text-only tweet.")
            // Using the async V2 function for the final post
            Task {
                do {
                    let tweetId = try await self.postTweetV2(text: text, mediaId: nil, credentials: creds)
                    completion(.success(tweetId))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Media Upload + Post (Completion-based, bridged to async helpers)
    private func uploadMediaAndPostTweet(
        text: String,
        image: UIImage,
        credentials: OAuthCredentials,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        log("-> Calling uploadMediaAndPostTweet (Async Bridge)")
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            log("❌ uploadMediaAndPostTweet failed: Could not get JPEG data from image.")
            completion(.failure(APIError.invalidMedia))
            return
        }
        log("Image data size: \(String(format: "%.2f", Double(imageData.count) / 1024.0 / 1024.0)) MB")

        Task {
            do {
                // 1. INIT (V1.1)
                log("Step 1: mediaUploadInit started...")
                let mediaId = try await self.mediaUploadInit(data: imageData, credentials: credentials)
                
                // 2. APPEND (V1.1)
                log("Step 2: mediaUploadAppend started...")
                try await self.mediaUploadAppend(mediaId: mediaId, data: imageData, credentials: credentials)
                
                // 3. FINALIZE (V1.1)
                log("Step 3: mediaUploadFinalize started...")
                try await self.mediaUploadFinalize(mediaId: mediaId, credentials: credentials)
                
                // 4. POST TWEET (V2)
                log("Step 4: postTweetV2 with media started...")
                let tweetId = try await self.postTweetV2(text: text, mediaId: mediaId, credentials: credentials)
                
                log("✅ Media Upload and Post complete. Tweet ID: \(tweetId)")
                completion(.success(tweetId))
            } catch {
                log("❌ Upload/Post FAILED in Task: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Media Upload (INIT → APPEND → FINALIZE)
extension TwitterAPI {

    // INIT
    private func mediaUploadInit(data: Data, credentials: OAuthCredentials) async throws -> String {
        log("-> Calling mediaUploadInit (V1.1)")
        
        let params: [String: String] = [
            "command": "INIT",
            "total_bytes": "\(data.count)",
            "media_type": "image/jpeg",
            "media_category": "tweet_image"
        ]
        
        guard let url = URL(string: uploadURL),
              // Pass parameters to the header builder for signing
              let header = buildOAuth1Header(url: url, method: "POST", parameters: params) else {
            log("❌ mediaUploadInit failed: URL or OAuth Header creation failed.")
            throw TwitterAPIError.authenticationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.key)=\($0.value.percentEncoded)" }.joined(separator: "&").data(using: .utf8)

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: responseData, encoding: .utf8) ?? "No body"
                log("⚠️ INIT HTTP Error: Status \(httpResponse.statusCode). Response Body: \(body.prefix(100))...")
                throw TwitterAPIError.apiError("INIT HTTP Status \(httpResponse.statusCode)")
            }
            
            if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let mediaId = json["media_id_string"] as? String {
                log("✅ INIT success, media_id: \(mediaId)")
                return mediaId
            } else {
                let body = String(data: responseData, encoding: .utf8) ?? "No body"
                log("❌ INIT failed: Unexpected response structure. Response: \(body.prefix(100))...")
                throw TwitterAPIError.apiError("INIT failed: Unexpected response")
            }
        } catch let networkError as URLError {
            log("❌ INIT Network Failed: \(networkError.localizedDescription)")
            throw TwitterAPIError.networkError(networkError)
        } catch let jsonError as DecodingError {
            log("❌ INIT JSON Decoding Failed: \(jsonError.localizedDescription)")
            throw TwitterAPIError.jsonDecodingFailed(jsonError)
        }
    }

    // APPEND
    private func mediaUploadAppend(mediaId: String, data: Data, credentials: OAuthCredentials) async throws {
        log("-> Calling mediaUploadAppend (V1.1) for media ID: \(mediaId)")
        let chunkSize = 5 * 1024 * 1024 // 5MB chunks
        let chunks = stride(from: 0, to: data.count, by: chunkSize).map { start -> Data in
            let end = min(start + chunkSize, data.count)
            return data[start..<end]
        }
        log("Dividing media into \(chunks.count) chunks.")

        for (index, chunk) in chunks.enumerated() {
            let params: [String: String] = [
                "command": "APPEND",
                "media_id": mediaId,
                "segment_index": "\(index)",
                "media": chunk.base64EncodedString() // Note: Base64 string is included in the signature!
            ]

            guard let url = URL(string: uploadURL),
                  let header = buildOAuth1Header(url: url, method: "POST", parameters: params) else {
                log("❌ mediaUploadAppend failed: URL or OAuth Header creation failed.")
                throw TwitterAPIError.authenticationFailed
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(header, forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = params.map { "\($0.key)=\($0.value.percentEncoded)" }.joined(separator: "&")
            request.httpBody = body.data(using: .utf8)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                    log("⚠️ APPEND HTTP Error: Status \(httpResponse.statusCode) for chunk \(index + 1).")
                    throw TwitterAPIError.apiError("APPEND HTTP Status \(httpResponse.statusCode)")
                }
                log("📤 APPEND chunk \(index + 1)/\(chunks.count) uploaded successfully.")
            } catch let error {
                log("❌ APPEND chunk \(index + 1) FAILED: \(error.localizedDescription)")
                throw error
            }
        }
    }

    // FINALIZE
    private func mediaUploadFinalize(mediaId: String, credentials: OAuthCredentials) async throws {
        log("-> Calling mediaUploadFinalize (V1.1) for media ID: \(mediaId)")
        let params: [String: String] = [
            "command": "FINALIZE",
            "media_id": mediaId
        ]
        
        guard let url = URL(string: uploadURL),
              let header = buildOAuth1Header(url: url, method: "POST", parameters: params) else {
            log("❌ mediaUploadFinalize failed: URL or OAuth Header creation failed.")
            throw TwitterAPIError.authenticationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.key)=\($0.value.percentEncoded)" }.joined(separator: "&").data(using: .utf8)

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: responseData, encoding: .utf8) ?? "No body"
                log("⚠️ FINALIZE HTTP Error: Status \(httpResponse.statusCode). Response Body: \(body.prefix(100))...")
                throw TwitterAPIError.apiError("FINALIZE HTTP Status \(httpResponse.statusCode)")
            }

            if let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let processingInfo = json["processing_info"] as? [String: Any]? {
                
                if let state = processingInfo?["state"] as? String {
                    log("⏳ FINALIZE success. Media processing state: \(state)")
                }

                if let state = processingInfo?["state"] as? String, state == "pending" {
                    log("⏳ Media processing pending. Starting status polling...")
                    try await pollMediaStatus(mediaId: mediaId)
                } else if let state = processingInfo?["state"] as? String, state == "failed" {
                    let errMsg = (processingInfo?["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                    log("❌ FINALIZE reported FAILED processing: \(errMsg)")
                    throw TwitterAPIError.apiError("Processing failed: \(errMsg)")
                } else {
                    log("✅ FINALIZE success (No or complete processing)")
                }
            } else {
                log("✅ FINALIZE success (No explicit processing info)")
            }
        } catch let error {
            log("❌ FINALIZE FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    // POLL MEDIA STATUS
    private func pollMediaStatus(mediaId: String) async throws {
        log("-> Polling media status for ID: \(mediaId)")
        
        let params: [String: String] = [
            "command": "STATUS",
            "media_id": mediaId
        ]
        
        var urlComponents = URLComponents(string: uploadURL)!
        urlComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = urlComponents.url,
              let header = buildOAuth1Header(url: URL(string: uploadURL)!, method: "GET", parameters: params) else {
            log("❌ pollMediaStatus failed: URL or OAuth Header creation failed.")
            throw TwitterAPIError.authenticationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(header, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                log("⚠️ STATUS HTTP Error: Status \(httpResponse.statusCode).")
                throw TwitterAPIError.apiError("STATUS HTTP Status \(httpResponse.statusCode)")
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let processingInfo = json["processing_info"] as? [String: Any],
               let state = processingInfo["state"] as? String {
                
                log("⏳ Media processing state: **\(state)**")
                
                switch state {
                case "succeeded":
                    log("✅ Media processing complete.")
                case "failed":
                    let errMsg = (processingInfo["error"] as? [String: Any])?["message"] as? String ?? "Unknown"
                    log("❌ Media processing failed: \(errMsg)")
                    throw TwitterAPIError.apiError("Processing failed: \(errMsg)")
                default:
                    let checkAfterSecs = (processingInfo["check_after_secs"] as? Double) ?? 2.0
                    log("💤 Polling again in \(checkAfterSecs) seconds...")
                    try await Task.sleep(nanoseconds: UInt64(checkAfterSecs * 1_000_000_000))
                    try await pollMediaStatus(mediaId: mediaId)
                }
            } else {
                log("❌ STATUS check failed: Unexpected response structure.")
                throw TwitterAPIError.apiError("STATUS check failed: Unexpected response")
            }
        } catch let error {
            log("❌ POLL STATUS FAILED: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Async V2 Posting Endpoint
extension TwitterAPI {
    fileprivate func postTweetV2(text: String, mediaId: String?, credentials: OAuthCredentials) async throws -> String {
        log("-> Async postTweetV2 called (V2 Endpoint). Media ID: \(mediaId ?? "None")")

        guard let url = URL(string: tweetV2URL) else {
            throw APIError.apiError(message: "Invalid V2 Tweet URL")
        }
        
        // 1. Construct V2 JSON Body
        var jsonBody: [String: Any] = ["text": text]
        if let mediaId = mediaId {
            jsonBody["media"] = ["media_ids": [mediaId]] // V2 media structure
        }
        
        // 2. Build OAuth Header: V2 POST requests with JSON body DO NOT include body params in signature
        guard let header = buildOAuth1Header(url: url, method: "POST", parameters: [:]) else {
            log("❌ Async postTweetV2 failed: OAuth Header creation failed.")
            throw APIError.authenticationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 3. Set JSON Body
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                log("⚠️ Async postTweetV2 HTTP Error: Status \(httpResponse.statusCode). Response Body: \(body.prefix(200))...")
                throw APIError.apiError(message: "HTTP Status \(httpResponse.statusCode)")
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataDict = json["data"] as? [String: Any],
               let idStr = dataDict["id"] as? String { // V2 returns 'id' under 'data'
                log("✅ Async postTweetV2 success! Tweet ID: \(idStr)")
                return idStr
            } else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                log("❌ Async postTweetV2 JSON Error/API Error: \(body.prefix(200))...")
                throw APIError.apiError(message: "Unexpected V2 response or API error")
            }
        } catch let networkError as URLError {
            log("❌ Async postTweetV2 Network Failed: \(networkError.localizedDescription)")
            throw APIError.networkError(networkError)
        } catch let jsonError as DecodingError {
            log("❌ Async postTweetV2 JSON Decoding Failed: \(jsonError.localizedDescription)")
            throw APIError.jsonDecodingFailed(jsonError)
        }
    }
}
