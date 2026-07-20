import Foundation

struct BinanceAccountResponse: Decodable {
  var balances: [Balance]
  struct Balance: Decodable {
    var asset: String
    var free: String
    var locked: String
  }
}

struct CoinbaseAccountsResponse: Decodable {
  var accounts: [Account]
  var hasNext: Bool
  var cursor: String?

  enum CodingKeys: String, CodingKey {
    case accounts
    case hasNext = "has_next"
    case cursor
  }

  struct Account: Decodable, Equatable {
    var identifier: UUID?
    var currency: String
    var availableBalance: Money?
    var hold: Money?

    enum CodingKeys: String, CodingKey {
      case identifier = "uuid"
      case currency
      case availableBalance = "available_balance"
      case hold
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      currency = try container.decode(String.self, forKey: .currency)
      availableBalance = try container.decodeIfPresent(Money.self, forKey: .availableBalance)
      hold = try container.decodeIfPresent(Money.self, forKey: .hold)

      // The API documents `uuid` as the stable account identity. Treat it as
      // untrusted input: a missing, non-string, or non-canonical value leaves
      // this one account invalid without discarding other valid accounts on the
      // same page. The caller skips it with an explicit aggregate warning.
      let rawIdentifier: String?
      do {
        rawIdentifier = try container.decodeIfPresent(String.self, forKey: .identifier)
      } catch {
        rawIdentifier = nil
      }
      guard let candidate = rawIdentifier,
        candidate.utf8.count == 36,
        let parsed = UUID(uuidString: candidate),
        parsed.uuidString.lowercased() == candidate.lowercased()
      else {
        identifier = nil
        return
      }
      identifier = parsed
    }
  }

  struct Money: Decodable, Equatable { var value: String }
}

struct KrakenBalanceResponse: Decodable {
  var error: [String]
  var result: [String: String]?
}

struct KrakenAssetsResponse: Decodable {
  var error: [String]
  var result: [String: Asset]
  struct Asset: Decodable { var altname: String }
}
