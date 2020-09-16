//
//  ACSubscription.swift
//  ACActionCable
//
//  Created by Julian Tigler on 9/11/20.
//

import Foundation

public class ACSubscription {
    
    // MARK: Properties
    
    let channelIdentifier: ACChannelIdentifier
    let onMessage: ACMessageHandler
        
    private unowned var client: ACClient
    
    // MARK: Initialization
    
    init(client: ACClient, channelIdentifier: ACChannelIdentifier, onMessage: @escaping ACMessageHandler) {
        self.client = client
        self.channelIdentifier = channelIdentifier
        self.onMessage = onMessage
    }
    
    // MARK: Sending
    
    public func send(actionName: String, data: [String: Any]? = nil, completion: ACEventHandler? = nil) {
        guard let command = ACCommand(type: .message, identifier: self.channelIdentifier, action: actionName, data: data), let message = command.string else { return }
        self.client.send(text: message) { completion?() }
    }
}

// MARK: Equatable

extension ACSubscription: Equatable {
    
    public static func == (lhs: ACSubscription, rhs: ACSubscription) -> Bool {
        lhs.channelIdentifier == rhs.channelIdentifier
    }
}

// MARK: Hashable

extension ACSubscription: Hashable {
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(channelIdentifier.string)
    }
}