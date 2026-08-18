//
//  ACMessage.swift
//  ACActionCable
//
//  Created by Julian Tigler on 9/12/20.
//

import Foundation
import os

public typealias ACMessageHandler = @Sendable (ACMessage) -> Void

public struct ACMessage: Decodable, Sendable {

    // MARK: Properties

    // Separate locks on purpose: decoding holds decoderStorage's lock while init(from:) reads
    // messageTypesStorage, and an unfair lock is not reentrant, so sharing one would deadlock
    // on that nested acquisition.
    private static let decoderStorage: OSAllocatedUnfairLock<JSONDecoder> = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return OSAllocatedUnfairLock(initialState: decoder)
    }()

    private typealias RegisteredMessageType = any (Decodable & Sendable).Type
    private static let messageTypesStorage = OSAllocatedUnfairLock(initialState: [String: RegisteredMessageType]())

    /// Applies `configure` to the decoder used for all messages, while no message is being decoded.
    ///
    /// `JSONDecoder` is a class, so vending it directly would let callers mutate it while the
    /// socket is decoding on another thread; this is the only way to change its configuration.
    public static func configureDecoder(_ configure: @Sendable (JSONDecoder) -> Void) {
        decoderStorage.withLock { configure($0) }
    }

    public var type: ACMessageType?
    public var body: ACMessageBody?
    public var bodyData: Data?
    public var identifier: ACChannelIdentifier?
    public var disconnectReason: ACDisconnectReason?
    public var reconnect: Bool?
    
    enum CodingKeys: String, CodingKey {
        case type
        case identifier
        case body = "message"
        case disconnectReason = "reason"
        case reconnect
    }

    public static func register<A: Decodable & Sendable>(type: A.Type, forChannelIdentifier identifier: ACChannelIdentifier) {
        messageTypesStorage.withLock { $0[identifier.string] = type }
    }

    public static func unregisterType(forChannelIdentifier identifier: ACChannelIdentifier) {
        messageTypesStorage.withLock { _ = $0.removeValue(forKey: identifier.string) }
    }

    public static func unregisterAllTypes() {
        messageTypesStorage.withLock { $0.removeAll() }
    }

    private static func messageType(forChannelIdentifier identifier: ACChannelIdentifier) -> RegisteredMessageType? {
        messageTypesStorage.withLock { $0[identifier.string] }
    }

    // MARK: Initialization
    
    init?(string: String) {
        guard let data = string.data(using: .utf8) else { return nil }

        // The decode stays inside the lock: that is what makes configureDecoder wait until no
        // message is being decoded, so copying the decoder out and decoding outside would let a
        // configuration change mutate it mid-decode.
        let decodedMessage = Self.decoderStorage.withLock { try? $0.decode(ACMessage.self, from: data) }
        guard var message = decodedMessage else { return nil }

        do {
            if let jsonMessage = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any], let decodedBody = jsonMessage["message"] as? [String: Any]  {
                message.bodyData = try JSONSerialization.data(withJSONObject: decodedBody)
            }
        } catch {
            message.bodyData = nil
        }


        self = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try container.decodeIfPresent(ACMessageType.self, forKey: .type)
        identifier = try container.decodeIfPresent(ACChannelIdentifier.self, forKey: .identifier)
        disconnectReason = try container.decodeIfPresent(ACDisconnectReason.self, forKey: .disconnectReason)
        reconnect = try container.decodeIfPresent(Bool.self, forKey: .reconnect)

        // special handling for message BODY
        if let identifier, let messageType = Self.messageType(forChannelIdentifier: identifier) {
            let bodyObject = try container.decodeIfPresent(messageType, forKey: .body)
            body = ACMessageBody.object(bodyObject)
        } else {
            body = try? container.decodeIfPresent(ACMessageBody.self, forKey: .body)
        }
    }
}

// MARK: ACMessageType

public enum ACMessageType: String, Decodable, Sendable {
    case confirmSubscription = "confirm_subscription"
    case rejectSubscription = "reject_subscription"
    case welcome
    case disconnect
    case ping
    case message
}

// MARK: ACMessageBody

public enum ACMessageBody: Decodable, Sendable {
    case ping(Int)
    case object((any Sendable)?)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .ping(value)
        } else if let value = try? container.decode(ACMessageBodySingleObject.self) {
            self = .object(value.object)
        } else {
            throw DecodingError.typeMismatch(ACMessageBody.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unable to parse message body"))
        }
    }
}

// MARK: ACMessageBodyObject

public struct ACMessageBodySingleObject: Decodable, Sendable {
    public let object: (any Sendable)?
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        guard container.allKeys.count == 1, let firstKey = container.allKeys.first else {
            throw DecodingError.typeMismatch(ACMessageBodySingleObject.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Expected message container to only have one top-level key"))
        }
        
        let key = firstKey.stringValue
        guard let decoder = Self.decoder(forKey: key) else {
            throw DecodingError.typeMismatch(ACMessageBodySingleObject.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "No message decoder registered for key: \(key)"))
        }

        object = try? decoder(container)
    }

    private typealias BodyDecoder = @Sendable (KeyedDecodingContainer<DynamicKey>) throws -> any Sendable
    private static let decodersStorage = OSAllocatedUnfairLock(initialState: [String: BodyDecoder]())

    public static func register<A: Decodable & Sendable>(type: A.Type, forKey key: String? = nil) {
        let pascalCaseTypeName = String(describing: type)
        let camelCaseTypeName = pascalCaseTypeName.prefix(1).lowercased() + pascalCaseTypeName.dropFirst()

        decodersStorage.withLock { decoders in
            decoders[camelCaseTypeName] = { container in
                try container.decode(A.self, forKey: DynamicKey(stringValue: key ?? camelCaseTypeName)!)
            }
        }
    }

    private static func decoder(forKey key: String) -> BodyDecoder? {
        decodersStorage.withLock { $0[key] }
    }
}

// MARK: DynamicKey

struct DynamicKey: CodingKey {
    var intValue: Int?
    var stringValue: String
    
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = intValue.description
    }
    
    init?(stringValue: String) {
        self.stringValue = stringValue
    }
}

// MARK: ACDisconnectReason

public enum ACDisconnectReason: String, Decodable, Sendable {
    case unauthorized
    case invalidRequest = "invalid_request"
    case serverRestart = "server_restart"
}
