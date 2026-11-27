# Tasks onboarding: sign-in and a first board

Design for how someone gets from installing Tasks (GitKanban) to a working board, on Mac and on
iPhone/iPad. Nothing here is built yet. The current-flow section describes `main` as of
2026-11-27. The rest is a proposal, and the decisions it needs are listed at the end with a
recommended answer for each.

> **Not part of this doc:** the "Sign in to your Apple Account / Apple Media Services" prompt that
> a Mac build can show at launch. That is not a Git sign-in. It comes from the update check calling
> `AppTransaction` on a copy that was not installed from the App Store, and GITKITTIE-110 fixes it.
> Tasks never asks for an Apple Account password, and nothing below changes that.

## 1. Today's first run, from the code

Shared model: `swift/GitKanbanKit/Sources/GitKanbanKit/AppModel.swift` (Connect, OAuth, repos,
`openBoard`, `createProject`). Screens: `apps/gitkanban-macos/GitKanban/Board/RootView.swift` and
`apps/gitkanban-ios/GitKanban/Board/RootView.swift` (`ConnectView`, `AddRepoView`,
`BoardPickerView`, `FolderLevel`). Git hosts are reached only through GitPont.

### What a person sees

**Mac.** The Connect screen appears while there is no connection and no local folder (`hasHome`).
It shows, top to bottom:

1. **Try the Demo**. This is the prominent filled button.
2. **Open a Folder…**: a plain folder with no git. Its errors are discarded (`try?`).
3. **Sign in with GitHub**: GitHub's OAuth **device flow** (`startGitHubOAuth`, OAuth App client
   `Ov23li24tWFt7qLuLqCe`, scope `repo`). The screen shows an 8-character code and opens
   github.com/login/device in the **default browser** straight away. The person types or pastes the
   code there and approves, and the app polls until it has a token. On the Mac the code is not
   copied for them, and the app does not come back to the front afterwards.
4. **Use a token instead**: a segmented control with GitHub, GitLab.com and GitLab (self-hosted),
   a server URL field and a `SecureField` for a personal access token. Nothing explains which scopes
   to pick or where to create the token.

**iPhone/iPad.** The Connect screen is a single long `Form`:

- "No account?" with **Open the demo board**
- "Folder on your Mac" (a Bonjour/Tailscale folder server)
- a Provider menu
- **Sign in with GitHub** (device flow)
- a token field with **Connect with Token**

During the device flow the code is copied automatically. **Open GitHub** shows the page in an
`SFSafariViewController`. Since iOS 11 that view does not share Safari's cookies, so the person has
to sign in to GitHub again there, two-factor step included, before entering the code. The footer
asks for a token with "repository read/write scope". That is wrong for GitLab: writing files
through the GitLab API needs the `api` scope.

**After sign-in (both).** The token is saved to the shared keychain item as a bare access-token
string, and the login goes to defaults. The app loads **every repository** the account can see,
sorted by last update. The sidebar or home then says "No Boards — Add a repository or open a
folder". **Add Repository** lists all repos with a filter. Tapping one adds it to the sidebar at
once, then opens a folder browser: "Use repository root as a board" plus a tree of every folder,
each with a checkbox. The app does not show which folders are boards. When a repo already has
boards, a quick picker offers the folders next to them.

**Opening a board.** `RemoteBoardStore.loadBoard` resolves lanes from the folder's README and its
parent README:

- A folder with cards but no config triggers `boardNeedsSetup`. The setup sheet then infers lanes
  from the subfolders (`detectConfig`). This is the only "make this a board" path that exists
  today, and it only appears when there are already cards.
- A folder with no config and no cards gives no lanes. The board shows "No cards in *folder* —
  This folder has no cards in any lane. If the board lives in another folder, pick it with Browse
  Boards…". It has no **New Task** button, because there is no lane to put a task in.

**Creating anything.** `createProject` writes `<Name>/README.md` with five default lanes and opens
it. It is reachable only from the board's "…" menu or the sidebar's **+** menu, and the **+** menu
shows it only once a board is already open (`selectedProject != nil`). Tasks never creates a
repository. GitPont can (`createRepository` exists for GitHub, GitLab, Forgejo/Gitea and
Bitbucket), but nothing calls it.

