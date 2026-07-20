import CryptoKit
import Foundation

public struct ExchangeCredentials: Codable, Equatable, Sendable {
  public var apiKey: String
  public var secret: String
  public var passphrase: String?

  public init(apiKey: String, secret: String, passphrase: String? = nil) {
    self.apiKey = apiKey
    self.secret = secret
    self.passphrase = passphrase
  }
}

public struct SignedExchangeRequest: Equatable, Sendable {
  public var method: String
  public var path: String
  public var query: String
  public var body: String
  public var headers: [String: String]

  public init(
    method: String, path: String, query: String = "", body: String = "", headers: [String: String]
  ) {
    self.method = method
    self.path = path
    self.query = query
    self.body = body
    self.headers = headers
  }
}

public enum ExchangeSigningError: Error, Equatable, LocalizedError, Sendable {
  case invalidCoinbaseKeyName
  case invalidCoinbasePrivateKey
  case invalidCoinbaseRequest
  case invalidKrakenSecret

  public var errorDescription: String? {
    switch self {
    case .invalidCoinbaseKeyName:
      return "Coinbase requires a CDP key name such as organizations/.../apiKeys/...."
    case .invalidCoinbasePrivateKey:
      return "Coinbase requires an ES256 CDP EC private key in PEM format."
    case .invalidCoinbaseRequest:
      return "Coinbase JWT request metadata is invalid."
    case .invalidKrakenSecret:
      return "Kraken requires a standard Base64 API secret."
    }
  }
}

public enum ExchangeRequestSigner {
  public static func binanceAccountRequest(
    credentials: ExchangeCredentials,
    timestampMs: Int64,
    path: String = "/api/v3/account"
  ) -> SignedExchangeRequest {
    let query = "timestamp=\(timestampMs)"
    let signature = hmacSHA256Hex(message: query, secret: credentials.secret)
    return SignedExchangeRequest(
      method: "GET",
      path: path,
      query: "\(query)&signature=\(signature)",
      headers: ["X-MBX-APIKEY": credentials.apiKey]
    )
  }

  public static func binanceAPIRestrictionsRequest(
    credentials: ExchangeCredentials,
    timestampMs: Int64
  ) -> SignedExchangeRequest {
    binanceAccountRequest(
      credentials: credentials,
      timestampMs: timestampMs,
      path: "/sapi/v1/account/apiRestrictions"
    )
  }

  public static func coinbaseAccountsRequest(
    credentials: ExchangeCredentials,
    timestamp: Int64,
    nonce: String,
    host: String = "api.coinbase.com",
    path: String = "/api/v3/brokerage/accounts",
    query: String = ""
  ) throws -> SignedExchangeRequest {
    let keyName = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard keyName.hasPrefix("organizations/"), keyName.contains("/apiKeys/") else {
      throw ExchangeSigningError.invalidCoinbaseKeyName
    }
    guard !nonce.isEmpty, !normalizedHost.isEmpty, path.hasPrefix("/") else {
      throw ExchangeSigningError.invalidCoinbaseRequest
    }
    let pem = credentials.secret
      .replacingOccurrences(of: "\\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
      throw ExchangeSigningError.invalidCoinbasePrivateKey
    }

    let header = CoinbaseJWTHeader(kid: keyName, nonce: nonce)
    let payload = CoinbaseJWTPayload(
      sub: keyName,
      nbf: timestamp,
      exp: timestamp + 120,
      uri: "GET \(normalizedHost)\(path)"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encodedHeader = Base64URL.encode(try encoder.encode(header))
    let encodedPayload = Base64URL.encode(try encoder.encode(payload))
    let signingInput = "\(encodedHeader).\(encodedPayload)"
    guard let signingData = signingInput.data(using: .utf8) else {
      throw ExchangeSigningError.invalidCoinbaseRequest
    }
    let signature = try privateKey.signature(for: signingData)
    let jwt = "\(signingInput).\(Base64URL.encode(signature.rawRepresentation))"

    return SignedExchangeRequest(
      method: "GET",
      path: path,
      query: query,
      headers: ["Authorization": "Bearer \(jwt)"]
    )
  }

  public static func krakenBalanceRequest(
    credentials: ExchangeCredentials,
    nonce: String,
    path: String = "/0/private/Balance"
  ) throws -> SignedExchangeRequest {
    let body = "nonce=\(nonce)"
    let bodyHash = SHA256.hash(data: Data("\(nonce)\(body)".utf8))
    var message = Data(path.utf8)
    message.append(Data(bodyHash))
    // Kraken issues standard Base64 secrets (including +, /, and = padding),
    // not the unpadded Base64URL format used by our vault wire envelopes.
    let encodedSecret = credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let secret = Data(base64Encoded: encodedSecret), !secret.isEmpty else {
      throw ExchangeSigningError.invalidKrakenSecret
    }
    let key = SymmetricKey(data: secret)
    let signature = HMAC<SHA512>.authenticationCode(for: message, using: key)
    return SignedExchangeRequest(
      method: "POST",
      path: path,
      body: body,
      headers: [
        "API-Key": credentials.apiKey,
        "API-Sign": Data(signature).base64EncodedString(),
      ]
    )
  }

  private static func hmacSHA256Hex(message: String, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).hexString
  }

}

private struct CoinbaseJWTHeader: Encodable {
  var alg = "ES256"
  var typ = "JWT"
  var kid: String
  var nonce: String
}

private struct CoinbaseJWTPayload: Encodable {
  var sub: String
  var iss = "cdp"
  var nbf: Int64
  var exp: Int64
  var uri: String
}
