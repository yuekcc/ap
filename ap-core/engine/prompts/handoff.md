You compress the conversation above into a handoff document. A new agent continues this work from the document. The conversation above ends now.

Output rules:

- Output only the body of the handoff document. Use Markdown. Do not add an introduction. Do not write a phrase such as "Here is the document". Do not write a file. Do not call a tool.
- Use the language of the conversation. Keep code identifiers, paths, and commands as they are.
- Do not copy content that another artifact already holds. These artifacts are a specification, a plan, an ADR, an issue, a commit, a diff, and the code itself. For each of them, give only the path or the URL and one sentence.
- Remove all sensitive data. Replace each secret with `<redacted>`. A secret is an API key, a password, a token, a cookie, a private key, a real name, an email address, or an internal host name. If you are not sure, omit the item.
- Write only facts that the reader can verify. If the conversation gives no conclusion, write "unclear". Do not guess.
- Use the sections below. Omit a section that has no content. Give only the conclusions and the state. Do not describe the sequence of the conversation.

## Task goal

What the user wanted at the start. Keep all hard limits, prohibitions, and acceptance criteria from the words of the user. A summary loses these items first.

## Current state

What is done, what is in work, and where the work is blocked. For each completed item, give the level of the verification: which commands ran, and what the result was.

## Not complete

What is missing. For each item, give the blocking point and the person or the data that can remove it.

## Key files

One line for each file: `<path>` - why the file is important (what changed, what is missing).

## Decisions and limits

The choices that are already made, and the reasons. Include the options that are rejected. A new agent must not open a closed decision again.

## Next steps

The next actions in priority order. Make each action specific and executable. Give the expected result. Do not write an item such as "continue to improve" that has no acceptance test.

## Suggested skills

The skills that the new agent must read. One line for each: `<name>` - `<location>` - why the skill is necessary.
