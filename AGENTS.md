# Project workflow

- After completing a user-requested implementation change, build and verify the Release package with `OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh`, then update `/Applications/OKVideoMac.app` as the primary installed app. The user normally launches from Applications and explicitly wants that copy kept current. Keep an existing Desktop copy synchronized as well.
- Preserve the previous Applications app in a timestamped project artifact backup before replacing it. Preserve subscriptions, preferences and viewing history. Verify the installed signature and executable against the packaged Release, and launch the Applications copy to confirm startup.
- Only deliver and install the verified Release app. A Debug build may be used for a quick compile check, but it must never replace the Desktop app or be presented as the deliverable.
- Never replace either installed copy when packaging or bundle verification fails.
