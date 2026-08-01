# TypeScript and JavaScript Rules

- Do not add `skipLibCheck: true` to hide type errors. Maintain `strict`, `noUnusedLocals`, `noUnusedParameters`, `noImplicitReturns`, `noFallthroughCasesInSwitch`, and `esModuleInterop`; use LF line endings.
- Document functions, interfaces, and classes with JSDoc in the project-specified language, otherwise English. Use flat ESLint configuration (`eslint.config.mjs`), not legacy `.eslintrc` files.
- Default Prettier configuration: no semicolons, single quotes, ES5 trailing commas, 80-column print width, 2-space indentation, parenthesized arrow arguments, and LF endings.
- Await promises or explicitly discard them with `void`; call caught exceptions `error` or `err`; avoid type-impossible conditions and use-before-define. `any`, `null`, and common abbreviations are allowed where justified.
- Use pnpm and pin Node in `.node-version`. Keep the existing Jest or Vitest choice. Before introducing the first test runner, explain the Jest/Vitest trade-off and obtain the user's choice.
