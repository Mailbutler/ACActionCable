# ACActionCable

[ACActionCable](https://github.com/High5Apps/ACActionCable) is a Swift 5 client for [Ruby on Rails](https://rubyonrails.org/) 6's [Action Cable](https://guides.rubyonrails.org/action_cable_overview.html) WebSocket server. It is a hard fork of [Action-Cable-Swift](https://github.com/nerzh/Action-Cable-Swift). It aims to be well-tested, dependency-free, and easy to use.

## Installation

### CocoaPods

If your project doesn't use [CocoaPods](https://cocoapods.org/) yet, [follow this guide](https://guides.cocoapods.org/using/using-cocoapods.html).

Add the following line to your `Podfile`:

```ruby
pod 'ACActionCable', '~> 2'
```

ACActionCable uses [semantic versioning](https://semver.org/).

## Usage

### Implement ACWebSocketProtocol

You can use ACActionCable with any WebSocket library you'd like. Just create a class that implements [`ACWebSocketProtocol`](https://github.com/High5Apps/ACActionCable/blob/master/Sources/ACActionCable/ACWebSocketProtocol.swift). If you use [Starscream](https://github.com/daltoniam/Starscream), you can just copy [`ACStarscreamWebSocket`](https://github.com/High5Apps/ACActionCable/blob/master/Examples/ACStarscreamWebSocket.swift) into your project.

### Create a [singleton](https://en.wikipedia.org/wiki/Singleton_pattern) class to hold an ACClient

```swift
// MyClient.swift

import ACActionCable

class MyClient {

    static let shared = MyClient()
    private let client: ACClient

    private init() {
        let socket = ACStarscreamWebSocket(stringURL: "https://myrailsapp.com/cable") // Your concrete implementation of ACWebSocketProtocol (see above)
        client = ACClient(socket: socket, connectionMonitorTimeout: 6)
    }
}
```

If you set a `connectionMonitorTimeout` and no ping is received for that many seconds, then [`ACConnectionMonitor`](https://github.com/High5Apps/ACActionCable/blob/master/Sources/ACActionCable/ACConnectionMonitor.swift) will periodically attempt to reconnect. Leave `connectionMonitorTimeout` nil to disable connection monitoring.

### Connect and disconnect

You can set custom headers based on your server's requirements

```swift
// MyClient.swift

func connect() {
    client.headers = [
        "Auth": "Token",
        "Origin": "https://myrailsapp.com",
    ]
    client.connect()
}

func disconnect() {
    client.disconnect()
}
```

You probably want to connect when the user's session begins and disconnect when the user logs out.

```swift
// User.swift

func onSessionCreated() {
    MyClient.shared.connect()
    // ...
}

func logOut() {
    // ...
    MyClient.shared.disconnect()
}
```

### Subscribe and unsubscribe

```swift
// MyClient.swift

func subscribe(to channelIdentifier: ACChannelIdentifier, with messageHandler: @escaping ACMessageHandler) -> ACSubscription? {
    guard let subscription = client.subscribe(to: channelIdentifier, with: messageHandler) else {
        print("Warning: MyClient ignored attempt to double subscribe. You are already subscribed to \(channelIdentifier)")
        return nil
    }
    return subscription
}

func unsubscribe(from subscription: ACSubscription) {
    client.unsubscribe(from: subscription)
}
```

```swift
// ChatChannel.swift

import ACActionCable

class ChatChannel {

    private var subscription: ACSubscription?

    func subscribe(to roomId: Int) {
        guard subscription == nil else { return }
        let channelIdentifier = ACChannelIdentifier(channelName: "ChatChannel", identifier: ["room_id": roomId])!
        subscription = MyClient.shared.subscribe(to: channelIdentifier, with: handleMessage(_:))
    }

    func unsubscribe() {
        guard let subscription = subscription else { return }
        MyClient.shared.unsubscribe(from: subscription)
        self.subscription = nil
    }

    private func handleMessage(_ message: ACMessage) {
        switch message.type {
        case .confirmSubscription:
            print("ChatChannel subscribed")
        case .rejectSubscription:
            print("Server rejected ChatChannel subscription")
        default:
            break
        }
    }
}
```

Subscriptions are resubscribed on reconnection, so beware that `.confirmSubscription` may be called multiple times per subscription.

### Register your [`Decodable`](https://developer.apple.com/documentation/foundation/archives_and_serialization/encoding_and_decoding_custom_types) messages

ACActionCable automatically decodes your models. For example, if your server broadcasts the following message:

```json
{
  "identifier": "{\"channel\":\"ChatChannel\",\"room_id\":42}",
  "message": {
    "my_object": {
      "sender_id": 311,
      "text": "Hello, room 42!",
      "sent_at": 1600545466.294104
    }
  }
}
```

Then ACActionCable provides two different approaches to automatically decode it:

#### A) Automatically decode single key of `message`

```swift
// MyObject.swift

struct MyObject: Codable { // Must implement Decodable or Codable
    let senderId: Int
    let text: String
    let sentAt: Date
}
```

All you have to do is register the `Codable` struct for a _single_ key. The name of the `struct` must match the name of that **single** key.

```swift
// MyClient.swift

private init() {
  // Decode the single object for key `my_object` within `message`
  ACMessageBodySingleObject.register(type: MyObject.self)
}
```

```swift
// ChatChannel.swift

private func handleMessage(_ message: ACMessage) {
    switch (message.type, message.body) {
    case (.confirmSubscription, _):
        print("ChatChannel subscribed")
    case (.rejectSubscription, _):
        print("Server rejected ChatChannel subscription")
    case (_, .object(let object)):
        switch object {
        case let myObject as MyObject:
            print("\(myObject.text.debugDescription) from Sender \(myObject.senderId) at \(myObject.sentAt)")
            // "Hello, room 42!" from Sender 311 at 2020-09-19 19:57:46 +0000
        default:
            print("Warning: ChatChannel ignored message")
        }
    default:
        break
    }
}
```

If the `message` object sent from the server contains more than a single key, you have another option for automatic decoding:

#### B) Automatically decode whole `message` object

```swift
// MessageType.swift

struct MessageType: Codable { // Must implement Decodable or Codable
    let myObject: MyObject
}

struct MyObject: Codable { // Must implement Decodable or Codable
    let senderId: Int
    let text: String
    let sentAt: Date
}
```

All you have to do is register the `Codable` struct for the whole `message` object.

```swift
// MyClient.swift

private init() {
  // Decode the whole `message` object
  ACMessage.register(type: MessageType.self, forChannelIdentifier: channelIdentifier)
}
```

The `channelIdentifier` must match the one the handler is subscribing to, because all incoming `message` objects for that channel will be decoded according to `MessageType`.

```swift
// ChatChannel.swift

private func handleMessage(_ message: ACMessage) {
    switch (message.type, message.body) {
    case (.confirmSubscription, _):
        print("ChatChannel subscribed")
    case (.rejectSubscription, _):
        print("Server rejected ChatChannel subscription")
    case (_, .object(let object)):
        switch object {
        case let message as MessageType:
            print("\(message.myObject.text.debugDescription) from Sender \(message.myObject.senderId) at \(message.myObject.sentAt)")
            // "Hello, room 42!" from Sender 311 at 2020-09-19 19:57:46 +0000
        default:
            print("Warning: ChatChannel ignored message")
        }
    default:
        break
    }
}
```

### Accessing the raw message body data

ACActionCable also provides access to the raw message body data for more involved processing:

```swift
// ChatChannel.swift

private func handleMessage(_ message: ACMessage) {
    switch (message.type) {
    case (.confirmSubscription):
        print("ChatChannel subscribed")
    case (.rejectSubscription):
        print("Server rejected ChatChannel subscription")
    default:
        guard let bodyData = message.bodyData else {
            return
        }

        // do something fancy with the raw `Data`
    }
}
```

### Send messages

ACActionCable automatically encodes your [`Encodable`](https://developer.apple.com/documentation/foundation/archives_and_serialization/encoding_and_decoding_custom_types) objects too:

```swift
// MyObject.swift

struct MyObject: Codable { // Must implement Encodable or Codable
    let action: String
    let senderId: Int
    let text: String
    let sentAt: Date
}
```

```swift
// ChatChannel.swift

func speak(_ text: String) {
    let myObject = MyObject(action: "speak", senderId: 99, text: text, sentAt: Date())
    subscription?.send(object: myObject)
}
```

Calling `channel.speak("my message")` would cause the following to be sent:

```json
{
  "command": "message",
  "data": "{\"action\":\"speak\",\"my_object\":{\"sender_id\":99,\"sent_at\":1600545466.294104,\"text\":\"my message\"}}",
  "identifier": "{\"channel\":\"ChatChannel\",\"room_id\":42}"
}
```

### (Optional) Modify encoder/decoder date formatting

By default, `Date` objects are encoded or decoded using [`.secondsSince1970`](https://developer.apple.com/documentation/foundation/jsonencoder/dateencodingstrategy/secondssince1970). If you need to change to another format:

```swift
ACCommand.encoder.dateEncodingStrategy = .iso8601 // for dates like "2020-09-19T20:09:04Z"
ACMessage.decoder.dateDecodingStrategy = .iso8601
```

Note that `.iso8601` is quite strict and doesn't allow fractional seconds. If you need them, consider using `.secondsSince1970`, `millisecondsSince1970`, `.formatted`, or `.custom`.

### (Optional) Add an ACClientTap

If you need to listen to the internal state of `ACClient`, use `ACClientTap`.

```swift
// MyClient.swift

private init() {
    // ...
    let tap = ACClientTap(
        onConnected: { (headers) in
            print("Client connected with headers: \(headers.debugDescription)")
        }, onDisconnected: { (reason) in
            print("Client disconnected with reason: \(reason.debugDescription)")
        }, onText: { (text) in
            print("Client received text: \(text)")
        }, onMessage: { (message) in
            print("Client received message: \(message)")
        })
    client.add(tap)
}
```

## Contributing

Instead of opening an issue, please fix it yourself and then [create a pull request](https://docs.github.com/en/github/collaborating-with-issues-and-pull-requests/creating-a-pull-request-from-a-fork). Please add new tests for your feature or fix, and don't forget to make sure that all the tests pass!
