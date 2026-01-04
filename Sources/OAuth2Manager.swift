import Foundation
import AppKit
import AuthenticationServices

// MARK: - OAuth2 Configuration

struct OAuth2Config {
    let clientId: String
    let clientSecret: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let redirectURI: String
    let scopes: [String]
    
    static let gmail = OAuth2Config(
        clientId: "", // User needs to set this
        clientSecret: "", // User needs to set this
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        redirectURI: "com.imapmenu://oauth2callback",
        scopes: ["https://mail.google.com/"]
    )
}

// MARK: - OAuth2 Tokens

struct OAuth2Tokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    
    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60) // 1 minute buffer
    }
}

// MARK: - OAuth2 Manager

class OAuth2Manager: NSObject, ObservableObject {
    static let shared = OAuth2Manager()
    
    @Published var isAuthenticating = false
    
    private var authSession: ASWebAuthenticationSession?
    private var completionHandler: ((Result<OAuth2Tokens, Error>) -> Void)?
    
    enum OAuth2Error: LocalizedError {
        case missingCredentials
        case authorizationFailed(String)
        case tokenExchangeFailed(String)
        case refreshFailed(String)
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "OAuth2 credentials not configured. Please set Client ID and Secret in Settings."
            case .authorizationFailed(let msg):
                return "Authorization failed: \(msg)"
            case .tokenExchangeFailed(let msg):
                return "Token exchange failed: \(msg)"
            case .refreshFailed(let msg):
                return "Token refresh failed: \(msg)"
            case .invalidResponse:
                return "Invalid response from OAuth2 server"
            }
        }
    }
    
    // MARK: - Authorization Flow
    
    func authorize(config: OAuth2Config, email: String, completion: @escaping (Result<OAuth2Tokens, Error>) -> Void) {
        guard !config.clientId.isEmpty, !config.clientSecret.isEmpty else {
            completion(.failure(OAuth2Error.missingCredentials))
            return
        }
        
        self.completionHandler = completion
        
        // Build authorization URL
        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "login_hint", value: email)
        ]
        
        guard let authURL = components.url else {
            completion(.failure(OAuth2Error.authorizationFailed("Invalid URL")))
            return
        }
        
        DispatchQueue.main.async {
            self.isAuthenticating = true
            
            // Use ASWebAuthenticationSession for secure OAuth flow
            self.authSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "com.imapmenu"
            ) { [weak self] callbackURL, error in
                DispatchQueue.main.async {
                    self?.isAuthenticating = false
                }
                
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        completion(.failure(OAuth2Error.authorizationFailed("User cancelled")))
                    } else {
                        completion(.failure(OAuth2Error.authorizationFailed(error.localizedDescription)))
                    }
                    return
                }
                
                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    completion(.failure(OAuth2Error.authorizationFailed("No authorization code received")))
                    return
                }
                
                // Exchange code for tokens
                self?.exchangeCodeForTokens(code: code, config: config, completion: completion)
            }
            
            self.authSession?.presentationContextProvider = self
            self.authSession?.prefersEphemeralWebBrowserSession = false
            self.authSession?.start()
        }
    }
    
    // MARK: - Token Exchange
    
    private func exchangeCodeForTokens(code: String, config: OAuth2Config, completion: @escaping (Result<OAuth2Tokens, Error>) -> Void) {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(OAuth2Error.tokenExchangeFailed(error.localizedDescription)))
                return
            }
            
            guard let data = data else {
                completion(.failure(OAuth2Error.invalidResponse))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let error = json["error"] as? String {
                        let description = json["error_description"] as? String ?? error
                        completion(.failure(OAuth2Error.tokenExchangeFailed(description)))
                        return
                    }
                    
                    guard let accessToken = json["access_token"] as? String,
                          let refreshToken = json["refresh_token"] as? String,
                          let expiresIn = json["expires_in"] as? Int else {
                        completion(.failure(OAuth2Error.invalidResponse))
                        return
                    }
                    
                    let tokens = OAuth2Tokens(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
                    )
                    
                    completion(.success(tokens))
                }
            } catch {
                completion(.failure(OAuth2Error.tokenExchangeFailed(error.localizedDescription)))
            }
        }.resume()
    }
    
    // MARK: - Token Refresh
    
    func refreshTokens(refreshToken: String, config: OAuth2Config, completion: @escaping (Result<OAuth2Tokens, Error>) -> Void) {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(OAuth2Error.refreshFailed(error.localizedDescription)))
                return
            }
            
            guard let data = data else {
                completion(.failure(OAuth2Error.invalidResponse))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let error = json["error"] as? String {
                        let description = json["error_description"] as? String ?? error
                        completion(.failure(OAuth2Error.refreshFailed(description)))
                        return
                    }
                    
                    guard let accessToken = json["access_token"] as? String,
                          let expiresIn = json["expires_in"] as? Int else {
                        completion(.failure(OAuth2Error.invalidResponse))
                        return
                    }
                    
                    // Refresh token may or may not be returned
                    let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
                    
                    let tokens = OAuth2Tokens(
                        accessToken: accessToken,
                        refreshToken: newRefreshToken,
                        expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
                    )
                    
                    completion(.success(tokens))
                }
            } catch {
                completion(.failure(OAuth2Error.refreshFailed(error.localizedDescription)))
            }
        }.resume()
    }
    
    // MARK: - XOAUTH2 String Generation
    
    static func generateXOAuth2String(email: String, accessToken: String) -> String {
        let authString = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(authString.utf8).base64EncodedString()
    }
    
    // MARK: - Keychain Storage for Tokens
    
    func saveTokens(_ tokens: OAuth2Tokens, for accountId: String) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(tokens) {
            KeychainHelper.save(key: "oauth2_tokens_\(accountId)", value: String(data: data, encoding: .utf8) ?? "")
        }
    }
    
    func loadTokens(for accountId: String) -> OAuth2Tokens? {
        guard let jsonString = KeychainHelper.load(key: "oauth2_tokens_\(accountId)"),
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuth2Tokens.self, from: data)
    }
    
    func deleteTokens(for accountId: String) {
        KeychainHelper.delete(key: "oauth2_tokens_\(accountId)")
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension OAuth2Manager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first!
    }
}
