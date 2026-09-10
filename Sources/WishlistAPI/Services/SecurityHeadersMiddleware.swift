import Vapor

struct SecurityHeadersMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        response.headers.replaceOrAdd(name: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()")
        response.headers.replaceOrAdd(name: "Cross-Origin-Opener-Policy", value: "same-origin")
        response.headers.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: "same-site")
        if request.application.environment == .production {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains")
        }
        return response
    }
}

