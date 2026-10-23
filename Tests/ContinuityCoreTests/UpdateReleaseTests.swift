import XCTest
@testable import ContinuityCore

final class UpdateReleaseTests: XCTestCase {
    func release(_ tag: String, branch: String, preview: Bool = true, url: String = "https://github.com/Clascheurduturfu/galaxy-continuity-mac/releases/tag/test") throws -> GitHubRelease {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name":tag, "target_commitish":branch, "html_url":url,"draft":false,"prerelease":preview,"assets":[]])
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
    func testSemanticBetaOrderingAndStablePromotion() {
        XCTAssertLessThan(ReleaseVersion("v1.0-beta.2")!, ReleaseVersion("1.0-beta.10")!)
        XCTAssertLessThan(ReleaseVersion("1.0-beta.10")!, ReleaseVersion("1.0-rc.1")!)
        XCTAssertLessThan(ReleaseVersion("1.0-rc.1")!, ReleaseVersion("1.0")!)
        XCTAssertNil(ReleaseVersion("not-a-version"))
        XCTAssertNil(ReleaseVersion(""))
        XCTAssertNil(ReleaseVersion("1..0"))
    }
    func testPreviewCannotSelectMainOrForeignRelease() throws {
        let values = try [release("1.0-beta.3", branch:"preview"), release("8.0",branch:"main",preview:false), release("9.0",branch:"preview",url:"https://example.com/releases/tag/x")]
        XCTAssertEqual(GitHubRelease.newest(values,channel:.preview,after:"1.0-beta.2")?.tag_name,"1.0-beta.3")
        XCTAssertEqual(GitHubRelease.newest(values,channel:.stable,after:"1.0")?.tag_name,"8.0")
        XCTAssertNil(GitHubRelease.newest(values,channel:.preview,after:"1.0-beta.3"))
    }
    func testAssetMustHaveDigestAndExactRepositoryAPI() throws {
        let object:[String:Any] = ["name":"GalaxyContinuityLab-1.0-beta.3-macOS-arm64.zip","url":"https://api.github.com/repos/Clascheurduturfu/galaxy-continuity-mac/releases/assets/123","size":100,"digest":"sha256:"+String(repeating:"a",count:64)]
        let good = try JSONDecoder().decode(GitHubRelease.Asset.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertTrue(good.trustedAPIURL); XCTAssertNotNil(good.sha256)
        var bad = object;bad["url"]="https://example.com/repos/Clascheurduturfu/galaxy-continuity-mac/releases/assets/123";bad["digest"]="sha256:no"
        let rejected = try JSONDecoder().decode(GitHubRelease.Asset.self,from:JSONSerialization.data(withJSONObject:bad))
        XCTAssertFalse(rejected.trustedAPIURL); XCTAssertNil(rejected.sha256)
    }
}

final class UpdateRedirectTests: XCTestCase {
    func testAuthorizationNeverCrossesGitHubAPIOrigin() {
        XCTAssertTrue(GitHubUpdateRedirect.mayKeepAuthorization(URL(string: "https://api.github.com/repos/test")!))
        XCTAssertTrue(GitHubUpdateRedirect.mayKeepAuthorization(URL(string: "https://api.github.com:443/repos/test")!))
        for text in ["https://api.github.com:8443/x", "https://user@api.github.com/x", "http://api.github.com/x", "https://api.github.com.evil.invalid/x", "https://github.com/x", "https://release-assets.githubusercontent.com/x"] {
            XCTAssertFalse(GitHubUpdateRedirect.mayKeepAuthorization(URL(string: text)!))
        }
        XCTAssertTrue(GitHubUpdateRedirect.allowed(URL(string: "https://release-assets.githubusercontent.com/x")!))
        XCTAssertFalse(GitHubUpdateRedirect.allowed(URL(string: "https://api.github.com:8443/x")!))
    }
}
