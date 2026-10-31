# Bite Log

A food diary for iPhone that you talk to. Say or type what you ate ("two eggs
scrambled with a slice of sourdough"), or photograph your plate, and Bite Log
works out the calories, protein, fat and carbs.

Bring your own AI model: Claude, OpenAI, OpenRouter, or a model you run
yourself (llama.cpp, Ollama, LM Studio). Your food log stays with you: on your phone and in your own backups.

## Why Bite Log

Food tracking should help you understand what you eat, not make you anxious
about it. Some research has linked calorie-tracking apps with disordered
eating, and many of them are built to keep you hooked: streaks to protect,
badges to earn, reminders that nag, premium tiers to sell. Bite Log's goal is
to help people have a healthy relationship with food, so it has:

- **No gamification.** No streaks, badges, points, scores or reminders.
- **No upselling.** No ads, subscriptions or in-app purchases.
- **Complete privacy.** No account and no Bite Log server. Your log lives on
  your phone and in your own backups, never with us.

The person who built Bite Log doesn't need it to make money, and doesn't think
compromising anyone's health for a few extra dollars is worth it. The goal is
to help us be better, not profits.

Bite Log grew out of the local LLM movement: people running AI models on their
own hardware because your data should belong to you. So Bite Log has no AI of
its own. You connect a model you choose, Claude with your own API key or a
model on your own computer. Your health data only touches Apple (your phone
and its backups) and the AI you give permission to, never the author of this
app.

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
stored on your phone, and in its backups (iCloud or your computer) if you make
them; the developer never receives any of it. When you log something, the text or photo goes to the
model provider you chose, under that provider's terms. API keys are kept in
the iOS Keychain on this device only, never in backups. Full policy: [PRIVACY.md](PRIVACY.md).

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

## Disclaimer

Bite Log is not a medical device and does not give medical or nutrition
advice; its author is not a health professional. Its numbers are estimates
from the USDA database and an AI model, and can be wrong. Don't use it for
medical decisions such as dosing insulin or managing allergies. See
[TERMS.md](TERMS.md).

## License

MIT. See [LICENSE](LICENSE).
