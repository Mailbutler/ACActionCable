//
//  ACClient.swift
//  ACActionCable
//
//  Created by Julian Tigler on 9/11/20.
//

import Foundation
import os

public final class ACClient {

    // MARK: Properties

    public var headers: ACRequestHeaders? = nil

    static var reconnectDelay: UInt32 = 1

    var connectionMonitor: ACConnectionMontior?

    private var socket: ACWebSocketProtocol

    private struct SubscriberState {
        var subscriptions: [ACChannelIdentifier: ACSubscription] = [:]
        var taps: Set<ACClientTap> = []
    }

    /// Written by the app's threads through `subscribe`/`unsubscribe`/`add`/`remove` and by the
    /// socket's callback queue when a subscription is rejected, so every access takes this lock.
    private let subscriberState = OSAllocatedUnfairLock(initialState: SubscriberState())
    
    // MARK: Initialization
    
    public init(socket: ACWebSocketProtocol, headers: ACRequestHeaders? = nil, connectionMonitorTimeout: TimeInterval? = nil) {
        self.socket = socket
        self.socket.onConnected = onSocketConnected(headers:)
        self.socket.onDisconnected = onSocketDisconnected(reason:)
        self.socket.onText = onSocketText(text:)
        
        self.headers = headers
        
        if let timeout = connectionMonitorTimeout {
            connectionMonitor = ACConnectionMontior(client: self, staleThreshold: timeout)
        }
    }
    
    // MARK: Socket Callbacks
    
    private func onSocketConnected(headers: ACRequestHeaders?) {
        let state = subscriberState.withLock { $0 }

        state.taps.forEach() { $0.onConnected?(headers) }

        state.subscriptions.keys.forEach() {
            guard let command = ACCommand(type: .subscribe, identifier: $0) else { return }
            send(command)
        }
    }

    private func onSocketDisconnected(reason: String?) {
        subscriberState.withLock { $0.taps }.forEach() { $0.onDisconnected?(reason) }
    }

    private func onSocketText(text: String) {
        let taps = subscriberState.withLock { $0.taps }

        taps.forEach() { $0.onText?(text) }

        guard let message = ACMessage(string: text) else { return }

        taps.forEach() { $0.onMessage?(message) }

        guard let channelIdentifier = message.identifier,
              let subscription = subscriberState.withLock({ $0.subscriptions[channelIdentifier] }) else { return }

        subscription.onMessage(message)

        switch message.type {
        case .rejectSubscription:
            subscriberState.withLock { _ = $0.subscriptions.removeValue(forKey: subscription.channelIdentifier) }
        default:
            break
        }
    }
    
    // MARK: Connections
    
    public func connect() {
        connectionMonitor?.start()
        socket.connect(headers: headers)
    }
    
    public func disconnect(allowReconnect: Bool = false) {
        if !allowReconnect {
            connectionMonitor?.stop()
        }
        
        socket.disconnect()
    }
    
    func reconnect() {
        socket.disconnect()
        sleep(Self.reconnectDelay)
        socket.connect(headers: headers)
    }
    
    // MARK: Sending
    
    func send(_ command: ACCommand, completion: ACEventHandler? = nil) {
        guard let text = command.string else { return }
        socket.send(text: text, completion: completion)
    }
    
    // MARK: Subscriptions
    
    public func subscribe(to channelIdentifier: ACChannelIdentifier, with messageHandler: @escaping ACMessageHandler) -> ACSubscription? {
        guard let command = ACCommand(type: .subscribe, identifier: channelIdentifier) else { return nil }

        let subscription = ACSubscription(client: self, channelIdentifier: channelIdentifier, onMessage: messageHandler)

        let inserted = subscriberState.withLock { state in
            guard state.subscriptions[subscription.channelIdentifier] == nil else { return false }
            state.subscriptions[subscription.channelIdentifier] = subscription
            return true
        }
        guard inserted else { return nil }

        send(command)

        return subscription
    }

    @discardableResult
    public func unsubscribe(from subscription: ACSubscription) -> Bool {
        guard let command = ACCommand(type: .unsubscribe, identifier: subscription.channelIdentifier) else { return false }

        guard subscriberState.withLock({ $0.subscriptions.removeValue(forKey: subscription.channelIdentifier) != nil }) else { return false }

        send(command)

        return true
    }

    // MARK: Tapping

    public func add(_ tap: ACClientTap) {
        subscriberState.withLock { _ = $0.taps.insert(tap) }
    }

    public func remove(_ tap: ACClientTap) {
        subscriberState.withLock { _ = $0.taps.remove(tap) }
    }
    
    // MARK: Deinitialization
    
    deinit {
        connectionMonitor?.stop()
    }
}

// MARK: - Sendable

/// `@unchecked` because only part of the type is checkable: `subscriptions` and `taps` are behind
/// `subscriberState`'s lock, while the rest is a usage contract — `socket`, `headers` and
/// `connectionMonitor` are configured before `connect()` and left alone afterwards, and
/// `reconnectDelay` is a knob the tests set before exercising reconnection.
extension ACClient: @unchecked Sendable {}
