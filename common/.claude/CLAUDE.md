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

# Performance and Reliability

Maintain ~/Development/papercuts.md, a global log shared by all my AI sessions of anything that slowed down development. When you lose time to one mid-session, append date · symptom · fix · project. Check this file first when tooling fails mysteriously.
