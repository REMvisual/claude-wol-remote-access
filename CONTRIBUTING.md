# Contributing

Contributions are welcome.

## Reporting issues

- Use the bug report template for bugs, the feature request template for ideas.
- Check existing issues first.
- For Wake-on-LAN problems, please read
  [TROUBLESHOOTING](skills/wake-panel/reference/TROUBLESHOOTING.md) first — most
  failures in this domain have a specific, non-obvious cause that is already
  catalogued there, and the fix is often in firmware rather than in this code.

## Pull requests

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/my-improvement`).
3. Install your version locally:
   ```bash
   cp -r skills/wake-panel "$HOME/.claude/skills/wake-panel"
   ```
4. Verify it works by running `/wake-panel` in Claude Code.
5. Update `CHANGELOG.md`.
6. Open a pull request.

## Guidelines

- Keep the skill's voice and structure. It is written as gated stages for a
  reason: a silent failure at stage 3 surfaces as an inexplicable one at stage 6.
- No hard dependencies. Optional integrations must degrade gracefully.
- **No addresses, MACs, hostnames or keys in any file.** Site-specific facts do
  not belong in a skill that ships publicly.
- If you add a troubleshooting entry, lead with the *symptom*, then the cause.
  The reference is organised for someone who does not yet know what is wrong.
- No emojis.

## License

By contributing, you agree that your contributions will be licensed under the
MIT License.