### Dead ends and problems

| # | Where | What happens |
|---|---|---|
| D1 | No suitable repo | The repo list offers no "Create a repository" option. The person has to leave for github.com, create one, and come back. |
| D2 | Mac, came back from github.com | `AddRepoView` loads repos only when the list is empty, and the Mac has no refresh button or pull-to-refresh. The new repo does not appear until the app is relaunched. |
| D3 | New or empty repo picked | The root or a folder without a README config opens as "No cards in …" with no lanes and no **New Task**. The way out is a **New Project…** item in a menu nobody is pointed to, and the empty board stays in the sidebar afterwards. |
| D4 | Repo with zero commits | Folder listings fail silently (`try?` gives "No subfolders"). Whether `createProject`'s first write lands on an empty repo is untested on each provider. GitHub's Git Data API, which batch commits use, refuses empty repos. |
| D5 | Folder browser | The person must already know which folder is a board. A wrong pick leads to D3. |
| D6 | Add Repository → Cancel | The repo was added to the sidebar before any board was chosen, so it stays there with a "Browse boards…" placeholder. |
| D7 | GitLab, Codeberg, Gitea and others | Token only. There is no link to the provider's token page and no scope guidance, and the iOS scope text is wrong for GitLab. GitPont also supports Forgejo/Gitea and Bitbucket, but `ProviderChoice` does not offer them. |
| D8 | iPhone sign-in | The device flow runs in an `SFSafariViewController` with no Safari cookies, so the person signs in to GitHub from scratch and then types a code: two hand-offs for one sign-in. |
| D9 | Mac sign-in | The code page opens in the default browser and the person has to find their way back to Tasks. |
| D10 | Token expired or revoked | There is no "Sign in again" state. Errors appear as generic messages, and the only fix is Sign Out followed by Connect. Only a bare access token is stored (no refresh token or expiry), so OAuth tokens that expire, like GitLab's 2-hour tokens, cannot work as stored today. |
| D11 | One account at a time | Connecting GitLab means signing out of GitHub, and signing out removes every provider board from the sidebar. |
| D12 | No git account, iPhone | Only the demo or a Mac folder server is available. There is no local or iCloud board on iOS, and no way to keep what was made in the demo. |
| D13 | Mac "Open a Folder…" on Connect | A failure is swallowed, and the button seems to do nothing. |
| D14 | Hierarchy | The demo is the primary button on the Mac. That is right for App Review and wrong for someone who came to use their own board. |

Doc drift seen on the way: `apps/gitkanban-macos/docs/Features.md` still says the Mac app "clones
the chosen repo into an app-owned checkout". It works over the provider API through GitPont now.

## 2. Proposed flows

Principles:

- One obvious action per screen.
- System sheets for anything that signs in.
- Every write to a provider is something the person confirmed.
- Every empty state has a way forward.
- The board that gets created is exactly the board-repo contract (`tasks/README.md` shape), so
  agents and other apps can read it at once.

### 2.1 First screen (Mac window and iPhone)

> **Tasks** *(the wordmark)*
> Your tasks, as files in your own Git repository.
>
> **[ Sign in with GitHub ]** *(filled, the one primary button)*
> **Other Git provider…** *(plain button: GitLab, self-hosted GitLab, Codeberg/Forgejo/Gitea)*
> **Start without an account** *(plain button, see 2.6)*
>
> *Try the demo board* *(text link, bottom)* · *(iPhone only)* *Folder on your Mac* *(text link)*

No form, no token field, no provider picker on the first screen. The demo stays one tap away for
App Review and for the curious, but it is not what the screen leads with.

### 2.2 Sign in

**GitHub** (details in section 3):

1. Tap **Sign in with GitHub**. Tasks gets a device code and puts it on the clipboard.
2. The system sign-in sheet opens (`ASWebAuthenticationSession`). Above the page it says: *"Tasks"
   wants to use "github.com" to Sign In*. The sheet shares Safari's cookies, so someone already
   signed in to GitHub skips the password, and passkeys and Password AutoFill work.
3. Under the sheet, the app says in one line: "Paste the code **WDJB-MJHT** on GitHub, then
   approve." A **Copy** button sits next to the code.
