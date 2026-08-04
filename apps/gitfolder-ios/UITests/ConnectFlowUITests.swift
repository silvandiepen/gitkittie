import XCTest

/// Sign-in has to happen inside the app. App Store review rejected GitKanban 1.0 (2)
/// under guideline 4 for handing the device flow off to Safari; GitFolder shipped the
/// same pattern, so these tests guard the fix here too.
final class ConnectFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The connect screen offers GitHub sign-in and says it stays in the app.
    func testConnectScreenOffersInAppGitHubSignIn() {
        let app = XCUIApplication()
        app.launch()

        let signIn = app.buttons["Sign in with GitHub"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "Connect screen should offer GitHub sign-in")
        XCTAssertTrue(
            app.staticTexts["Authorise on github.com without leaving the app — no token to create."].exists,
            "The footer should promise sign-in stays in the app"
        )
    }

    /// The reviewer's path. App Store review bounced 1.0 (3) under guideline 2.1(a)
    /// because they could not get past sign-in — the demo was the last item on the
    /// screen, below a token field. It must be reachable from a cold launch with no
    /// account, without scrolling past the sign-in options.
    func testDemoIsReachableWithoutAnAccount() {
        let app = XCUIApplication()
        app.launch()

        let demo = app.buttons["Open the demo repositories"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "The demo must be offered on the connect screen")
        XCTAssertTrue(demo.isHittable, "The demo must be reachable without scrolling past sign-in")

        demo.tap()
        XCTAssertTrue(app.staticTexts["travel-journal"].waitForExistence(timeout: 20), "The demo repos should open")
    }

    /// The regression guard for guideline 4: tapping sign-in must present GitHub inside
    /// the app rather than switching to Safari.
    ///
    /// Requires network — the device code comes from github.com. A failure here is either
    /// a real regression or an offline machine; the assertion messages distinguish them.
    func testSignInPresentsGitHubInsideTheApp() throws {
        let app = XCUIApplication()
        app.launch()

        let signIn = app.buttons["Sign in with GitHub"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()

        let waiting = app.staticTexts["Waiting for authorisation…"]
        guard waiting.waitForExistence(timeout: 30) else {
            throw XCTSkip("No device code from github.com — needs network to exercise this flow.")
        }

        // The browser must NOT have opened yet. GitHub cannot prefill the code (it drops
        // a user_code query param at its own session-verification redirect), so the user
        // has to read it here first — opening the page automatically would bury the code
        // behind the browser that needs it.
        XCTAssertFalse(app.webViews.firstMatch.exists, "GitHub must not open before the code is shown")
        XCTAssertTrue(app.buttons["Copy Code"].exists, "The code must be visible and copyable first")

        app.buttons["Open GitHub"].tap()

        // SFSafariViewController runs in-process, so its chrome is visible to the app's
        // element tree. If the app had called openURL instead, Safari would be a separate
        // process and the app would drop out of the foreground.
        let browserAppeared = app.webViews.firstMatch.waitForExistence(timeout: 30)
            || app.buttons["Done"].waitForExistence(timeout: 5)
        XCTAssertTrue(browserAppeared, "GitHub should open in an in-app Safari View Controller")
        XCTAssertEqual(app.state, .runningForeground, "Sign-in must not hand off to the default browser")
    }
}

/// Smoke coverage for the offline demo — the same launch hooks `@sil/app-release` drives
/// for App Store screenshots, so a break here breaks capture too.
final class DemoRepoUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDemoShowsRepositoryList() {
        let app = XCUIApplication()
        app.launchEnvironment["GITFOLDER_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["travel-journal"].waitForExistence(timeout: 20), "Demo repos should list")
    }

    func testDemoOpenRouteOpensRepository() {
        let app = XCUIApplication()
        app.launchEnvironment["GITFOLDER_DEMO"] = "1"
        app.launchEnvironment["GITFOLDER_DEMO_OPEN"] = "demo/travel-journal"
        app.launch()

        XCTAssertTrue(app.staticTexts["README.md"].waitForExistence(timeout: 20), "Repo contents should open directly")
    }
}
