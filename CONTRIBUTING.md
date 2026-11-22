# Contributing to Paddock

Paddock is proprietary software. Its source is public only for transparency
and is not licensed under an open-source license.

By submitting a contribution, you represent that you have the right to
submit the work and grant John Gowelle the perpetual, worldwide,
non-exclusive, royalty-free right and license to use, copy, modify,
distribute, and sublicense the contribution as part of Paddock or under
another license selected by the owner.

Do not submit confidential, third-party, patented, or GPL/LGPL code unless
the contribution is approved in writing and is compatible with Paddock's
proprietary distribution and its third-party obligations.

Contributions that have not been accepted remain owned by their authors.

## Reporting a problem or an idea

Open an issue from the templates at
<https://github.com/gowelle/paddock/issues/new/choose>. For a problem, the
Paddock version (About Paddock), your macOS version, and what
`paddock status` prints save a round of questions. Leave
passwords, tokens and private paths out of what you paste.

Report a security problem privately, at
<https://github.com/gowelle/paddock/security/advisories/new>, not in a public
issue.

## Sending a change

1. Say what you plan in an issue first, unless it is a small fix. Paddock
   leaves some things out on purpose (see the roadmap in
   `docs/superpowers/plans/`).
2. Build and test as the [README](README.md#building-from-source) describes.
   `swift test --filter '^PaddockCoreTests\.'` runs the unit tests, which need
   nothing outside the repository; they also run on every push and pull
   request.
3. Keep to the code's habits: logic lives in `PaddockCore` with tests, views
   hold none; tests never touch your real Paddock home or `/Applications`;
   nothing is installed with Homebrew or MacPorts.
4. Open a pull request against `main` that says what changed and how you
   checked it.
