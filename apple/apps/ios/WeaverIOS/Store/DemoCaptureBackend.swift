#if os(iOS)
import Foundation
import WeaverCore

/// Fills the inspector with realistic sample flows so the iOS UI is fully
/// drivable before the packet-tunnel extension exists (iOS-P0/P1). Every
/// screen labels this as demo data — it never pretends to be live capture.
/// Emits a burst up front, then a slow trickle, and completes flows after a
/// short delay so the in-flight → done transition (and `objectWillChange`
/// live-update path) is exercised exactly as with a real backend.
@MainActor
final class DemoCaptureBackend: CaptureBackend {
    private weak var events: ProxyEventHandler?
    private var timer: Timer?

    func start(events: ProxyEventHandler) {
        self.events = events
        for sample in Self.samples.prefix(6) { emit(sample) }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitRandom() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        events = nil
    }

    private func emitRandom() {
        guard let sample = Self.samples.randomElement() else { return }
        emit(sample)
    }

    private func emit(_ sample: Sample) {
        guard let events else { return }
        let flow = Flow(
            method: sample.method,
            url: URL(string: sample.url)!,
            scheme: "https",
            host: URL(string: sample.url)!.host ?? "",
            path: URL(string: sample.url)!.path,
            requestHeaders: [
                HTTPHeader(name: "Host", value: URL(string: sample.url)!.host ?? ""),
                HTTPHeader(name: "User-Agent", value: sample.client),
                HTTPHeader(name: "Accept", value: "application/json"),
            ],
            requestBody: sample.requestBody?.data(using: .utf8),
            isTLS: true,
            clientDescription: sample.client
        )
        flow.httpVersion = "HTTP/2"
        events.flowDidStart(flow)

        // Complete the flow shortly after, mutating it in place.
        let delay = Double.random(in: 0.3...1.1)
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                flow.statusCode = sample.status
                flow.responseHeaders = [
                    HTTPHeader(name: "Content-Type", value: sample.contentType),
                    HTTPHeader(name: "Server", value: "cloudflare"),
                ]
                flow.responseBody = sample.responseBody.data(using: .utf8)
                flow.completedAt = Date()
                events.flowDidComplete(flow)
            }
        }
    }

    struct Sample {
        let method: String
        let url: String
        let client: String
        let status: Int
        let contentType: String
        let requestBody: String?
        let responseBody: String
    }

    static let samples: [Sample] = [
        Sample(method: "GET", url: "https://api.github.com/user/repos?per_page=30",
               client: "GitHub/402.0", status: 200, contentType: "application/json",
               requestBody: nil,
               responseBody: #"[{"id":1296269,"name":"weaver","private":false,"stargazers_count":128}]"#),
        Sample(method: "POST", url: "https://api.stripe.com/v1/payment_intents",
               client: "Stripe/24.1", status: 200, contentType: "application/json",
               requestBody: "amount=1999&currency=usd",
               responseBody: #"{"id":"pi_3P","object":"payment_intent","amount":1999,"status":"requires_confirmation"}"#),
        Sample(method: "GET", url: "https://api.spotify.com/v1/me/player",
               client: "Spotify/8.9", status: 204, contentType: "application/json",
               requestBody: nil, responseBody: ""),
        Sample(method: "PUT", url: "https://api.example.com/v2/users/42/settings",
               client: "Weaver/1.0", status: 200, contentType: "application/json",
               requestBody: #"{"theme":"dark","notifications":true}"#,
               responseBody: #"{"ok":true,"updated":["theme","notifications"]}"#),
        Sample(method: "GET", url: "https://cdn.example.com/assets/logo.png",
               client: "Weaver/1.0", status: 200, contentType: "image/png",
               requestBody: nil, responseBody: "…binary…"),
        Sample(method: "DELETE", url: "https://api.example.com/v2/cart/items/7",
               client: "Shop/3.2", status: 404, contentType: "application/json",
               requestBody: nil,
               responseBody: #"{"error":"not_found","message":"Cart item 7 does not exist"}"#),
        Sample(method: "POST", url: "https://analytics.example.com/collect",
               client: "Analytics/5.0", status: 500, contentType: "application/json",
               requestBody: #"{"event":"tap","screen":"home"}"#,
               responseBody: #"{"error":"internal","trace":"a1b2c3"}"#),
        Sample(method: "GET", url: "https://api.weather.com/v3/forecast?lat=37.7&lon=-122.4",
               client: "Weather/12.4", status: 200, contentType: "application/json",
               requestBody: nil,
               responseBody: #"{"temp":18,"conditions":"Partly Cloudy","humidity":72}"#),
    ]
}
#endif
