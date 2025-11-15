# Repository Guidelines

## Project Structure & Module Organization
SwiftUI app code lives in `pdf-converter`, which contains the `PDFConverterApp.swift` entry point, the Core Data stack in `Persistence.swift`, view hierarchies such as `ContentView.swift`, and assets under `Assets.xcassets`. Unit tests are isolated in `pdf-converterTests`, UI automation lives in `pdf-converterUITests`, and the project definition is tracked in `pdf-converter.xcodeproj`. Keep new modules self-contained in their own folders and expose them through lightweight view models to minimize coupling.

## Build, Test, and Development Commands
Use Xcode for everyday development (`xed .`) or automate with the CLI: `xcodebuild -scheme pdf-converter -destination 'platform=iOS Simulator,name=iPhone 15' build` compiles the app, while `xcodebuild test -scheme pdf-converter -destination 'platform=iOS Simulator,name=iPhone 15'` runs both unit and UI suites. When debugging Core Data, `xcrun simctl get_app_container booted com.roguewaveapps.pdf-converter data` locates the sandbox for inspecting stored PDFs.

## Coding Style & Naming Conventions
Follow standard Swift conventions: four-space indentation, `PascalCase` for types, `camelCase` for properties, and enum cases in lower camel case (mirroring `Tab` and `ToolAction`). Prefer SwiftUI composition over massive views; extract helpers into extensions and keep files under ~300 lines. Type erasure and dependency injection should happen near the view boundary so that `ContentView` stays declarative.

## Testing Guidelines
Functional scenarios belong in `PDFConverterTests.swift`, with method names formatted as `testScenario_expectedResult`. UI flows that touch scanning, tab switching, or biometrics should go into `PDFConverterUITests.swift` using launch arguments to stub hardware access. Maintain parity by adding at least one UI test for every major user-facing tool and ensure the simulator runs pass with `xcodebuild test` before opening a PR.

## Commit & Pull Request Guidelines
Commits in this repo use short, imperative subjects (e.g., “Simplify signature placement”) and bundle one logical change; keep them under 72 characters. PRs must describe the motivation, summarize testing output, link to any Jira/task IDs, and include screenshots or screen recordings for UI additions so reviewers can validate tab-bar interactions quickly. Rebase on the latest `main` before requesting review.

## Security & Configuration Tips
The app touches photos, documents, and biometric preferences, so never commit sample data or simulator containers. Maintain the entitlements file only through Xcode, rotate API keys via environment variables, and gate experimental scanning flows behind feature flags so production builds remain stable.
