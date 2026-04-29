# macOS Menu Design Notes

agentd is intentionally menu-bar-first, so its primary interface should feel
like a native macOS utility instead of a miniature dashboard.

Current design guardrails:

- Keep menu item labels short and scannable. Long labels belong in setup
  windows or reports, not in the menu bar extra.
- Keep actions visible and disabled when unavailable so people can learn the
  app's command surface.
- Use familiar SF Symbols for destructive, update, permission, and file actions.
- Use system materials and semantic colors so the menu adapts to Light and Dark
  appearances.
- Keep Sparkle visible in the app surface: release builds show a normal
  "Check for Updates..." command, while local builds show "Updates Not
  Configured" instead of a dead-looking generic disabled item.

References:

- Apple Human Interface Guidelines: The menu bar
  https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- Apple Human Interface Guidelines: Menus
  https://developer.apple.com/design/human-interface-guidelines/menus
- Sparkle documentation: Programmatic setup
  https://sparkle-project.org/documentation/programmatic-setup/
- Sparkle documentation: Basic setup and security concerns
  https://sparkle-project.org/documentation/
