import Foundation

@testable import AddressAtlasCore

/// Answers the Solana stake-account lookups (`getProgramAccounts` on the Stake
/// program and `getEpochInfo`) as "this address has no stake accounts". Like
/// the network-identity proofs, they are a precondition of every Solana scan
/// rather than the subject of most Solana tests. The answer is stamped with the
/// slot the request asks for (`minContextSlot`), so it never disturbs a test's
/// own snapshot-slot choreography. Tests of stake handling opt out and answer
/// these requests themselves.
func emptySolanaStakeAccountResponse(for request: URLRequest) -> (Data, HTTPURLResponse)? {
  guard let body = request.httpBody, !body.isEmpty,
    let text = String(data: body, encoding: .utf8),
    text.contains("getProgramAccounts") || text.contains("getEpochInfo"),
    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
    let method = json["method"] as? String,
    let id = json["id"] as? Int,
    let params = json["params"] as? [Any]
  else { return nil }
  let config = params.compactMap { $0 as? [String: Any] }.last
  let slot = (config?["minContextSlot"] as? NSNumber)?.uint64Value ?? 123
  switch method {
  case "getProgramAccounts":
    guard params.first as? String == "Stake11111111111111111111111111111111111111" else {
      return nil
    }
    return (
      Data(
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"context\":{\"slot\":\(slot)},\"value\":[]}}"
          .utf8),
      httpResponse(for: request)
    )
  case "getEpochInfo":
    return (
      Data(
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"absoluteSlot\":\(slot),\"epoch\":700,\"slotIndex\":1,\"slotsInEpoch\":432000}}"
          .utf8),
      httpResponse(for: request)
    )
  default:
    return nil
  }
}

struct StubHTTPClient: HTTPClient, @unchecked Sendable {
  let automaticallyServesNetworkIdentity: Bool
  let automaticallyServesEmptySolanaStakeAccounts: Bool
  let handler: (URLRequest) throws -> (Data, HTTPURLResponse)

  init(
    automaticallyServesNetworkIdentity: Bool = true,
    automaticallyServesEmptySolanaStakeAccounts: Bool = true,
    handler: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)
  ) {
    self.automaticallyServesNetworkIdentity = automaticallyServesNetworkIdentity
    self.automaticallyServesEmptySolanaStakeAccounts = automaticallyServesEmptySolanaStakeAccounts
    self.handler = handler
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if automaticallyServesEmptySolanaStakeAccounts,
      let response = emptySolanaStakeAccountResponse(for: request)
    {
      return response
    }
    if automaticallyServesNetworkIdentity {
      let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
      if body.contains("\"eth_chainId\"") {
        let chainIDByHost = [
          "ethereum-rpc.publicnode.com": "0x1", "mainnet.base.org": "0x2105",
          "arb1.arbitrum.io": "0xa4b1", "mainnet.optimism.io": "0xa",
          "polygon.drpc.org": "0x89", "bsc-dataseed.binance.org": "0x38",
          "api.avax.network": "0xa86a", "rpc.gnosischain.com": "0x64",
          "rpc.linea.build": "0xe708", "rpc.mantle.xyz": "0x1388",
          "rpc.scroll.io": "0x82750", "mainnet.era.zksync.io": "0x144",
        ]
        let chainID = request.url?.host.flatMap { chainIDByHost[$0] } ?? "0x1"
        return (
          Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":\"\(chainID)\"}".utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("\"getGenesisHash\"") {
        return (
          Data(
            #"{"jsonrpc":"2.0","id":0,"result":"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"}"#
              .utf8),
          httpResponse(for: request)
        )
      }
      if body.contains("\"server_info\"") {
        return (Data(#"{"result":{"info":{"network_id":0}}}"#.utf8), httpResponse(for: request))
      }
    }
    return try handler(request)
  }
}

final class BatchRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []

  func append(_ size: Int) {
    lock.lock()
    defer { lock.unlock() }
    sizes.append(size)
  }

  func snapshot() -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return sizes
  }
}

func httpResponse(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
  HTTPURLResponse(
    url: request.url ?? URL(string: "https://example.com")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: ["content-type": "application/json"]
  )!
}

func testSessionToken(
  accountId: String,
  sessionId: String = "99999999-9999-4999-8999-999999999999"
) -> String {
  let issuedAt = Int64(Date().timeIntervalSince1970 * 1_000) - 1_000
  let payload: [String: Any] = [
    "userId": accountId,
    "sessionId": sessionId,
    "issuedAt": issuedAt,
    "expiresAt": issuedAt + SyncSessionToken.maximumLifetimeMilliseconds,
  ]
  let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  return "v1.session.\(Base64URL.encode(data)).\(Base64URL.encode(Data(repeating: 0x5A, count: 32)))"
}
