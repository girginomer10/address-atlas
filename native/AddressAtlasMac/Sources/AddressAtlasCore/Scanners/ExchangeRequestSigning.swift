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

  public init(method: String, path: String, query: String = "", body: String = "", headers: [String: String]) {
    self.method = method
    self.path = path
    self.query = query
    self.body = body
    self.headers = headers
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

  public static func coinbaseAccountsRequest(
    credentials: ExchangeCredentials,
    timestamp: String,
    path: String = "/api/v3/brokerage/accounts"
  ) -> SignedExchangeRequest {
    let method = "GET"
    let body = ""
    let prehash = "\(timestamp)\(method)\(path)\(body)"
    let signature = hmacSHA256Base64(message: prehash, secret: credentials.secret)
    return SignedExchangeRequest(
      method: method,
      path: path,
      body: body,
      headers: [
        "CB-ACCESS-KEY": credentials.apiKey,
        "CB-ACCESS-SIGN": signature,
        "CB-ACCESS-TIMESTAMP": timestamp,
        "CB-ACCESS-PASSPHRASE": credentials.passphrase ?? ""
      ]
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
    let secret = try Base64URL.decode(credentials.secret)
    let key = SymmetricKey(data: secret)
    let signature = HMAC<SHA512>.authenticationCode(for: message, using: key)
    return SignedExchangeRequest(
      method: "POST",
      path: path,
      body: body,
      headers: [
        "API-Key": credentials.apiKey,
        "API-Sign": Data(signature).base64EncodedString()
      ]
    )
  }

  private static func hmacSHA256Hex(message: String, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).hexString
  }

  private static func hmacSHA256Base64(message: String, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).base64EncodedString()
  }
}
