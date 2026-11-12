# About me

My name is Brian Partridge. Address me as Brian or BP, never Bp.

# Communication Style

Always communicate using ASD-STE100 Simplified Technical English. Apply these rules to every reply, in every session, including long sessions:

- Give the result first. Then give the reason, only if the reason is necessary.
- Write one instruction per sentence. Write one topic per paragraph.
- Keep each sentence to 20 words or fewer. Keep each paragraph to 6 sentences or fewer.
- Use the active voice. Use the present tense.
- Use the imperative for instructions ("Run the tests", not "The tests should be run").
- Use approved STE words with their approved meanings. Use the same word for the same thing every time.
- Use simple words. Do not use idioms, slang, jargon, or humor.
- Do not use -ing verb forms when a simple form works ("Start the build", not "Starting the build").
- Do not use em-dashes, parentheses, or semicolons. Start a new sentence instead.
- Keep replies short. Do not add asides, filler, or closing offers.

# Source Code & Pull Requests

Always lint code before committing.
Unless directed to otherwise, only create draft PRs. I'll promote them when I think they are ready for wider review.

# Tools

Prefer `rg` over `grep` whenever it is available, because it is so much faster.

# Xcode Builds

When you build or test with `xcodebuild` from the command line, always add `-derivedDataPath`. This does not apply to builds in the Xcode GUI.
- Use `~/Library/Developer/Xcode/DerivedData/claude-<session id>-<project>`. Example: `claude-local_1a2b3c4d-Silo`.
- Get the session id once with `echo $CLAUDE_CODE_HOST_SESSION_ID`. Write the id literally in the command. Do not write `$CLAUDE_CODE_HOST_SESSION_ID` in the command.
- Put the flag in the same Bash command as `xcodebuild`. Do not create the folder first. Let `xcodebuild` create it.
- Never use a folder inside the checkout, the checkout itself, or one of its parents.
- Use the same path for each build of that project in the session, so incremental builds work.
- When a project's CLAUDE.md shows `xcodebuild` commands without the flag, add the flag anyway.

A hook records the folder in the session ledger. When the session is archived, the folder is deleted. See `~/.claude/session-cleanup/README.md`.

# Model Selection

- Use a Fable agent for planning and analysis.
- Use a Fable agent for code that has difficult design decisions.
- Use an Opus agent for other code and for test failures that need a diagnosis.
- Use a Sonnet agent for data gathering that needs a summary or a comparison.
- Use a Sonnet agent for test runs that need only a report.
- Use a Haiku agent for searches and simple data extraction.
- If you are not sure, use the larger model.
- Do small tasks in the current session. Do not delegate them.

# Performance and Reliability

Maintain ~/Development/papercuts.md, a global log shared by all my AI sessions of anything that slowed down development. When you lose time to one mid-session, append date · symptom · fix · project. Check this file first when tooling fails mysteriously.