4. The person pastes, presses Continue, then Authorize.
5. Tasks is polling all along. When the token arrives, Tasks closes the sheet itself
   (`session.cancel()`) and moves on. There is no "come back to the app" step.
6. Errors appear in place:
   - "GitHub said no — nothing was shared." with **Try Again**
   - "The code expired." with **New Code**
   - "Can't reach GitHub." with **Try Again**

**GitLab.com**: one tap. The system sheet opens GitLab's authorize page (OAuth with PKCE, no
secret). After approval the sheet closes on the `gitkittie-tasks://oauth/gitlab` callback and
Tasks is signed in.

**Self-hosted GitLab, Forgejo/Gitea, Codeberg** (Codeberg only if registered, see 3.3): a sheet
titled **Connect to your Git server**.

1. Server address: "git.example.com". Tasks checks it and names what it found: "GitLab 17.5" or
   "Forgejo".
2. **Create a Token on git.example.com**. This opens the provider's new-token page in the system
   browser sheet with the name and scopes filled in. GitLab supports
   `/-/user_settings/personal_access_tokens?name=Tasks&scopes=api`; for Forgejo/Gitea Tasks names
   the scopes to tick.
3. A token field with a **Paste** button, and **Connect**.

Scopes are stated in plain words: "Tasks needs to read and write repositories (scope `api`)."

Everything is stored in the Keychain (shared access group) as a GitPont `GitCredential`, with the
refresh token and expiry kept. A token that stops working puts a quiet "Sign in again" row in the
sidebar instead of a generic error.

### 2.3 After sign-in: choose or create a board

Tasks loads the account's repos, then checks the likely candidates for a board: a root or
first-level `README.md` with `config: board` or `config: project` and lane folders. It reads only
directory listings and the README, never every card. The screen, **Your boards**:

> **Boards we found** *(only if any)*
> silvandiepen/tasks — 47 boards · **Add**
>
> **[ Create a New Board ]** *(filled; primary when nothing was found)*
> **Use Another Repository…** *(plain)*

- **Found boards**: **Add** goes to the existing quick picker, with that repo's board folders
  pre-checked.
- **Create a New Board** → 2.4.
- **Use Another Repository…** → the current repo list, which now has a refresh button on the Mac
  (D2). Each row shows "Board" or nothing. Picking a repo that is not a board → 2.5.

The repo goes into the sidebar only once a board in it is chosen (D6).

### 2.4 Create a new board repository

One sheet, **New Board**:

| Field | Default | Notes |
|---|---|---|
| Name | "tasks" | Becomes the repo name. Checked live with GitPont `repository(_:)`, which returns 404 when the name is free. "You already have a repository called tasks — Use It Instead". |
| Owner | the signed-in account | Organisations appear only if Sil picks the org option (Q5). |
| Board name | "My Tasks" | The first project folder. Its first letters become the card ID prefix (`MT-001`). |
| Lanes | Simple: To do · Doing · Done | The other choice is "Agent workflow: To do · In Progress · In Review · Testing · Done", the board contract's five lanes (Q7). |
| Private | on | Shown as a toggle with the line "Only you and people you invite can see it." |

Footer, one line: "Creates a private repository on GitHub with a README that describes the board,
so people and agents can use it too."

**[ Create Board ]** then:

1. `createRepository(name, isPrivate: true, initializeWithReadme: true)`. Initialising matters: it
   gives the repo a default branch, so step 2 can be a single batch commit on every provider (D4).
2. One `commitFiles` commit, "Set up Tasks board", containing:
   - `README.md`: `config: board` frontmatter (the chosen lanes, priorities P0–P3, the default
     types, `users:` with the signed-in login as `kind: human`, `review_path: review`) and a short
     body describing the format (Q8).
   - `<Board name>/README.md`: `config: project`, `project: <Board name>`. It inherits the lanes.
   - `<Board name>/<n>. <Lane>/.gitkeep` for every lane, so the folders exist as the contract
     requires. The card loader already skips anything that is not `.md`.
   - `<Board name>/1. To do/<PREFIX>-001-<slug>.md`: the first card (Q9), with valid contract
     frontmatter.
