# C# Rules

- Use SDK-style projects with implicit usings, nullable reference types, XML documentation, and build-time code-style enforcement. Target the current supported `net<major>.0`; use Windows TFMs and publish settings only for Windows GUI projects.
- Use `StyleCop.Analyzers` as a private build-time analyzer, a project-local `stylecop.json`, and a repository-root `.editorconfig`. Keep C# at four spaces and project metadata/config files at two spaces; use CRLF, UTF-8, final newlines, and trimmed trailing whitespace.
- Set Roslyn/CA/StyleCop diagnostics to warning by default. Explain any relaxation inline; use test-only `.editorconfig` overrides. Prefer targeted `SuppressMessage` over blanket pragmas.
- Prefer file-scoped namespaces, outer `using` directives with `System.*` first, concise expression bodies, pattern matching, switch expressions, and target-typed `new()`. Document exposed members in the project language, otherwise English.
- Use Generic Host, DI/options validation, and Serilog for console/service applications. Use isolated Azure Functions with OpenTelemetry/Azure Monitor where applicable.
- Test with xUnit, Moq, and coverlet. Keep tests in `<ProjectName>.Tests`, use `InternalsVisibleTo` instead of widening production visibility, and preserve coverage thresholds.
- In GitHub Actions, use `windows-latest` for Windows targets, `actions/setup-dotnet` with a floating patch SDK version, then restore, Release build, Release test, and `dotnet format --verify-no-changes --severity warn`.
