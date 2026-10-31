# Bite Log

A food diary for iPhone that you talk to. Say or type what you ate ("two eggs
scrambled with a slice of sourdough"), or photograph your plate, and Bite Log
works out the calories, protein, fat and carbs.

Bring your own AI model: Claude, OpenAI, OpenRouter, or a model you run
yourself (llama.cpp, Ollama, LM Studio). Your food log stays on your phone.

## What it does

- **Log by voice, text or photo.** Speech is turned into text on the phone.
  The model reads what you ate and looks every food up in the USDA database;
  the numbers come from the database, not the model.
- **Fix anything.** Change an amount, swap a food, or just say what was wrong
  ("it was half that much rice").
- **Your own foods.** Photograph a package label to add a product. Build
  recipes from an ingredient list, or photograph a recipe page.
- **Goals and history.** Daily calorie and macro targets, and a history of past days.

## Privacy

There is no Bite Log server and no account. Your log, photos and recordings are
stored on your phone. When you log something, the text or photo goes to the
model provider you chose, under that provider's terms. API keys are kept in
the iOS Keychain.

## Building

Needs Xcode 27+, iOS 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen                   # generates BiteLog.xcodeproj from project.yml
open bitelog.xcworkspace
```

Change settings in `project.yml`, not in Xcode's project editor; regenerating
overwrites the project. To run on your own phone, set `DEVELOPMENT_TEAM` and
the bundle IDs in `project.yml` to your own.

Tests: `xcodebuild -workspace bitelog.xcworkspace -scheme BiteLog -destination 'platform=iOS Simulator,name=iPhone 17' test`.
Tests that call a live model run only when `TEST_RUNNER_BITELOG_LIVE` is set
to a model server's URL (see the test files).

## Data

`Data/fdc.db` is built from [USDA FoodData Central](https://fdc.nal.usda.gov/)
(Foundation, SR Legacy and Survey foods), which is in the public domain.

## License

MIT. See [LICENSE](LICENSE).