3. Add the repo with that board selected and open it. Progress shows in place: "Creating
   repository… Setting up the board… Opening…".
4. If step 1 succeeded and step 2 failed, the screen says so ("The repository was made but the
   board files weren't written") and offers **Try Again**, which reruns step 2 on the existing
   repo. Tasks never leaves a half-made repo it then forgets.

The templates (root README, project README, first card) belong in `packages/gitkanban-core` as the
source of truth, mirrored in Swift. They do not belong in a view.

### 2.5 Make an existing repository (or folder) a board

When the picked repo or folder has no board config, the board does not show "No cards in …".
It shows **Set Up a Board Here**:

> **This repository isn't a board yet.**
> Tasks can add a README and lane folders. Nothing else in the repository changes.
> Where: **Repository root** · **New folder: Tasks/** *(default when the root has other files)*
> Lanes: Simple / Agent workflow
> **[ Make It a Board ]**

This is one commit with the same files as 2.4, minus the repo. If the folder already has cards in
subfolders, Tasks goes to the existing `detectConfig` setup sheet instead, which infers lanes from
those folders. The same action is offered when a board folder that is already in the sidebar
loses its config (D3).

### 2.6 Start without an account, and connect to Git later

**Start without an account** creates a board in a folder:

- **Mac**: `iCloud Drive ▸ Tasks ▸ <Board>` by default, or **Choose Folder…**. This builds on the
  existing `LocalFolderSource`.
- **iPhone/iPad**: the app's iCloud Drive container. This is new: `LocalFolderSource` with file
  coordination on iOS, plus the iCloud Documents capability.

The files are the same as 2.4 (root README, project, lanes, first card), so the folder is already a
valid board repo minus the `.git`. A short line says: "Stored in iCloud Drive. Connect a Git
repository any time for history and agent access."

**Connect to Git later**: the board's menu gets **Move to a Git Repository…**.

1. Sign in, if needed.
2. Create a repository (2.4 without the template step) or choose an empty one.
3. Upload the folder's files in one commit.
4. Switch the sidebar entry from folder to provider.
5. Ask "Keep the iCloud copy?". The recommended answer is to keep it, read-only, until the person
   removes it.

Limits to say plainly in the UI and the docs: iCloud Drive has no history. Two devices editing the
same card offline can produce a "conflicted copy" file, and Tasks should list those under the
board rather than hide them.

### 2.7 Demo

The demo stays as it is: a full in-memory board, offline, no sign-in. Its toolbar gets one quiet
action, **Make My Own Board**, which leads to 2.1 minus the demo link. Copying demo cards into a
real board is not worth building.

## 3. Sign-in: how to make it Apple-native

What "Apple-native" means here:

- The provider's own page runs inside `ASWebAuthenticationSession`, the system sign-in sheet. It
  shares Safari's cookies, so passkeys and AutoFill work.
- Secrets live in the Keychain only.
- There is no password field of our own, ever.
- There is no embedded `WKWebView` login.
- The person is never sent to the default browser to find their own way back.

### 3.1 Per provider: what each one allows

| Provider | Flow | Secret needed? | Scopes for Tasks (incl. creating a repo) | Token lifetime | Registration |
|---|---|---|---|---|---|
| **GitHub** (OAuth App, existing) | Device flow (today). Also web flow with PKCE (S256). | Device flow: **no**. Web flow: **yes**. GitHub requires `client_secret` at the token exchange even with PKCE. | `repo` (private repos: read, write, create). `read:org` only if org owners are wanted. | No expiry unless revoked | Exists: client `Ov23li24tWFt7qLuLqCe`, device flow enabled |
| GitHub (GitHub App) | Web or device flow, user-to-server tokens | Refresh needs the secret, except device-flow tokens | Fine-grained, per installation. A new repo is not in the installation unless it covers "All repositories". | 8 h, refresh 6 months | New app. Not recommended: per-repo installs make "create a repo then use it" awkward. |
| **GitLab.com** | OAuth with PKCE (GitPont supports `.oauthPKCE`) | **No**: register as a non-confidential app | `api` (`write_repository` is git-over-HTTP only and cannot write through the API) | 2 h access, refresh token | **Sil registers** a GitLab.com application |
| Self-hosted GitLab | Same, but per instance | No | `api` | 2 h | Every server needs its own app, so: **token** |
| Forgejo / Gitea / Codeberg | OAuth with PKCE, public client (GitPont `ForgeProvider`) | No | repository read/write, user read | ~1 h, refresh | Codeberg: Sil could register one app. Other servers: token. |
| Bitbucket Cloud | GitPont: OAuth "not configured". Consumers need a secret. | Yes | — | — | Out of scope for now. Token (Atlassian API token) later. |

### 3.2 GitHub: recommendation

Keep the **device flow**, presented natively (2.2): code on the clipboard, the page in
`ASWebAuthenticationSession` (custom callback scheme `gitkittie-tasks`, never hit), and the sheet
closed by Tasks when polling succeeds. No secret ships in the app and no server is involved. The
cost is one paste.

The truly one-tap alternative is the web flow with PKCE in the same sheet, but GitHub still wants
the client secret at the exchange. That leaves two ways to do it, both rejected for now:

- **Embed the secret in the app.** Against the no-secrets rule, and extractable.
- **A token-exchange Cloudflare Worker.** It holds the secret, swaps `code + code_verifier` for a
  token and keeps nothing. It would be a new worker: the relay's rule "never handles git tokens"
  should stay. The token would pass through our server once, which changes the privacy story ("no
  data leaves your device…") and the App Store privacy label.

Recommendation: not now (Q1). Revisit if testers stumble on the code.

The scope stays `repo`. Before the sheet opens, Tasks says why in one line: "GitHub will ask to let
Tasks read and write your repositories. Tasks only touches the boards you add."

### 3.3 Other providers: recommendation

- **GitLab.com**: OAuth with PKCE in the system sheet (one tap). Sil registers the application.
- **Self-hosted GitLab and Forgejo/Gitea**: the guided token sheet (2.2).
- **Codeberg**: one registered app, only if Sil wants Codeberg named in the list (Q3).
- **Bitbucket**: later.

Store the full `GitCredential` through GitPont's `KeychainCredentialStore` and refresh before
expiry (`refreshCredential`). That is required for GitLab and Forgejo OAuth (D10).

### 3.4 Sign in with Apple, Apple Account, iCloud

- **Sign in with Apple has no role.** Tasks has no account of its own. The Git provider is the
  account, and Sign in with Apple cannot give access to GitHub or GitLab. App Store guideline 4.8
  does not require it: apps that are a client for a specific third-party service, where the person
  signs in to that service to reach their own content, are exempt.
- **iCloud (2.6)** uses the Apple Account already on the device through iCloud Drive. There is no
  sign-in UI. If iCloud Drive is off, the screen says "Turn on iCloud Drive in Settings to keep
  boards in iCloud" and offers **Choose Folder…** on the Mac.
- The App Store sign-in prompt seen at launch is unrelated (GITKITTIE-110).

### 3.5 What Sil needs to register or decide

| Item | Where | Notes |
|---|---|---|
| GitHub OAuth App | github.com → Settings → Developer settings | Exists. Check that its name, logo and homepage read "Tasks by GitKittie" on the consent page. Only if Q1 = worker: add a callback URL and put the secret in the worker. |
| GitLab.com application | gitlab.com → Preferences → Applications | Name "Tasks". Redirect `gitkittie-tasks://oauth/gitlab`. **Confidential: off.** Scope `api`. The client id goes into the app; it is not a secret. |
| Codeberg OAuth2 app | codeberg.org → Settings → Applications | Only if Q3 includes Codeberg. Public client, redirect `gitkittie-tasks://oauth/codeberg`. |
| iCloud Documents capability + container `iCloud.app.hakobs.gitkanban` | Developer portal via the `_appstore` hub, both bundle ids, plus `project.yml` | Only if Q10 includes iPhone. |
| URL scheme | — | Nothing to add. `gitkittie-tasks` is already registered, and `ASWebAuthenticationSession` catches its own callback either way. Route `oauth/*` so the new-task handler ignores it. |

### 3.6 App Store review

- The demo stays reachable without an account. The review notes should say so, plus how to test
  sign-in (a test GitHub account with one board repo).
- Guideline 4.8 exemption: client of a third-party service. No Sign in with Apple needed.
- No account deletion requirement (5.1.1(v)), since Tasks creates no account of its own. The note
  should still say that the repository Tasks creates belongs to the person's GitHub account.
- `ASWebAuthenticationSession` is the sign-in mechanism Apple expects, and it works in the
  sandboxed Mac app. A link to create a free GitHub account is fine (no payments involved).
- A token-exchange worker (Q1 option) would mean declaring that data in the privacy label.
- iCloud Drive storage is ordinary user data in the user's own iCloud. Nothing to declare.

## 4. Implementation cards

To file once the questions are answered. GitPont work comes first, per the repo rule that GitPont
is the only gateway to a git host.

1. **GitPont: new-repo board bootstrap works on every provider.** A test proves
   `createRepository(initializeWithReadme: true)` followed by `commitFiles` on GitHub, GitLab and
   Forgejo. If Q5 = orgs: a "where can I create repositories" call (account + orgs/groups) with
   `read:org` on GitHub.
2. **Credentials: store `GitCredential`, refresh, "Sign in again".** Uses GitPont
   `KeychainCredentialStore`, migrates the bare token, and handles the 401 state (D10).
3. **Native sign-in.** A small `WebSignIn` wrapper around `ASWebAuthenticationSession`
   (GitKanbanKit, anchor passed in by each app). GitHub device flow in the sheet with auto-close.
   GitLab.com PKCE. The guided token sheet for servers (D7–D9).
4. **Board template in `gitkanban-core`** (TS) **and its Swift mirror.** Root README, project
   README, lane `.gitkeep` files, first card. Tests compare the output with the contract.
5. **Create a board repository** (model + Mac and iOS sheets, 2.4) (D1, D4).
6. **Choose or make a board.** "Boards we found" detection, Board labels in the repo list, refresh
   on the Mac, add the repo only once a board is chosen, and **Set Up a Board Here** replacing the
   empty state (2.3, 2.5) (D2, D3, D5, D6).
7. **First screen redesign** (2.1, 2.7) (D14), plus the Open a Folder error fix (D13).
8. **Start without an account** (iCloud Drive) **and Move to a Git Repository** (2.6) (D12).
9. **Multiple accounts at once** (D11). Only if Q11 says so, and kept separate.

Order: 1 → 2 → 3 and 4 in parallel → 5 → 6 → 7. Then 8, then 9.

## 5. Open questions (recommended answers)

Asked in the board review `GitKittie/review/GITKITTIE-114-onboarding/`.

1. **GitHub sign-in**: *Recommended:* device flow in the system sheet, code on the clipboard, sheet
   closes itself. No server. Alternatives: a one-tap web flow through a token-exchange worker, or
   keep today's flow.
2. **GitLab.com sign-in**: *Recommended:* OAuth with PKCE in the system sheet (Sil registers the
   app). Alternative: keep tokens only.
3. **Providers in the list at first**: *Recommended:* GitHub, GitLab.com, self-hosted GitLab, and
   Forgejo/Gitea by token. Codeberg named with OAuth later. Bitbucket later.
4. **First screen's primary action**: *Recommended:* Sign in with GitHub, with the demo as a text
   link. Alternative: keep the demo first.
5. **Where a new board repo can be created**: *Recommended:* the personal account only at first.
   Organisations need `read:org` and a GitPont call.
6. **Shape of a new board repo**: *Recommended:* the board-repo shape (root README with board
   config, one project folder), the same as the shared tasks repo. Alternative: the repo root is
   the board.
7. **Default lanes**: *Recommended:* the choice on the New Board sheet, with Simple (To do · Doing
   · Done) preselected and Agent workflow (the five contract lanes) one tap away.
8. **What the new README says**: *Recommended:* the config plus a short description of the format,
   linking to the full contract on the website. Alternatives: the full agent contract, or config
   only.
9. **First card**: *Recommended:* one card in To do that explains how the board works.
   Alternative: start empty.
10. **Start without an account**: *Recommended:* iCloud Drive on Mac and iPhone, with Move to a Git
    Repository later. Alternatives: Mac only, or no local start.
11. **More than one account at once**: *Recommended:* yes, as its own card after onboarding ships.
