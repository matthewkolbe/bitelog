import XCTest

/// First-run setup, then logging with the connected model. Set
/// TEST_RUNNER_BITELOG_SHOTS=<dir> to save screenshots there;
/// TEST_RUNNER_BITELOG_LIVE=http://<server>:<port>/v1 connects to that server and
/// goes on to log an entry, change it, and build a recipe.
final class SettingsUITests: XCTestCase {
    let env = ProcessInfo.processInfo.environment

    @MainActor
    func testSetupThenLog() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        // no model yet: setup is the only screen
        XCTAssertTrue(app.staticTexts["Bring your own AI model"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Today"].exists)
        shot(app, "0-intro")
        app.buttons["Connect a model"].tap()
        shot(app, "1-setup")

        // a navigation row's label is "title, subtitle"
        let qwen = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your own computer'")).firstMatch
        if let dir = env["BITELOG_SHOTS"], !qwen.waitForExistence(timeout: 5) {
            try? app.debugDescription.write(toFile: dir + "/tree.txt", atomically: true, encoding: .utf8)
        }
        qwen.tap()
        let address = app.textFields["Server address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let connect = app.buttons["Connect"]
        XCTAssertFalse(connect.isEnabled, "Connect needs a model id first")
        shot(app, "2-connect")

        // the step-by-step guide, with the memory each model needs
        app.buttons["Step-by-step guide"].tap()
        XCTAssertTrue(app.staticTexts["Gemma 4 26B-A4B (recommended)"].waitForExistence(timeout: 5))
        shot(app, "2-guide")
        app.swipeUp()
        shot(app, "2-guide-more")
        app.swipeUp()
        shot(app, "2-guide-agent")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(address.waitForExistence(timeout: 5))

        guard let live = env["BITELOG_LIVE"] else { return }
        address.tap()
        address.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        address.typeText(live + "\n")  // return closes the keyboard
        let model = app.textFields["Model id"]
        model.tap()
        model.typeText((env["BITELOG_MODEL"] ?? "qwen38") + "\n")
        connect.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 120), "never connected to \(live)")
        shot(app, "3-connected")

        // log an entry with that model
        app.tabBars.buttons["Today"].tap()
        app.buttons["Type instead"].tap()  // the Simulator has no speech model
        let box = app.textFields["What did you eat?"]
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        box.typeText("150 grams of plain greek yogurt and a banana")
        app.buttons["Log it"].tap()
        shot(app, "6-thinking")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'greek yogurt'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let done = NSPredicate(format: "label MATCHES '.*[0-9]+$'")  // done rows end with their kcal
        XCTAssertTrue(app.buttons.matching(done).firstMatch.waitForExistence(timeout: 300), "entry never finished")
        shot(app, "7-logged")
        app.buttons.matching(done).firstMatch.tap()  // opens in place
        let changeButton = app.buttons["Change this entry"]
        XCTAssertTrue(changeButton.waitForExistence(timeout: 5))
        shot(app, "8-entry")

        // change it by text
        changeButton.tap()
        let change = app.textFields.firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.tap()
        change.typeText("the yogurt was 200 grams")
        shot(app, "9-change")
        app.buttons["Change it"].tap()
        let changed = app.staticTexts["Changed: “the yogurt was 200 grams”"]
        XCTAssertTrue(changed.waitForExistence(timeout: 300), "the change was never applied")
        shot(app, "10-changed")

        // a recipe, broken down by the model
        app.tabBars.buttons["Settings"].tap()
        let foods = app.buttons["My foods and recipes"]
        XCTAssertTrue(foods.waitForExistence(timeout: 5))
        foods.tap()
        app.buttons["Add a recipe"].tap()
        let name = app.textFields["Name, e.g. My miso soup"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Breakfast oats")
        let ingredients = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH '1 tbsp'")).firstMatch
        ingredients.tap()
        ingredients.typeText("40 g rolled oats, 200 g whole milk, 1 banana")
        shot(app, "11-recipe")
        app.buttons["Work it out"].tap()
        let save = app.buttons["Save recipe"]
        XCTAssertTrue(save.waitForExistence(timeout: 300), "no breakdown")
        shot(app, "12-review")
        save.tap()
        XCTAssertTrue(app.staticTexts["Breakfast oats"].waitForExistence(timeout: 10))
        shot(app, "13-foods")
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = env["BITELOG_SHOTS"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
