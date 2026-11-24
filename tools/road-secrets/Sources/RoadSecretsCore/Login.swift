import Foundation

/// The scaffold login call made by `check` for principals (spec Section 7.8).
public protocol LoginChecking {
    /// POSTs `{"username":..,"password":..}` and returns the status and body.
    func login(url: URL, username: String, password: String) throws -> (status: Int, body: Data)
}

public struct URLSessionLogin: LoginChecking {
    public init() {}

    public func login(url: URL, username: String, password: String) throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        final class Box: @unchecked Sendable {
            var status = 0
            var body = Data()
            var error: Error?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.body = data ?? Data()
            box.error = error
            done.signal()
        }.resume()
        done.wait()
        if let error = box.error {
            throw RoadError(.external, "login request to \(url.absoluteString) failed: \(error.localizedDescription)")
        }
        return (box.status, box.body)
    }
}
