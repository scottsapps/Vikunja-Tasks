import XCTest
@testable import Veyrn

final class VikunjaAPIRequestTests: XCTestCase {
    func testMergePatchRequestUsesMergePatchContentType() throws {
        let request = try VikunjaAPI.makeMergePatchRequest(
            "/tasks/42",
            body: ["due_date": "2026-08-25T01:00:00Z"],
            base: "https://vikunja.example/api/v2"
        )

        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/merge-patch+json"
        )
    }
}
