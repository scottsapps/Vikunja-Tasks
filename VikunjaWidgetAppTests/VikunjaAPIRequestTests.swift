import XCTest
@testable import Veyrn

final class VikunjaAPIRequestTests: XCTestCase {
    func testUnprocessableV2TaskPatchIsEligibleForFallback() {
        XCTAssertTrue(
            VikunjaAPI.v2TaskPatchIsUnprocessable(
                VikunjaAPI.APIError.badStatus(422)
            )
        )
        XCTAssertFalse(
            VikunjaAPI.v2TaskPatchIsUnprocessable(
                VikunjaAPI.APIError.badStatus(401)
            )
        )
    }

    func testRejectedV2TaskPatchInvokesV1FallbackOnce() async throws {
        var fallbackCount = 0
        var fetchCount = 0

        let result: String = try await VikunjaAPI.performV2TaskUpdate(
            updateV2: { throw VikunjaAPI.V2TaskPatchRejected() },
            fetchUpdated: {
                fetchCount += 1
                return "v2"
            },
            updateV1: {
                fallbackCount += 1
                return "v1"
            }
        )

        XCTAssertEqual(result, "v1")
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertEqual(fetchCount, 0)
    }

    func testLaterV2Task422DoesNotInvokeV1Fallback() async {
        var fallbackCount = 0

        do {
            let _: String = try await VikunjaAPI.performV2TaskUpdate(
                updateV2: { throw VikunjaAPI.APIError.badStatus(422) },
                fetchUpdated: { "v2" },
                updateV1: {
                    fallbackCount += 1
                    return "v1"
                }
            )
            XCTFail("Expected the later v2 error to propagate")
        } catch {
            XCTAssertEqual((error as? VikunjaAPI.APIError)?.statusCode, 422)
        }

        XCTAssertEqual(fallbackCount, 0)
    }

    func testPostUpdateFetch422DoesNotInvokeV1Fallback() async {
        var fallbackCount = 0

        do {
            let _: String = try await VikunjaAPI.performV2TaskUpdate(
                updateV2: {},
                fetchUpdated: { throw VikunjaAPI.APIError.badStatus(422) },
                updateV1: {
                    fallbackCount += 1
                    return "v1"
                }
            )
            XCTFail("Expected the fetch error to propagate")
        } catch {
            XCTAssertEqual((error as? VikunjaAPI.APIError)?.statusCode, 422)
        }

        XCTAssertEqual(fallbackCount, 0)
    }

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
